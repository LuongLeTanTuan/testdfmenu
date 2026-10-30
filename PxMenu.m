#import <UIKit/UIKit.h>
#import "PxFloatingButton.h"
#import "PxOverlay.h"
#import "PxMenuView.h"

// The dylib is injected into the host app, so there is no app delegate to hook.
// Wait for a key window, install, and re-assert on foreground.
static NSInteger const kPxMaxInstallAttempts = 40;

static UIWindow *PxKeyWindow(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) return window;
    }
    return nil;
}

static void PxSelfCheck(void) {
    NSArray<PxTab *> *tabs = [PxStore shared].tabs;
    NSCAssert(tabs.count > 0, @"PX: no tabs built");
    NSMutableSet *keys = [NSMutableSet set];
    for (PxTab *tab in tabs) {
        for (PxSection *section in [tab.sections arrayByAddingObjectsFromArray:tab.rightSections]) {
            for (PxControl *control in section.controls) {
                NSCAssert(control.key.length > 0, @"PX: control '%@' has no key", control.title);
                if ([control.key hasPrefix:@"btn_"]) continue;
                NSCAssert(![keys containsObject:control.key], @"PX: duplicate key '%@'", control.key);
                [keys addObject:control.key];
            }
        }
    }
}

static void PxInstallUI(NSInteger attempt) {
    if (PxKeyWindow()) {
        PxSelfCheck();
        [PxOverlay install];
        // Restore the overlay link from persisted state: the display thread
        // drives both the ESP draw loop and the periodic skin re-apply.
        BOOL any = [PxStore boolForKey:@"esp_players"] || [PxStore boolForKey:@"skin_enable"];
        [[PxOverlay shared] setEnabled:any];
        [[PxFloatingButton shared] showButton];
        return;
    }
    if (attempt >= kPxMaxInstallAttempts) return;
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
        PxInstallUI(0);
    }];
}

__attribute__((constructor))
static void PxMenuInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PxObserveForeground();
        PxInstallUI(0);
    });
}
