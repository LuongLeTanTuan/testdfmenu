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
#import <sys/stat.h>
#import <dirent.h>
#import <errno.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <stdio.h>
#import <unistd.h>
#import <stdarg.h>
#include <string.h>
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

// The injected image's own base, so the rebind walk and the hiding layer can
// both recognise "ours" without string matching. Set once from dladdr.
static void *gSelfBase;
static const char *gSelfPath;

static BOOL AnoRebindEverywhere(const char *want, void *replacement, void **outOriginal) {
    BOOL any = NO;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) { gAnoSkipped++; continue; }
        if ((void *)mh == gSelfBase) { gAnoSkipped++; continue; }
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
        static char kEmptyReport[4] = "";
        AnoLog(@"binary report %zu B — MUTED to suppress ban report", n);
        NSLog(@"[AnoMute] binary report (%zu B) — muted", n);
        return kEmptyReport;
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

#pragma mark - image hiding

// anogs imports exactly these four from libdyld:
//   __dyld_image_count, __dyld_get_image_header, __dyld_get_image_name,
//   __dyld_get_image_vmaddr_slide
// Its whole "foreign image" check is that walk: our dylib is image N, its name
// is PxMenu.dylib, and no amount of not-patching-code hides that. Rebind anogs'
// own import slots and the walk returns the stock image list with no extra
// entries -- libdyld itself is never touched, so nothing else in the process
// notices. Same trick as the report exports: no code byte changes.
static uint32_t (*gRealImageCount)(void);
static const struct mach_header *(*gRealImageHeader)(uint32_t);
static const char *(*gRealImageName)(uint32_t);
static intptr_t (*gRealImageSlide)(uint32_t);

// Defined at the bottom; used for dladdr so the image base is taken from the
// loaded Mach-O header rather than guessed from a segment address.
static void AnoMuteEntry(void);

#define kAnoMaxImages 1024
static uint32_t gKeep[kAnoMaxImages];
static uint32_t gKeepCount;
static uint32_t gKeepBuiltFor;

static BOOL AnoIsOurs(const struct mach_header *mh, const char *name) {
    if (mh && (void *)mh == gSelfBase) return YES;
    if (!name) return NO;
    if (gSelfPath && strcmp(name, gSelfPath) == 0) return YES;
    if (strstr(name, "PxMenu") || strstr(name, "AnoMute")) return YES;
    return NO;
}

// Rebuilt whenever the image count changes. dyld never unloads at a constant
// count in this app, so count is a good enough key; a dlclose/dlopen pair that
// keeps the total is the one case this misses.
// shortcut: count-keyed cache, rebuild on every call if that ever bites.
static void AnoBuildKeep(void) {
    uint32_t n = gRealImageCount ? gRealImageCount() : 0;
    if (n == gKeepBuiltFor) return;
    uint32_t take = n > kAnoMaxImages ? kAnoMaxImages : n;
    gKeepCount = 0;
    for (uint32_t i = 0; i < take; i++) {
        const struct mach_header *mh = gRealImageHeader(i);
        const char *nm = gRealImageName(i);
        if (AnoIsOurs(mh, nm)) continue;
        gKeep[gKeepCount++] = i;
    }
    gKeepBuiltFor = n;
}

static uint32_t AnoImageCount(void) {
    AnoBuildKeep();
    return gKeepCount;
}

// The main executable's load commands name the injected dylib. That is the one
// signal no import rebind can remove, because dyld itself needs the command.
// Hand back a private copy of image 0's header with our LC_LOAD_DYLIB entries
// cut out: it still describes a valid image, it just lists one fewer dependency
// than dyld actually loaded.
static uint8_t *gHdrCopy;
static BOOL gHdrTried;

