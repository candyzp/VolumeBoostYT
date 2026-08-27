#import "YTBassHUD.h"
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <os/lock.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "fishhook.h"

@interface YTSettingsCell : UITableViewCell
@end

@interface YTSettingsSectionItem : NSObject
+ (instancetype)switchItemWithTitle:(NSString *)title
                   titleDescription:(NSString *)titleDescription
            accessibilityIdentifier:(NSString *)accessibilityIdentifier
                           switchOn:(BOOL)switchOn
                        switchBlock:(BOOL (^)(YTSettingsCell *cell, BOOL enabled))switchBlock
                      settingItemId:(int)settingItemId;
@end

@interface YTSettingsViewController : UIViewController
- (void)setSectionItems:(NSMutableArray<YTSettingsSectionItem *> *)items
            forCategory:(NSUInteger)category
                  title:(NSString *)title
       titleDescription:(NSString *)titleDescription
           headerHidden:(BOOL)headerHidden;
- (void)setSectionItems:(NSMutableArray<YTSettingsSectionItem *> *)items
            forCategory:(NSUInteger)category
                  title:(NSString *)title
                   icon:(id)icon
       titleDescription:(NSString *)titleDescription
           headerHidden:(BOOL)headerHidden;
@end

@interface YTSettingsGroupData : NSObject
@property(nonatomic, assign) NSInteger type;
- (NSArray<NSNumber *> *)orderedCategories;
@end

@interface YTAppSettingsPresentationData : NSObject
+ (NSArray<NSNumber *> *)settingsCategoryOrder;
@end

@interface YTSettingsSectionItemManager : NSObject
@end

static const NSInteger BassTweakSection = 'bsyt';
static NSString *const kBassBoostEnabledKey = @"BassBoostEnabled";
static NSString *const kRememberBassEnabledKey = @"RememberBassEnabled";
static NSString *const kCustomYouTubeBassAmountKey = @"CustomYouTubeBassAmount";

static volatile BOOL gBassEnabled = YES;
static volatile BOOL gRememberBass = YES;
static volatile float gBassAmount = 0.0f;
static volatile uint32_t gBassGeneration = 1;

#define BASS_MAX_CHANNELS 8

typedef struct {
  AudioStreamBasicDescription format;
  uint32_t generation;
  float configuredAmount;
  float b0, b1, b2, a1, a2;
  float z1[BASS_MAX_CHANNELS];
  float z2[BASS_MAX_CHANNELS];
} BassFilterState;

typedef struct BassRenderContext {
  AudioUnit unit;
  AudioUnitElement element;
  AURenderCallback originalProc;
  void *originalRefCon;
  AudioStreamBasicDescription format;
  volatile BOOL hasFormat;
  BassFilterState filter;
  struct BassRenderContext *next;
} BassRenderContext;

static OSStatus (*OriginalAudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID,
                                                AudioUnitScope, AudioUnitElement,
                                                const void *, UInt32) = NULL;
static OSStatus (*OriginalAudioUnitInitialize)(AudioUnit) = NULL;
static BassRenderContext *gRenderContexts = NULL;
static os_unfair_lock gRenderContextsLock = OS_UNFAIR_LOCK_INIT;

static float ClampBassAmount(float value) {
  if (value < 0.0f) return 0.0f;
  if (value > 1.0f) return 1.0f;
  return value;
}

static void LoadBassPreferences(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  gBassEnabled = [defaults objectForKey:kBassBoostEnabledKey] == nil
                     ? YES
                     : [defaults boolForKey:kBassBoostEnabledKey];
  gRememberBass = [defaults objectForKey:kRememberBassEnabledKey] == nil
                      ? YES
                      : [defaults boolForKey:kRememberBassEnabledKey];
  if (gRememberBass && [defaults objectForKey:kCustomYouTubeBassAmountKey] != nil)
    gBassAmount = ClampBassAmount([defaults floatForKey:kCustomYouTubeBassAmountKey]);
  else
    gBassAmount = 0.0f;
}

static void BumpBassGeneration(void) {
  uint32_t next = gBassGeneration + 1;
  gBassGeneration = next == 0 ? 1 : next;
}

static void SetBassAmount(float amount) {
  amount = ClampBassAmount(amount);
  gBassAmount = amount;
  BumpBassGeneration();
  if (gRememberBass) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:amount forKey:kCustomYouTubeBassAmountKey];
    [defaults synchronize];
  }
}

