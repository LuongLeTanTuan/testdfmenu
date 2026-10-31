// PxUE4 — minimal UE4 runtime reader for the DeltaForce client.
//
// Everything here is discovered at runtime by scanning the host image, so the
// module survives game updates. Nothing in the game is patched: we only read
// memory and call UFunction objects through ProcessEvent. That is deliberate —
// the shipped anti-cheat (anogs / Tencent ACE) keeps opcode snapshots and
// reports `inline_hook_opcode_dismatch` on patched code.

#import "PxUE4.h"
#import "PxStore.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <mach/vm_region.h>
#import <QuartzCore/QuartzCore.h>
#import <string.h>
#import <math.h>

static void PxUELog(NSString *fmt, ...);

// ---------------------------------------------------------------- layouts --
// Delta Force ships a modified UE4. The shipped cheat reads UObject::Class at
// +0x08 and the FName at +0x1C; stock 4.23-4.27 uses +0x10 and +0x18. Neither
// number is trusted here: pxCalibrate() scores every candidate tuple against
// the live object array and keeps the one whose names actually resolve. A wrong
// tuple fails closed instead of reading garbage.
enum {
    kUFnFlags    = 0xB8,   // UFunction::FunctionFlags
    kFnNative    = 0x400,  // FUNC_Native
    kObjStride   = 24,     // sizeof(FUObjectItem)
    kNameBlocks  = 0x2000, // FNameEntryAllocator::Blocks capacity
};

static uint32_t g_classOff    = 0x10; // UObject::ClassPrivate   (calibrated)
static uint32_t g_nameOff     = 0x18; // UObject::NamePrivate    (calibrated)
static uint32_t g_outerOff    = 0x20; // UObject::OuterPrivate   (follows nameOff)
static uint32_t g_nameStride  = 1;    // bytes per name-pool index unit
static uint32_t g_nameShift   = 16;   // entries per name block = 1 << shift
static uint32_t g_chunkShift  = 16;   // objects per FUObjectItem chunk
static int32_t  g_arrMaxDelta = 8;    // MaxElements, relative to the chunk slot
static int32_t  g_arrNumDelta = 12;   // NumElements, relative to the chunk slot
static int32_t  g_altMaxDelta;        // the other count layout, kept as a fallback
static int32_t  g_altNumDelta;
static BOOL     g_arrHasAlt;
static BOOL     g_layoutOK;

typedef struct { float x, y, z; } PxVec3;

static inline PxVec3 pxVec3(float x, float y, float z) {
    PxVec3 v = { x, y, z };
    return v;
}
// NaN fails both comparisons; the bounds reject the infinities without pulling
// in <cmath>, which stays global-namespace-clean under ObjC++.
static inline BOOL pxFinite(float v) { return v == v && v > -1e30f && v < 1e30f; }
static inline PxVec3 pxAdd(PxVec3 a, PxVec3 b) { return pxVec3(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline PxVec3 pxSub(PxVec3 a, PxVec3 b) { return pxVec3(a.x - b.x, a.y - b.y, a.z - b.z); }
static inline PxVec3 pxMul(PxVec3 a, float s)  { return pxVec3(a.x * s, a.y * s, a.z * s); }
static inline float  pxDot(PxVec3 a, PxVec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline PxVec3 pxCross(PxVec3 a, PxVec3 b) {
    return pxVec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

// ------------------------------------------------------- readable ranges --
#define PX_MAX_RANGES 8192
static uint64_t g_rangeLo[PX_MAX_RANGES];
static uint64_t g_rangeHi[PX_MAX_RANGES];
static uint8_t  g_rangeW[PX_MAX_RANGES];    // VM_PROT_WRITE
static int      g_rangeCount;
static int      g_hitRegion = -1;           // last region that answered a hit

static void pxBuildRanges(void) {
    g_rangeCount = 0;
    g_hitRegion = -1;
    // vm_region_recurse_64, not mach_vm_region_recurse: the mach_vm header is a
    // deliberate #error on iOS and the 64-bit vm API is the one exported there.
    vm_address_t addr = 0;
    while (g_rangeCount < PX_MAX_RANGES) {
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &addr, &size, &depth,
                                                (vm_region_recurse_info_t)&info, &count);
        if (kr != KERN_SUCCESS || size == 0) break;
        if (!info.is_submap && (info.protection & VM_PROT_READ)) {
            g_rangeLo[g_rangeCount] = addr;
            g_rangeHi[g_rangeCount] = addr + size;
            g_rangeW[g_rangeCount] = (info.protection & VM_PROT_WRITE) ? 1 : 0;
            g_rangeCount++;
        }
        addr += size;
    }
}

static int pxWritableCount(void) {
    int n = 0;
    for (int i = 0; i < g_rangeCount; i++) if (g_rangeW[i]) n++;
    return n;
}

static inline BOOL pxIn(uint64_t a, size_t len) {
    int lo = 0, hi = g_rangeCount - 1;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        if (a < g_rangeLo[mid]) hi = mid - 1;
        else if (a >= g_rangeHi[mid]) lo = mid + 1;
        else return (a + len) <= g_rangeHi[mid];
    }
    return NO;
}

// The scanners walk pointer-dense structures: consecutive candidates usually
// land in the same region, so remembering the last hit turns the common case
// into two compares instead of a ten-step binary search.
static inline BOOL pxInFast(uint64_t a, size_t len) {
    int c = g_hitRegion;
    if (c >= 0 && a >= g_rangeLo[c] && a + len <= g_rangeHi[c]) return YES;
    int lo = 0, hi = g_rangeCount - 1;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        if (a < g_rangeLo[mid]) hi = mid - 1;
        else if (a >= g_rangeHi[mid]) lo = mid + 1;
        else {
            if (a + len > g_rangeHi[mid]) return NO;
            g_hitRegion = mid;
            return YES;
        }
    }
    return NO;
}

static inline BOOL pxRd64(uint64_t a, uint64_t *out) {
    if (a & 7) return NO;
    if (!pxInFast(a, 8)) return NO;
    *out = *(volatile uint64_t *)a;
    return YES;
}
static inline BOOL pxRd32(uint64_t a, uint32_t *out) {
    if (a & 3) return NO;
    if (!pxInFast(a, 4)) return NO;
    *out = *(volatile uint32_t *)a;
    return YES;
}
static inline BOOL pxRd16(uint64_t a, uint16_t *out) {
    if (a & 1) return NO;
    if (!pxInFast(a, 2)) return NO;
    *out = *(volatile uint16_t *)a;
    return YES;
}

// ------------------------------------------------------------- host image --
static uint64_t g_imgBase;
static uint64_t g_imgSlide;
static struct { uint64_t lo, hi; } g_data[8];
static int g_dataCount;
static struct { uint64_t lo, hi; } g_code[4];
static int g_codeCount;

static BOOL pxLoadHostImage(void) {
    g_imgBase = 0;
    g_dataCount = 0;
    g_codeCount = 0;

    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        const char *slash = strrchr(path, '/');
        const char *leaf = slash ? slash + 1 : path;
        if (strcmp(leaf, "DeltaForceClient") != 0) continue;

        const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!hdr || hdr->magic != MH_MAGIC_64) continue;

        g_imgSlide = (uint64_t)_dyld_get_image_vmaddr_slide(i);
        g_imgBase = (uint64_t)hdr;

        const uint8_t *cmd = (const uint8_t *)(hdr + 1);
        for (uint32_t c = 0; c < hdr->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cmd;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
                uint64_t lo = sg->vmaddr + g_imgSlide;
                uint64_t hi = lo + sg->vmsize;
                if (!strncmp(sg->segname, "__DATA", 6) && g_dataCount < 8) {
                    g_data[g_dataCount].lo = lo;
                    g_data[g_dataCount].hi = hi;
                    g_dataCount++;
                } else if (!strncmp(sg->segname, "__TEXT", 6) && g_codeCount < 4) {
                    g_code[g_codeCount].lo = lo;
                    g_code[g_codeCount].hi = hi;
                    g_codeCount++;
                }
            }
            cmd += lc->cmdsize;
        }
        return g_imgBase != 0;
    }
    return NO;
}

static BOOL pxInHostCode(uint64_t a, size_t len) {
    for (int i = 0; i < g_codeCount; i++)
        if (a >= g_code[i].lo && a + len <= g_code[i].hi) return YES;
    return NO;
}

static BOOL pxInHostData(uint64_t a, size_t len) {
    for (int i = 0; i < g_dataCount; i++)
        if (a >= g_data[i].lo && a + len <= g_data[i].hi) return YES;
    return NO;
}

// ---------------------------------------------------------------- globals --
static uint64_t g_nameBlocks;   // &FNameEntryAllocator::Blocks[0]
static uint64_t g_objArray;     // &TUObjectArray::Objects
static uint32_t g_peIndex;      // UObject::ProcessEvent vtable slot
static uint32_t g_objCount;

