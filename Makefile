TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = PxMenu

PxMenu_FILES = \
    PxMenu.m \
    Menu/PxStore.m \
    Menu/PxMenuView.m \
    Menu/PxOverlay.m \
    Menu/PxUE4.mm \
    Menu/PxFloatingButton.m

PxMenu_CFLAGS = -fobjc-arc -Wall -Wno-unused-parameter
PxMenu_CCFLAGS = -fobjc-arc -Wall -Wno-unused-parameter -std=gnu++17
PxMenu_FRAMEWORKS = UIKit Foundation QuartzCore
PxMenu_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/library.mk
