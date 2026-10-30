TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = PxMenu PxMenuLite AnoMute

PxMenu_FILES = \
    PxMenu.m \
    Menu/PxStore.m \
    Menu/PxMenuView.m \
    Menu/PxOverlay.m \
    Menu/PxUE4.mm \
    Menu/PxFloatingButton.m

PxMenu_CFLAGS = -fobjc-arc -Wall -Wno-unused-parameter -IMenu
PxMenu_CCFLAGS = -fobjc-arc -Wall -Wno-unused-parameter -std=gnu++17 -IMenu
PxMenu_FRAMEWORKS = UIKit Foundation QuartzCore
PxMenu_LDFLAGS = -undefined dynamic_lookup

PxMenuLite_FILES = $(PxMenu_FILES)
PxMenuLite_CFLAGS = $(PxMenu_CFLAGS) -DPX_LITE=1
PxMenuLite_CCFLAGS = $(PxMenu_CCFLAGS) -DPX_LITE=1
PxMenuLite_FRAMEWORKS = $(PxMenu_FRAMEWORKS)
PxMenuLite_LDFLAGS = $(PxMenu_LDFLAGS)

# Standalone: rebinds the host's anogs import slots. Drop the inject line for
# this one if you would rather fold it into PxMenu (see README, "One dylib").
AnoMute_FILES = AnoMute/AnoMute.m
AnoMute_CFLAGS = -fobjc-arc -Wall -Wno-unused-parameter
AnoMute_FRAMEWORKS = Foundation
AnoMute_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/library.mk
