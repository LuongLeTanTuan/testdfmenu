// AnoMute — rebinds the host app's import slots for the anogs/ACE report
// exports, dumps every report to Documents/AnoMute/, and scrubs detection
// flags out of the text report before the app paints it into its own packet.
//
// Why slots and not MSHookFunction: anogs snapshots code bytes
// ("inline_hook_opcode_dismatch", "ms_hook_opcode"). Rebinding a
// __la_symbol_ptr / __got entry touches no code page, so there is nothing to
// compare. No substrate is linked or bundled.

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <mach/vm_region.h>
#import <dlfcn.h>
#import <stdarg.h>
#import <string.h>
#import <stdlib.h>

#pragma mark - boot log

// Same file PxMenu writes, so one log answers both questions: did our code run,
// and did the report rebind happen before the process died.
static void AnoLog(NSString *fmt, ...) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        path = docs ? [docs stringByAppendingPathComponent:@"PxBoot.log"] : nil;
    });
    if (!path) return;

    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSData *data = [[NSString stringWithFormat:@"[AnoMute] %@\n", msg] dataUsingEncoding:NSUTF8StringEncoding];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:data attributes:nil];
        return;
    }
    @try { [fh seekToEndOfFile]; [fh writeData:data]; }
    @catch (NSException *e) { }
    [fh closeFile];
}

#pragma mark - report buffer

// A const size_t is not a constant expression in C; the buffer needs a macro.
#define kAnoReportCap (256 * 1024)

// One static buffer, never freed: the app may hand the pointer to a queue and
// read it after we return. Freeing here, or returning malloc'd memory that the
// app later passes to AnoSDKFree, is a double-free on arm64.
static char gScrubBuf[kAnoReportCap];

#pragma mark - symbol slots

// File offsets in a Mach-O are not virtual addresses. For any image where
// __LINKEDIT.fileoff != __LINKEDIT.vmaddr -- true of every binary with a large
// __bss, including the game itself -- `base + symoff` lands in the middle of
// __DATA, and the "symbol table" read from there is heap garbage. The old code
// did exactly that and died inside strcmp before it could log anything.
static const uint8_t *AnoAddrOfFileRange(const struct mach_header_64 *mh,
                                         const struct segment_command_64 **segs,
                                         int segCount, uint64_t textVM,
                                         uint32_t fileoff, uint64_t size) {
    for (int i = 0; i < segCount; i++) {
        const struct segment_command_64 *sg = segs[i];
        if (fileoff < sg->fileoff) continue;
        if ((uint64_t)fileoff + size > sg->fileoff + sg->filesize) continue;
        return (const uint8_t *)mh + (sg->vmaddr - textVM) + (fileoff - sg->fileoff);
    }
    return NULL;
}

