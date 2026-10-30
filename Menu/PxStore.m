#import "PxStore.h"
#import "PxUE4.h"
#import <UIKit/UIKit.h>
#import <stdlib.h>

static void PxToast(NSString *message) {
    if (message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *key = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        UIViewController *vc = key.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) return;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"PxUE4"
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

@implementation PxControl

- (instancetype)init {
    if ((self = [super init])) {
        _minValue = 0.0f;
        _maxValue = 100.0f;
        _unit = @"";
    }
    return self;
}

@end

@implementation PxSection

+ (instancetype)sectionWithTitle:(NSString *)title {
    PxSection *section = [[PxSection alloc] init];
    section.title = title;
    section.controls = [NSMutableArray array];
    return section;
}

- (PxControl *)addSwitch:(NSString *)title key:(NSString *)key handler:(void (^)(BOOL))handler {
    PxControl *control = [[PxControl alloc] init];
    control.type = PxControlSwitch;
    control.key = key;
    control.title = title;
    control.boolValue = [PxStore boolForKey:key];
    control.handler = ^(PxControl *c) {
        [PxStore setBool:c.boolValue forKey:c.key];
        if (handler) handler(c.boolValue);
    };
    [self.controls addObject:control];
    return control;
}

- (PxControl *)addSlider:(NSString *)title key:(NSString *)key unit:(NSString *)unit
                     min:(float)min max:(float)max handler:(void (^)(float))handler {
    PxControl *control = [[PxControl alloc] init];
    control.type = PxControlSlider;
    control.key = key;
    control.title = title;
    control.unit = unit ?: @"";
    control.minValue = min;
    control.maxValue = max;
    NSString *storedKey = [@"px_" stringByAppendingString:key];
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:storedKey];
    // Midpoint is the sane first-run value for every slider here (FOV -> 90,
    // Max Distance -> 525, Opacity -> 55). Persisted from the first open so the
    // UI and the overlay agree.
    control.floatValue = stored ? [[NSUserDefaults standardUserDefaults] floatForKey:storedKey]
                                : (min + max) * 0.5f;
    if (!stored) [[NSUserDefaults standardUserDefaults] setFloat:control.floatValue forKey:storedKey];
    control.handler = ^(PxControl *c) {
        [PxStore setFloat:c.floatValue forKey:c.key];
        if (handler) handler(c.floatValue);
    };
    [self.controls addObject:control];
    return control;
}

- (PxControl *)addCombo:(NSString *)title key:(NSString *)key
                options:(NSArray<NSString *> *)options handler:(void (^)(NSInteger))handler {
    PxControl *control = [[PxControl alloc] init];
    control.type = PxControlCombo;
    control.key = key;
    control.title = title;
    control.options = options;
    control.selectedIndex = [PxStore integerForKey:key];
    if (control.selectedIndex >= (NSInteger)options.count) control.selectedIndex = 0;
    control.handler = ^(PxControl *c) {
        [PxStore setInteger:c.selectedIndex forKey:c.key];
        if (handler) handler(c.selectedIndex);
    };
    [self.controls addObject:control];
    return control;
}

- (PxControl *)addButton:(NSString *)title handler:(void (^)(void))handler {
    PxControl *control = [[PxControl alloc] init];
    control.type = PxControlButton;
    control.key = [NSString stringWithFormat:@"btn_%@", title];
    control.title = title;
    control.handler = ^(PxControl *c) {
        if (handler) handler();
    };
    [self.controls addObject:control];
    return control;
}

- (PxControl *)addText:(NSString *)title key:(NSString *)key
           placeholder:(NSString *)placeholder handler:(void (^)(NSString *))handler {
    PxControl *control = [[PxControl alloc] init];
    control.type = PxControlText;
    control.key = key;
    control.title = title;
    control.placeholder = placeholder;
    control.textValue = [PxStore stringForKey:key] ?: @"";
    control.handler = ^(PxControl *c) {
        [PxStore setString:c.textValue ?: @"" forKey:c.key];
        if (handler) handler(c.textValue);
    };
    [self.controls addObject:control];
    return control;
}

@end

@implementation PxTab

+ (instancetype)tabWithTitle:(NSString *)title {
    PxTab *tab = [[PxTab alloc] init];
    tab.title = title;
    tab.sections = [NSMutableArray array];
    tab.rightSections = [NSMutableArray array];
    return tab;
}

- (PxSection *)addSection:(NSString *)title {
    PxSection *section = [PxSection sectionWithTitle:title];
    [self.sections addObject:section];
    return section;
}

- (PxSection *)addRightSection:(NSString *)title {
    PxSection *section = [PxSection sectionWithTitle:title];
    [self.rightSections addObject:section];
    return section;
}

@end

static NSString * const kPxMasterKey = @"px_master";

@implementation PxStore

+ (instancetype)shared {
    static PxStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[PxStore alloc] init];
        [store loadDefaults];
    });
    return store;
}

+ (NSString *)storageKey:(NSString *)key {
    return [@"px_" stringByAppendingString:key];
}

+ (BOOL)boolForKey:(NSString *)key {
    return [[NSUserDefaults standardUserDefaults] boolForKey:[self storageKey:key]];
}

