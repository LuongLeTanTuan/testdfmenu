#import "PxMenuView.h"
#import "PxOverlay.h"
#import <objc/runtime.h>

static const CGFloat kPxRowSwitch  = 44.0f;
static const CGFloat kPxRowSlider  = 58.0f;
static const CGFloat kPxRowCombo   = 44.0f;
static const CGFloat kPxRowButton  = 40.0f;
static const CGFloat kPxRowText    = 44.0f;
static const CGFloat kPxSectionHdr = 30.0f;
static const void * const kPxControlKey = &kPxControlKey;

@interface PxMenuView () <UIScrollViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) UILabel *masterLabel;
@property (nonatomic, strong) UITextField *leftSearch;
@property (nonatomic, strong) UITextField *rightSearch;
@property (nonatomic, strong) UIScrollView *leftScroll;
@property (nonatomic, strong) UIScrollView *rightScroll;
@property (nonatomic, strong) UIView *tabBar;
@property (nonatomic, strong) NSMutableArray<UIButton *> *tabButtons;
@property (nonatomic, strong) NSMutableArray<UIView *> *rowViews;
@property (nonatomic, assign) NSInteger activeTab;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSInteger frameCount;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, strong) UIWindow *hostWindow;
@end

@implementation PxMenuView

+ (instancetype)shared {
    static PxMenuView *view;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        view = [[PxMenuView alloc] initWithFrame:UIScreen.mainScreen.bounds];
        [view buildUI];
    });
    return view;
}

- (BOOL)isVisible {
    return self.superview != nil && !self.hidden;
}

#pragma mark - Build

- (void)buildUI {
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.hidden = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    self.rowViews = [NSMutableArray array];
    self.tabButtons = [NSMutableArray array];

    self.container = [[UIView alloc] initWithFrame:CGRectZero];
    self.container.backgroundColor = [UIColor colorWithRed:0.055 green:0.058 blue:0.070 alpha:0.97];
    self.container.layer.cornerRadius = 16;
    self.container.layer.borderWidth = 1;
    self.container.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    self.container.clipsToBounds = YES;
    [self addSubview:self.container];

    [self buildHeader];
    [self buildTabBar];
    [self buildContent];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.container addGestureRecognizer:tap];

    [self relayout];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(relayout)
                                                 name:UIDeviceOrientationDidChangeNotification object:nil];
}

- (void)buildHeader {
    self.header = [[UIView alloc] initWithFrame:CGRectZero];
    [self.container addSubview:self.header];

    self.statusDot = [[UIView alloc] initWithFrame:CGRectMake(16, 0, 8, 8)];
    self.statusDot.backgroundColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.52 alpha:1];
    self.statusDot.layer.cornerRadius = 4;
    self.statusDot.layer.shadowColor = self.statusDot.backgroundColor.CGColor;
    self.statusDot.layer.shadowRadius = 6;
    self.statusDot.layer.shadowOpacity = 0.9;
    self.statusDot.layer.shadowOffset = CGSizeZero;
    [self.header addSubview:self.statusDot];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.text = @"PX EXT";
    self.titleLabel.textColor = [UIColor colorWithWhite:0.95 alpha:1];
    self.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.header addSubview:self.titleLabel];

    self.fpsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.fpsLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    self.fpsLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.fpsLabel.textAlignment = NSTextAlignmentRight;
    [self.header addSubview:self.fpsLabel];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"✕" forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[UIColor colorWithWhite:0.55 alpha:1] forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:17];
    [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:self.closeButton];

    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    divider.tag = 9001;
    [self.container addSubview:divider];

    self.masterLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.masterLabel.text = @"Master";
    self.masterLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    self.masterLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [self.container addSubview:self.masterLabel];

    self.masterSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.masterSwitch.onTintColor = [UIColor colorWithRed:0.20 green:0.80 blue:0.50 alpha:1];
    self.masterSwitch.transform = CGAffineTransformMakeScale(0.72, 0.72);
    [self.masterSwitch addTarget:self action:@selector(masterChanged:) forControlEvents:UIControlEventValueChanged];
    [self.container addSubview:self.masterSwitch];
}