static const struct mach_header *AnoScrubbedHeader(uint32_t realIndex) {
    const struct mach_header_64 *h =
        (const struct mach_header_64 *)gRealImageHeader(realIndex);
    if (!h || h->magic != MH_MAGIC_64 || realIndex != 0) return (const struct mach_header *)h;
    if (gHdrCopy) return (const struct mach_header *)gHdrCopy;
    if (gHdrTried) return (const struct mach_header *)h;

    size_t cap = sizeof(*h) + (size_t)h->sizeofcmds;
    uint8_t *buf = malloc(cap);
    if (!buf) return (const struct mach_header *)h;
    memcpy(buf, h, sizeof(*h));

    uint8_t *dst = buf + sizeof(*h);
    const uint8_t *src = (const uint8_t *)h + sizeof(*h);
    const uint8_t *end = src + h->sizeofcmds;
    uint32_t kept = 0;

    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)src;
        if (lc->cmdsize < sizeof(*lc) || src + lc->cmdsize > end) break;

        BOOL drop = NO;
        if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB ||
            lc->cmd == LC_REEXPORT_DYLIB || lc->cmd == LC_LOAD_UPWARD_DYLIB) {
            const struct dylib_command *dc = (const struct dylib_command *)lc;
            if (dc->dylib.name.offset < lc->cmdsize) {
                const char *dn = (const char *)lc + dc->dylib.name.offset;
                if (AnoIsOurs(NULL, dn)) drop = YES;
            }
        }
        if (!drop) {
            memmove(dst, lc, lc->cmdsize);
            dst += lc->cmdsize;
            kept++;
        }
        src += lc->cmdsize;
    }

    gHdrTried = YES;
    if (kept == h->ncmds) { free(buf); return (const struct mach_header *)h; }

    struct mach_header_64 *out = (struct mach_header_64 *)buf;
    out->ncmds = kept;
    out->sizeofcmds = (uint32_t)(dst - buf) - (uint32_t)sizeof(*h);
    gHdrCopy = buf;
    return (const struct mach_header *)buf;
}

static const struct mach_header *AnoImageHeader(uint32_t i) {
    AnoBuildKeep();
    return (i < gKeepCount) ? AnoScrubbedHeader(gKeep[i]) : NULL;
}

static const char *AnoImageName(uint32_t i) {
    AnoBuildKeep();
    return (i < gKeepCount) ? gRealImageName(gKeep[i]) : NULL;
}

static intptr_t AnoImageSlide(uint32_t i) {
    AnoBuildKeep();
    return (i < gKeepCount) ? gRealImageSlide(gKeep[i]) : 0;
}

#pragma mark - pointer attribution

// proc_regionfilename answers "which file backs this page", and for our pages
// the answer is the injected dylib's path. dladdr answers the same question for
// a single pointer. Both get "unknown" for our range: anogs treats an
// unattributable page the same as a page it never asked about.
static int (*gRealRegionFile)(int, uint64_t, void *, uint32_t);
static int (*gRealDladdr)(const void *, Dl_info *);

static BOOL AnoAddressIsOurs(const void *addr) {
    if (!gSelfBase || !addr) return NO;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)gSelfBase;
    uintptr_t base = (uintptr_t)gSelfBase;
    uintptr_t p = (uintptr_t)addr;
    const struct load_command *lc = (const struct load_command *)((const uint8_t *)mh + sizeof(*mh));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (p >= base + sg->vmaddr && p < base + sg->vmaddr + sg->vmsize) return YES;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    return NO;
}

static int AnoRegionFile(int pid, uint64_t address, void *buffer, uint32_t bufsize) {
    if (AnoAddressIsOurs((const void *)(uintptr_t)address)) return 0;
    return gRealRegionFile ? gRealRegionFile(pid, address, buffer, bufsize) : 0;
}

static int AnoDladdr(const void *addr, Dl_info *info) {
    if (AnoAddressIsOurs(addr)) {
        if (info) memset(info, 0, sizeof(*info));
        return 0;
    }
    return gRealDladdr ? gRealDladdr(addr, info) : 0;
}

// objc_getClass is the only class lookup anogs imports. Refuse our own names so
// a name probe for the menu's classes comes back empty.
static Class (*gRealGetClass)(const char *);