static BOOL     g_nameCrypted = YES; // ansi name bytes are obfuscated in this build
static uint64_t g_namePool;     // &FNamePool global, decoded from __text
static uint64_t g_uobjArray;    // &FUObjectArray global, decoded from __text
static BOOL     g_staticTried;

static uint64_t g_classGPChar;  // UClass "GPCharacterBase" (informational)
static uint64_t g_classCamMgr;  // UClass "PlayerCameraManager"
static uint64_t g_classActor;   // UClass "Actor"
static uint64_t g_fnActorLoc;
static uint64_t g_fnCamLoc;
static uint64_t g_fnCamRot;
static uint64_t g_fnTeammate;
static uint64_t g_fnHealth;
static uint64_t g_fnHealthMax;

static uint64_t g_descClass;       // UClass "ModularWeaponDesc" (skin path)
static uint64_t g_skinSetter;      // UFunction SetSkin on ModularWeaponDesc
static uint64_t g_appDataClass;     // UClass "ModularWeaponDataComponentAppearance"
static uint64_t g_appDataSetter;    // UFunction SetSkin on appearance data comp
static uint64_t g_appFuncClass;     // UClass "ModularWeaponFuncComponentAppearance"
static uint64_t g_appFuncSetter;    // UFunction SetSkin on appearance func comp

static uint64_t g_camMgr;      // live APlayerCameraManager instance

static NSMutableArray<NSNumber *> *g_charClasses; // UClass pointers for characters
static uint64_t g_charPtrs[64];                   // same set, unboxed for the hot loop
static int g_charPtrCount;
static NSMutableArray<NSNumber *> *g_actors;      // cached character instances
static NSString *g_status = @"not scanned";
static CFTimeInterval g_lastActorScan;
static CFTimeInterval g_lastScan;
static int g_scanAttempts;
static BOOL g_scanning;
static BOOL g_published;   // the one flag the main thread may trust

// ------------------------------------------------------------ name lookup --
// Names are stored obfuscated: the length in the header stays plaintext, and
// every byte is xored with a key derived from it, so the key needs no table.
static void pxUnmask(char *s, uint32_t len) {
    if (!s || len == 0) return;
    uint32_t key;
    switch (len % 9) {
        case 0:  key = (len & 0x1F) + len; break;
        case 1:  key = (len ^ 0xDF) + len; break;
        case 2:  key = (len | 0xCF) + len; break;
        case 3:  key = 33 * len; break;
        case 4:  key = len + (len >> 2); break;
        case 5:  key = 3 * len + 5; break;
        case 6:  key = ((4 * len) | 5) + len; break;
        case 7:  key = ((len >> 4) | 7) + len; break;
        default: key = (len ^ 0xC) + len; break;
    }
    for (uint32_t i = 0; i < len; i++) s[i] = (char)((uint8_t)~(uint8_t)s[i] ^ (uint8_t)(key & 0x80));
}

static BOOL pxNameAt(uint32_t index, char *out, size_t cap) {
    if (!g_nameBlocks || cap < 2) return NO;
    uint32_t block = index >> g_nameShift;
    if (block >= kNameBlocks) return NO;

    uint64_t blk = 0;
    if (!pxRd64(g_nameBlocks + (uint64_t)block * 8, &blk) || blk == 0) return NO;

    uint64_t entry = blk + (uint64_t)(index & ((1u << g_nameShift) - 1)) * g_nameStride;
    uint16_t hdr = 0;
    if (!pxRd16(entry, &hdr)) return NO;

    uint32_t len = hdr >> 1;
    BOOL wide = (hdr & 1) != 0;
    if (len == 0 || len > 200) return NO;

    size_t bytes = wide ? (size_t)len * 2 : len;
    uint64_t strAddr = entry + 2;
    if (!pxIn(strAddr, bytes)) return NO;

    if (!wide) {
        size_t n = MIN(bytes, cap - 1);
        memcpy(out, (const void *)strAddr, n);
        out[n] = 0;
        if (g_nameCrypted) pxUnmask(out, (uint32_t)n);
        return YES;
    }
    uint32_t i = 0;
    for (; i < len && i + 1 < cap; i++) {
        uint16_t w = 0;
        if (!pxRd16(strAddr + i * 2, &w)) break;
        out[i] = (w < 0x80) ? (char)w : '?';
    }
    out[i] = 0;
    return i > 0;
}

static BOOL pxNameOf(uint64_t obj, char *out, size_t cap) {
    uint32_t idx = 0;
    if (!pxRd32(obj + g_nameOff, &idx)) return NO;
    return pxNameAt(idx, out, cap);
}

static BOOL pxClassNameOf(uint64_t obj, char *out, size_t cap) {
    uint64_t cls = 0;
    if (!pxRd64(obj + g_classOff, &cls) || !cls) return NO;
    return pxNameOf(cls, out, cap);
}

// The build that ships this game drops the UObject vtable and keeps Class at
// +0x08 / Name at +0x1C / Outer at +0x10 (stock 4.2x: +0x10 / +0x18 / +0x20).
// Outer never sits at name+8 on both, so the pair is picked together.
static uint32_t pxOuterFor(uint32_t nameOff) {
    return (nameOff == 0x1C) ? 0x10 : 0x20;
}

static inline uint64_t pxOuterOf(uint64_t obj) {
    uint64_t outer = 0;
    if (!pxRd64(obj + g_outerOff, &outer)) return 0;
    return outer;
}

// ---------------------------------------------------------- object array --
static uint32_t pxObjectCount(void) {
    uint32_t n = 0;
    if (g_objArray && pxRd32((uint64_t)((int64_t)g_objArray + g_arrNumDelta), &n)) return n;
    return 0;
}

// Resolves one index in the object array. Chunk count and chunk size are
// runtime values in this build, so the shift is calibrated rather than assumed.
static BOOL pxObjectAt(uint32_t idx, uint64_t *out) {
    if (!g_objArray) return NO;
    uint64_t chunk = 0;
    uint32_t chunkIdx = idx >> g_chunkShift;
    uint32_t within = idx & ((1u << g_chunkShift) - 1);
    if (!pxRd64(g_objArray + (uint64_t)chunkIdx * 8, &chunk) || chunk == 0) return NO;

    uint64_t obj = 0;
    if (!pxRd64(chunk + (uint64_t)within * kObjStride, &obj) || obj == 0) return NO;
    if (obj & 7) return NO;
    if (!pxIn(obj, 0x30)) return NO;
    *out = obj;
    return YES;
}

// Calls `body` for every live UObject. Returns the number of objects visited.
template <typename F>
static uint32_t pxForEachObject(F body) {
    if (!g_objArray) return 0;
    uint32_t num = pxObjectCount();
    if (num == 0 || num > 0x800000) return 0;

    uint32_t visited = 0;
    uint32_t chunkSize = 1u << g_chunkShift;
    uint32_t chunks = (num + chunkSize - 1) >> g_chunkShift;
    for (uint32_t c = 0; c < chunks; c++) {
        for (uint32_t i = 0; i < chunkSize; i++) {
            uint32_t idx = (c << g_chunkShift) + i;
            if (idx >= num) break;
            uint64_t obj = 0;
            if (!pxObjectAt(idx, &obj)) continue;
            visited++;
            body(obj);
        }
    }
    return visited;
}

// --------------------------------------------------------------- discovery --
// GNames and GObjects are heap-backed here: the block pointer array, the chunk
// list and the objects themselves are all malloc'd. Scanning the host's
// __DATA segment therefore finds nothing, which is what the first build did.
// Walk writable VM instead, host data first (a hit there is cheap), and cap the
// total so a bad guess can't stall the scan thread for seconds.
#define PX_SCAN_CAP (768ull << 20)

static uint64_t g_scanBytes;
static double   g_scanMs;
static int      g_nameHits;
static int      g_objHits;
static int      g_objProbes;

template <typename F>
static void pxScanWritable(F body) {
    uint64_t budget = PX_SCAN_CAP;
    uint64_t bytes = 0;
    double t0 = CACurrentMediaTime();

    for (int pass = 0; pass < 2 && bytes < budget; pass++) {
        for (int i = 0; i < g_rangeCount && bytes < budget; i++) {
            if (!g_rangeW[i]) continue;
            BOOL inHost = pxInHostData(g_rangeLo[i], 1);
            if ((pass == 0) != inHost) continue;

            uint64_t p = g_rangeLo[i];
            uint64_t end = g_rangeHi[i];
            uint64_t room = budget - bytes;
            if (end - p > room) end = p + room;
            for (; p + 8 <= end; p += 8) body(p, *(volatile uint64_t *)p);
            bytes += end - g_rangeLo[i];
        }
    }
    g_scanBytes = bytes;
    g_scanMs = (CACurrentMediaTime() - t0) * 1000.0;
}