- (UITextField *)makeSearchFieldWithPlaceholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.placeholder = placeholder;
    field.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    field.layer.cornerRadius = 8;
    field.layer.borderWidth = 1;
    field.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.06].CGColor;
    field.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    field.font = [UIFont systemFontOfSize:12];
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyDone;
    field.delegate = self;
    field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    field.leftViewMode = UITextFieldViewModeAlways;
    [field addTarget:self action:@selector(searchChanged:) forControlEvents:UIControlEventEditingChanged];
    return field;
}

- (void)buildContent {
    self.leftSearch = [self makeSearchFieldWithPlaceholder:@"Search left"];
    self.rightSearch = [self makeSearchFieldWithPlaceholder:@"Search right"];
    [self.container addSubview:self.leftSearch];
    [self.container addSubview:self.rightSearch];

    self.leftScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.rightScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    for (UIScrollView *scroll in @[self.leftScroll, self.rightScroll]) {
        scroll.backgroundColor = [UIColor clearColor];
        scroll.showsVerticalScrollIndicator = YES;
        scroll.alwaysBounceVertical = YES;
        scroll.delegate = self;
        [self.container addSubview:scroll];
    }
}

- (void)buildTabBar {
    self.tabBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.tabBar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.03];
    [self.container addSubview:self.tabBar];

    NSArray<PxTab *> *tabs = [PxStore shared].tabs;
    for (NSInteger i = 0; i < (NSInteger)tabs.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = i;
        button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        [button setTitle:tabs[i].title forState:UIControlStateNormal];
        [button addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.tabBar addSubview:button];
        [self.tabButtons addObject:button];
    }
}

#pragma mark - Layout

- (void)relayout {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat width = MIN(screen.size.width - 20, 620);
    CGFloat height = MIN(screen.size.height - 100, 560);
    CGFloat originX = (screen.size.width - width) / 2;
    CGFloat originY = (screen.size.height - height) / 2;
    self.frame = screen;
    self.container.frame = CGRectMake(originX, originY, width, height);

    CGFloat headerH = 48, masterH = 44, searchH = 40, tabH = 50;
    self.header.frame = CGRectMake(0, 0, width, headerH);
    self.statusDot.center = CGPointMake(22, headerH / 2);
    self.titleLabel.frame = CGRectMake(36, 0, 120, headerH);
    self.fpsLabel.frame = CGRectMake(width - 150, 0, 90, headerH);
    self.closeButton.frame = CGRectMake(width - 44, 0, 44, headerH);

    UIView *divider = [self.container viewWithTag:9001];
    divider.frame = CGRectMake(0, headerH, width, 1);

    self.masterLabel.frame = CGRectMake(18, headerH + 8, 120, 28);
    self.masterSwitch.center = CGPointMake(width - 40, headerH + 22);
    self.masterSwitch.on = [PxStore shared].masterEnabled;

    CGFloat searchY = headerH + masterH;
    self.leftSearch.frame = CGRectMake(12, searchY, (width - 30) / 2, searchH - 8);
    self.rightSearch.frame = CGRectMake(width / 2 + 3, searchY, (width - 30) / 2, searchH - 8);

    CGFloat contentY = searchY + searchH;
    CGFloat contentH = height - contentY - tabH;
    CGFloat colW = (width - 30) / 2;
    self.leftScroll.frame = CGRectMake(12, contentY, colW, contentH);
    self.rightScroll.frame = CGRectMake(width / 2 + 3, contentY, colW, contentH);

    self.tabBar.frame = CGRectMake(0, height - tabH, width, tabH);
    CGFloat tabW = width / MAX((CGFloat)self.tabButtons.count, 1.0f);
    for (NSInteger i = 0; i < (NSInteger)self.tabButtons.count; i++) {
        self.tabButtons[i].frame = CGRectMake(i * tabW, 0, tabW, tabH);
    }
    [self rebuildContent];
}

