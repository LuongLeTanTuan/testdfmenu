#import "PxOverlay.h"
#import "PxStore.h"
#import "PxUE4.h"
#import <stdlib.h>

@interface PxOverlay ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) NSInteger tick;
@end

// A window created without a scene on iOS 13+ stays detached and never draws,
// even with hidden = NO. Read it fresh every time: the scene set can be empty
// for the first seconds of the process, and a nil captured once at creation
// would keep the window invisible for the rest of the launch.
static UIWindowScene *PxActiveScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
        }
    }
    return nil;
}


@implementation PxOverlay

+ (instancetype)shared {
    static PxOverlay *overlay;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        overlay = [[PxOverlay alloc] initWithFrame:UIScreen.mainScreen.bounds];
        overlay.backgroundColor = [UIColor clearColor];
        overlay.userInteractionEnabled = NO;
        overlay.opaque = NO;
        // Do NOT touch overlay.enabled here. The setter calls +install, +install
        // calls +shared, and +shared is still inside this dispatch_once block --
        // a re-entrant dispatch_once deadlocks the main thread, the watchdog
        // kills the app, and the boot log stops on the line just before it
        // (selfcheck), which is exactly the "menu never appears" report.
        // Ivars are zeroed by alloc, so enabled is already NO.
    });
    return overlay;
}