static BOOL AnoIsOurClassName(const char *n) {
    static const char *const ours[] = {
        "PxEntry", "PxOverlay", "PxMenuView", "PxFloatingButton",
        "PxStore", "PxTab", "PxSection", "PxControl", "PxUE4", NULL
    };
    for (int i = 0; ours[i]; i++) if (strcmp(n, ours[i]) == 0) return YES;
    return NO;
}

static Class AnoGetClass(const char *name) {
    if (name && AnoIsOurClassName(name)) return Nil;
    return gRealGetClass ? gRealGetClass(name) : Nil;
}

#pragma mark - detection telemetry

// anogs is the only caller whose behaviour is worth watching, and wrapping libc
// process-wide would put our code on every call in the app. These slots live in
// anogs' own __got, so the wrapper runs for anogs and nothing else.
//
// Nothing is blocked here. A ban followed a scan we have not identified, and
// guessing at which import to silence would trade a week of bans for a crash.
// The log names the call and its argument; the next step is chosen from that.
static BOOL AnoRebindInAnogs(const char *want, void *replacement, void **outOriginal) {
    BOOL any = NO;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        const char *nm = _dyld_get_image_name(i);
        if (!mh || !nm || mh->magic != MH_MAGIC_64) continue;
        if (!strstr(nm, "anogs")) continue;
        if (((const struct mach_header_64 *)mh)->flags & MH_DYLIB_IN_CACHE) continue;
        if (AnoRebindInImage((const struct mach_header_64 *)mh, want, replacement, outOriginal))
            any = YES;
    }
    return any;
}

// Raw file writer for the wrappers below. AnoLog goes through NSString and
// NSFileHandle, and those reach dlopen/dlsym on first use -- which is exactly
// the slot being wrapped, so the wrapper re-enters itself and the stack dies.
// open/write/close are plain syscalls: nothing here can call back into anogs.
static char gRawPath[512];
static volatile int gRawArmed;

static void AnoRawLog(const char *s) {
    if (!gRawArmed || !s || !gRawPath[0]) return;
    int fd = open(gRawPath, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    write(fd, "[AnoMute] ", 11);
    write(fd, s, strlen(s));
    write(fd, "\n", 1);
    close(fd);
}

static void AnoArmRawLog(void) {
    if (gRawArmed) return;
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) return;
    NSString *p = [docs stringByAppendingPathComponent:@"PxBoot.log"];
    if (!p || ![p getFileSystemRepresentation:gRawPath maxLength:sizeof(gRawPath)]) return;
    gRawArmed = 1;
}

// One line per function on first sight, then one per 256 calls: a scan loop can
// call these thousands of times and a log that size cannot be read on a phone.
#define ANO_TRACE(...) do { \
    static int n_; \
    if (n_ == 0 || (n_ & 0xFF) == 0) { \
        char b_[512]; \
        snprintf(b_, sizeof(b_), __VA_ARGS__); \
        char l_[560]; \
        snprintf(l_, sizeof(l_), "#%d %s", n_, b_); \
        AnoRawLog(l_); \
    } \
    n_++; \
} while (0)

static int (*gRealTaskInfo)(task_t, task_flavor_t, task_info_t, mach_msg_type_number_t *);
static kern_return_t (*gRealRegionRecurse)(vm_map_t, vm_address_t *, vm_size_t *,
                                           natural_t *, vm_region_recurse_info_t,
                                           mach_msg_type_number_t *);
static int (*gRealSysctlByName)(const char *, void *, size_t *, void *, size_t);
static void *(*gRealMemmem)(const void *, size_t, const void *, size_t);
static kern_return_t (*gRealVmRead)(vm_map_read_t, vm_address_t, vm_size_t,
                                    vm_offset_t *, mach_msg_type_number_t *);