static void ResetFilter(BassFilterState *state) {
  memset(state->z1, 0, sizeof(state->z1));
  memset(state->z2, 0, sizeof(state->z2));
}

static void ConfigureFilter(BassFilterState *state,
                            const AudioStreamBasicDescription *format,
                            float amount) {
  if (!state || !format || format->mSampleRate <= 0.0) return;

  float gainDB = 12.0f * amount;
  float A = powf(10.0f, gainDB / 40.0f);
  float w0 = 2.0f * (float)M_PI * 120.0f / (float)format->mSampleRate;
  float cw = cosf(w0);
  float sw = sinf(w0);
  float alpha = sw / sqrtf(2.0f);
  float beta = 2.0f * sqrtf(A) * alpha;

  float b0 = A * ((A + 1.0f) - (A - 1.0f) * cw + beta);
  float b1 = 2.0f * A * ((A - 1.0f) - (A + 1.0f) * cw);
  float b2 = A * ((A + 1.0f) - (A - 1.0f) * cw - beta);
  float a0 = (A + 1.0f) + (A - 1.0f) * cw + beta;
  float a1 = -2.0f * ((A - 1.0f) + (A + 1.0f) * cw);
  float a2 = (A + 1.0f) + (A - 1.0f) * cw - beta;
  if (fabsf(a0) < 0.000001f) return;

  state->b0 = b0 / a0;
  state->b1 = b1 / a0;
  state->b2 = b2 / a0;
  state->a1 = a1 / a0;
  state->a2 = a2 / a0;
  state->format = *format;
  state->generation = gBassGeneration;
  state->configuredAmount = amount;
  ResetFilter(state);
}

static inline float FilterSample(BassFilterState *state, UInt32 channel, float x) {
  float y = state->b0 * x + state->z1[channel];
  state->z1[channel] = state->b1 * x - state->a1 * y + state->z2[channel];
  state->z2[channel] = state->b2 * x - state->a2 * y;
  return y;
}

static inline int16_t ClampS16(float sample) {
  if (sample > 32767.0f) return 32767;
  if (sample < -32768.0f) return -32768;
  return (int16_t)lrintf(sample);
}

static inline int32_t ClampS32(double sample) {
  if (sample > 2147483647.0) return INT32_MAX;
  if (sample < -2147483648.0) return INT32_MIN;
  return (int32_t)llrint(sample);
}

static void ProcessPCM(BassFilterState *state,
                       const AudioStreamBasicDescription *format,
                       AudioBufferList *buffers,
                       UInt32 frames,
                       float amount) {
  if (!state || !format || !buffers || frames == 0 || amount <= 0.0001f) return;
  if (format->mFormatID != kAudioFormatLinearPCM) return;

  UInt32 channels = format->mChannelsPerFrame;
  if (channels == 0 || channels > BASS_MAX_CHANNELS) return;

  BOOL isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
  BOOL isSigned = (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
  BOOL nonInterleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  UInt32 bits = format->mBitsPerChannel;
  if (!((isFloat && bits == 32) || (isSigned && (bits == 16 || bits == 32)))) return;

  if (state->generation != gBassGeneration ||
      fabsf(state->configuredAmount - amount) > 0.0001f ||
      fabs(state->format.mSampleRate - format->mSampleRate) > 0.5 ||
      state->format.mChannelsPerFrame != channels ||
      state->format.mFormatFlags != format->mFormatFlags ||
      state->format.mBitsPerChannel != bits) {
    ConfigureFilter(state, format, amount);
  }

  for (UInt32 b = 0; b < buffers->mNumberBuffers; b++) {
    AudioBuffer *buffer = &buffers->mBuffers[b];
    if (!buffer->mData || buffer->mDataByteSize == 0) continue;

    if (nonInterleaved) {
      UInt32 channel = b;
      if (channel >= channels) continue;
      if (isFloat) {
        UInt32 count = MIN(frames, buffer->mDataByteSize / (UInt32)sizeof(float));
        float *p = (float *)buffer->mData;
        for (UInt32 i = 0; i < count; i++) p[i] = FilterSample(state, channel, p[i]);
      } else if (bits == 16) {
        UInt32 count = MIN(frames, buffer->mDataByteSize / (UInt32)sizeof(int16_t));
        int16_t *p = (int16_t *)buffer->mData;
        for (UInt32 i = 0; i < count; i++) p[i] = ClampS16(FilterSample(state, channel, (float)p[i]));
      } else {
        UInt32 count = MIN(frames, buffer->mDataByteSize / (UInt32)sizeof(int32_t));
        int32_t *p = (int32_t *)buffer->mData;
        for (UInt32 i = 0; i < count; i++) {
          float x = (float)((double)p[i] / 2147483648.0);
          p[i] = ClampS32((double)FilterSample(state, channel, x) * 2147483648.0);
        }
      }
      continue;
    }

    if (isFloat) {
      UInt32 count = MIN(frames, buffer->mDataByteSize / (UInt32)(sizeof(float) * channels));
      float *p = (float *)buffer->mData;
      for (UInt32 f = 0; f < count; f++) {
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 i = f * channels + c;
          p[i] = FilterSample(state, c, p[i]);
        }
      }
    } else if (bits == 16) {
      UInt32 count = MIN(frames, buffer->mDataByteSize / (UInt32)(sizeof(int16_t) * channels));
      int16_t *p = (int16_t *)buffer->mData;
      for (UInt32 f = 0; f < count; f++) {
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 i = f * channels + c;
          p[i] = ClampS16(FilterSample(state, c, (float)p[i]));
        }
      }
    } else {
      UInt32 count = MIN(frames, buffer->mDataByteSize / (UInt32)(sizeof(int32_t) * channels));
      int32_t *p = (int32_t *)buffer->mData;
      for (UInt32 f = 0; f < count; f++) {
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 i = f * channels + c;
          float x = (float)((double)p[i] / 2147483648.0);
          p[i] = ClampS32((double)FilterSample(state, c, x) * 2147483648.0);
        }
      }
    }
  }
}