static BOOL pxFindNamePool(void) {
    const uint8_t kNone[8] = { 0x08, 0x00, 'N', 'o', 'n', 'e', 0x00, 0x00 };
    BOOL found = NO;
    g_nameHits = 0;

    pxScanWritable([&](uint64_t p, uint64_t v) {
        if (found) return;
        if (v < 0x10000 || v > 0x00007FFFFFFFFFFFULL) return;
        if (v & 7) return;
        if (!pxInFast(v, 8)) return;

        const uint8_t *b = (const uint8_t *)v;
        if (memcmp(b, kNone, 6) != 0) return;
        g_nameHits++;

        // Blocks[0] found. Validate the next few slots look like a pool.
        int good = 0;
        for (int k = 1; k <= 4; k++) {
            uint64_t nb = 0;
            if (!pxRd64(p + (uint64_t)k * 8, &nb)) break;
            if (nb == 0) { good++; continue; }
            if (pxIn(nb, 16)) good++;
        }
        if (good < 1) return;

        g_nameBlocks = p;
        g_nameCrypted = NO;    // the raw bytes already spelled "None"
        char tmp[16];
        if (pxNameAt(0, tmp, sizeof(tmp)) && strcmp(tmp, "None") == 0) { found = YES; return; }
        g_nameBlocks = 0;
    });
    return found;
}

static BOOL pxProbeObjectArray(uint64_t slot, int32_t maxDelta, int32_t numDelta,
                               uint32_t *numOut) {
    uint64_t chunks = 0, chunk0 = 0;
    uint32_t maxE = 0, numE = 0;

    if (!pxRd64(slot, &chunks) || chunks == 0 || (chunks & 7)) return NO;
    if (!pxRd32((uint64_t)((int64_t)slot + maxDelta), &maxE)) return NO;
    if (!pxRd32((uint64_t)((int64_t)slot + numDelta), &numE)) return NO;
    if (numE < 1000 || numE > 0x800000) return NO;
    if (maxE < numE || maxE > 0x800000) return NO;

    if (!pxRd64(chunks, &chunk0) || chunk0 == 0) return NO;
    if (!pxIn(chunk0, (uint64_t)kObjStride * 8)) return NO;

    // First entries must be heap pointers whose vtable also lands in the image.
    int plausible = 0;
    for (int i = 0; i < 8; i++) {
        uint64_t obj = 0;
        if (!pxRd64(chunk0 + (uint64_t)i * kObjStride, &obj) || obj == 0) continue;
        if (obj & 7) continue;
        if (!pxIn(obj, 0x30)) continue;
        uint64_t vt = 0;
        if (!pxRd64(obj, &vt) || vt == 0 || (vt & 7)) continue;
        if (!pxIn(vt, 8)) continue;
        plausible++;
    }
    if (plausible < 3) return NO;

    if (numOut) *numOut = numE;
    return YES;
}

static BOOL pxFindObjectArray(void) {
    BOOL found = NO;
    g_objHits = 0;
    g_objProbes = 0;

    pxScanWritable([&](uint64_t p, uint64_t v) {
        if (found) return;
        if (v < 0x10000 || v > 0x00007FFFFFFFFFFFULL) return;
        if (v & 7) return;
        if (!pxInFast(v, 8)) return;

        // Stock TUObjectArray keeps the counts after the chunk list; the
        // shipped cheat reads them before it. Prefer the first that probes
        // clean and keep the other as a calibration fallback.
        static const int32_t kMaxDelta[] = { 0x10, 8, -0xC };
        static const int32_t kNumDelta[] = { 0x14, 12, -8 };
        int picked = -1;
        g_arrHasAlt = NO;
        for (int v2 = 0; v2 < 3; v2++) {
            uint32_t num = 0;
            g_objProbes++;
            if (!pxProbeObjectArray(p, kMaxDelta[v2], kNumDelta[v2], &num)) continue;
            if (picked < 0) {
                picked = v2;
                g_objArray = p;
                g_arrMaxDelta = kMaxDelta[v2];
                g_arrNumDelta = kNumDelta[v2];
                g_objCount = num;
            } else {
                g_altMaxDelta = kMaxDelta[v2];
                g_altNumDelta = kNumDelta[v2];
                g_arrHasAlt = YES;
            }
        }
        if (picked >= 0) { g_objHits++; found = YES; }
    });
    return found;
}

// ------------------------------------------------------- static pointers --
// Both globals are ordinary __DATA slots, and the build keeps the ADRL pairs
// that reach them. Decoding a pattern hit yields the address outright: no heap
// walk, no candidate scoring, nothing to calibrate away.
typedef struct {
    const uint8_t *pat;
    const uint8_t *mask;
    uint32_t len;
    uint32_t step;      // offset from the pattern hit to the adrp
} PxPat;

// 4f d3 ?? ?? 7d 92 ?? ?? ?? ?? ?? ?? ?? 91
static const uint8_t kPatNames[]  = { 0x4F, 0xD3, 0, 0, 0x7D, 0x92, 0, 0, 0, 0, 0, 0, 0, 0x91 };
static const uint8_t kMaskNames[] = { 0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0xFF };

// 94 e0 23 00 91 ?? ?? ?? 94 08 7d 80 52   (FUObjectArray ctor)
static const uint8_t kPatUObj0[]  = { 0x94, 0xE0, 0x23, 0x00, 0x91, 0, 0, 0, 0x94, 0x08, 0x7D, 0x80, 0x52 };
static const uint8_t kMaskUObj0[] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

// 40 20 1e ?? 03 ?? aa ?? 03 ?? aa ?? ?? 40 b9 ?? ?? ?? ?? ?? ?? ?? 91
static const uint8_t kPatUObj4[]  = { 0x40, 0x20, 0x1E, 0, 0x03, 0, 0xAA, 0, 0x03, 0, 0xAA, 0, 0,
                                      0x40, 0xB9, 0, 0, 0, 0, 0, 0, 0, 0x91 };
static const uint8_t kMaskUObj4[] = { 0xFF, 0xFF, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0,
                                      0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0xFF };

static BOOL pxCodeMatch(uint64_t at, const PxPat *p) {
    if (!pxInHostCode(at, p->len)) return NO;
    for (uint32_t i = 0; i < p->len; i++) {
        if (!p->mask[i]) continue;
        if (*(const volatile uint8_t *)(at + i) != p->pat[i]) return NO;
    }
    return YES;
}

// adrp + add #imm, the idiom that reaches a global without a GOT slot.
static BOOL pxAdrlAt(uint64_t at, uint64_t *out) {
    if (!pxInHostCode(at, 8)) return NO;
    uint32_t i0 = *(const volatile uint32_t *)at;
    uint32_t i1 = *(const volatile uint32_t *)(at + 4);
    if ((i0 & 0x9F000000u) != 0x90000000u) return NO;

    int64_t imm = (int64_t)((((i0 >> 5) & 0x7FFFFu) << 2) | ((i0 >> 29) & 3u));
    if (imm & (1 << 20)) imm -= (1 << 21);
    uint64_t addr = (at & ~0xFFFULL) + (uint64_t)imm * 4096;   // wraps for negative imm

    if ((i1 & 0x7F800000u) == 0x11000000u && ((i1 >> 22) & 1u) == 0 &&
        ((i1 >> 5) & 0x1Fu) == (i0 & 0x1Fu))
        addr += (uint64_t)((i1 >> 10) & 0xFFFu);
    *out = addr;
    return YES;
}

// Byte-at-a-time over 300 MB is too slow; hunt the first pattern byte with the
// classic zero-byte trick, then verify the mask at the few hits it turns up.
static uint64_t pxScanCode(const PxPat *p, uint64_t *out) {
    const uint64_t kLo = 0x0101010101010101ULL;
    const uint64_t kHi = 0x8080808080808080ULL;
    const uint64_t splat = kLo * p->pat[0];

    for (int r = 0; r < g_codeCount; r++) {
        uint64_t lo = g_code[r].lo, hi = g_code[r].hi;
        for (uint64_t a = lo; a + 8 <= hi; a += 8) {
            uint64_t v = *(const volatile uint64_t *)a;
            uint64_t x = v ^ splat;
            uint64_t m = (x - kLo) & ~x & kHi;
            while (m) {
                uint32_t hit = __builtin_ctzll(m) >> 3;
                m &= m - 1;
                uint64_t at = a + hit;
                if (!pxCodeMatch(at, p)) continue;
                if (pxAdrlAt(at + p->step, out)) return at;
            }
        }
    }
    return 0;
}

