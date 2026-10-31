#ifndef PXFLOATINGBUTTON_H
#define PXFLOATINGBUTTON_H

#import <UIKit/UIKit.h>

// A plain UIView, not a UIWindow. A UIWindow made off to the side only appears
// on iOS 13+ once it has a windowScene, and a game that owns its scene can leave
// that assignment silently ineffective -- the window exists, hidden is NO, and
// nothing is on screen. A subview of the key window cannot miss that way.
@interface PxFloatingButton : UIView

+ (instancetype)shared;
- (void)showButton;
- (void)hideButton;

@end

#endif