static BOOL IsOutputAudioUnit(AudioUnit unit) {
  if (!unit) return NO;
  AudioComponent component = AudioComponentInstanceGetComponent(unit);
  if (!component) return NO;
  AudioComponentDescription desc;
  memset(&desc, 0, sizeof(desc));
  if (AudioComponentGetDescription(component, &desc) != noErr) return NO;
  return desc.componentType == kAudioUnitType_Output;
}

static BOOL TryReadFormat(AudioUnit unit, AudioUnitScope scope,
                          AudioUnitElement element,
                          AudioStreamBasicDescription *format) {
  UInt32 size = sizeof(*format);
  memset(format, 0, sizeof(*format));
  if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                           scope, element, format, &size) != noErr)
    return NO;
  return format->mFormatID == kAudioFormatLinearPCM &&
         format->mSampleRate > 0.0 &&
         format->mChannelsPerFrame > 0;
}

static BOOL ReadPlaybackFormat(AudioUnit unit, AudioUnitElement element,
                               AudioStreamBasicDescription *format) {
  if (TryReadFormat(unit, kAudioUnitScope_Input, element, format)) return YES;
  if (element != 0 && TryReadFormat(unit, kAudioUnitScope_Input, 0, format)) return YES;
  if (TryReadFormat(unit, kAudioUnitScope_Output, element, format)) return YES;
  if (element != 0 && TryReadFormat(unit, kAudioUnitScope_Output, 0, format)) return YES;
  return NO;
}

static void RegisterRenderContext(BassRenderContext *context) {
  os_unfair_lock_lock(&gRenderContextsLock);
  context->next = gRenderContexts;
  gRenderContexts = context;
  os_unfair_lock_unlock(&gRenderContextsLock);
}

static void RefreshRenderContexts(AudioUnit unit) {
  os_unfair_lock_lock(&gRenderContextsLock);
  for (BassRenderContext *context = gRenderContexts;
       context;
       context = context->next) {
    if (context->unit != unit) continue;
    AudioStreamBasicDescription format;
    if (ReadPlaybackFormat(context->unit, context->element, &format)) {
      context->format = format;
      context->hasFormat = YES;
      context->filter.generation = 0;
    }
  }
  os_unfair_lock_unlock(&gRenderContextsLock);
}

static OSStatus BassRenderCallback(void *refCon,
                                   AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp,
                                   UInt32 inBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList *ioData) {
  BassRenderContext *context = (BassRenderContext *)refCon;
  if (!context || !context->originalProc) return noErr;

  OSStatus status = context->originalProc(context->originalRefCon,
                                          ioActionFlags,
                                          inTimeStamp,
                                          inBusNumber,
                                          inNumberFrames,
                                          ioData);
  if (status != noErr || !ioData || !context->hasFormat || !gBassEnabled)
    return status;

  float amount = ClampBassAmount(gBassAmount);
  if (amount <= 0.0001f) return status;
  ProcessPCM(&context->filter, &context->format, ioData, inNumberFrames, amount);
  return status;
}

