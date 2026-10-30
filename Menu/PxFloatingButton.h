#ifndef PXFLOATINGBUTTON_H
#define PXFLOATINGBUTTON_H

#import <UIKit/UIKit.h>

@interface PxFloatingButton : UIWindow

+ (instancetype)shared;
- (void)showButton;
- (void)hideButton;

@end

#endif