static BOOL AnoRebindInImage(const struct mach_header_64 *mh, const char *want,
                             void *replacement, void **outOriginal) {
    // A shared-cache image keeps symoff/indirectsymoff as offsets into the cache
    // file, not into the image, so no arithmetic on `base` can reach them.
    if (mh->flags & MH_DYLIB_IN_CACHE) return NO;

    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysym = NULL;
    const struct segment_command_64 *segs[64];
    int segCount = 0;
    uint64_t textVM = 0;

    const uint8_t *base = (const uint8_t *)mh;
    const struct load_command *lc = (const struct load_command *)(base + sizeof(*mh));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysym = (const struct dysymtab_command *)lc;
        else if (lc->cmd == LC_SEGMENT_64 && segCount < 64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            segs[segCount++] = sg;
            if (strcmp(sg->segname, "__TEXT") == 0) textVM = sg->vmaddr;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!symtab || !dysym || segCount == 0) return NO;

    const struct nlist_64 *syms = (const struct nlist_64 *)AnoAddrOfFileRange(
        mh, segs, segCount, textVM, symtab->symoff,
        (uint64_t)symtab->nsyms * sizeof(struct nlist_64));
    const char *strs = (const char *)AnoAddrOfFileRange(
        mh, segs, segCount, textVM, symtab->stroff, symtab->strsize);
    const uint32_t *indir = (const uint32_t *)AnoAddrOfFileRange(
        mh, segs, segCount, textVM, dysym->indirectsymoff,
        (uint64_t)dysym->nindirectsyms * sizeof(uint32_t));
    if (!syms || !strs || !indir) return NO;

    BOOL hit = NO;
    for (int s = 0; s < segCount; s++) {
        const struct segment_command_64 *seg = segs[s];
        const struct section_64 *sect = (const struct section_64 *)((const uint8_t *)seg + sizeof(*seg));
        for (uint32_t i = 0; i < seg->nsects; i++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            if (sect->size == 0) continue;

            uint32_t count = (uint32_t)(sect->size / sizeof(void *));
            if (sect->reserved1 >= dysym->nindirectsyms) continue;
            if ((uint64_t)sect->reserved1 + count > dysym->nindirectsyms) continue;

            const uint8_t *slotBase = (const uint8_t *)mh + (sect->addr - textVM);
            for (uint32_t k = 0; k < count; k++) {
                uint32_t si = indir[sect->reserved1 + k];
                if (si == INDIRECT_SYMBOL_LOCAL || si == INDIRECT_SYMBOL_ABS) continue;
                if (si >= symtab->nsyms) continue;
                uint32_t strx = syms[si].n_un.n_strx;
                if (strx == 0 || strx >= symtab->strsize) continue;
                if (strcmp(strs + strx, want) != 0) continue;

                void **slot = (void **)(uintptr_t)(slotBase + k * sizeof(void *));
                uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(getpagesize() - 1);
                vm_protect(mach_task_self(), (vm_address_t)page, getpagesize(), false,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                if (outOriginal && !*outOriginal) *outOriginal = *slot;
                *slot = replacement;
                // Leave the page writable. It held a pointer table, dyld may
                // lazy-bind into it later, and forcing it back to RX would turn
                // that into a fault inside the host.
                vm_protect(mach_task_self(), (vm_address_t)page, getpagesize(), false,
                           VM_PROT_READ | VM_PROT_WRITE);
                hit = YES;
            }
        }
    }
    return hit;
}

static uint32_t gAnoScanned, gAnoSkipped;

static BOOL AnoRebindEverywhere(const char *want, void *replacement, void **outOriginal) {
    BOOL any = NO;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) { gAnoSkipped++; continue; }
        if (((const struct mach_header_64 *)mh)->flags & MH_DYLIB_IN_CACHE) { gAnoSkipped++; continue; }
        gAnoScanned++;
        if (AnoRebindInImage((const struct mach_header_64 *)mh, want, replacement, outOriginal))
            any = YES;
    }
    return any;
}

#pragma mark - scrub

// Keys whose value is a detection verdict. Anything else (device model, uid,
// version, timings) is left byte-identical: a report that lost its identity
// fields is as loud as a report that says "detected".
static const char *const kAnoFlagKeys[] = {
    "root_alert", "emu_alert", "cheat_open_id", "s_open_id", "debugger",
    "check_state", "ts2_alert", "9010_alert", "9005_alert", "9014_alert",
    "inline_hook_opcode_dismatch", "ms_hook_opcode", "ms_set_inlie_hook",
    "black_module_macho", "ms_data_crc", "mrpcs_data_crc_error",
    "ms_single_match", "mrpcs_single_data_not_match",
    "ms_common_match", "mrpcs_common_data_not_match",
    NULL
};

static BOOL AnoLooksTextual(const char *p, size_t n) {
    size_t printable = 0, sample = n < 256 ? n : 256;
    if (sample == 0) return NO;
    for (size_t i = 0; i < sample; i++) {
        unsigned char c = (unsigned char)p[i];
        if ((c >= 0x20 && c < 0x7F) || c == '\n' || c == '\r' || c == '\t') printable++;
    }
    return printable * 100 >= sample * 90;
}