- (void)rebuildContent {
    for (UIView *view in self.rowViews) [view removeFromSuperview];
    [self.rowViews removeAllObjects];

    NSArray<PxTab *> *tabs = [PxStore shared].tabs;
    if (self.activeTab >= (NSInteger)tabs.count) self.activeTab = 0;
    PxTab *tab = tabs[self.activeTab];

    [self updateTabAppearance];
    [self fillScroll:self.leftScroll sections:tab.sections filter:self.leftSearch.text];
    [self fillScroll:self.rightScroll sections:tab.rightSections filter:self.rightSearch.text];
}

- (void)updateTabAppearance {
    UIColor *accent = [UIColor colorWithRed:0.20 green:0.80 blue:0.50 alpha:1];
    for (NSInteger i = 0; i < (NSInteger)self.tabButtons.count; i++) {
        BOOL active = (i == self.activeTab);
        [self.tabButtons[i] setTitleColor:(active ? accent : [UIColor colorWithWhite:0.45 alpha:1])
                                 forState:UIControlStateNormal];
    }
}

#pragma mark - Content building

- (CGFloat)heightForControl:(PxControl *)control {
    switch (control.type) {
        case PxControlSwitch: return kPxRowSwitch;
        case PxControlSlider: return kPxRowSlider;
        case PxControlCombo:  return kPxRowCombo;
        case PxControlButton: return kPxRowButton;
        case PxControlText:   return kPxRowText;
    }
    return kPxRowSwitch;
}

- (void)fillScroll:(UIScrollView *)scroll sections:(NSArray<PxSection *> *)sections filter:(NSString *)filter {
    for (UIView *subview in scroll.subviews) [subview removeFromSuperview];
    CGFloat y = 4;
    NSString *needle = [filter lowercaseString] ?: @"";

    for (PxSection *section in sections) {
        UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
        card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.035];
        card.layer.cornerRadius = 10;
        card.layer.borderWidth = 1;
        card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.05].CGColor;

        CGFloat cardY = 0;
        UILabel *headerLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, scroll.bounds.size.width - 24, kPxSectionHdr)];
        headerLabel.text = section.title;
        headerLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        headerLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        [card addSubview:headerLabel];
        cardY += kPxSectionHdr;

        for (PxControl *control in section.controls) {
            BOOL matches = needle.length == 0 ||
                [control.title.lowercaseString containsString:needle];
            UIView *row = [self buildRowForControl:control width:scroll.bounds.size.width];
            row.hidden = !matches;
            if (matches) {
                row.frame = CGRectMake(0, cardY, scroll.bounds.size.width, row.frame.size.height);
                [card addSubview:row];
                [self.rowViews addObject:row];
                cardY += row.frame.size.height;
            }
        }
        card.frame = CGRectMake(0, y, scroll.bounds.size.width, cardY);
        [scroll addSubview:card];
        y += cardY + 8;
    }
    scroll.contentSize = CGSizeMake(scroll.bounds.size.width, MAX(y, scroll.bounds.size.height));
    scroll.contentOffset = CGPointZero;
}

