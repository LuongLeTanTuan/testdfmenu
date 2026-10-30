#import "PxStore.h"
#import "PxUE4.h"
#import "PxSkinCatalog.h"
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

static PxTab *pxBuildSkinTab(void) {
    PxTab *skin = [PxTab tabWithTitle:@"Skin"];
    PxSection *skinLeft = [skin addSection:@"Catalog Picker"];

    NSMutableArray<NSString *> *weaponNames = [NSMutableArray arrayWithCapacity:kPxWeaponCount];
    for (uint32_t i = 0; i < kPxWeaponCount; i++) {
        [weaponNames addObject:[NSString stringWithUTF8String:kPxWeaponNames[i]]];
    }

    NSInteger currentWpnIdx = [PxStore integerForKey:@"skin_weapon_idx"];
    if (currentWpnIdx < 0 || currentWpnIdx >= (NSInteger)kPxWeaponCount) currentWpnIdx = 0;

    NSArray<NSString *> *(^skinsForWeapon)(uint32_t) = ^NSArray<NSString *> *(uint32_t wIdx) {
        uint32_t count = pxSkinCountForWeapon(wIdx);
        NSMutableArray<NSString *> *list = [NSMutableArray arrayWithCapacity:count];
        for (uint32_t s = 0; s < count; s++) {
            const PxSkinEntry *entry = pxSkinForWeaponAt(wIdx, s);
            if (entry && entry->name) {
                [list addObject:[NSString stringWithUTF8String:entry->name]];
            } else {
                [list addObject:[NSString stringWithFormat:@"Skin #%u", s + 1]];
            }
        }
        if (list.count == 0) [list addObject:@"Default / None"];
        return list;
    };

    NSArray<NSString *> *initSkins = skinsForWeapon((uint32_t)currentWpnIdx);
    NSInteger currentSkinIdx = [PxStore integerForKey:@"skin_select_idx"];
    if (currentSkinIdx < 0 || currentSkinIdx >= (NSInteger)initSkins.count) currentSkinIdx = 0;

    __block PxControl *skinCombo = nil;
    [skinLeft addCombo:@"Weapon" key:@"skin_weapon_idx" options:weaponNames handler:^(NSInteger newWpnIdx) {
        if (newWpnIdx < 0 || newWpnIdx >= (NSInteger)kPxWeaponCount) return;
        [PxStore setInteger:newWpnIdx forKey:@"skin_weapon_idx"];
        NSArray<NSString *> *newSkins = skinsForWeapon((uint32_t)newWpnIdx);
        if (skinCombo) {
            skinCombo.options = newSkins;
            skinCombo.selectedIndex = 0;
            [PxStore setInteger:0 forKey:@"skin_select_idx"];
            const PxSkinEntry *firstSkin = pxSkinForWeaponAt((uint32_t)newWpnIdx, 0);
            if (firstSkin) {
                NSString *hexId = [NSString stringWithFormat:@"0x%08X", firstSkin->skinId];
                [PxStore setString:hexId forKey:@"skin_gun_id"];
            }
        }
    }];

    skinCombo = [skinLeft addCombo:@"Skin" key:@"skin_select_idx" options:initSkins handler:^(NSInteger newSkinIdx) {
        NSInteger wIdx = [PxStore integerForKey:@"skin_weapon_idx"];
        if (wIdx < 0 || wIdx >= (NSInteger)kPxWeaponCount) wIdx = 0;
        const PxSkinEntry *entry = pxSkinForWeaponAt((uint32_t)wIdx, (uint32_t)newSkinIdx);
        if (entry) {
            NSString *hexId = [NSString stringWithFormat:@"0x%08X", entry->skinId];
            [PxStore setString:hexId forKey:@"skin_gun_id"];
        }
    }];

    NSString *curRaw = [PxStore stringForKey:@"skin_gun_id"];
    if (curRaw.length == 0) {
        const PxSkinEntry *entry = pxSkinForWeaponAt((uint32_t)currentWpnIdx, (uint32_t)currentSkinIdx);
        if (entry) {
            [PxStore setString:[NSString stringWithFormat:@"0x%08X", entry->skinId] forKey:@"skin_gun_id"];
        }
    }

    [skinLeft addText:@"Custom ID" key:@"skin_gun_id" placeholder:@"0x8588D162 or decimal" handler:nil];

    PxSection *skinRight = [skin addRightSection:@"Actions"];
    [skinRight addSwitch:@"Auto Re-apply" key:@"skin_enable" handler:nil];

    [skinRight addButton:@"Apply Skin" handler:^{
        NSString *raw = [[PxStore stringForKey:@"skin_gun_id"]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        int32_t skinId = 0;
        if (raw.length > 0) {
            skinId = (int32_t)strtoul(raw.UTF8String, NULL, 0);
        } else {
            NSInteger wIdx = [PxStore integerForKey:@"skin_weapon_idx"];
            NSInteger sIdx = [PxStore integerForKey:@"skin_select_idx"];
            const PxSkinEntry *entry = pxSkinForWeaponAt((uint32_t)wIdx, (uint32_t)sIdx);
            if (entry) skinId = (int32_t)entry->skinId;
        }

        if (skinId == 0) {
            PxToast(@"Select a skin or enter a valid ID first.");
            return;
        }

        NSInteger result = [[PxUE4 shared] applySkin:skinId];
        switch (result) {
            case 1:  PxToast([NSString stringWithFormat:@"Skin 0x%X applied via descriptor.", skinId]); break;
            case 2:  PxToast([NSString stringWithFormat:@"Skin 0x%X applied via Appearance Data Component.", skinId]); break;
            case 3:  PxToast([NSString stringWithFormat:@"Skin 0x%X applied via descriptor + Data Component.", skinId]); break;
            case 4:  PxToast([NSString stringWithFormat:@"Skin 0x%X applied via Appearance Func Component.", skinId]); break;
            case 5:
            case 6:
            case 7:  PxToast([NSString stringWithFormat:@"Skin 0x%X applied via all components (hops 0x%lX).", skinId, (long)result]); break;
            case 0:  PxToast(@"No weapon/appearance component ready. Hold gun in match."); break;
            case -1: PxToast(@"UE4 runtime not ready yet."); break;
            case -2: PxToast(@"Weapon/Appearance classes not found in UE4."); break;
            case -3: PxToast(@"SetSkin setter functions not found."); break;
            default: PxToast([NSString stringWithFormat:@"applySkin code: %ld", (long)result]); break;
        }
    }];

    [skinRight addButton:@"Restore Default (0)" handler:^{
        NSInteger result = [[PxUE4 shared] applySkin:0];
        if (result > 0) {
            PxToast(@"Default weapon appearance restored.");
        } else {
            PxToast(@"Nothing to restore yet (hold weapon in match).");
        }
    }];

    [skinRight addButton:@"Runtime Status" handler:^{
        PxToast([[PxUE4 shared] statusLine]);
    }];

    return skin;
}

#if defined(PX_LITE)

- (NSArray<PxTab *> *)buildTabs {
    // 1. ESP / Visuals tab
    PxTab *visuals = [PxTab tabWithTitle:@"ESP"];
    PxSection *esp = [visuals addSection:@"Player ESP"];
    [esp addSwitch:@"Players" key:@"esp_players" handler:nil];
    [esp addSwitch:@"Box" key:@"esp_box" handler:nil];
    [esp addSwitch:@"Skeleton" key:@"esp_skeleton" handler:nil];
    [esp addSwitch:@"Distance" key:@"esp_distance" handler:nil];
    [esp addSwitch:@"Health Bar" key:@"esp_health" handler:nil];
    [esp addSwitch:@"Team Check" key:@"esp_team_check" handler:nil];
    [esp addSlider:@"Max Distance" key:@"esp_max_dist" unit:@"m" min:50 max:1000 handler:nil];

    PxSection *visualsRight = [visuals addRightSection:@"Render & Style"];
    [visualsRight addSlider:@"Opacity" key:@"vis_opacity" unit:@"%" min:10 max:100 handler:nil];
    [visualsRight addCombo:@"Box Style" key:@"vis_box_style"
                   options:@[@"Corner", @"Full", @"3D"] handler:nil];
    [visualsRight addCombo:@"Color" key:@"vis_color"
                   options:@[@"Green", @"Red", @"Cyan", @"Magenta"] handler:nil];
    [visualsRight addSlider:@"Camera FOV" key:@"esp_fov" unit:@"°" min:40 max:140 handler:nil];
    [visualsRight addSwitch:@"Show FPS" key:@"vis_fps" handler:nil];

    // 2. ModSkin Tab with full 85-weapon / 705-skin catalog picker
    PxTab *skin = pxBuildSkinTab();

    // 3. System Diagnostics & Settings tab
    PxTab *diag = [PxTab tabWithTitle:@"System"];
    PxSection *diagLeft = [diag addSection:@"UE4 Runtime"];
    [diagLeft addButton:@"Rescan UE4" handler:^{
        [[PxUE4 shared] invalidate];
        [[PxUE4 shared] scanIfNeeded];
        PxToast([[PxUE4 shared] statusLine]);
    }];
    [diagLeft addButton:@"Dump to Documents" handler:^{
        [[PxUE4 shared] scanIfNeeded];
        [[PxUE4 shared] dumpReport];
        PxToast([[PxUE4 shared] statusLine]);
    }];
    [diagLeft addButton:@"Runtime Status" handler:^{
        PxToast([[PxUE4 shared] statusLine]);
    }];

    PxSection *diagRight = [diag addRightSection:@"Settings"];
    [diagRight addSwitch:@"Master Switch" key:kPxMasterKey handler:nil];
    [diagRight addSlider:@"Menu Opacity" key:@"misc_menu_alpha" unit:@"%" min:40 max:100 handler:nil];
    [diagRight addSwitch:@"Hide on Screenshot" key:@"misc_secure" handler:nil];
    [diagRight addButton:@"Reset Config" handler:^{
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        for (NSString *key in ud.dictionaryRepresentation.allKeys) {
            if ([key hasPrefix:@"px_"]) [ud removeObjectForKey:key];
        }
        [ud synchronize];
        PxToast(@"Config reset to defaults.");
    }];

    return @[visuals, skin, diag];
}

#else

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

    PxTab *skin = pxBuildSkinTab();

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

#endif

@end
