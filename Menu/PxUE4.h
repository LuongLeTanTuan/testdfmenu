#ifndef PXUE4_H
#define PXUE4_H

#import <UIKit/UIKit.h>

// One projected enemy. Filled by PxUE4, consumed by PxOverlay.
typedef struct {
    CGRect rect;        // screen-space box, points
    float  distance;    // metres
    float  health;
    float  healthMax;
} PxEntity;

@interface PxUE4 : NSObject

+ (instancetype)shared;

// YES once GNames + GObjects + ProcessEvent index are all resolved.
@property (nonatomic, readonly) BOOL ready;

// Discovers the UE4 globals inside the host process. Cheap after the first
// successful call; retries while unresolved.
- (void)scanIfNeeded;
- (void)invalidate;

// Projects every live enemy into `out`. Returns the number written (<= max).
- (NSUInteger)collectEntities:(PxEntity *)out max:(NSUInteger)max viewSize:(CGSize)size;

- (NSString *)statusLine;

// Calls the reflected SetSkin setter on the weapon descriptor owned by the
// local player. Nothing is patched; only ProcessEvent runs.
// Returns 1 on success, 0 when no descriptor resolved, and a negative code:
// -1 runtime not ready, -2 descriptor class missing, -3 setter missing.
- (NSInteger)applySkin:(int32_t)skinId;

// Full diagnostic text, also written to Documents/PxUE4.log.
- (NSString *)dumpReport;

@end

// One line into Documents/PxBoot.log from anywhere in the dylib, so the menu and
// the injector leave a trail even when no UE4 state exists yet.
void PxLogShared(NSString *fmt, ...);

#endif