- (UIView *)buildRowForControl:(PxControl *)control width:(CGFloat)width {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, [self heightForControl:control])];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, width - 90, row.frame.size.height)];
    label.text = control.title;
    label.textColor = [UIColor colorWithWhite:0.88 alpha:1];
    label.font = [UIFont systemFontOfSize:12.5];
    [row addSubview:label];

    switch (control.type) {
        case PxControlSwitch: {
            UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
            toggle.onTintColor = [UIColor colorWithRed:0.20 green:0.80 blue:0.50 alpha:1];
            toggle.transform = CGAffineTransformMakeScale(0.62, 0.62);
            toggle.center = CGPointMake(width - 34, row.frame.size.height / 2);
            toggle.on = control.boolValue;
            objc_setAssociatedObject(toggle, kPxControlKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            [row addSubview:toggle];
            break;
        }
        case PxControlSlider: {
            label.frame = CGRectMake(12, 6, width - 90, 18);

            UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(width - 72, 6, 60, 18)];
            value.textAlignment = NSTextAlignmentRight;
            value.textColor = [UIColor colorWithRed:0.35 green:0.85 blue:0.60 alpha:1];
            value.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
            value.text = [self textForControl:control];
            value.tag = 7001;
            [row addSubview:value];

            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, 30, width - 24, 20)];
            slider.minimumValue = control.minValue;
            slider.maximumValue = control.maxValue;
            slider.value = control.floatValue;
            slider.minimumTrackTintColor = [UIColor colorWithRed:0.20 green:0.80 blue:0.50 alpha:1];
            slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.10];
            objc_setAssociatedObject(slider, kPxControlKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [row addSubview:slider];
            break;
        }
        case PxControlCombo: {
            UIButton *combo = [UIButton buttonWithType:UIButtonTypeCustom];
            combo.frame = CGRectMake(width - 108, 8, 96, row.frame.size.height - 16);
            combo.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
            combo.layer.cornerRadius = 7;
            combo.titleLabel.font = [UIFont systemFontOfSize:11];
            NSString *current = control.options.count > control.selectedIndex
                ? control.options[control.selectedIndex] : @"—";
            [combo setTitle:[current stringByAppendingString:@"  ▾"] forState:UIControlStateNormal];
            [combo setTitleColor:[UIColor colorWithWhite:0.85 alpha:1] forState:UIControlStateNormal];
            objc_setAssociatedObject(combo, kPxControlKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [combo addTarget:self action:@selector(comboTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:combo];
            break;
        }
        case PxControlButton: {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
            button.frame = CGRectMake(12, 4, width - 24, row.frame.size.height - 8);
            button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
            button.layer.cornerRadius = 7;
            button.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
            [button setTitle:control.title forState:UIControlStateNormal];
            [button setTitleColor:[UIColor colorWithWhite:0.9 alpha:1] forState:UIControlStateNormal];
            objc_setAssociatedObject(button, kPxControlKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [button addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];
            label.hidden = YES;
            [row addSubview:button];
            break;
        }
        case PxControlText: {
            label.frame = CGRectMake(12, 0, width - 164, row.frame.size.height);

            UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(width - 148, 8, 136, row.frame.size.height - 16)];
            field.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
            field.layer.cornerRadius = 7;
            field.textColor = [UIColor colorWithWhite:0.92 alpha:1];
            field.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
            field.textAlignment = NSTextAlignmentCenter;
            field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
            field.returnKeyType = UIReturnKeyDone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.text = control.textValue;
            field.attributedPlaceholder = [[NSAttributedString alloc]
                initWithString:control.placeholder ?: @""
                    attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.22]}];
            objc_setAssociatedObject(field, kPxControlKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [field addTarget:self action:@selector(textFieldChanged:)
                forControlEvents:UIControlEventEditingDidEnd | UIControlEventEditingDidEndOnExit];
            field.delegate = self;
            [row addSubview:field];
            break;
        }
    }
    return row;
}

- (NSString *)textForControl:(PxControl *)control {
    if (control.maxValue >= 100) {
        return [NSString stringWithFormat:@"%.0f%@", control.floatValue, control.unit];
    }
    return [NSString stringWithFormat:@"%.1f%@", control.floatValue, control.unit];
}

#pragma mark - Actions

