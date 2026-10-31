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

// Nothing but the heartbeat runs for the first five seconds. The reported crash
// lands around 1.5 s; if it is the host's integrity sweep, installing late gets
// past it, and if it is our own code, the heartbeat proves we were alive until
// then and the kill came from outside.
static const double kPxInstallDelay = 5.0;

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

// Proves the process is still alive between install steps. A log that stops on a
// heartbeat with no exception above it means something outside this dylib killed
// the app, which no amount of local hardening can fix. Every tick is logged:
// the resolution is what tells us which step was running.
static void PxHeartbeat(NSInteger tick, NSInteger total) {
    PxLog(@"heartbeat %ld/%ld images=%u", (long)tick, (long)total, (unsigned)_dyld_image_count());
    if (tick >= total) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PxHeartbeat(tick + 1, total);
    });
}

// After the UI is up the only remaining question is whether the process is still
// alive. A boot log that ends on an "alive" line means the app was killed at that
// second; one that ends on a lifecycle line means it went to the background
// instead; one that runs to the moment the user noticed means the app never died
// and the session was dropped on the server.
static void PxSlowBeat(NSInteger tick) {
    PxLog(@"alive %ld images=%u", (long)tick, (unsigned)_dyld_image_count());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PxSlowBeat(tick + 1);
    });
}

static void PxObserveLifecycle(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    void (^note)(NSNotification *) = ^(NSNotification *n) {
        PxLog(@"lifecycle %@", n.name);
    };
    for (NSString *name in @[ UIApplicationDidBecomeActiveNotification,
                              UIApplicationWillResignActiveNotification,
                              UIApplicationDidEnterBackgroundNotification,
                              UIApplicationWillTerminateNotification ]) {
        [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:note];
    }
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
            // Never restore the overlay from persisted state. ESP is what killed
            // the process on the previous build, and because the switch was
            // saved as on, every later launch died again before the menu could
            // be reached -- a loop with no way out from the device itself.
            // The display link still starts here (the skin re-apply rides on
            // it); only the ESP window stays down until the switch is touched.
            BOOL persisted = [PxStore boolForKey:@"esp_players"];
            [[PxOverlay shared] setEnabled:NO];
            PxLog(@"overlay enabled=0 (persisted esp=%d, deferred to the menu switch)", (int)persisted);
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
        static BOOL beatStarted;
        if (!beatStarted) {
            beatStarted = YES;
            PxObserveLifecycle();
            PxSlowBeat(0);
        }
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

    PxHeartbeat(0, 24);   // 24 * 0.25s = 6s, past the reported crash

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPxInstallDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PxLog(@"install delay elapsed");
        @try {
            PxObserveForeground();
            PxLog(@"foreground observer registered");
        } @catch (NSException *e) {
            PxLog(@"observer registration threw: %@", e);
        }
        PxInstallUI(0);
    });
}
