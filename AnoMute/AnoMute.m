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
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>

#pragma mark - report buffer

// A const size_t is not a constant expression in C; the buffer needs a macro.
#define kAnoReportCap (256 * 1024)

// One static buffer, never freed: the app may hand the pointer to a queue and
// read it after we return. Freeing here, or returning malloc'd memory that the
// app later passes to AnoSDKFree, is a double-free on arm64.
static char gScrubBuf[kAnoReportCap];

#pragma mark - symbol slots

static BOOL AnoRebindInImage(const struct mach_header_64 *mh, const char *want,
                             void *replacement, void **outOriginal) {
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysym = NULL;
    const struct segment_command_64 *segs[64];
    int segCount = 0;

    const uint8_t *base = (const uint8_t *)mh;
    const struct load_command *lc = (const struct load_command *)(base + sizeof(*mh));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysym = (const struct dysymtab_command *)lc;
        else if (lc->cmd == LC_SEGMENT_64 && segCount < 64)
            segs[segCount++] = (const struct segment_command_64 *)lc;
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!symtab || !dysym) return NO;

    const struct nlist_64 *syms  = (const struct nlist_64 *)(base + symtab->symoff);
    const char            *strs  = (const char *)(base + symtab->stroff);
    const uint32_t        *indir = (const uint32_t *)(base + dysym->indirectsymoff);
    BOOL hit = NO;

    for (int s = 0; s < segCount; s++) {
        const struct segment_command_64 *seg = segs[s];
        const struct section_64 *sect = (const struct section_64 *)((const uint8_t *)seg + sizeof(*seg));
        for (uint32_t i = 0; i < seg->nsects; i++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            if (sect->size == 0) continue;

            uint32_t count = (uint32_t)(sect->size / sizeof(void *));
            void **slots = (void **)(base + sect->offset);
            for (uint32_t k = 0; k < count; k++) {
                uint32_t si = indir[sect->reserved1 + k];
                if (si == INDIRECT_SYMBOL_LOCAL || si == INDIRECT_SYMBOL_ABS) continue;
                if (si >= symtab->nsyms) continue;
                const char *nm = strs + syms[si].n_un.n_strx;
                if (strcmp(nm, want) != 0) continue;

                void **slot = &slots[k];
                // The slot lives in __DATA and dyld already had it writable; a
                // fresh vm_protect is still required because some builds map it
                // RO after binding.
                uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(getpagesize() - 1);
                size_t len = getpagesize();
                vm_protect(mach_task_self(), (vm_address_t)page, len, false,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                if (outOriginal && !*outOriginal) *outOriginal = *slot;
                *slot = replacement;
                vm_protect(mach_task_self(), (vm_address_t)page, len, false,
                           VM_PROT_READ | VM_PROT_EXECUTE);
                hit = YES;
            }
        }
    }
    return hit;
}

static BOOL AnoRebindEverywhere(const char *want, void *replacement, void **outOriginal) {
    BOOL any = NO;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) continue;  // skip arm64e/32-bit slices
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

static size_t AnoScrub(char *buf, size_t n) {
    size_t changed = 0;
    for (int k = 0; kAnoFlagKeys[k]; k++) {
        const char *key = kAnoFlagKeys[k];
        size_t klen = strlen(key);
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
        }
    }
    return changed;
}

#pragma mark - hooked exports

static void *(*gOrigGetReport)(void);
static int   (*gOrigIoctl)(int, void *, void *, void *);

static void AnoDump(const char *tag, const char *p, size_t n) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        dir = [paths.firstObject stringByAppendingPathComponent:@"AnoMute"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    });
    if (!dir || n == 0) return;
    NSString *f = [dir stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%s_%u.txt", tag, (unsigned)time(NULL)]];
    [[NSData dataWithBytes:p length:n] writeToFile:f atomically:YES];
    NSLog(@"[AnoMute] %s %zu bytes -> %@", tag, n, f);
}

// Returns the app's view of the report. Text reports get flags neutralised in
// place-in-copy; binary reports are passed through untouched because there is
// no safe way to edit a format we have not parsed yet.
static void *AnoGetReport(void) {
    if (!gOrigGetReport) return NULL;
    char *p = (char *)gOrigGetReport();
    if (!p) return NULL;

    size_t n = strnlen(p, kAnoReportCap - 1);
    if (n == 0) return p;

    AnoDump("raw", p, n);

    if (!AnoLooksTextual(p, n)) {
        NSLog(@"[AnoMute] binary report (%zu B) — passthrough", n);
        return p;
    }

    memcpy(gScrubBuf, p, n);
    gScrubBuf[n] = '\0';
    size_t changed = AnoScrub(gScrubBuf, n);
    AnoDump("scrubbed", gScrubBuf, n);
    NSLog(@"[AnoMute] report %zu B, %zu flag(s) neutralised", n, changed);
    return changed ? gScrubBuf : p;
}

static int AnoIoctl(int cmd, void *a, void *b, void *c) {
    NSLog(@"[AnoMute] ioctl cmd=%d", cmd);
    return gOrigIoctl ? gOrigIoctl(cmd, a, b, c) : 0;
}

#pragma mark - install

static void AnoInstall(void) {
    // dlsym on RTLD_DEFAULT, not the saved slot value: a lazy slot still holds
    // __stub_helper until first call, and calling that would be fatal.
    gOrigGetReport = dlsym(RTLD_DEFAULT, "AnoSDKGetReportData");
    gOrigIoctl     = dlsym(RTLD_DEFAULT, "AnoSDKIoctl");

    if (!gOrigGetReport) {
        NSLog(@"[AnoMute] anogs not mapped yet, retry");
        return;
    }

    void *tmp = NULL;
    BOOL any = NO;
    any |= AnoRebindEverywhere("_AnoSDKGetReportData",  (void *)AnoGetReport, &tmp);
    any |= AnoRebindEverywhere("_AnoSDKGetReportData2", (void *)AnoGetReport, NULL);
    any |= AnoRebindEverywhere("_AnoSDKGetReportData3", (void *)AnoGetReport, NULL);
    any |= AnoRebindEverywhere("_AnoSDKGetReportData4", (void *)AnoGetReport, NULL);
    if (gOrigIoctl)
        any |= AnoRebindEverywhere("_AnoSDKIoctl", (void *)AnoIoctl, NULL);

    NSLog(@"[AnoMute] rebind %s (orig %p)", any ? "OK" : "MISSED", gOrigGetReport);
}

__attribute__((constructor))
static void AnoMuteEntry(void) {
    // anogs init runs from the host's +load/init chain; 3 s is after that and
    // before the first heartbeat on every build observed so far.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ULL * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        AnoInstall();
    });
}