// Blocks sits at a fixed offset inside the pool; which one differs per build, so
// both are tried and the one that resolves index 0 to "None" wins. That check
// also settles whether the name bytes are obfuscated.
static BOOL pxPoolWorks(uint64_t blocks, BOOL *cryptedOut) {
    uint64_t saveBlocks = g_nameBlocks;
    BOOL saveCrypted = g_nameCrypted;
    char nm[16];
    BOOL ok = NO;

    g_nameBlocks = blocks;

    g_nameCrypted = YES;
    if (pxNameAt(0, nm, sizeof(nm)) && strcmp(nm, "None") == 0) { ok = YES; *cryptedOut = YES; }

    if (!ok) {
        g_nameCrypted = NO;
        if (pxNameAt(0, nm, sizeof(nm)) && strcmp(nm, "None") == 0) { ok = YES; *cryptedOut = NO; }
    }

    g_nameBlocks = saveBlocks;
    g_nameCrypted = saveCrypted;
    return ok;
}

static void pxResolveStatics(void) {
    // The pointers are fixed once the image is mapped, but the pool behind them
    // fills in during boot, so the validation gets a few more chances.
    if (g_staticTried >= 8) return;
    if (!g_imgBase) return;
    if (g_nameBlocks && g_objArray) { g_staticTried = 8; return; }
    g_staticTried++;

    static const PxPat kNames = { kPatNames, kMaskNames, 14, 6 };
    static const PxPat kUObj0 = { kPatUObj0, kMaskUObj0, 13, 0x11 };
    static const PxPat kUObj4 = { kPatUObj4, kMaskUObj4, 23, 0x0F };

    if (!g_namePool) pxScanCode(&kNames, &g_namePool);
    if (!g_uobjArray && !pxScanCode(&kUObj0, &g_uobjArray))
        pxScanCode(&kUObj4, &g_uobjArray);

    uint64_t namesAddr = g_namePool, objAddr = g_uobjArray;

    if (namesAddr) {
        static const uint32_t kOff[] = { 0x38, 0x40 };
        for (int i = 0; i < 2 && !g_nameBlocks; i++) {
            uint64_t cand = namesAddr + kOff[i];
            uint64_t deref = 0;
            if (pxPoolWorks(cand, &g_nameCrypted)) {
                g_nameBlocks = cand;
            } else if (pxRd64(cand, &deref) && deref && pxPoolWorks(deref, &g_nameCrypted)) {
                g_nameBlocks = deref;
            }
        }
    }

    if (objAddr) {
        // FUObjectArray::ObjObjects then TUObjectArray::Objects; the counts sit
        // around the chunk slot, which pxProbeObjectArray already knows how to
        // score. Fall back to a read-back if the strict probe says no.
        static const uint32_t kSlot[]     = { 0x20, 0x10 };
        static const int32_t  kMaxDelta[] = { 0x10, 8, -0xC };
        static const int32_t  kNumDelta[] = { 0x14, 12, -8 };

        for (int s = 0; s < 2 && !g_objArray; s++) {
            for (int d = 0; d < 3; d++) {
                uint32_t num = 0;
                if (!pxProbeObjectArray(objAddr + kSlot[s], kMaxDelta[d], kNumDelta[d], &num)) continue;
                g_objArray = objAddr + kSlot[s];
                g_arrMaxDelta = kMaxDelta[d];
                g_arrNumDelta = kNumDelta[d];
                g_objCount = num;
                break;
            }
        }
        if (!g_objArray) {
            g_objArray = objAddr + kSlot[0];
            g_arrMaxDelta = kMaxDelta[0];
            g_arrNumDelta = kNumDelta[0];
            g_objCount = pxObjectCount();
            uint64_t obj = 0;
            int live = 0;
            for (uint32_t i = 0; i < 64; i++) if (pxObjectAt(i, &obj)) live++;
            if (live < 8) g_objArray = 0;
        }
    }

    PxUELog(@"statics: GNames=0x%llX pool=0x%llX crypted=%d GObjects=0x%llX chunks=0x%llX count=0x%X",
            namesAddr, g_nameBlocks, (int)g_nameCrypted, objAddr, g_objArray, g_objCount);
}

// ------------------------------------------------------------- calibration --
static uint64_t g_layoutScore;

