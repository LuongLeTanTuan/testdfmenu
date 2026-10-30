#ifndef PXSTORE_H
#define PXSTORE_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PxControlType) {
    PxControlSwitch = 0,
    PxControlSlider,
    PxControlCombo,
    PxControlButton,
    PxControlText,
};

@interface PxControl : NSObject
@property (nonatomic, assign) PxControlType type;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) BOOL boolValue;
@property (nonatomic, assign) float floatValue;
@property (nonatomic, assign) float minValue;
@property (nonatomic, assign) float maxValue;
@property (nonatomic, copy) NSString *unit;
@property (nonatomic, copy) NSArray<NSString *> *options;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, copy) NSString *textValue;
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic, copy) void (^handler)(PxControl *control);
@end

@interface PxSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSMutableArray<PxControl *> *controls;
+ (instancetype)sectionWithTitle:(NSString *)title;
- (PxControl *)addSwitch:(NSString *)title key:(NSString *)key handler:(void (^)(BOOL on))handler;
- (PxControl *)addSlider:(NSString *)title key:(NSString *)key unit:(NSString *)unit
                     min:(float)min max:(float)max handler:(void (^)(float value))handler;
- (PxControl *)addCombo:(NSString *)title key:(NSString *)key
                options:(NSArray<NSString *> *)options handler:(void (^)(NSInteger index))handler;
- (PxControl *)addButton:(NSString *)title handler:(void (^)(void))handler;
- (PxControl *)addText:(NSString *)title key:(NSString *)key
           placeholder:(NSString *)placeholder handler:(void (^)(NSString *text))handler;
@end

@interface PxTab : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSMutableArray<PxSection *> *sections;   // left column
@property (nonatomic, strong) NSMutableArray<PxSection *> *rightSections;
+ (instancetype)tabWithTitle:(NSString *)title;
- (PxSection *)addSection:(NSString *)title;
- (PxSection *)addRightSection:(NSString *)title;
@end

@interface PxStore : NSObject

+ (instancetype)shared;

@property (nonatomic, strong) NSArray<PxTab *> *tabs;
@property (nonatomic, assign) BOOL masterEnabled;

- (void)loadDefaults;
- (void)persistAll;

+ (BOOL)boolForKey:(NSString *)key;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;
+ (float)floatForKey:(NSString *)key;
+ (void)setFloat:(float)value forKey:(NSString *)key;
+ (NSInteger)integerForKey:(NSString *)key;
+ (void)setInteger:(NSInteger)value forKey:(NSString *)key;
+ (NSString *)stringForKey:(NSString *)key;
+ (void)setString:(NSString *)value forKey:(NSString *)key;

@end

#endif
