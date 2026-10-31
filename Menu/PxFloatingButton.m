#import "PxFloatingButton.h"
#import "PxMenuView.h"
#import "PxStore.h"
#import "PxUE4.h"

static NSString * const kPxButtonXKey = @"px_btn_x";
static NSString * const kPxButtonYKey = @"px_btn_y";

@interface PxFloatingButton ()
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) NSInteger attachTries;
@end

@implementation PxFloatingButton

+ (instancetype)shared {
    static PxFloatingButton *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGFloat side = 52.0f;
        CGFloat savedX = [PxStore floatForKey:kPxButtonXKey];
        CGFloat savedY = [PxStore floatForKey:kPxButtonYKey];
        CGRect screen = UIScreen.mainScreen.bounds;
        CGFloat x = savedX > 0 ? savedX : screen.size.width - side - 12;
        CGFloat y = savedY > 0 ? savedY : screen.size.height * 0.35;

        instance = [[PxFloatingButton alloc] initWithFrame:CGRectMake(x, y, side, side)];
        instance.backgroundColor = [UIColor clearColor];
        instance.userInteractionEnabled = YES;
        [instance buildButton];
    });
    return instance;
}

- (void)buildButton {
    CGFloat side = self.bounds.size.width;

    self.button = [UIButton buttonWithType:UIButtonTypeCustom];
    self.button.frame = self.bounds;
    self.button.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.09 alpha:0.92];
    self.button.layer.cornerRadius = side / 2;
    self.button.layer.borderWidth = 1;
    self.button.layer.borderColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.52 alpha:0.85].CGColor;
    self.button.layer.shadowColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.52 alpha:0.55].CGColor;
    self.button.layer.shadowRadius = 8;
    self.button.layer.shadowOpacity = 1;
    self.button.layer.shadowOffset = CGSizeZero;
    self.button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [self.button setTitle:@"PX" forState:UIControlStateNormal];
    [self.button setTitleColor:[UIColor colorWithRed:0.35 green:0.95 blue:0.60 alpha:1] forState:UIControlStateNormal];
    [self.button addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.button];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.button addGestureRecognizer:pan];
}

// The key window, preferring one that already has a scene and a visible size.
// [UIApplication windows] is deprecated but still the only call that returns the
// host's window when the game never adopts a scene delegate.
static UIWindow *PxHostWindow(void) {
    UIWindow *fallback = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden) continue;
        if (!fallback) fallback = w;
        if (w.isKeyWindow) return w;
    }
    if (fallback) return fallback;
    for (UIWindow *w in [UIApplication sharedApplication].windows) return w;
    return nil;
}

- (void)showButton {
    UIWindow *host = PxHostWindow();
    if (!host) {
        // No window yet. Try again for a few seconds rather than giving up: the
        // game builds its window after the menu's install delay on a cold start.
        if (self.attachTries < 20) {
            self.attachTries++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self showButton]; });
        } else {
            PxLogShared(@"button attach: no host window after %ld tries", (long)self.attachTries);
        }
        return;
    }
    self.attachTries = 0;

    if (self.superview != host) [self removeFromSuperview];
    if (self.superview != host) [host addSubview:self];
    [host bringSubviewToFront:self];
    self.hidden = NO;

    PxLogShared(@"button attach: host=%@ level=%.0f frame=%@ onTop=%d",
                NSStringFromClass([host class]), host.windowLevel,
                NSStringFromCGRect(self.frame),
                (int)(host.subviews.lastObject == self));
}

- (void)hideButton {
    self.hidden = YES;
    [self removeFromSuperview];
}

- (void)buttonTapped {
    // The drag flag used to be sticky: a pan that ended without TouchUpInside
    // left it set and swallowed the next tap, so the menu could not be reopened.
    // Read the live recogniser state instead.
    UIGestureRecognizer *pan = self.button.gestureRecognizers.firstObject;
    if (pan && (pan.state == UIGestureRecognizerStateBegan ||
                pan.state == UIGestureRecognizerStateChanged)) return;
    [[PxMenuView shared] toggleMenu];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    CGPoint center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];

    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat half = self.bounds.size.width / 2;
    center.x = MAX(half + 4, MIN(screen.size.width - half - 4, center.x));
    center.y = MAX(half + 40, MIN(screen.size.height - half - 4, center.y));
    self.center = center;

    if (pan.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
        self.button.transform = CGAffineTransformMakeScale(1.08, 1.08);
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled) {
        self.button.transform = CGAffineTransformIdentity;
        [PxStore setFloat:(float)self.frame.origin.x forKey:kPxButtonXKey];
        [PxStore setFloat:(float)self.frame.origin.y forKey:kPxButtonYKey];
    }
}

@end