- (void)switchChanged:(UISwitch *)sender {
    PxControl *control = objc_getAssociatedObject(sender, kPxControlKey);
    if (!control) return;
    control.boolValue = sender.on;
    if (control.handler) control.handler(control);
    // The overlay display link drives both the ESP draw loop and the periodic
    // skin re-apply, so it runs while either feature is on.
    if ([control.key isEqualToString:@"esp_players"] ||
        [control.key isEqualToString:@"skin_enable"]) {
        BOOL any = [PxStore boolForKey:@"esp_players"] || [PxStore boolForKey:@"skin_enable"];
        [[PxOverlay shared] setEnabled:any];
    }
}

- (void)textFieldChanged:(UITextField *)sender {
    PxControl *control = objc_getAssociatedObject(sender, kPxControlKey);
    if (!control) return;
    control.textValue = sender.text ?: @"";
    if (control.handler) control.handler(control);
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    [self textFieldChanged:textField];
}

- (void)sliderChanged:(UISlider *)sender {
    PxControl *control = objc_getAssociatedObject(sender, kPxControlKey);
    if (!control) return;
    control.floatValue = sender.value;
    UIView *row = sender.superview;
    UILabel *value = [row viewWithTag:7001];
    value.text = [self textForControl:control];
    if (control.handler) control.handler(control);
}

- (void)comboTapped:(UIButton *)sender {
    PxControl *control = objc_getAssociatedObject(sender, kPxControlKey);
    if (!control || control.options.count == 0) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:control.title
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)control.options.count; i++) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:control.options[i]
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *a) {
            control.selectedIndex = i;
            if (control.handler) control.handler(control);
            [self rebuildContent];
        }];
        [sheet addAction:action];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *host = [UIApplication sharedApplication].keyWindow.rootViewController;
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = sender;
        sheet.popoverPresentationController.sourceRect = sender.bounds;
    }
    [host presentViewController:sheet animated:YES completion:nil];
}

- (void)actionTapped:(UIButton *)sender {
    PxControl *control = objc_getAssociatedObject(sender, kPxControlKey);
    if (control && control.handler) control.handler(control);
    [self rebuildContent];
}

- (void)tabTapped:(UIButton *)sender {
    self.activeTab = sender.tag;
    [self rebuildContent];
}

- (void)masterChanged:(UISwitch *)sender {
    [PxStore shared].masterEnabled = sender.on;
    [[PxStore shared] persistAll];
    [[PxOverlay shared] setEnabled:sender.on];
}

- (void)searchChanged:(UITextField *)sender {
    [self rebuildContent];
}

- (void)dismissKeyboard {
    [self endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)closeTapped {
    [self hideMenu];
}

#pragma mark - Show / hide

- (void)showMenu {
    if (!self.hostWindow) {
        UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        window.windowLevel = UIWindowLevelAlert + 60;
        window.backgroundColor = [UIColor clearColor];
        window.rootViewController = [[UIViewController alloc] init];
        window.rootViewController.view.backgroundColor = [UIColor clearColor];
        window.hidden = NO;
        [window.rootViewController.view addSubview:self];
        self.hostWindow = window;
    }
    self.hostWindow.hidden = NO;
    self.hidden = NO;
    [self relayout];
    [self startDisplayLink];
}

- (void)hideMenu {
    self.hidden = YES;
    [self removeFromSuperview];
    self.hostWindow.hidden = YES;
    self.hostWindow = nil;
    [self stopDisplayLink];
}

- (void)toggleMenu {
    if (self.isVisible) [self hideMenu];
    else [self showMenu];
}

#pragma mark - FPS

- (void)startDisplayLink {
    if (self.displayLink) return;
    self.lastFrameTime = CACurrentMediaTime();
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkTick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopDisplayLink {
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)displayLinkTick:(CADisplayLink *)link {
    self.frameCount++;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval elapsed = now - self.lastFrameTime;
    if (elapsed >= 0.5) {
        NSInteger fps = (NSInteger)round(self.frameCount / elapsed);
        self.fpsLabel.text = [NSString stringWithFormat:@"%ld FPS  %.0fms", (long)fps, link.duration * 1000.0];
        self.frameCount = 0;
        self.lastFrameTime = now;
    }
}

@end