+ (void)install {
    PxOverlay *overlay = [self shared];
    if (!overlay.window) {
        UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        window.windowLevel = UIWindowLevelAlert + 50;
        window.backgroundColor = [UIColor clearColor];
        window.rootViewController = [[UIViewController alloc] init];
        window.rootViewController.view.backgroundColor = [UIColor clearColor];
        window.rootViewController.view.userInteractionEnabled = NO;
        // Belt and braces: the root view already refuses touches, but the window
        // itself defaults to YES and a visible full-screen window at level 2050
        // sitting above the game is the last thing the touch router should meet.
        window.userInteractionEnabled = NO;
        // A window created without a scene on iOS 13+ stays detached and never
        // draws, even with hidden = NO.
        if (@available(iOS 13.0, *)) {
            window.windowScene = PxActiveScene();
        }
        window.hidden = YES;   // shown only while the ESP is actually enabled
        [window.rootViewController.view addSubview:overlay];
        overlay.window = window;
    }
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    // No install from here: +install is the caller, and re-entering it from the
    // +shared initialiser deadlocks dispatch_once. PxInstallUI always installs
    // before the first setEnabled:.
    // The timer drives both the box draw and the periodic skin re-apply. The
    // skin has to work without the ESP window ever coming up, so the link
    // starts on the first call and stays up for the life of the process; only
    // the window visibility follows `enabled`.
    if (!self.link) {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        // 20 Hz is enough for boxes; 60 Hz burns battery for nothing.
        self.link.preferredFramesPerSecond = 20;
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    // A transparent full-screen window still sits in the app's window list and
    // costs a hit-test pass on every touch; keep it out of the chain unless the
    // ESP is on.
    self.window.hidden = !enabled;
    [self setNeedsDisplay];
}

- (void)tick:(CADisplayLink *)link {
    static int firstTick;
    if (!firstTick) { firstTick = 1; PxLogShared(@"overlay tick 1"); }

    self.tick++;
    if (![PxUE4 shared].ready) [[PxUE4 shared] scanIfNeeded];

    // The window is only allowed on screen when it can actually draw something.
    // Leaving a full-screen transparent window at level 2050 up while the ESP has
    // nothing to show is how the game ends up feeling like it stopped taking
    // touches: the window is above it, it is interactive at the window level, and
    // it paints nothing. The display link is independent of window visibility, so
    // the skin re-apply below still runs with the window hidden.
    BOOL want = self.enabled && [PxUE4 shared].ready;
    if (self.window && self.window.hidden == want) self.window.hidden = !want;

    // Mod skin: descriptor changes when the held weapon changes or the player
    // respawns, so re-send the id every 2 s while auto re-apply is on.
    static CFTimeInterval lastSkin;
    static int32_t lastSkinId;
    if ([PxStore boolForKey:@"skin_enable"]) {
        NSString *raw = [PxStore stringForKey:@"skin_gun_id"];
        int32_t skinId = raw.length ? (int32_t)strtoul(raw.UTF8String, NULL, 0) : 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (skinId != lastSkinId || now - lastSkin > 2.0) {
            lastSkinId = skinId;
            lastSkin = now;
            if (skinId != 0 && [PxUE4 shared].ready) [[PxUE4 shared] applySkin:skinId];
        }
    }

    [self setNeedsDisplay];
}

- (void)refresh {
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (!self.enabled) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    if (![PxStore boolForKey:@"esp_players"]) return;

    NSInteger colorIndex = [PxStore integerForKey:@"vis_color"];
    UIColor *accent;
    switch (colorIndex) {
        case 1: accent = [UIColor colorWithRed:0.95 green:0.35 blue:0.35 alpha:1]; break;
        case 2: accent = [UIColor colorWithRed:0.30 green:0.85 blue:0.95 alpha:1]; break;
        case 3: accent = [UIColor colorWithRed:0.90 green:0.40 blue:0.95 alpha:1]; break;
        default: accent = [UIColor colorWithRed:0.25 green:0.95 blue:0.55 alpha:1]; break;
    }

    CGFloat opacity = [PxStore floatForKey:@"vis_opacity"] / 100.0f;
    if (opacity <= 0.0f) opacity = 0.85f;

    float maxDistance = [PxStore floatForKey:@"esp_max_dist"];
    if (maxDistance <= 0.0f) maxDistance = 1000.0f;

    BOOL showBox = [PxStore boolForKey:@"esp_box"];
    BOOL showDistance = [PxStore boolForKey:@"esp_distance"];
    BOOL showHealth = [PxStore boolForKey:@"esp_health"];
    BOOL showSkeleton = [PxStore boolForKey:@"esp_skeleton"];
    NSInteger boxStyle = [PxStore integerForKey:@"vis_box_style"];

    CGContextSetLineWidth(ctx, 1.5);
    CGContextSetStrokeColorWithColor(ctx, [accent colorWithAlphaComponent:opacity].CGColor);
    CGContextSetFillColorWithColor(ctx, [accent colorWithAlphaComponent:opacity * 0.9].CGColor);

    PxEntity entities[64];
    NSUInteger count = [[PxUE4 shared] collectEntities:entities max:64 viewSize:rect.size];
    if (count == 0) return;

    UIFont *font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightMedium];
    for (NSUInteger i = 0; i < count; i++) {
        CGRect box = entities[i].rect;
        float distance = entities[i].distance;
        if (distance > maxDistance) continue;

        if (showBox) {
            switch (boxStyle) {
                case 1: // full
                    CGContextStrokeRect(ctx, box);
                    break;
                case 2: { // 3D: outer frame plus a short base line
                    CGContextStrokeRect(ctx, box);
                    CGContextMoveToPoint(ctx, box.origin.x, CGRectGetMaxY(box));
                    CGContextAddLineToPoint(ctx, CGRectGetMaxX(box), CGRectGetMaxY(box));
                    CGContextStrokePath(ctx);
                    break;
                }
                default: { // corners
                    CGFloat l = box.size.width * 0.25, t = box.size.height * 0.15;
                    CGContextMoveToPoint(ctx, box.origin.x, box.origin.y + t);
                    CGContextAddLineToPoint(ctx, box.origin.x, box.origin.y);
                    CGContextAddLineToPoint(ctx, box.origin.x + l, box.origin.y);
                    CGContextMoveToPoint(ctx, CGRectGetMaxX(box) - l, box.origin.y);
                    CGContextAddLineToPoint(ctx, CGRectGetMaxX(box), box.origin.y);
                    CGContextAddLineToPoint(ctx, CGRectGetMaxX(box), box.origin.y + t);
                    CGContextMoveToPoint(ctx, box.origin.x, CGRectGetMaxY(box) - t);
                    CGContextAddLineToPoint(ctx, box.origin.x, CGRectGetMaxY(box));
                    CGContextAddLineToPoint(ctx, box.origin.x + l, CGRectGetMaxY(box));
                    CGContextMoveToPoint(ctx, CGRectGetMaxX(box) - l, CGRectGetMaxY(box));
                    CGContextAddLineToPoint(ctx, CGRectGetMaxX(box), CGRectGetMaxY(box));
                    CGContextAddLineToPoint(ctx, CGRectGetMaxX(box), CGRectGetMaxY(box) - t);
                    CGContextStrokePath(ctx);
                    break;
                }
            }
        }

        NSString *label = showDistance
            ? [NSString stringWithFormat:@"%.0f M", distance]
            : nil;
        if (label) {
            [label drawAtPoint:CGPointMake(box.origin.x, box.origin.y - 13)
                withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: accent}];
        }

        if (showHealth && entities[i].health > 0.0f && entities[i].healthMax > 0.0f) {
            CGFloat ratio = entities[i].health / entities[i].healthMax;
            ratio = MAX(0.0f, MIN(1.0f, ratio));

            CGRect track = CGRectMake(box.origin.x - 5, box.origin.y, 3, box.size.height);
            CGContextSetFillColorWithColor(ctx, [[UIColor blackColor] colorWithAlphaComponent:opacity * 0.6].CGColor);
            CGContextFillRect(ctx, track);

            UIColor *hpColor = ratio > 0.6f ? accent
                             : (ratio > 0.3f ? [UIColor colorWithRed:0.95 green:0.75 blue:0.20 alpha:1]
                                            : [UIColor colorWithRed:0.95 green:0.30 blue:0.30 alpha:1]);
            CGContextSetFillColorWithColor(ctx, [hpColor colorWithAlphaComponent:opacity].CGColor);
            CGContextFillRect(ctx, CGRectMake(track.origin.x,
                                              track.origin.y + track.size.height * (1.0f - ratio),
                                              track.size.width,
                                              track.size.height * ratio));
            CGContextSetFillColorWithColor(ctx, [accent colorWithAlphaComponent:opacity * 0.9].CGColor);
        }

        if (showSkeleton) {
            CGFloat midX = CGRectGetMidX(box);
            CGContextMoveToPoint(ctx, midX, box.origin.y + box.size.height * 0.15);
            CGContextAddLineToPoint(ctx, midX, box.origin.y + box.size.height * 0.55);
            CGContextAddLineToPoint(ctx, box.origin.x + box.size.width * 0.2, box.origin.y + box.size.height * 0.75);
            CGContextMoveToPoint(ctx, midX, box.origin.y + box.size.height * 0.55);
            CGContextAddLineToPoint(ctx, box.origin.x + box.size.width * 0.8, box.origin.y + box.size.height * 0.75);
            CGContextStrokePath(ctx);
        }
    }
}

@end