static BOOL pxValidIdent(const char *s) {
    size_t n = strlen(s);
    if (n == 0 || n > 120) return NO;
    char c0 = s[0];
    if (!((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z') || c0 == '_')) return NO;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        BOOL ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '_' || c == '/' || c == ':';
        if (!ok) return NO;
    }
    return YES;
}

// A UObject's class is itself a UObject whose class is one of these. Requiring
// the third hop is what separates the real NamePrivate from FName::Number,
// which also resolves to a short valid entry.
static BOOL pxIsMetaClass(const char *s) {
    static const char *kMeta[] = {
        "Class", "BlueprintGeneratedClass", "WidgetBlueprintGeneratedClass",
        "AnimBlueprintGeneratedClass", "ScriptStruct", "Function",
        "Package", "World", "Struct",
    };
    for (int i = 0; i < 9; i++)
        if (strcmp(s, kMeta[i]) == 0) return YES;
    return NO;
}

static int pxScoreTuple(uint32_t classOff, uint32_t nameOff, uint32_t stride,
                        uint32_t nameShift, uint32_t chunkShift) {
    g_classOff = classOff;
    g_nameOff = nameOff;
    g_nameStride = stride;
    g_nameShift = nameShift;
    g_chunkShift = chunkShift;

    uint32_t num = pxObjectCount();
    if (num < 128) return 0;

    uint32_t step = num / 192;
    if (step < 1) step = 1;

    int score = 0, tried = 0;
    uint32_t idx = step;                      // skip object 0, often a stub
    for (; idx < num && tried < 192; idx += step, tried++) {
        uint64_t obj = 0;
        if (!pxObjectAt(idx, &obj)) continue;

        char own[128];
        if (!pxNameOf(obj, own, sizeof(own)) || !pxValidIdent(own)) continue;

        uint64_t cls = 0;
        if (!pxRd64(obj + classOff, &cls) || cls == 0 || (cls & 7)) continue;

        char cname[128];
        if (!pxNameOf(cls, cname, sizeof(cname)) || !pxValidIdent(cname)) continue;

        score += 1;

        uint64_t meta = 0;
        if (!pxRd64(cls + classOff, &meta) || meta == 0 || (meta & 7)) continue;
        char mname[128];
        if (pxNameOf(meta, mname, sizeof(mname)) && pxIsMetaClass(mname)) score += 3;
    }
    return score;
}

// Picks the tuple that explains the most live objects. Runs once per discovery.
static BOOL pxCalibrate(void) {
    if (!g_objArray || !g_nameBlocks) return NO;

    // Order matters: ties keep the first candidate, and the public dump of this
    // exact game (Android, same content) reports Class +0x08 / Name +0x1C /
    // name stride 2 / 1<<18 entries per block. Those go first so a tie lands on
    // the layout the shipped build actually uses instead of a stock guess.
    static const uint32_t kClass[]  = { 0x08, 0x10 };
    static const uint32_t kName[]   = { 0x1C, 0x18 };
    static const uint32_t kStride[] = { 2, 1 };
    static const uint32_t kShift[]  = { 18, 16, 17, 14, 13 };
    static const uint32_t kChunk[]  = { 16, 17 };

    int best = 0;
    uint32_t bClass = kClass[0], bName = kName[0], bStride = kStride[0];
    uint32_t bShift = kShift[0], bChunk = kChunk[0];

    for (int a = 0; a < 2; a++)
    for (int b = 0; b < 2; b++)
    for (int c = 0; c < 2; c++)
    for (int d = 0; d < 5; d++)
    for (int e = 0; e < 2; e++) {
        int sc = pxScoreTuple(kClass[a], kName[b], kStride[c], kShift[d], kChunk[e]);
        if (sc > best) {
            best = sc;
            bClass = kClass[a]; bName = kName[b]; bStride = kStride[c];
            bShift = kShift[d]; bChunk = kChunk[e];
        }
    }

    g_classOff = bClass;
    g_nameOff = bName;
    g_outerOff = pxOuterFor(bName);
    g_nameStride = bStride;
    g_nameShift = bShift;
    g_chunkShift = bChunk;
    g_layoutScore = (uint64_t)best;
    g_layoutOK = best >= 96;            // >= 50% of the 192-object sample
    return g_layoutOK;
}

// ProcessEvent is inherited unmodified by every UObject, so its slot holds the
// same function pointer across all class vtables. That is the fingerprint we
// use — plus the function body must read UFunction::FunctionFlags at [x1+0xB8].
static BOOL pxBodyReadsFunctionFlags(uint64_t fn) {
    if (!pxInHostCode(fn, 0x40)) return NO;
    const uint32_t *w = (const uint32_t *)fn;
    for (int i = 0; i < 0x400 / 4; i++) {
        if (!pxInHostCode((uint64_t)(w + i), 4)) break;
        uint32_t insn = w[i];
        // ldr w<Rt>, [x1, #0xb8]   (Rn = 1, imm12 = 0x2e); Rt is the low 5 bits
        if ((insn & 0xFFFFFFE0u) == 0xB940B820u) return YES;
    }
    return NO;
}

static BOOL pxFindProcessEvent(void) {
    uint64_t vt[512];
    int vtCount = 0;
    uint32_t seen = 0, stride = 1;

    uint32_t num = pxObjectCount();
    if (num > 4096) stride = num / 1024;

    uint64_t lastVt = 0;
    pxForEachObject([&](uint64_t obj) {
        if (vtCount >= 512) return;
        seen++;
        if (stride > 1 && (seen % stride) != 0) return;
        uint64_t v = 0;
        if (!pxRd64(obj, &v) || v == 0 || v == lastVt) return;
        lastVt = v;
        vt[vtCount++] = v;
    });

    if (vtCount < 32) return NO;

    uint32_t bestIdx = 0, bestCount = 0;
    for (uint32_t idx = 0x10; idx < 0x200 && idx < 0x1000; idx++) {
        uint64_t ref = 0;
        if (!pxRd64(vt[0] + (uint64_t)idx * 8, &ref) || ref == 0) continue;
        if (!pxInHostCode(ref, 0x20)) continue;

        uint32_t same = 0;
        for (int k = 0; k < vtCount; k++) {
            uint64_t v = 0;
            if (pxRd64(vt[k] + (uint64_t)idx * 8, &v) && v == ref) same++;
        }
        if (same < (uint32_t)(vtCount * 0.85f)) continue;
        if (same <= bestCount) continue;
        if (!pxBodyReadsFunctionFlags(ref)) continue;

        bestIdx = idx;
        bestCount = same;
    }
    if (bestIdx == 0) return NO;
    g_peIndex = bestIdx;
    return YES;
}

// ------------------------------------------------------------- ufunction --
static void pxInvoke(uint64_t obj, uint64_t fn, void *parms) {
    if (!obj || !fn || !g_peIndex) return;
    if (!pxIn(obj, 8) || !pxIn(fn + kUFnFlags, 4)) return;

    uint32_t *flags = (uint32_t *)(fn + kUFnFlags);
    uint32_t saved = *flags;
    *flags = saved | kFnNative;

    void **vtable = *(void ***)obj;
    if (vtable && pxIn((uint64_t)vtable, (uint64_t)(g_peIndex + 1) * 8)) {
        void *entry = vtable[g_peIndex];
        if (entry && pxInHostCode((uint64_t)entry, 8)) {
            ((void (*)(void *, void *, void *))entry)((void *)obj, (void *)fn, parms);
        }
    }
    *flags = saved;
}

static uint64_t pxFindClass(const char *wanted) {
    uint64_t found = 0;
    pxForEachObject([&](uint64_t obj) {
        if (found) return;
        char cls[128];
        if (!pxClassNameOf(obj, cls, sizeof(cls))) return;
        if (strcmp(cls, "Class") != 0) return;
        char nm[128];
        if (!pxNameOf(obj, nm, sizeof(nm))) return;
        if (strcmp(nm, wanted) == 0) found = obj;
    });
    return found;
}

static uint64_t pxFindFunction(uint64_t owner, const char *name) {
    uint64_t found = 0;
    pxForEachObject([&](uint64_t obj) {
        if (found) return;
        char cls[128];
        if (!pxClassNameOf(obj, cls, sizeof(cls))) return;
        if (strcmp(cls, "Function") != 0) return;
        uint64_t outer = pxOuterOf(obj);
        if (outer != owner) return;
        char nm[128];
        if (!pxNameOf(obj, nm, sizeof(nm))) return;
        if (strcmp(nm, name) == 0) found = obj;
    });
    return found;
}

// --------------------------------------------------------------- entities --
static BOOL pxProject(PxVec3 world, PxVec3 camLoc, PxVec3 right, PxVec3 up, PxVec3 fwd,
                      CGSize size, float tanHalfH, CGPoint *out) {
    PxVec3 d = pxSub(world, camLoc);
    float z = pxDot(d, fwd);
    if (z < 1.0f) return NO;
    float x = pxDot(d, right);
    float y = pxDot(d, up);

    float aspect = (float)(size.width / MAX(size.height, 1.0f));
    float tanHalfV = tanHalfH / MAX(aspect, 0.0001f);

    out->x = size.width * 0.5f + (x / z) * (size.width * 0.5f) / tanHalfH;
    out->y = size.height * 0.5f - (y / z) * (size.height * 0.5f) / tanHalfV;
    return YES;
}

static void pxCameraBasis(float pitchDeg, float yawDeg, PxVec3 *fwd, PxVec3 *right, PxVec3 *up) {
    const float d2r = (float)M_PI / 180.0f;
    float p = pitchDeg * d2r, y = yawDeg * d2r;
    PxVec3 f = pxVec3(cosf(p) * cosf(y), cosf(p) * sinf(y), sinf(p));
    PxVec3 worldUp = pxVec3(0, 0, 1);
    PxVec3 r = pxCross(f, worldUp);
    if (pxDot(r, r) < 1e-4f) r = pxVec3(0, 1, 0);
    float rl = sqrtf(pxDot(r, r));
    r = pxMul(r, 1.0f / rl);
    PxVec3 u = pxCross(r, f);
    float ul = sqrtf(pxDot(u, u));
    u = pxMul(u, 1.0f / MAX(ul, 1e-4f));

    *fwd = f;
    *right = r;
    *up = u;
}

// A failed scan leaves a line in PxBoot.log next to the boot markers, so one
// log answers "did discovery run, how much did it walk, what did it hit".
static void PxUELog(NSString *fmt, ...) {
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

    NSString *line = [NSString stringWithFormat:@"[%9.3f] [ue4] %@\n", CACurrentMediaTime(), msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) { [data writeToFile:path atomically:NO]; return; }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try { [fh seekToEndOfFile]; [fh writeData:data]; }
    @catch (NSException *e) { }
    [fh closeFile];
}

// g_status is read from the main thread; assign it there.
static void pxSetStatus(NSString *s) {
    dispatch_async(dispatch_get_main_queue(), ^{ g_status = s; });
}

static dispatch_queue_t pxScanQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("px.ue4.scan", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(q, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return q;
}

// -------------------------------------------------------------------- dump --
// A live SDK dump, written by the process itself. No jailbreak, no external
// tool: once the object array and name pool resolve, everything the game knows
// about its own classes is reachable. Struct offsets below come from the public
// AndUEDumper output for this exact game (same content, same UE branch).
enum {
    kStructSuper      = 0x40,   // UStruct::SuperStruct
    kStructChildProps = 0x68,   // UStruct::ChildProperties (FField chain)
    kFieldNext        = 0x18,   // FField::Next
    kFieldName        = 0x28,   // FField::NamePrivate (FName)
    kPropArrayDim     = 0x38,
    kPropElemSize     = 0x3C,
    kPropFlags        = 0x40,
    kPropOffset       = 0x4C,
};

static BOOL pxFieldName(uint64_t field, char *out, size_t cap) {
    uint32_t idx = 0;
    if (!pxRd32(field + kFieldName, &idx)) return NO;
    return pxNameAt(idx, out, cap);
}

static void pxDumpSDK(NSMutableString *summary) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) return;
    NSString *dir = [docs stringByAppendingPathComponent:@"DUMP"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:nil error:nil];

    NSMutableString *objs = [NSMutableString stringWithCapacity:4 << 20];
    [objs appendString:@"idx\tclass\tname\touter\taddr\n"];
    uint32_t idx = 0;
    pxForEachObject([&](uint64_t obj) {
        if (idx >= 250000) return;
        char cls[128] = { 0 }, nm[128] = { 0 }, onm[128] = { 0 };
        pxClassNameOf(obj, cls, sizeof(cls));
        pxNameOf(obj, nm, sizeof(nm));
        uint64_t outer = pxOuterOf(obj);
        if (outer) pxNameOf(outer, onm, sizeof(onm));
        [objs appendFormat:@"%u\t%s\t%s\t%s\t0x%llX\n", idx++, cls, nm, onm, obj];
    });
    [objs writeToFile:[dir stringByAppendingPathComponent:@"Objects.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSMutableString *cls = [NSMutableString stringWithCapacity:8 << 20];
    uint32_t classes = 0, props = 0;
    pxForEachObject([&](uint64_t obj) {
        if (classes >= 30000) return;
        char cname[128] = { 0 };
        if (!pxClassNameOf(obj, cname, sizeof(cname))) return;
        if (strcmp(cname, "Class") != 0) return;

        char nm[128] = { 0 }, sup[128] = { 0 };
        if (!pxNameOf(obj, nm, sizeof(nm))) return;
        uint64_t super = 0;
        if (pxRd64(obj + kStructSuper, &super) && super) pxNameOf(super, sup, sizeof(sup));

        [cls appendFormat:@"class %s : %s\n", nm, sup[0] ? sup : "?"];
        classes++;

        uint64_t field = 0;
        if (!pxRd64(obj + kStructChildProps, &field)) { [cls appendString:@"\n"]; return; }
        for (int i = 0; i < 400 && field; i++) {
            char fname[128] = { 0 };
            uint32_t off = 0, dim = 0, elem = 0, flags = 0;
            BOOL ok = pxFieldName(field, fname, sizeof(fname)) &&
                      pxRd32(field + kPropOffset, &off) &&
                      pxRd32(field + kPropArrayDim, &dim) &&
                      pxRd32(field + kPropElemSize, &elem) &&
                      pxRd32(field + kPropFlags, &flags);
            if (ok) {
                [cls appendFormat:@"  0x%04X  %-40s dim=%u elem=%u flags=0x%08X\n",
                    off, fname, dim, elem, flags];
                props++;
            }
            uint64_t next = 0;
            if (!pxRd64(field + kFieldNext, &next)) break;
            if (next == field) break;
            field = next;
        }
        [cls appendString:@"\n"];
    });
    [cls writeToFile:[dir stringByAppendingPathComponent:@"Classes.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];

    if (summary) {
        [summary appendFormat:@"dump           %u objects, %u classes, %u properties -> %@\n",
            idx, classes, props, dir];
    }
}

// ------------------------------------------------------------------- API --
@implementation PxUE4

+ (instancetype)shared {
    static PxUE4 *ue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ue = [[PxUE4 alloc] init]; });
    return ue;
}

- (BOOL)ready {
    return g_published;
}

- (void)invalidate {
    g_nameBlocks = 0;
    g_objArray = 0;
    g_peIndex = 0;
    g_objCount = 0;
    g_namePool = 0;
    g_uobjArray = 0;
    g_staticTried = NO;
    g_nameCrypted = YES;
    g_layoutOK = NO;
    g_layoutScore = 0;
    g_arrHasAlt = NO;
    g_classOff = 0x10;
    g_nameOff = 0x18;
    g_outerOff = 0x20;
    g_nameStride = 1;
    g_nameShift = 16;
    g_chunkShift = 16;
    g_fnActorLoc = g_fnCamLoc = g_fnCamRot = 0;
    g_fnTeammate = g_fnHealth = g_fnHealthMax = 0;
    g_descClass = g_skinSetter = 0;
    g_appDataClass = g_appDataSetter = 0;
    g_appFuncClass = g_appFuncSetter = 0;
    g_classGPChar = g_classCamMgr = g_classActor = 0;
    g_camMgr = 0;
    [g_charClasses removeAllObjects];
    g_charPtrCount = 0;
    [g_actors removeAllObjects];
    g_lastActorScan = 0;
    g_scanAttempts = 0;
    g_published = NO;
    g_status = @"reset";
}

- (void)scanIfNeeded {
    if (self.ready || g_scanning) return;
    // A full pass walks every writable page; 60 attempts covers a slow boot
    // without hammering the device forever if the layout never shows up.
    if (g_scanAttempts > 60) return;

    CFTimeInterval now = CACurrentMediaTime();
    // Back off after the first few attempts: a pass costs a second of CPU and a
    // retry every 1.5 s forever would just burn the device.
    double gap = g_scanAttempts < 8 ? 1.5 : 5.0;
    if (now - g_lastScan < gap) return;
    g_lastScan = now;
    g_scanAttempts++;

    // Discovery is pure reads, but a pass can take a second on a cold heap and
    // the render loop must not wait on it.
    g_scanning = YES;
    dispatch_async(pxScanQueue(), ^{
        [self scanOnce];
        g_scanning = NO;
    });
}

- (void)scanOnce {
    pxBuildRanges();                 // the heap grows between attempts
    if (!g_imgBase && !pxLoadHostImage()) { pxSetStatus(@"host image not found"); return; }

    pxResolveStatics();              // static globals first: no heap walk needed

    if (!g_nameBlocks && !pxFindNamePool()) {
        pxSetStatus(@"GNames not found");
        PxUELog(@"GNames miss: %d candidate pointers, %.1f MB in %.0f ms",
                g_nameHits, g_scanBytes / 1048576.0, g_scanMs);
        return;
    }
    if (!g_objArray && !pxFindObjectArray()) {
        pxSetStatus(@"GObjects not found");
        PxUELog(@"GObjects miss: %d hits, %d probes, %.1f MB in %.0f ms",
                g_objHits, g_objProbes, g_scanBytes / 1048576.0, g_scanMs);
        return;
    }
    if (!g_layoutOK && !pxCalibrate()) {
        // The array matched both count layouts structurally; try the other one
        // before giving up.
        if (g_arrHasAlt) {
            int32_t m = g_arrMaxDelta, n = g_arrNumDelta;
            g_arrMaxDelta = g_altMaxDelta;
            g_arrNumDelta = g_altNumDelta;
            g_altMaxDelta = m;
            g_altNumDelta = n;
            if (!pxCalibrate()) {
                g_arrMaxDelta = m;
                g_arrNumDelta = n;
            } else {
                g_objCount = pxObjectCount();
            }
        }
    }
    if (!g_layoutOK) {
        pxSetStatus([NSString stringWithFormat:@"layout calibration failed (score %llu)", g_layoutScore]);
        PxUELog(@"layout calibration failed: gnames=0x%llX gobjects=0x%llX count=0x%X score=%llu",
                g_nameBlocks, g_objArray, g_objCount, g_layoutScore);
        return;
    }
    if (!g_peIndex && !pxFindProcessEvent()) { pxSetStatus(@"ProcessEvent index not found"); return; }

    if (!g_classGPChar)  g_classGPChar = pxFindClass("GPCharacterBase");
    if (!g_classCamMgr)  g_classCamMgr = pxFindClass("PlayerCameraManager");
    if (!g_classActor)   g_classActor = pxFindClass("Actor");

    g_fnActorLoc = g_classActor ? pxFindFunction(g_classActor, "K2_GetActorLocation") : 0;

    if (g_classCamMgr) {
        g_fnCamLoc = pxFindFunction(g_classCamMgr, "GetCameraLocation");
        g_fnCamRot = pxFindFunction(g_classCamMgr, "GetCameraRotation");
    }
    if (g_classGPChar) {
        g_fnTeammate  = pxFindFunction(g_classGPChar, "BP_IsCharacterTeammate");
        g_fnHealth    = pxFindFunction(g_classGPChar, "GetHealth");
        g_fnHealthMax = pxFindFunction(g_classGPChar, "GetHealthMax");
    }

    if (!g_charClasses) g_charClasses = [NSMutableArray array];
    if (g_charClasses.count == 0) {
        pxForEachObject([](uint64_t obj) {
            if (g_charClasses.count >= 64) return;
            char cls[128];
            if (!pxClassNameOf(obj, cls, sizeof(cls))) return;
            if (strcmp(cls, "Class") != 0) return;
            char nm[128];
            if (!pxNameOf(obj, nm, sizeof(nm))) return;
            if (!strstr(nm, "Character")) return;
            [g_charClasses addObject:@(obj)];
        });
        g_charPtrCount = 0;
        for (NSNumber *n in g_charClasses)
            if (g_charPtrCount < 64) g_charPtrs[g_charPtrCount++] = n.unsignedLongLongValue;
    }

    if (!g_actors) g_actors = [NSMutableArray array];

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"img=0x%llX gnames=0x%llX gobjects=0x%llX(0x%X) pe=0x%X",
        g_imgBase, g_nameBlocks, g_objArray, g_objCount, g_peIndex];
    [s appendFormat:@" layout[cls=%X name=%X stride=%u shift=%u chunk=%u score=%llu]",
        g_classOff, g_nameOff, g_nameStride, g_nameShift, g_chunkShift, g_layoutScore];
    [s appendFormat:@" charClasses=%lu", (unsigned long)g_charClasses.count];
    [s appendFormat:@" fn[loc=%llX cam=%llX/%llX team=%llX hp=%llX/%llX]",
        g_fnActorLoc, g_fnCamLoc, g_fnCamRot, g_fnTeammate, g_fnHealth, g_fnHealthMax];
    pxSetStatus(s);

    // Publish point: ready is the last flag set, and the fence keeps the rest of
    // the discovery visible to the thread that starts reading right after it.
    __sync_synchronize();
    g_published = YES;
    PxUELog(@"ready: %@", s);
}

static void pxRefreshActors(void) {
    if (!g_actors) g_actors = [NSMutableArray array];
    [g_actors removeAllObjects];

    if (g_camMgr || g_classCamMgr) {
        // An exact compare against the base UClass never hits. The shipped class
        // is "DFMPlayerCameraManager" (the binary registers APlayerCameraManager,
        // ADFMPlayerCameraManager, AGPPlayerCameraManager), and any subclass of
        // the base breaks equality the same way. Match the class-name tail, the
        // same relaxed rule the character scan below already uses.
        static const char kCamTail[] = "PlayerCameraManager";
        uint64_t cam = 0;
        pxForEachObject([&](uint64_t obj) {
            if (cam) return;
            uint64_t cls = 0;
            if (!pxRd64(obj + g_classOff, &cls) || cls == 0) return;
            char cn[128] = { 0 };
            if (!pxNameOf(cls, cn, sizeof(cn))) return;
            size_t n = strlen(cn), k = sizeof(kCamTail) - 1;
            if (n < k || strcmp(cn + n - k, kCamTail) != 0) return;
            if (!pxIn(obj, 8) || !(*(void **)obj)) return;
            cam = obj;
        });
        if (cam) g_camMgr = cam;
    }

    if (g_charPtrCount == 0) return;

    pxForEachObject([&](uint64_t obj) {
        if (g_actors.count >= 160) return;
        uint64_t cls = 0;
        if (!pxRd64(obj + g_classOff, &cls) || cls == 0) return;
        BOOL wanted = NO;
        for (int i = 0; i < g_charPtrCount; i++)
            if (g_charPtrs[i] == cls) { wanted = YES; break; }
        if (!wanted) return;
        [g_actors addObject:@(obj)];
    });
}

// The local pawn is the character whose origin sits on top of the camera.
static uint64_t pxLocalPawn(PxVec3 camLoc) {
    if (!g_fnActorLoc) return 0;
    alignas(16) uint8_t parms[64];
    for (NSNumber *n in g_actors) {
        uint64_t obj = n.unsignedLongLongValue;
        memset(parms, 0, sizeof(parms));
        pxInvoke(obj, g_fnActorLoc, parms);
        PxVec3 p = pxVec3(*(float *)(parms + 0), *(float *)(parms + 4), *(float *)(parms + 8));
        if (!pxFinite(p.x) || !pxFinite(p.y) || !pxFinite(p.z)) continue;
        PxVec3 d = pxSub(p, camLoc);
        if (sqrtf(pxDot(d, d)) < 150.0f) return obj;
    }
    return 0;
}

- (NSUInteger)collectEntities:(PxEntity *)out max:(NSUInteger)max viewSize:(CGSize)size {
    if (!self.ready || !out || max == 0) return 0;
    if (size.width < 2 || size.height < 2) return 0;

    CFTimeInterval now = CACurrentMediaTime();
    if (now - g_lastActorScan > 2.0) {
        pxRefreshActors();
        g_lastActorScan = now;
    }
    if (g_actors.count == 0) return 0;

    // Camera: cached APlayerCameraManager instance, refreshed with the actors.
    uint64_t camMgr = g_camMgr;
    if (!camMgr) {
        pxRefreshActors();
        g_lastActorScan = now;
        camMgr = g_camMgr;
    }
    if (!camMgr || !g_fnCamLoc || !g_fnCamRot) return 0;

    alignas(16) uint8_t parms[64];
    memset(parms, 0, sizeof(parms));
    pxInvoke(camMgr, g_fnCamLoc, parms);
    PxVec3 camLoc = pxVec3(*(float *)(parms + 0), *(float *)(parms + 4), *(float *)(parms + 8));

    memset(parms, 0, sizeof(parms));
    pxInvoke(camMgr, g_fnCamRot, parms);
    float pitch = *(float *)(parms + 0);
    float yaw   = *(float *)(parms + 4);

    PxVec3 fwd, right, up;
    pxCameraBasis(pitch, yaw, &fwd, &right, &up);

    // Box is built on a horizontal basis so pitch does not shear the volume.
    PxVec3 hFwd = pxVec3(fwd.x, fwd.y, 0);
    float hl = sqrtf(pxDot(hFwd, hFwd));
    hFwd = (hl > 1e-4f) ? pxMul(hFwd, 1.0f / hl) : pxVec3(1, 0, 0);

    float fov = [PxStore floatForKey:@"esp_fov"];
    if (fov < 20.0f || fov > 170.0f) fov = 90.0f;
    float tanHalfH = tanf(fov * 0.5f * (float)M_PI / 180.0f);
    if (tanHalfH < 0.01f) return 0;

    float maxDist = [PxStore floatForKey:@"esp_max_dist"];
    if (maxDist <= 0.0f) maxDist = 400.0f;
    BOOL wantHealth = [PxStore boolForKey:@"esp_health"];
    BOOL teamCheck = [PxStore boolForKey:@"esp_team_check"];

    // Local pawn = the character standing on top of the camera.
    uint64_t self_ = pxLocalPawn(camLoc);

    NSUInteger count = 0;
    for (NSNumber *n in g_actors) {
        if (count >= max) break;
        uint64_t actor = n.unsignedLongLongValue;
        if (actor == self_) continue;

        memset(parms, 0, sizeof(parms));
        pxInvoke(actor, g_fnActorLoc, parms);
        PxVec3 feet = pxVec3(*(float *)(parms + 0), *(float *)(parms + 4), *(float *)(parms + 8));
        if (!pxFinite(feet.x) || !pxFinite(feet.y) || !pxFinite(feet.z)) continue;

        PxVec3 dv = pxSub(feet, camLoc);
        float dist = sqrtf(pxDot(dv, dv));
        if (dist < 150.0f) continue;                 // self
        if (dist > maxDist * 100.0f) continue;       // slider is metres

        if (teamCheck && self_ && g_fnTeammate) {
            memset(parms, 0, sizeof(parms));
            *(uint64_t *)parms = self_;
            pxInvoke(actor, g_fnTeammate, parms);
            if (parms[8]) continue;
        }

        float hp = -1.0f, hpMax = -1.0f;
        if (wantHealth && g_fnHealth) {
            memset(parms, 0, sizeof(parms));
            pxInvoke(actor, g_fnHealth, parms);
            hp = *(float *)parms;
            if (g_fnHealthMax) {
                memset(parms, 0, sizeof(parms));
                pxInvoke(actor, g_fnHealthMax, parms);
                hpMax = *(float *)parms;
            }
        }
        if (hp == 0.0f && hpMax > 0.0f) continue;    // dead

        // Camera-facing box, 80 x 80 x 175 cm around the actor origin.
        int valid = 0;
        float minX = 1e9f, minY = 1e9f, maxX = -1e9f, maxY = -1e9f;
        for (int c = 0; c < 8; c++) {
            float sx = (c & 1) ? 40.0f : -40.0f;
            float sy = (c & 2) ? 40.0f : -40.0f;
            float sz = (c & 4) ? 175.0f : 0.0f;
            PxVec3 corner = pxAdd(pxAdd(feet, pxMul(right, sx)), pxMul(hFwd, sy));
            corner.z = feet.z + sz;

            CGPoint sp;
            if (!pxProject(corner, camLoc, right, up, fwd, size, tanHalfH, &sp)) { valid = -1; break; }
            minX = MIN(minX, (float)sp.x); maxX = MAX(maxX, (float)sp.x);
            minY = MIN(minY, (float)sp.y); maxY = MAX(maxY, (float)sp.y);
            valid++;
        }
        if (valid != 8) continue;
        if (maxX < -200 || minX > size.width + 200) continue;
        if (maxY < -200 || minY > size.height + 200) continue;

        PxEntity e;
        e.rect = CGRectMake(minX, minY, MAX(maxX - minX, 2.0f), MAX(maxY - minY, 2.0f));
        e.distance = dist / 100.0f;
        e.health = hp < 0 ? -1 : hp;
        e.healthMax = hpMax;
        out[count++] = e;
    }
    return count;
}

- (NSString *)statusLine {
    if (!g_objArray) return [NSString stringWithFormat:@"ue4: %@", g_status];
    return [NSString stringWithFormat:@"ue4: obj=0x%X actors=%lu pe=0x%X",
            g_objCount, (unsigned long)g_actors.count, g_peIndex];
}

- (NSInteger)applySkin:(int32_t)skinId {
    if (!self.ready) return -1;

    // 1. Resolve descriptor class and appearance component classes
    if (!g_descClass) {
        g_descClass = pxFindClass("ModularWeaponDesc");
        if (!g_descClass) g_descClass = pxFindClass("GPModularWeaponDesc");
    }
    if (!g_appDataClass) {
        g_appDataClass = pxFindClass("ModularWeaponDataComponentAppearance");
    }
    if (!g_appFuncClass) {
        g_appFuncClass = pxFindClass("ModularWeaponFuncComponentAppearance");
    }

    if (!g_descClass && !g_appDataClass && !g_appFuncClass) return -2;

    // 2. Resolve setters on descriptor or appearance components
    static const char *kSetters[] = {
        "SetSkin", "SetSkin_BS", "SetSkin_ES",
        "SetSkinInfo", "SetSkinApperanceId", "ApplySkin", "SetSkinId",
    };
    const int n = (int)(sizeof(kSetters) / sizeof(kSetters[0]));
    if (g_descClass && !g_skinSetter) {
        for (int i = 0; i < n && !g_skinSetter; i++)
            g_skinSetter = pxFindFunction(g_descClass, kSetters[i]);
    }
    if (g_appDataClass && !g_appDataSetter) {
        for (int i = 0; i < n && !g_appDataSetter; i++)
            g_appDataSetter = pxFindFunction(g_appDataClass, kSetters[i]);
    }
    if (g_appFuncClass && !g_appFuncSetter) {
        for (int i = 0; i < n && !g_appFuncSetter; i++)
            g_appFuncSetter = pxFindFunction(g_appFuncClass, kSetters[i]);
    }

    if (!g_skinSetter && !g_appDataSetter && !g_appFuncSetter) return -3;

    if (g_actors.count == 0) { pxRefreshActors(); g_lastActorScan = CACurrentMediaTime(); }

    // 3. Local pawn, resolved the same way the ESP does it.
    uint64_t pawn = 0;
    if (g_camMgr && g_fnCamLoc) {
        alignas(16) uint8_t cparms[64];
        memset(cparms, 0, sizeof(cparms));
        pxInvoke(g_camMgr, g_fnCamLoc, cparms);
        PxVec3 camLoc = pxVec3(*(float *)(cparms + 0), *(float *)(cparms + 4), *(float *)(cparms + 8));
        if (pxFinite(camLoc.x) && pxFinite(camLoc.y) && pxFinite(camLoc.z))
            pawn = pxLocalPawn(camLoc);
    }

    // 4. Find candidate instances for descriptor and appearance components
    uint64_t bestDesc = 0;
    int bestDescScore = -1;
    uint64_t bestAppData = 0;
    int bestAppDataScore = -1;
    uint64_t bestAppFunc = 0;
    int bestAppFuncScore = -1;

    pxForEachObject([&](uint64_t obj) {
        uint64_t cls = 0;
        if (!pxRd64(obj + g_classOff, &cls)) return;
        uint64_t vt = 0;
        if (!pxRd64(obj, &vt) || vt == 0) return;

        BOOL isDesc = (g_descClass && cls == g_descClass);
        BOOL isAppData = (g_appDataClass && cls == g_appDataClass);
        BOOL isAppFunc = (g_appFuncClass && cls == g_appFuncClass);
        if (!isDesc && !isAppData && !isAppFunc) return;

        int score = 0;
        uint64_t o = obj;
        for (int k = 0; k < 6; k++) {
            o = pxOuterOf(o);
            if (!o) break;
            score++;
            if (pawn && o == pawn) { score += 100; break; }
            BOOL onChar = NO;
            for (NSNumber *a in g_actors) {
                if (a.unsignedLongLongValue == o) { onChar = YES; break; }
            }
            if (onChar) { score += 10; break; }
        }

        if (isDesc && score > bestDescScore) {
            bestDescScore = score;
            bestDesc = obj;
        } else if (isAppData && score > bestAppDataScore) {
            bestAppDataScore = score;
            bestAppData = obj;
        } else if (isAppFunc && score > bestAppFuncScore) {
            bestAppFuncScore = score;
            bestAppFunc = obj;
        }
    });

    NSInteger hops = 0;
    alignas(16) uint8_t parms[32];
    memset(parms, 0, sizeof(parms));
    *(int32_t *)parms = skinId;

    // Hop 1: Descriptor
    if (bestDesc && bestDescScore > 0 && g_skinSetter) {
        pxInvoke(bestDesc, g_skinSetter, parms);
        hops |= 1;
    }

    // Hop 2: Appearance Data Component
    if (bestAppData && bestAppDataScore > 0 && g_appDataSetter) {
        pxInvoke(bestAppData, g_appDataSetter, parms);
        hops |= 2;
    }

    // Hop 3: Appearance Func Component
    if (bestAppFunc && bestAppFuncScore > 0 && g_appFuncSetter) {
        pxInvoke(bestAppFunc, g_appFuncSetter, parms);
        hops |= 4;
    }

    return hops; // 0: no object found; bits: 1=desc, 2=appData, 4=appFunc
}

- (NSString *)dumpReport {
    NSMutableString *s = [NSMutableString string];

    [s appendString:@"== host ==\n"];
    [s appendFormat:@"image      0x%llX slide 0x%llX\n", g_imgBase, g_imgSlide];
    [s appendFormat:@"data segs %d, code segs %d, ranges %d (writable %d)\n",
        g_dataCount, g_codeCount, g_rangeCount, pxWritableCount()];
    [s appendFormat:@"scan        %.1f MB in %.0f ms, attempts %d, nameHits %d, objProbes %d\n",
        g_scanBytes / 1048576.0, g_scanMs, g_scanAttempts, g_nameHits, g_objProbes];
    [s appendString:@"\n== discovered ==\n"];
    [s appendFormat:@"GNames blocks  0x%llX\n", g_nameBlocks];
    [s appendFormat:@"GObjects slot  0x%llX count 0x%X\n", g_objArray, g_objCount];
    [s appendFormat:@"layout         class=+0x%X name=+0x%X outer=+0x%X\n",
        g_classOff, g_nameOff, g_nameOff + 8];
    [s appendFormat:@"               stride=%u shift=%u chunk=%u score=%llu %@\n",
        g_nameStride, g_nameShift, g_chunkShift, g_layoutScore,
        g_layoutOK ? @"OK" : @"FAILED"];
    [s appendFormat:@"ProcessEvent   slot 0x%X\n", g_peIndex];
    [s appendFormat:@"ActorLocation  0x%llX\n", g_fnActorLoc];
    [s appendFormat:@"CameraLoc/Rot  0x%llX / 0x%llX\n", g_fnCamLoc, g_fnCamRot];
    [s appendFormat:@"Team/Health    0x%llX 0x%llX 0x%llX\n", g_fnTeammate, g_fnHealth, g_fnHealthMax];
    [s appendFormat:@"classes        GPCharacterBase 0x%llX  CameraManager 0x%llX\n",
        g_classGPChar, g_classCamMgr];
    [s appendFormat:@"modskin        Desc 0x%llX (fn 0x%llX) AppData 0x%llX (fn 0x%llX) AppFunc 0x%llX (fn 0x%llX)\n",
        g_descClass, g_skinSetter, g_appDataClass, g_appDataSetter, g_appFuncClass, g_appFuncSetter];

    if (g_nameBlocks) {
        [s appendString:@"\n== name pool sample ==\n"];
        [s appendString:@"idx 0..15: "];
        for (uint32_t i = 0; i < 16; i++) {
            char nm[64] = { 0 };
            if (pxNameAt(i, nm, sizeof(nm))) [s appendFormat:@"%s ", nm];
        }
        [s appendString:@"\n"];
    }

    if (g_objArray) {
        [s appendString:@"\n== first 24 objects ==\n"];
        uint32_t printed = 0;
        pxForEachObject([&](uint64_t obj) {
            if (printed >= 24) return;
            char cls[128] = { 0 }, nm[128] = { 0 };
            pxClassNameOf(obj, cls, sizeof(cls));
            pxNameOf(obj, nm, sizeof(nm));
            [s appendFormat:@"  0x%llX  %-24s  %s\n", obj, cls, nm];
            printed++;
        });

        [s appendString:@"\n== character classes ==\n"];
        for (NSNumber *n in g_charClasses) {
            char nm[128] = { 0 };
            pxNameOf(n.unsignedLongLongValue, nm, sizeof(nm));
            [s appendFormat:@"  0x%llX  %s\n", n.unsignedLongLongValue, nm];
        }

        [s appendString:@"\n== live actors ==\n"];
        pxRefreshActors();
        for (NSNumber *n in g_actors) {
            char nm[128] = { 0 };
            pxNameOf(n.unsignedLongLongValue, nm, sizeof(nm));
            [s appendFormat:@"  0x%llX  %s\n", n.unsignedLongLongValue, nm];
        }
        [s appendFormat:@"  total %lu\n", (unsigned long)g_actors.count];
    }

    if (g_objArray && g_nameBlocks && g_layoutOK) pxDumpSDK(s);

    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (documents) {
        NSString *path = [documents stringByAppendingPathComponent:@"PxUE4.log"];
        [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [s appendFormat:@"\nwritten to %@\n", path];
    }
    return s;
}

@end