+ (void)setBool:(BOOL)value forKey:(NSString *)key {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:[self storageKey:key]];
}

+ (float)floatForKey:(NSString *)key {
    return (float)[[NSUserDefaults standardUserDefaults] floatForKey:[self storageKey:key]];
}

+ (void)setFloat:(float)value forKey:(NSString *)key {
    [[NSUserDefaults standardUserDefaults] setFloat:value forKey:[self storageKey:key]];
}

+ (NSInteger)integerForKey:(NSString *)key {
    return [[NSUserDefaults standardUserDefaults] integerForKey:[self storageKey:key]];
}

+ (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    [[NSUserDefaults standardUserDefaults] setInteger:value forKey:[self storageKey:key]];
}

+ (NSString *)stringForKey:(NSString *)key {
    return [[NSUserDefaults standardUserDefaults] stringForKey:[self storageKey:key]];
}

+ (void)setString:(NSString *)value forKey:(NSString *)key {
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:[self storageKey:key]];
}

- (void)loadDefaults {
    self.masterEnabled = [PxStore boolForKey:kPxMasterKey];
    self.tabs = [self buildTabs];
}

- (void)persistAll {
    [PxStore setBool:self.masterEnabled forKey:kPxMasterKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// The menu tree. Feature handlers are the injection points where game logic
// attaches; the shell itself is complete without them.
- (NSArray<PxTab *> *)buildTabs {
    PxTab *gun = [PxTab tabWithTitle:@"Gun"];
    PxSection *aim = [gun addSection:@"Aim"];
    [aim addSwitch:@"Silent Aim" key:@"aim_silent" handler:nil];
    [aim addSwitch:@"Visible Check" key:@"aim_visible" handler:nil];
    [aim addSwitch:@"Ignore Knocked" key:@"aim_ignore_knocked" handler:nil];
    [aim addSlider:@"FOV" key:@"aim_fov" unit:@"°" min:1 max:180 handler:nil];
    [aim addSlider:@"Smooth" key:@"aim_smooth" unit:@"x" min:1 max:20 handler:nil];
    [aim addSlider:@"Bone Height" key:@"aim_bone" unit:@"" min:0 max:100 handler:nil];
    PxSection *gunRight = [gun addRightSection:@"Weapon"];
    [gunRight addSwitch:@"No Recoil" key:@"wpn_no_recoil" handler:nil];
    [gunRight addSwitch:@"No Spread" key:@"wpn_no_spread" handler:nil];
    [gunRight addSwitch:@"Infinite Ammo" key:@"wpn_inf_ammo" handler:nil];
    [gunRight addSwitch:@"Fast Reload" key:@"wpn_fast_reload" handler:nil];
    [gunRight addCombo:@"Fire Mode" key:@"wpn_fire_mode"
               options:@[@"Auto", @"Burst", @"Single"] handler:nil];

    PxTab *hero = [PxTab tabWithTitle:@"Hero"];
    PxSection *heroLeft = [hero addSection:@"Player"];
    [heroLeft addSwitch:@"God Mode" key:@"hero_god" handler:nil];
    [heroLeft addSwitch:@"No Skill Cooldown" key:@"hero_no_cd" handler:nil];
    [heroLeft addSwitch:@"Infinite Stamina" key:@"hero_inf_stamina" handler:nil];
    [heroLeft addSlider:@"Speed" key:@"hero_speed" unit:@"x" min:1 max:10 handler:nil];
    [heroLeft addSlider:@"Jump Boost" key:@"hero_jump" unit:@"x" min:1 max:5 handler:nil];
    PxSection *heroRight = [hero addRightSection:@"Abilities"];
    [heroRight addSwitch:@"Instant Cast" key:@"hero_instant_cast" handler:nil];
    [heroRight addSwitch:@"Auto Dodge" key:@"hero_auto_dodge" handler:nil];
    [heroRight addSwitch:@"Rapid Fire" key:@"hero_rapid_fire" handler:nil];
    [heroRight addCombo:@"Skill Slot" key:@"hero_skill_slot"
                options:@[@"Slot 1", @"Slot 2", @"Slot 3"] handler:nil];

    PxTab *melee = [PxTab tabWithTitle:@"Melee"];
    PxSection *meleeLeft = [melee addSection:@"Combat"];
    [meleeLeft addSwitch:@"Auto Parry" key:@"melee_auto_parry" handler:nil];
    [meleeLeft addSwitch:@"Combo Assist" key:@"melee_combo_assist" handler:nil];
    [meleeLeft addSwitch:@"Perfect Dodge" key:@"melee_perfect_dodge" handler:nil];
    [meleeLeft addSlider:@"Attack Range" key:@"melee_range" unit:@"m" min:1 max:15 handler:nil];
    PxSection *meleeRight = [melee addRightSection:@"Timing"];
    [meleeRight addSlider:@"Parry Window" key:@"melee_parry_window" unit:@"ms" min:50 max:500 handler:nil];
    [meleeRight addSwitch:@"Cancel Recovery" key:@"melee_cancel_recovery" handler:nil];
    [meleeRight addSwitch:@"Stamina Bypass" key:@"melee_stamina_bypass" handler:nil];

    PxTab *visuals = [PxTab tabWithTitle:@"Visuals"];
    PxSection *esp = [visuals addSection:@"ESP"];
    [esp addSwitch:@"Players" key:@"esp_players" handler:nil];
    [esp addSwitch:@"Box" key:@"esp_box" handler:nil];
    [esp addSwitch:@"Skeleton" key:@"esp_skeleton" handler:nil];
    [esp addSwitch:@"Distance" key:@"esp_distance" handler:nil];
    [esp addSwitch:@"Health Bar" key:@"esp_health" handler:nil];
    [esp addSlider:@"Max Distance" key:@"esp_max_dist" unit:@"m" min:50 max:1000 handler:nil];
    PxSection *visualsRight = [visuals addRightSection:@"Render"];
    [visualsRight addSlider:@"Opacity" key:@"vis_opacity" unit:@"%" min:10 max:100 handler:nil];
    [visualsRight addCombo:@"Box Style" key:@"vis_box_style"
                   options:@[@"Corner", @"Full", @"3D"] handler:nil];
    [visualsRight addCombo:@"Color" key:@"vis_color"
                   options:@[@"Green", @"Red", @"Cyan", @"Magenta"] handler:nil];
    [visualsRight addSwitch:@"Show FPS" key:@"vis_fps" handler:nil];

    PxTab *ue4 = [PxTab tabWithTitle:@"UE4"];
    PxSection *ue4Left = [ue4 addSection:@"Runtime"];
    [ue4Left addButton:@"Rescan" handler:^{
        [[PxUE4 shared] invalidate];
        [[PxUE4 shared] scanIfNeeded];
        PxToast([[PxUE4 shared] statusLine]);
    }];
    [ue4Left addButton:@"Dump to Documents" handler:^{
        [[PxUE4 shared] scanIfNeeded];
        [[PxUE4 shared] dumpReport];
        PxToast([[PxUE4 shared] statusLine]);
    }];
    PxSection *ue4Right = [ue4 addRightSection:@"ESP"];
    [ue4Right addSlider:@"Camera FOV" key:@"esp_fov" unit:@"°" min:40 max:140 handler:nil];
    [ue4Right addSwitch:@"Team Check" key:@"esp_team_check" handler:nil];

    PxTab *skin = [PxTab tabWithTitle:@"Skin"];
    PxSection *skinLeft = [skin addSection:@"Weapon"];
    [skinLeft addSwitch:@"Auto Re-apply" key:@"skin_enable" handler:nil];
    [skinLeft addText:@"Gun Skin ID" key:@"skin_gun_id" placeholder:@"numeric id" handler:nil];
    [skinLeft addButton:@"Apply Skin" handler:^{
        NSString *raw = [[PxStore stringForKey:@"skin_gun_id"]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (raw.length == 0) { PxToast(@"Enter a skin ID first."); return; }
        int32_t skinId = (int32_t)strtoul(raw.UTF8String, NULL, 10);
        NSInteger result = [[PxUE4 shared] applySkin:skinId];
        switch (result) {
            case 1:  PxToast([NSString stringWithFormat:@"Skin %d sent to the held weapon.", skinId]); break;
            case 0:  PxToast(@"No weapon descriptor yet. Hold the gun in a match."); break;
            case -1: PxToast(@"UE4 runtime not ready. Check the UE4 tab."); break;
            case -2: PxToast(@"ModularWeaponDesc class not found."); break;
            default: PxToast(@"SetSkin function not found on the descriptor."); break;
        }
    }];
    PxSection *skinRight = [skin addRightSection:@"State"];
    [skinRight addButton:@"Restore Default (0)" handler:^{
        NSInteger result = [[PxUE4 shared] applySkin:0];
        PxToast(result == 1 ? @"Default skin restored." : @"Nothing to restore yet.");
    }];
    [skinRight addButton:@"Runtime Status" handler:^{
        PxToast([[PxUE4 shared] statusLine]);
    }];

    PxTab *misc = [PxTab tabWithTitle:@"Misc"];
    PxSection *miscLeft = [misc addSection:@"System"];
    [miscLeft addSwitch:@"Master Switch" key:kPxMasterKey handler:nil];
    [miscLeft addSlider:@"Menu Opacity" key:@"misc_menu_alpha" unit:@"%" min:40 max:100 handler:nil];
    [miscLeft addSwitch:@"Hide on Screenshot" key:@"misc_secure" handler:nil];
    [miscLeft addButton:@"Reset Config" handler:^{
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        for (NSString *key in ud.dictionaryRepresentation.allKeys) {
            if ([key hasPrefix:@"px_"]) [ud removeObjectForKey:key];
        }
        [ud synchronize];
    }];
    PxSection *miscRight = [misc addRightSection:@"Info"];
    [miscRight addButton:@"Contact" handler:^{
        NSURL *url = [NSURL URLWithString:@"https://t.me/"];
        if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }];

    return @[gun, hero, melee, visuals, skin, ue4, misc];
}

@end