static size_t AnoScrub(char *buf, size_t n, NSMutableString *hits) {
    size_t changed = 0;
    for (int k = 0; kAnoFlagKeys[k] != NULL; k++) {
        const char *key = kAnoFlagKeys[k];
        size_t klen = strlen(key);
        BOOL found = NO;
        for (size_t i = 0; i + klen < n; i++) {
            if (memcmp(buf + i, key, klen) != 0) continue;
            // key must start a token, not sit inside a longer identifier
            if (i > 0) {
                char prev = buf[i - 1];
                BOOL boundary = (prev == '|' || prev == ';' || prev == ',' || prev == '&' ||
                                 prev == '\n' || prev == '\r' || prev == ' ' || prev == '{' ||
                                 prev == '"' || prev == '/');
                if (!boundary) continue;
            }
            size_t v = i + klen;
            // "key" bare (root_alert as its own token) or "key:value" / "key=value"
            if (v < n && (buf[v] == '=' || buf[v] == ':')) v++;
            // overwrite the value, keep every separator and the total length
            for (; v < n; v++) {
                char c = buf[v];
                if (c == '|' || c == ';' || c == ',' || c == '&' ||
                    c == '\n' || c == '\r' || c == '"' || c == '}') break;
                buf[v] = '0';
            }
            changed++;
            found = YES;
        }
        if (found && hits) [hits appendFormat:@"%s ", key];
    }
    return changed;
}

#pragma mark - hooked exports

static void *(*gOrigGetReport)(void);
static int   (*gOrigIoctl)(int, void *, void *, void *);

// Writes on a background queue. This runs inside an anti-cheat export on a
// thread we do not own; a synchronous write there can hold a lock the caller is
// waiting on, and a watchdog kill looks exactly like a crash in the boot log.
static void AnoDumpAsync(const char *tag, NSData *data) {
    if (data.length == 0) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        static NSString *dir;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            dir = [paths.firstObject stringByAppendingPathComponent:@"AnoMute"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:nil];
        });
        if (!dir) return;
        NSString *f = [dir stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"%s_%u.txt", tag, (unsigned)time(NULL)]];
        [data writeToFile:f atomically:YES];
        NSLog(@"[AnoMute] %s %lu bytes -> %@", tag, (unsigned long)data.length, f);
    });
}

static void AnoDump(const char *tag, const char *p, size_t n) {
    if (!p || n == 0) return;
    AnoDumpAsync(tag, [NSData dataWithBytes:p length:n]);
}

// How many bytes from `p` to the end of the mapping that contains it, 0 if the
// mapping is gone or unreadable. strnlen on an unterminated buffer walks off the
// end and faults; the report length is not ours to assume, so ask the kernel
// where the page ends first.
static size_t AnoReadableFrom(const void *p) {
    vm_address_t addr = (vm_address_t)p;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS)
        return 0;
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (!(info.protection & VM_PROT_READ)) return 0;
    if ((vm_address_t)p < addr) return 0;
    return (size_t)(addr + size - (vm_address_t)p);
}

// Returns the app's view of the report. Text reports get flags neutralised in
// place-in-copy; binary reports are passed through untouched because there is
// no safe way to edit a format we have not parsed yet.
static void *AnoGetReport(void) {
    if (!gOrigGetReport) return NULL;
    char *p = (char *)gOrigGetReport();
    if (!p) return NULL;

    size_t cap = AnoReadableFrom(p);
    if (cap > kAnoReportCap - 1) cap = kAnoReportCap - 1;
    if (cap == 0) return p;

    size_t n = strnlen(p, cap);
    if (n == 0) return p;

    AnoDump("raw", p, n);

    if (!AnoLooksTextual(p, n)) {
        AnoLog(@"binary report %zu B, passthrough", n);
        NSLog(@"[AnoMute] binary report (%zu B) — passthrough", n);
        return p;
    }

    memcpy(gScrubBuf, p, n);
    gScrubBuf[n] = '\0';
    NSMutableString *hits = [NSMutableString string];
    size_t changed = AnoScrub(gScrubBuf, n, hits);
    AnoDump("scrubbed", gScrubBuf, n);
    // The names matter more than the count: a report carrying black_module_macho
    // or ms_data_crc says which check fired, and a kick that follows one of these
    // lines is the anti-cheat reacting to something this file already knows about.
    AnoLog(@"report %zu B, %zu flag(s): %@", n, changed,
           hits.length ? hits : @"none");
    NSLog(@"[AnoMute] report %zu B, %zu flag(s) neutralised", n, changed);
    return changed ? gScrubBuf : p;
}