static int (*gRealStat)(const char *, struct stat *);
static int (*gRealLstat)(const char *, struct stat *);
static int (*gRealAccess)(const char *, int);
static int (*gRealOpen)(const char *, int, ...);
static int (*gRealFstatat)(int, const char *, struct stat *, int);
static int (*gRealOpenat)(int, const char *, int, ...);
static int (*gRealFaccessat)(int, const char *, int, int);
static struct dirent *(*gRealReaddir)(DIR *);
static int (*gRealPidInfo)(int, int, uint64_t, void *, int);

struct PxTaskDyldInfo {
    mach_vm_address_t all_image_info_addr;
    mach_vm_size_t    all_image_info_size;
    integer_t         all_image_info_format;
};

struct PxDyldImageInfo {
    const struct mach_header *imageLoadAddress;
    const char               *imageFilePath;
    uintptr_t                 imageFileModDate;
};

struct PxDyldAllImageInfos {
    uint32_t                        version;
    uint32_t                        infoArrayCount;
    const struct PxDyldImageInfo   *infoArray;
};

static struct PxDyldAllImageInfos gShadowDyldAllInfo;
static struct PxDyldImageInfo gShadowDyldImages[1024];

static int AnoTaskInfo(task_t t, task_flavor_t f, task_info_t out, mach_msg_type_number_t *cnt) {
    int ret = gRealTaskInfo ? gRealTaskInfo(t, f, out, cnt) : KERN_FAILURE;
    if (ret == KERN_SUCCESS && f == 17 && out) { // 17 == TASK_DYLD_INFO
        struct PxTaskDyldInfo *ti = (struct PxTaskDyldInfo *)out;
        if (ti->all_image_info_addr) {
            struct PxDyldAllImageInfos *orig = (struct PxDyldAllImageInfos *)(uintptr_t)ti->all_image_info_addr;
            if (orig->infoArray && orig->infoArrayCount > 0) {
                uint32_t keep = 0;
                uint32_t take = orig->infoArrayCount > 1024 ? 1024 : orig->infoArrayCount;
                for (uint32_t i = 0; i < take; i++) {
                    const struct PxDyldImageInfo *info = &orig->infoArray[i];
                    if (AnoIsOurs(info->imageLoadAddress, info->imageFilePath)) continue;
                    gShadowDyldImages[keep++] = *info;
                }
                gShadowDyldAllInfo = *orig;
                gShadowDyldAllInfo.infoArray = gShadowDyldImages;
                gShadowDyldAllInfo.infoArrayCount = keep;
                ti->all_image_info_addr = (mach_vm_address_t)(uintptr_t)&gShadowDyldAllInfo;
                ANO_TRACE("task_info(TASK_DYLD_INFO) masked %u -> %u images", take, keep);
            }
        }
    }
    return ret;
}

static kern_return_t AnoRegionRecurse(vm_map_t m, vm_address_t *a, vm_size_t *s, natural_t *d,
                                      vm_region_recurse_info_t i, mach_msg_type_number_t *c) {
    if (!gRealRegionRecurse || !a) return KERN_FAILURE;
    kern_return_t kr = gRealRegionRecurse(m, a, s, d, i, c);
    while (kr == KERN_SUCCESS && s && *s > 0 && AnoAddressIsOurs((const void *)*a)) {
        ANO_TRACE("vm_region_recurse_64 skipped our region at 0x%llX", (unsigned long long)*a);
        *a = *a + *s;
        kr = gRealRegionRecurse(m, a, s, d, i, c);
    }
    return kr;
}

static int AnoSysctlByName(const char *name, void *oldp, size_t *oldlenp,
                           void *newp, size_t newlen) {
    ANO_TRACE("sysctlbyname %s", name ? name : "(null)");
    return gRealSysctlByName ? gRealSysctlByName(name, oldp, oldlenp, newp, newlen) : -1;
}

static void *AnoMemmem(const void *hay, size_t hn, const void *needle, size_t nn) {
    ANO_TRACE("memmem hay=%zu needle=%zu", hn, nn);
    return gRealMemmem ? gRealMemmem(hay, hn, needle, nn) : NULL;
}

