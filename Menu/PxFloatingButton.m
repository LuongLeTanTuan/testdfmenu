#import "PxFloatingButton.h"
#import "PxMenuView.h"
#import "PxStore.h"

static NSString * const kPxButtonXKey = @"px_btn_x";
static NSString * const kPxButtonYKey = @"px_btn_y";

@interface PxFloatingButton ()
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, assign) BOOL dragging;
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
        instance.windowLevel = UIWindowLevelAlert + 100;
        instance.backgroundColor = [UIColor clearColor];
        instance.rootViewController = [[UIViewController alloc] init];
        instance.rootViewController.view.backgroundColor = [UIColor clearColor];
        // Same reason as PxOverlay: no scene means the window never appears.
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) { instance.windowScene = (UIWindowScene *)s; break; }
            }
        }
        [instance buildButton];
        instance.hidden = NO;
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
    [self.rootViewController.view addSubview:self.button];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.button addGestureRecognizer:pan];
}

- (void)showButton {
    self.hidden = NO;
}

- (void)hideButton {
    self.hidden = YES;
}

- (void)buttonTapped {
    if (self.dragging) {
        self.dragging = NO;
        return;
    }
    [[PxMenuView shared] toggleMenu];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self];
    CGPoint center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self];

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
