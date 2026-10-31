TARGET := iphone:clang:latest:14.0
ARCHS = arm64

# Theos resolves the SDK by name. When that resolution misses, clang and ld fall
# back to a macOS target and the linker stamps LC_VERSION_MIN_MACOSX into the
# image. dyld on iOS then refuses to load it and the host aborts before any
# constructor runs -- which is exactly a launch crash with an empty log. Pin the
# triple so the platform can never depend on SDK discovery.
#
# 14.0, not 15.0: dyld refuses a dylib whose LC_BUILD_VERSION minos is above the
# host, and the second device runs 14.8.1.
PX_TRIPLE = -target arm64-apple-ios14.0

include $(THEOS)/makefiles/common.mk

# The first line of PxBoot.log names the commit that produced the dylib. Two
# builds of one commit get different LC_UUIDs, so the sha256 changes every time
# and cannot answer "which build is on the device". The commit can.
PX_GIT := $(shell git rev-parse --short HEAD 2>/dev/null)
PX_TAG = $(if $(PX_GIT),$(PX_GIT),dev)

LIBRARY_NAME = PxMenu PxMenuLite AnoMute

PxMenu_FILES = \
    PxMenu.m \
    Menu/PxStore.m \
    Menu/PxMenuView.m \
    Menu/PxOverlay.m \
    Menu/PxUE4.mm \
    Menu/PxFloatingButton.m \
    AnoMute/AnoMute.m

PxMenu_CFLAGS = -fobjc-arc -Wall -Wno-unused-parameter -Wno-deprecated-declarations -Wno-unguarded-availability-new -IMenu -DPX_BUILD_TAG=\"$(PX_TAG)\" $(PX_TRIPLE)
PxMenu_CCFLAGS = -fobjc-arc -Wall -Wno-unused-parameter -Wno-deprecated-declarations -Wno-unguarded-availability-new -std=gnu++17 -IMenu -DPX_BUILD_TAG=\"$(PX_TAG)\" $(PX_TRIPLE)
PxMenu_FRAMEWORKS = UIKit Foundation QuartzCore
# No -Wl,-u,_OBJC_CLASS_$_PxEntry here: the shell eats $_PxEntry on the way to
# the linker and the build dies on "_OBJC_CLASS_". The class list is not the
# load path anyway -- see the __DATA,__mod_init_func pointer in PxMenu.m, which
# is what survives on every dyld from iOS 4 to 18.
PxMenu_LDFLAGS = -undefined dynamic_lookup -Wl,-not_for_dyld_shared_cache $(PX_TRIPLE)

PxMenuLite_FILES = $(PxMenu_FILES)
PxMenuLite_CFLAGS = $(PxMenu_CFLAGS) -DPX_LITE=1
PxMenuLite_CCFLAGS = $(PxMenu_CCFLAGS) -DPX_LITE=1
PxMenuLite_FRAMEWORKS = $(PxMenu_FRAMEWORKS)
PxMenuLite_LDFLAGS = $(PxMenu_LDFLAGS)

# Standalone: rebinds the host's anogs import slots. Drop the inject line for
# this one if you would rather fold it into PxMenu (see README, "One dylib").
AnoMute_FILES = AnoMute/AnoMute.m
AnoMute_CFLAGS = -fobjc-arc -Wall -Wno-unused-parameter -Wno-deprecated-declarations -Wno-unguarded-availability-new $(PX_TRIPLE)
AnoMute_FRAMEWORKS = Foundation
AnoMute_LDFLAGS = -undefined dynamic_lookup -Wl,-not_for_dyld_shared_cache $(PX_TRIPLE)

include $(THEOS_MAKE_PATH)/library.mk