static int AnoIoctl(int cmd, void *a, void *b, void *c) {
    NSLog(@"[AnoMute] ioctl cmd=%d", cmd);
    return gOrigIoctl ? gOrigIoctl(cmd, a, b, c) : 0;
}

#pragma mark - install

static void AnoInstall(NSInteger attempt) {
    // Kill switch: drop an empty file named AnoMute.off into the app's Documents
    // folder (Files app, file sharing is on) and relaunch. No reinstall needed to
    // find out whether a later crash is us or the anti-cheat.
    static NSString *offPath;
    static dispatch_once_t oncePath;
    dispatch_once(&oncePath, ^{
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        offPath = docs ? [docs stringByAppendingPathComponent:@"AnoMute.off"] : nil;
    });
    if (offPath && [[NSFileManager defaultManager] fileExistsAtPath:offPath]) {
        AnoLog(@"AnoMute.off present — rebind skipped, reports untouchable");
        return;
    }

    // dlsym on RTLD_DEFAULT, not the saved slot value: a lazy slot still holds
    // __stub_helper until first call, and calling that would be fatal.
    gOrigGetReport = dlsym(RTLD_DEFAULT, "AnoSDKGetReportData");
    gOrigIoctl     = dlsym(RTLD_DEFAULT, "AnoSDKIoctl");
    AnoLog(@"dlsym get=%p ioctl=%p", gOrigGetReport, gOrigIoctl);

    if (!gOrigGetReport) {
        // anogs is dlopen'd by the host, and the order is not guaranteed. The
        // old code gave up after one look and silently never muted anything.
        AnoLog(@"anogs not mapped yet (attempt %ld)", (long)attempt);
        if (attempt < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AnoInstall(attempt + 1);
            });
        }
        return;
    }

    void *tmp = NULL;
    BOOL any = NO;
    gAnoScanned = gAnoSkipped = 0;
    AnoLog(@"walk begin, %u images", _dyld_image_count());
    any |= AnoRebindEverywhere("_AnoSDKGetReportData",  (void *)AnoGetReport, &tmp);
    any |= AnoRebindEverywhere("_AnoSDKGetReportData2", (void *)AnoGetReport, NULL);
    any |= AnoRebindEverywhere("_AnoSDKGetReportData3", (void *)AnoGetReport, NULL);
    any |= AnoRebindEverywhere("_AnoSDKGetReportData4", (void *)AnoGetReport, NULL);
    if (gOrigIoctl)
        any |= AnoRebindEverywhere("_AnoSDKIoctl", (void *)AnoIoctl, NULL);

    AnoLog(@"rebind %s (orig %p) attempt=%ld scanned=%u skipped=%u",
           any ? "OK" : "MISSED", gOrigGetReport, (long)attempt, gAnoScanned, gAnoSkipped);
}

__attribute__((constructor))
static void AnoMuteEntry(void) {
    // Logged at load time, before the delay: if this line is missing from the
    // boot log while PxMenu's constructor line is present, this image never
    // finished loading and the crash is below both of us.
    AnoLog(@"=== AnoMute constructor, %u dyld images ===", (unsigned)_dyld_image_count());

    // 0.5 s: after the host's +load chain has had a chance to dlopen anogs, and
    // early enough to matter -- the old 3 s start was after the reported crash.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AnoLog(@"install start");
        AnoInstall(0);
    });
}