static OSStatus HookedAudioUnitSetProperty(AudioUnit inUnit,
                                           AudioUnitPropertyID inID,
                                           AudioUnitScope inScope,
                                           AudioUnitElement inElement,
                                           const void *inData,
                                           UInt32 inDataSize) {
  if (!OriginalAudioUnitSetProperty) return kAudio_ParamError;

  if (inID == kAudioUnitProperty_SetRenderCallback &&
      inScope == kAudioUnitScope_Input &&
      inData && inDataSize >= sizeof(AURenderCallbackStruct) &&
      IsOutputAudioUnit(inUnit)) {
    const AURenderCallbackStruct *incoming = (const AURenderCallbackStruct *)inData;
    if (incoming->inputProc && incoming->inputProc != BassRenderCallback) {
      BassRenderContext *context = (BassRenderContext *)calloc(1, sizeof(BassRenderContext));
      if (context) {
        context->unit = inUnit;
        context->element = inElement;
        context->originalProc = incoming->inputProc;
        context->originalRefCon = incoming->inputProcRefCon;
        context->hasFormat = ReadPlaybackFormat(inUnit, inElement, &context->format);

        AURenderCallbackStruct wrapped;
        wrapped.inputProc = BassRenderCallback;
        wrapped.inputProcRefCon = context;

        OSStatus status = OriginalAudioUnitSetProperty(inUnit, inID, inScope,
                                                       inElement, &wrapped,
                                                       sizeof(wrapped));
        if (status == noErr) {
          RegisterRenderContext(context);
          return status;
        }
        free(context);
      }
    }
  }

  OSStatus status = OriginalAudioUnitSetProperty(inUnit, inID, inScope,
                                                 inElement, inData, inDataSize);
  if (status == noErr && inID == kAudioUnitProperty_StreamFormat)
    RefreshRenderContexts(inUnit);
  return status;
}

static OSStatus HookedAudioUnitInitialize(AudioUnit inUnit) {
  if (!OriginalAudioUnitInitialize) return kAudio_ParamError;
  OSStatus status = OriginalAudioUnitInitialize(inUnit);
  if (status == noErr) RefreshRenderContexts(inUnit);
  return status;
}

static void InstallCoreAudioBassHook(void) {
  struct rebinding bindings[2];
  bindings[0].name = "AudioUnitSetProperty";
  bindings[0].replacement = (void *)HookedAudioUnitSetProperty;
  bindings[0].replaced = (void **)&OriginalAudioUnitSetProperty;
  bindings[1].name = "AudioUnitInitialize";
  bindings[1].replacement = (void *)HookedAudioUnitInitialize;
  bindings[1].replaced = (void **)&OriginalAudioUnitInitialize;
  rebind_symbols(bindings, 2);
}

static float bassGestureStartAmount = 0.0f;
static BOOL possibleBassGesture = NO;
static BOOL trackingBassGesture = NO;
static CGPoint bassInitialTouchPoint;

%group BassCore

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
  if (!gBassEnabled || self.screen != [UIScreen mainScreen]) {
    %orig(event);
    return;
  }

  NSSet<UITouch *> *touches = [event allTouches];
  if (touches.count == 0) {
    %orig(event);
    return;
  }

  UITouch *touch = [touches anyObject];
  CGPoint location = [touch locationInView:self];

  switch (touch.phase) {
  case UITouchPhaseBegan:
    if (location.x <= 25.0f) {
      possibleBassGesture = YES;
      trackingBassGesture = NO;
      bassInitialTouchPoint = location;
      return;
    }
    break;

  case UITouchPhaseMoved:
    if (possibleBassGesture) {
      CGFloat dx = location.x - bassInitialTouchPoint.x;
      CGFloat dy = fabs(location.y - bassInitialTouchPoint.y);
      if (dx > 15.0f && dx > dy) {
        trackingBassGesture = YES;
        possibleBassGesture = NO;
        bassInitialTouchPoint = location;
        bassGestureStartAmount = ClampBassAmount(gBassAmount);
        [[YTBassHUD sharedHUD] showWithValue:bassGestureStartAmount];
        return;
      }
      if (dy > 20.0f || dx < -10.0f) {
        possibleBassGesture = NO;
      } else {
        return;
      }
    }

    if (trackingBassGesture) {
      CGFloat translationY = location.y - bassInitialTouchPoint.y;
      SetBassAmount(bassGestureStartAmount - (float)translationY / 570.0f);
      [[YTBassHUD sharedHUD] showWithValue:ClampBassAmount(gBassAmount)];
      return;
    }
    break;

  case UITouchPhaseEnded:
  case UITouchPhaseCancelled:
    if (possibleBassGesture) {
      possibleBassGesture = NO;
      return;
    }
    if (trackingBassGesture) {
      trackingBassGesture = NO;
      [[YTBassHUD sharedHUD] performSelector:@selector(hide)
                                  withObject:nil
                                  afterDelay:1.0];
      return;
    }
    break;

  default:
    break;
  }

  %orig(event);
}
%end

