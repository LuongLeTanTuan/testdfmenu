#ifndef PXOVERLAY_H
#define PXOVERLAY_H

#import <UIKit/UIKit.h>

@interface PxOverlay : UIView

+ (instancetype)shared;
+ (void)install;
- (void)setEnabled:(BOOL)enabled;
- (void)refresh;

@end

#endif
