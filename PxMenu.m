#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <stdarg.h>
#import "PxFloatingButton.h"
#import "PxOverlay.h"
#import "PxMenuView.h"
#import "PxStore.h"

// The dylib is injected into the host app, so there is no app delegate to hook.
// Wait for a key window, install, and re-assert on foreground.
static NSInteger const kPxMaxInstallAttempts = 120;   // 120 * 0.25s = 30s

// Documents/PxBoot.log survives a SIGKILL, so it is the only way to tell "our
// code threw" apart from "the anti-cheat killed the process". Every step writes
// before it runs; the last line in the file is where it died.
static void PxLog(NSString *fmt, ...) {
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

    NSString *line = [NSString stringWithFormat:@"[%9.3f] %@\n", CACurrentMediaTime(), msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:NO];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try { [fh seekToEndOfFile]; [fh writeData:data]; }
    @catch (NSException *e) { }
    [fh closeFile];
}

static UIWindow *PxKeyWindow(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) return window;
    }
    return nil;
}

// A boot that never reached "install done" took the process down before the log
// could be read. Refuse to install on the next launch so the user always gets a
// second, log-producing boot instead of a loop that never yields evidence.
static NSString *PxMarkerPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        path = docs ? [docs stringByAppendingPathComponent:@"PxBoot.inprogress"] : nil;
    });
    return path;
}

// Cosmetic problems in the menu must never abort the host app. This used to be
// NSCAssert, which is live in a release Theos build (NS_BLOCK_ASSERTIONS is not
// set), so a single bad key killed the game ~1.5 s after launch.
static void PxSelfCheck(void) {
    NSArray<PxTab *> *tabs = [PxStore shared].tabs;
    if (tabs.count == 0) {
        PxLog(@"selfcheck: no tabs built");
        return;
    }
    NSMutableSet *keys = [NSMutableSet set];
    for (PxTab *tab in tabs) {
        for (PxSection *section in [tab.sections arrayByAddingObjectsFromArray:tab.rightSections]) {
            for (PxControl *control in section.controls) {
                if (control.key.length == 0) {
                    PxLog(@"selfcheck: tab '%@' control '%@' has no key", tab.title, control.title);
                    continue;
                }
                if ([control.key hasPrefix:@"btn_"]) continue;
                if ([keys containsObject:control.key]) {
                    PxLog(@"selfcheck: duplicate key '%@' in tab '%@'", control.key, tab.title);
                    continue;
                }
                [keys addObject:control.key];
            }
        }
    }
    PxLog(@"selfcheck: %lu tabs, %lu keys", (unsigned long)tabs.count, (unsigned long)keys.count);
}

static void PxInstallUI(NSInteger attempt) {
    UIWindow *key = PxKeyWindow();
    if (key && key.rootViewController) {
        PxLog(@"install attempt %ld: key window %@", (long)attempt, NSStringFromCGRect(key.bounds));

        NSString *marker = PxMarkerPath();
        if (marker) [@"" writeToFile:marker atomically:NO encoding:NSUTF8StringEncoding error:nil];

        @try {
            PxSelfCheck();
        } @catch (NSException *e) {
            PxLog(@"selfcheck threw: %@", e);
        }

        @try {
            [PxOverlay install];
            PxLog(@"overlay installed");
        } @catch (NSException *e) {
            PxLog(@"overlay install threw: %@", e);
        }

        @try {
            // Restore the overlay link from persisted state: the display thread
            // drives both the ESP draw loop and the periodic skin re-apply.
            BOOL any = [PxStore boolForKey:@"esp_players"] || [PxStore boolForKey:@"skin_enable"];
            [[PxOverlay shared] setEnabled:any];
            PxLog(@"overlay enabled=%d", any);
        } @catch (NSException *e) {
            PxLog(@"overlay enable threw: %@", e);
        }

        @try {
            [[PxFloatingButton shared] showButton];
            PxLog(@"floating button shown");
        } @catch (NSException *e) {
            PxLog(@"floating button threw: %@", e);
        }

        PxLog(@"install done");
        if (marker) [[NSFileManager defaultManager] removeItemAtPath:marker error:nil];
        return;
    }

    if (attempt % 8 == 0) PxLog(@"install attempt %ld: waiting for key window", (long)attempt);
    if (attempt >= kPxMaxInstallAttempts) {
        PxLog(@"install gave up after %ld attempts", (long)attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PxInstallUI(attempt + 1);
    });
}

static void PxObserveForeground(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        PxLog(@"did become active");
        PxInstallUI(0);
    }];
}

__attribute__((constructor))
static void PxMenuInit(void) {
    PxLog(@"=== PxMenu constructor, %u dyld images ===", (unsigned)_dyld_image_count());

    // The marker is written just before the UI installs and removed once it
    // succeeds, so its presence here means the previous boot died mid-install.
    // Skip this launch entirely: the menu is not worth a crash loop that never
    // leaves a readable log.
    NSString *marker = PxMarkerPath();
    if (marker && [[NSFileManager defaultManager] fileExistsAtPath:marker]) {
        [[NSFileManager defaultManager] removeItemAtPath:marker error:nil];
        PxLog(@"previous boot did not reach install done -- menu skipped this launch");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            PxObserveForeground();
            PxLog(@"foreground observer registered");
        } @catch (NSException *e) {
            PxLog(@"observer registration threw: %@", e);
        }
        PxInstallUI(0);
    });
}