%end

%group YouTubeBassSettings

%hook YTSettingsGroupData
- (NSArray<NSNumber *> *)orderedCategories {
  if (self.type != 1) return %orig;
  if (class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)))
    return %orig;

  NSArray<NSNumber *> *categories = %orig;
  if ([categories containsObject:@(BassTweakSection)]) return categories;
  NSMutableArray<NSNumber *> *mutable = [categories mutableCopy];
  if (mutable) [mutable insertObject:@(BassTweakSection) atIndex:0];
  return mutable.copy ?: categories;
}

+ (NSMutableArray<NSNumber *> *)tweaks {
  NSMutableArray<NSNumber *> *tweaks = %orig;
  if (tweaks && ![tweaks containsObject:@(BassTweakSection)])
    [tweaks addObject:@(BassTweakSection)];
  return tweaks;
}
%end

%hook YTAppSettingsPresentationData
+ (NSArray<NSNumber *> *)settingsCategoryOrder {
  NSArray<NSNumber *> *order = %orig;
  if ([order containsObject:@(BassTweakSection)]) return order;
  NSUInteger index = [order indexOfObject:@(1)];
  if (index == NSNotFound) return order;
  NSMutableArray<NSNumber *> *mutable = [order mutableCopy];
  [mutable insertObject:@(BassTweakSection) atIndex:index + 1];
  return mutable.copy;
}
%end

%hook YTSettingsSectionItemManager
%new(v@:@)
- (void)updateVolumeBoostYTBassSectionWithEntry:(id)entry {
  Class itemClass = %c(YTSettingsSectionItem);
  if (!itemClass) return;

  NSMutableArray<YTSettingsSectionItem *> *items = [NSMutableArray array];
  YTSettingsViewController *controller =
      [self valueForKey:@"_settingsViewControllerDelegate"];

  YTSettingsSectionItem *enable = [itemClass
      switchItemWithTitle:@"Enable Bass Boost"
      titleDescription:nil
      accessibilityIdentifier:nil
      switchOn:gBassEnabled
      switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
        gBassEnabled = enabled;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:enabled forKey:kBassBoostEnabledKey];
        [defaults synchronize];
        BumpBassGeneration();
        return YES;
      }
      settingItemId:10];
  [items addObject:enable];

  YTSettingsSectionItem *remember = [itemClass
      switchItemWithTitle:@"Remember Bass"
      titleDescription:nil
      accessibilityIdentifier:nil
      switchOn:gRememberBass
      switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
        gRememberBass = enabled;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:enabled forKey:kRememberBassEnabledKey];
        if (enabled)
          [defaults setFloat:ClampBassAmount(gBassAmount) forKey:kCustomYouTubeBassAmountKey];
        else
          [defaults removeObjectForKey:kCustomYouTubeBassAmountKey];
        [defaults synchronize];
        return YES;
      }
      settingItemId:11];
  [items addObject:remember];

  if ([controller respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
    [controller setSectionItems:items forCategory:BassTweakSection
                          title:@"Bass Boost" icon:nil
               titleDescription:nil headerHidden:NO];
  } else if ([controller respondsToSelector:@selector(setSectionItems:forCategory:title:titleDescription:headerHidden:)]) {
    [controller setSectionItems:items forCategory:BassTweakSection
                          title:@"Bass Boost"
               titleDescription:nil headerHidden:NO];
  }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
  if (category == BassTweakSection) {
    [self performSelector:@selector(updateVolumeBoostYTBassSectionWithEntry:)
               withObject:entry];
    return;
  }
  %orig;
}
%end

%end

%ctor {
  NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
  if ([bundleID isEqualToString:@"com.apple.springboard"]) return;
  if (!NSClassFromString(@"YTSettingsGroupData")) return;

  LoadBassPreferences();
  InstallCoreAudioBassHook();
  %init(BassCore);
  %init(YouTubeBassSettings);
}