static kern_return_t AnoVmRead(vm_map_read_t t, vm_address_t a, vm_size_t sz,
                               vm_offset_t *data, mach_msg_type_number_t *cnt) {
    if (AnoAddressIsOurs((const void *)a)) {
        ANO_TRACE("vm_read BLOCKED on our address 0x%llX", (unsigned long long)a);
        return KERN_PROTECTION_FAILURE;
    }
    return gRealVmRead ? gRealVmRead(t, a, sz, data, cnt) : KERN_FAILURE;
}

static BOOL AnoIsSuspiciousPath(const char *p) {
    if (!p) return NO;
    if (strstr(p, "PxMenu") || strstr(p, "AnoMute") || strstr(p, "PxUE4") ||
        strstr(p, "assetdb") || strstr(p, "renderd") || strstr(p, "ShaderCache")) {
        return YES;
    }
    return NO;
}

static int AnoStat(const char *path, struct stat *buf) {
    if (AnoIsSuspiciousPath(path)) {
        ANO_TRACE("stat hidden for %s", path);
        errno = ENOENT;
        return -1;
    }
    return gRealStat ? gRealStat(path, buf) : -1;
}

static int AnoLstat(const char *path, struct stat *buf) {
    if (AnoIsSuspiciousPath(path)) {
        ANO_TRACE("lstat hidden for %s", path);
        errno = ENOENT;
        return -1;
    }
    return gRealLstat ? gRealLstat(path, buf) : -1;
}

static int AnoAccess(const char *path, int mode) {
    if (AnoIsSuspiciousPath(path)) {
        ANO_TRACE("access hidden for %s", path);
        errno = ENOENT;
        return -1;
    }
    return gRealAccess ? gRealAccess(path, mode) : -1;
}

static int AnoOpen(const char *path, int flags, ...) {
    if (AnoIsSuspiciousPath(path)) {
        ANO_TRACE("open hidden for %s", path);
        errno = ENOENT;
        return -1;
    }
    if (!gRealOpen) { errno = ENOSYS; return -1; }
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return gRealOpen(path, flags, mode);
    }
    return gRealOpen(path, flags);
}

// openat / fstatat / faccessat / readdir carry the same hiding as open and stat:
// a scan can enumerate Frameworks/ and then stat each entry, so both ends of
// that path have to answer nothing.
static int AnoOpenat(int fd, const char *path, int flags, ...) {
    if (AnoIsSuspiciousPath(path)) {
        ANO_TRACE("openat hidden for %s", path ? path : "(null)");
        errno = ENOENT;
        return -1;
    }
    if (!gRealOpenat) { errno = ENOSYS; return -1; }
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return gRealOpenat(fd, path, flags, mode);
    }
    return gRealOpenat(fd, path, flags);
}

static int AnoFstatat(int fd, const char *path, struct stat *buf, int flag) {
    if (AnoIsSuspiciousPath(path)) {
        ANO_TRACE("fstatat hidden for %s", path ? path : "(null)");
        errno = ENOENT;
        return -1;
    }
    return gRealFstatat ? gRealFstatat(fd, path, buf, flag) : -1;
}

static int AnoFaccessat(int fd, const char *path, int mode, int flag) {
    if (AnoIsSuspiciousPath(path)) {
        ANO_TRACE("faccessat hidden for %s", path ? path : "(null)");
        errno = ENOENT;
        return -1;
    }
    return gRealFaccessat ? gRealFaccessat(fd, path, mode, flag) : -1;
}

static struct dirent *AnoReaddir(DIR *d) {
    while (gRealReaddir) {
        struct dirent *e = gRealReaddir(d);
        if (!e) return NULL;
        if (!AnoIsSuspiciousPath(e->d_name)) return e;
        ANO_TRACE("readdir hid %s", e->d_name);
    }
    return NULL;
}

