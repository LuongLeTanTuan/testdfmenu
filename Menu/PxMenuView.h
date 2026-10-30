#ifndef PXMENUVIEW_H
#define PXMENUVIEW_H

#import <UIKit/UIKit.h>
#import "PxStore.h"

@interface PxMenuView : UIView

+ (instancetype)shared;
- (void)showMenu;
- (void)hideMenu;
- (void)toggleMenu;
@property (nonatomic, readonly) BOOL isVisible;

@end

#endif
