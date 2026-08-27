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
	@python3 -c 'p="BassBoost.x"; s=open(p).read(); s=s.replace("[self updateVolumeBoostYTBassSectionWithEntry:entry];", "[self performSelector:@selector(updateVolumeBoostYTBassSectionWithEntry:) withObject:entry];"); open(p, "w").write(s)'
	@python3 -c 'p="BassBoost.x"; s=open(p).read(); old="""  MTAudioProcessingTapCallbacks callbacks = {\n      kMTAudioProcessingTapCallbacksVersion_0,\n      NULL,\n      BassTapInit,\n      BassTapFinalize,\n      BassTapPrepare,\n      BassTapUnprepare,\n      BassTapProcess};"""; new="""  MTAudioProcessingTapCallbacks callbacks;\n  memset(&callbacks, 0, sizeof(callbacks));\n  callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;\n  callbacks.clientInfo = NULL;\n  callbacks.init = BassTapInit;\n  callbacks.finalize = BassTapFinalize;\n  callbacks.prepare = BassTapPrepare;\n  callbacks.unprepare = BassTapUnprepare;\n  callbacks.process = BassTapProcess;"""; s=s.replace(old,new); open(p, "w").write(s)'

include $(THEOS_MAKE_PATH)/tweak.mk
