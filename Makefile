TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VolumeBoostYT

VolumeBoostYT_FILES = Tweak.x PlaybackPersistence.x BassBoost.x YTVolumeHUD.m YTBassHUD.m
VolumeBoostYT_CFLAGS = -fobjc-arc
VolumeBoostYT_FRAMEWORKS = UIKit AVFoundation AudioToolbox CoreMedia MediaToolbox
VolumeBoostYT_LOGOSFLAGS = -c generator=internal

before-all::
	@python3 -c 'p="Tweak.x"; s=open(p).read(); s=s.replace("#define ENABLE_VOLUME_PERSISTENCE 0", "#define ENABLE_VOLUME_PERSISTENCE 1").replace("  NSMutableArray *mutableCategories = %orig.mutableCopy;", "  NSArray<NSNumber *> *categories = %orig;\\n  NSMutableArray<NSNumber *> *mutableCategories = [categories mutableCopy];"); open(p, "w").write(s)'

include $(THEOS_MAKE_PATH)/tweak.mk