// The iOS SDK does not ship libproc.h, so the region-path flavour and its
// per-entry structs are not available here. The value is stable (PROC_PIDREGIONPATHINFO)
// and every path inside the buffer is a fixed-size NUL-terminated char array, so
// the scan below rewrites strings in place instead of walking a struct layout it
// cannot see.
enum { kAnoPidRegionPathInfo = 7, kAnoPidMaxRewrites = 64 };

static int AnoPidInfo(int pid, int flavor, uint64_t arg, void *buf, int size) {
    int r = gRealPidInfo ? gRealPidInfo(pid, flavor, arg, buf, size) : -1;
    if (r <= 0 || !buf || flavor != kAnoPidRegionPathInfo) return r;

    const char *host = (gRealImageName && gRealImageCount && gRealImageCount() > 0)
                       ? gRealImageName(0) : NULL;
    if (!host) return r;
    size_t hlen = strlen(host);
    if (hlen == 0 || hlen >= 1024) return r;

    char *b = (char *)buf;
    int rewrites = 0;
    for (int off = 0; off < r && rewrites < kAnoPidMaxRewrites; off++) {
        if (b[off] == 0) continue;
        if (off > 0 && b[off - 1] != 0) continue;
        size_t len = strnlen(b + off, (size_t)(r - off));
        if (len == 0 || off + (int)len >= r) continue;
        if (!AnoIsSuspiciousPath(b + off)) continue;

        ANO_TRACE("pidinfo path hidden: %s", b + off);
        memset(b + off, 0, len);
        memcpy(b + off, host, hlen < len ? hlen : len);
        rewrites++;
    }
    return r;
}

static void AnoInstallTelemetry(void) {
    gRealTaskInfo         = dlsym(RTLD_DEFAULT, "task_info");
    gRealRegionRecurse    = dlsym(RTLD_DEFAULT, "vm_region_recurse_64");
    gRealSysctlByName     = dlsym(RTLD_DEFAULT, "sysctlbyname");
    gRealMemmem           = dlsym(RTLD_DEFAULT, "memmem");
    gRealVmRead           = dlsym(RTLD_DEFAULT, "vm_read");
    gRealStat             = dlsym(RTLD_DEFAULT, "stat");
    gRealLstat            = dlsym(RTLD_DEFAULT, "lstat");
    gRealAccess           = dlsym(RTLD_DEFAULT, "access");
    gRealOpen             = dlsym(RTLD_DEFAULT, "open");
    gRealFstatat          = dlsym(RTLD_DEFAULT, "fstatat");
    gRealOpenat           = dlsym(RTLD_DEFAULT, "openat");
    gRealFaccessat        = dlsym(RTLD_DEFAULT, "faccessat");
    gRealReaddir          = dlsym(RTLD_DEFAULT, "readdir");
    gRealPidInfo          = dlsym(RTLD_DEFAULT, "proc_pidinfo");

    int n = 0;
    if (gRealTaskInfo && AnoRebindInAnogs("_task_info", (void *)AnoTaskInfo, NULL)) n++;
    if (gRealRegionRecurse && AnoRebindInAnogs("_vm_region_recurse_64", (void *)AnoRegionRecurse, NULL)) n++;
    if (gRealSysctlByName && AnoRebindInAnogs("_sysctlbyname", (void *)AnoSysctlByName, NULL)) n++;
    if (gRealMemmem && AnoRebindInAnogs("_memmem", (void *)AnoMemmem, NULL)) n++;
    if (gRealVmRead && AnoRebindInAnogs("_vm_read", (void *)AnoVmRead, NULL)) n++;
    if (gRealStat && AnoRebindInAnogs("_stat", (void *)AnoStat, NULL)) n++;
    if (gRealLstat && AnoRebindInAnogs("_lstat", (void *)AnoLstat, NULL)) n++;
    if (gRealAccess && AnoRebindInAnogs("_access", (void *)AnoAccess, NULL)) n++;
    if (gRealOpen && AnoRebindInAnogs("_open", (void *)AnoOpen, NULL)) n++;
    if (gRealFstatat && AnoRebindInAnogs("_fstatat", (void *)AnoFstatat, NULL)) n++;
    if (gRealOpenat && AnoRebindInAnogs("_openat", (void *)AnoOpenat, NULL)) n++;
    if (gRealFaccessat && AnoRebindInAnogs("_faccessat", (void *)AnoFaccessat, NULL)) n++;
    if (gRealReaddir && AnoRebindInAnogs("_readdir", (void *)AnoReaddir, NULL)) n++;
    if (gRealPidInfo && AnoRebindInAnogs("_proc_pidinfo", (void *)AnoPidInfo, NULL)) n++;
    AnoLog(@"telemetry & anti-detection: %d/14 imports rebound", n);
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

    // The originals of the hiding layer. Captured before any rebind so the
    // wrappers always call the real libdyld/libproc/libobjc functions.
    gRealImageCount  = dlsym(RTLD_DEFAULT, "_dyld_image_count");
    gRealImageHeader = dlsym(RTLD_DEFAULT, "_dyld_get_image_header");
    gRealImageName   = dlsym(RTLD_DEFAULT, "_dyld_get_image_name");
    gRealImageSlide  = dlsym(RTLD_DEFAULT, "_dyld_get_image_vmaddr_slide");
    gRealRegionFile  = dlsym(RTLD_DEFAULT, "proc_regionfilename");
    gRealDladdr      = dlsym(RTLD_DEFAULT, "dladdr");
    gRealGetClass    = dlsym(RTLD_DEFAULT, "objc_getClass");

    if (!gSelfBase) {
        Dl_info self;
        if (dladdr((const void *)(uintptr_t)&AnoMuteEntry, &self)) {
            gSelfBase = self.dli_fbase;
            gSelfPath = self.dli_fname;
        }
    }
    AnoLog(@"dlsym get=%p ioctl=%p self=%p", gOrigGetReport, gOrigIoctl, gSelfBase);

    // The hiding layer has no dependency on anogs being mapped yet, so it goes
    // in on the first pass -- the earlier it lands, the smaller the window in
    // which a scan sees the injected image.
    if (gRealImageCount && gRealImageHeader && gRealImageName && gRealImageSlide) {
        AnoRebindEverywhere("__dyld_image_count",            (void *)AnoImageCount,  NULL);
        AnoRebindEverywhere("__dyld_get_image_header",       (void *)AnoImageHeader, NULL);
        AnoRebindEverywhere("__dyld_get_image_name",         (void *)AnoImageName,   NULL);
        AnoRebindEverywhere("__dyld_get_image_vmaddr_slide", (void *)AnoImageSlide,  NULL);
    }
    if (gRealRegionFile) AnoRebindEverywhere("_proc_regionfilename", (void *)AnoRegionFile, NULL);
    if (gRealDladdr)     AnoRebindEverywhere("_dladdr",              (void *)AnoDladdr,     NULL);
    if (gRealGetClass)   AnoRebindEverywhere("_objc_getClass",       (void *)AnoGetClass,   NULL);

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
    // anogs is mapped, but mapped is not the same as finished initialising: its
    // constructor is still running on this thread and calls these very imports.
    // Rebinding its slots from inside that window is what took the app down at
    // launch. Three seconds is past the constructor and hours before a match.
    AnoArmRawLog();
    static dispatch_once_t onceTelemetry;
    dispatch_once(&onceTelemetry, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            AnoInstallTelemetry();
        });
    });
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

    // No delay. Every framework the app links is already mapped by the time a
    // dylib appended to LC_LOAD_DYLIB runs its constructor, anogs included, so
    // the hiding layer can go in before the app's own +load chain starts. The
    // 0.5 s hop the old code used left a window where a scan saw the injected
    // image, and it also put the rebind after the first integrity sweep.
    AnoLog(@"install start");
    AnoInstall(0);
}
