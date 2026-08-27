#import "YTBassHUD.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <MediaToolbox/MediaToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <math.h>

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
static NSString *const kVolumeBoostMasterEnabledKey = @"VolumeBoostYTEnabled";
static NSString *const kBassBoostEnabledKey = @"BassBoostEnabled";
static NSString *const kRememberBassEnabledKey = @"RememberBassEnabled";
static NSString *const kCustomYouTubeBassAmountKey = @"CustomYouTubeBassAmount";

static float currentBassAmount = 0.0f;
static BOOL currentBassAmountInitialized = NO;
static volatile uint32_t bassGeneration = 1;

static BOOL IsVolumeBoostMasterEnabled(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kVolumeBoostMasterEnabledKey] == nil)
    return YES;
  return [defaults boolForKey:kVolumeBoostMasterEnabledKey];
}

static BOOL IsBassBoostEnabled(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kBassBoostEnabledKey] == nil)
    return YES;
  return [defaults boolForKey:kBassBoostEnabledKey];
}

static BOOL IsRememberBassEnabled(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kRememberBassEnabledKey] == nil)
    return YES;
  return [defaults boolForKey:kRememberBassEnabledKey];
}

static float GetBassAmount(void) {
  if (!currentBassAmountInitialized) {
    currentBassAmountInitialized = YES;
    if (IsRememberBassEnabled()) {
      NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
      if ([defaults objectForKey:kCustomYouTubeBassAmountKey] != nil)
        currentBassAmount = [defaults floatForKey:kCustomYouTubeBassAmountKey];
    }
  }
  currentBassAmount = fmaxf(0.0f, fminf(1.0f, currentBassAmount));
  return currentBassAmount;
}

static void BumpBassGeneration(void) {
  bassGeneration++;
  if (bassGeneration == 0)
    bassGeneration = 1;
}

static void SetBassAmount(float amount) {
  amount = fmaxf(0.0f, fminf(1.0f, amount));
  currentBassAmount = amount;
  currentBassAmountInitialized = YES;

  if (IsRememberBassEnabled()) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:amount forKey:kCustomYouTubeBassAmountKey];
    [defaults synchronize];
  }
  BumpBassGeneration();
}

// -----------------------------------------------------------------------------
// Shared low-shelf DSP. 100% = +12 dB below roughly 120 Hz.
// -----------------------------------------------------------------------------

#define BASS_MAX_CHANNELS 8

typedef struct {
  AudioStreamBasicDescription format;
  uint32_t generation;
  float configuredAmount;
  float b0, b1, b2, a1, a2;
  float z1[BASS_MAX_CHANNELS];
  float z2[BASS_MAX_CHANNELS];
} BassFilterState;

static void ResetFilter(BassFilterState *state) {
  if (!state)
    return;
  memset(state->z1, 0, sizeof(state->z1));
  memset(state->z2, 0, sizeof(state->z2));
}

static void ConfigureFilter(BassFilterState *state,
                            const AudioStreamBasicDescription *format,
                            float amount) {
  if (!state || !format || format->mSampleRate <= 0.0)
    return;

  const float gainDB = 12.0f * amount;
  const float A = powf(10.0f, gainDB / 40.0f);
  const float w0 = 2.0f * (float)M_PI * 120.0f / (float)format->mSampleRate;
  const float cw = cosf(w0);
  const float sw = sinf(w0);
  const float alpha = sw / sqrtf(2.0f);
  const float beta = 2.0f * sqrtf(A) * alpha;

  float b0 = A * ((A + 1.0f) - (A - 1.0f) * cw + beta);
  float b1 = 2.0f * A * ((A - 1.0f) - (A + 1.0f) * cw);
  float b2 = A * ((A + 1.0f) - (A - 1.0f) * cw - beta);
  float a0 = (A + 1.0f) + (A - 1.0f) * cw + beta;
  float a1 = -2.0f * ((A - 1.0f) + (A + 1.0f) * cw);
  float a2 = (A + 1.0f) + (A - 1.0f) * cw - beta;

  if (fabsf(a0) < 0.000001f)
    return;

  state->b0 = b0 / a0;
  state->b1 = b1 / a0;
  state->b2 = b2 / a0;
  state->a1 = a1 / a0;
  state->a2 = a2 / a0;
  state->format = *format;
  state->generation = bassGeneration;
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
  if (!state || !format || !buffers || frames == 0 || amount <= 0.0001f)
    return;
  if (format->mFormatID != kAudioFormatLinearPCM)
    return;

  UInt32 channels = format->mChannelsPerFrame;
  if (channels == 0 || channels > BASS_MAX_CHANNELS)
    return;

  BOOL isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
  BOOL isSigned = (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
  BOOL nonInterleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  UInt32 bits = format->mBitsPerChannel;
  if (!((isFloat && bits == 32) || (isSigned && (bits == 16 || bits == 32))))
    return;

  if (state->generation != bassGeneration ||
      fabsf(state->configuredAmount - amount) > 0.0001f ||
      fabs(state->format.mSampleRate - format->mSampleRate) > 0.5 ||
      state->format.mChannelsPerFrame != channels ||
      state->format.mFormatFlags != format->mFormatFlags ||
      state->format.mBitsPerChannel != bits) {
    ConfigureFilter(state, format, amount);
  }

  for (UInt32 b = 0; b < buffers->mNumberBuffers; b++) {
    AudioBuffer *buffer = &buffers->mBuffers[b];
    if (!buffer->mData || buffer->mDataByteSize == 0)
      continue;

    if (nonInterleaved) {
      UInt32 channel = b;
      if (channel >= channels)
        continue;
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
      for (UInt32 f = 0; f < count; f++)
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 i = f * channels + c;
          p[i] = FilterSample(state, c, p[i]);
        }
    } else if (bits == 16) {
      UInt32 count = MIN(frames, buffer->mDataByteSize / (UInt32)(sizeof(int16_t) * channels));
      int16_t *p = (int16_t *)buffer->mData;
      for (UInt32 f = 0; f < count; f++)
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 i = f * channels + c;
          p[i] = ClampS16(FilterSample(state, c, (float)p[i]));
        }
    } else {
      UInt32 count = MIN(frames, buffer->mDataByteSize / (UInt32)(sizeof(int32_t) * channels));
      int32_t *p = (int32_t *)buffer->mData;
      for (UInt32 f = 0; f < count; f++)
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 i = f * channels + c;
          float x = (float)((double)p[i] / 2147483648.0);
          p[i] = ClampS32((double)FilterSample(state, c, x) * 2147483648.0);
        }
    }
  }
}

// -----------------------------------------------------------------------------
// MLAVPlayer path: AVPlayerItem audio processing tap.
// -----------------------------------------------------------------------------

static void BassTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **storageOut) {
  *storageOut = calloc(1, sizeof(BassFilterState));
}

static void BassTapFinalize(MTAudioProcessingTapRef tap) {
  void *storage = MTAudioProcessingTapGetStorage(tap);
  if (storage) free(storage);
}

static void BassTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                           const AudioStreamBasicDescription *format) {
  BassFilterState *state = (BassFilterState *)MTAudioProcessingTapGetStorage(tap);
  if (state && format) ConfigureFilter(state, format, GetBassAmount());
}

static void BassTapUnprepare(MTAudioProcessingTapRef tap) {
  BassFilterState *state = (BassFilterState *)MTAudioProcessingTapGetStorage(tap);
  if (state) ResetFilter(state);
}

static void BassTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                           MTAudioProcessingTapFlags flags,
                           AudioBufferList *bufferList,
                           CMItemCount *numberFramesOut,
                           MTAudioProcessingTapFlags *flagsOut) {
  OSStatus status = MTAudioProcessingTapGetSourceAudio(
      tap, numberFrames, bufferList, flagsOut, NULL, numberFramesOut);
  if (status != noErr || !numberFramesOut)
    return;

  if (!IsVolumeBoostMasterEnabled() || !IsBassBoostEnabled())
    return;

  BassFilterState *state = (BassFilterState *)MTAudioProcessingTapGetStorage(tap);
  if (!state)
    return;
  ProcessPCM(state, &state->format, bufferList, (UInt32)*numberFramesOut, GetBassAmount());
}

static const void *kBassTapInstalledKey = &kBassTapInstalledKey;
static BOOL didLogAVPath = NO;

static BOOL InstallBassTapOnItem(AVPlayerItem *item) {
  if (!item || [objc_getAssociatedObject(item, kBassTapInstalledKey) boolValue])
    return YES;

  NSArray<AVAssetTrack *> *tracks = [item.asset tracksWithMediaType:AVMediaTypeAudio];
  AVAssetTrack *audioTrack = tracks.firstObject;
  if (!audioTrack)
    return NO;

  MTAudioProcessingTapCallbacks callbacks = {
      kMTAudioProcessingTapCallbacksVersion_0,
      NULL,
      BassTapInit,
      BassTapFinalize,
      BassTapPrepare,
      BassTapUnprepare,
      BassTapProcess};

  MTAudioProcessingTapRef tap = NULL;
  OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects,
                                               &tap);
  if (status != noErr || !tap)
    return NO;

  AVMutableAudioMixInputParameters *params =
      [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack];
  params.audioTapProcessor = tap;
  AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
  mix.inputParameters = @[ params ];
  item.audioMix = mix;
  CFRelease(tap);

  objc_setAssociatedObject(item, kBassTapInstalledKey, @YES,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (!didLogAVPath) {
    didLogAVPath = YES;
    NSLog(@"[VolumeBoostYT] Bass path: YouTube AV player audio tap attached");
  }
  return YES;
}

static void ScheduleBassTapInstall(AVPlayerItem *item) {
  if (!item)
    return;
  __weak AVPlayerItem *weakItem = item;
  const NSTimeInterval delays[] = {0.0, 0.25, 0.9};
  for (int i = 0; i < 3; i++) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      AVPlayerItem *strongItem = weakItem;
      if (strongItem) InstallBassTapOnItem(strongItem);
    });
  }
}

// -----------------------------------------------------------------------------
// MLHAMPlayer path: YouTube HAM feeds AVSampleBufferAudioRenderer. We inspect
// the real enqueued format and process it only when HAM hands the renderer PCM.
// Compressed frames are left untouched rather than pretending they are PCM.
// -----------------------------------------------------------------------------

@interface VBYTRendererBassState : NSObject {
@public
  BassFilterState filter;
}
@end
@implementation VBYTRendererBassState
@end

static const void *kRendererBassStateKey = &kRendererBassStateKey;
static BOOL didLogHAMPCM = NO;
static BOOL didLogHAMCompressed = NO;

static void ProcessHAMSampleBuffer(id renderer, CMSampleBufferRef sampleBuffer) {
  if (!sampleBuffer || !IsVolumeBoostMasterEnabled() || !IsBassBoostEnabled() ||
      GetBassAmount() <= 0.0001f)
    return;

  CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
  if (!description || CMFormatDescriptionGetMediaType(description) != kCMMediaType_Audio)
    return;

  const AudioStreamBasicDescription *format =
      CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)description);
  if (!format)
    return;

  if (format->mFormatID != kAudioFormatLinearPCM) {
    if (!didLogHAMCompressed) {
      didLogHAMCompressed = YES;
      UInt32 f = format->mFormatID;
      char fourcc[5] = {(char)(f >> 24), (char)(f >> 16), (char)(f >> 8), (char)f, 0};
      NSLog(@"[VolumeBoostYT] HAM audio renderer is receiving compressed format '%s'; waiting for a PCM surface", fourcc);
    }
    return;
  }

  UInt32 channels = MAX((UInt32)1, format->mChannelsPerFrame);
  size_t listSize = sizeof(AudioBufferList) +
      (channels > 1 ? (channels - 1) * sizeof(AudioBuffer) : 0);
  AudioBufferList *list = (AudioBufferList *)calloc(1, listSize);
  if (!list)
    return;

  CMBlockBufferRef blockBuffer = NULL;
  OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer, NULL, list, listSize, kCFAllocatorDefault,
      kCFAllocatorDefault, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      &blockBuffer);
  if (status != noErr) {
    free(list);
    if (blockBuffer) CFRelease(blockBuffer);
    return;
  }

  VBYTRendererBassState *holder = objc_getAssociatedObject(renderer, kRendererBassStateKey);
  if (!holder) {
    holder = [VBYTRendererBassState new];
    objc_setAssociatedObject(renderer, kRendererBassStateKey, holder,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  UInt32 frames = (UInt32)CMSampleBufferGetNumSamples(sampleBuffer);
  ProcessPCM(&holder->filter, format, list, frames, GetBassAmount());

  if (!didLogHAMPCM) {
    didLogHAMPCM = YES;
    NSLog(@"[VolumeBoostYT] Bass path: YouTube HAM PCM sample-buffer renderer active");
  }

  if (blockBuffer) CFRelease(blockBuffer);
  free(list);
}

// -----------------------------------------------------------------------------
// Left-edge gesture, mirroring the existing right-edge volume gesture.
// -----------------------------------------------------------------------------

static float bassGestureStartAmount = 0.0f;
static BOOL possibleBassGesture = NO;
static BOOL trackingBassGesture = NO;
static CGPoint bassInitialTouchPoint;

%group BassCore

%hook AVPlayer
- (instancetype)initWithPlayerItem:(AVPlayerItem *)item {
  id orig = %orig(item);
  ScheduleBassTapInstall(item);
  return orig;
}
- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
  %orig(item);
  ScheduleBassTapInstall(item);
}
- (void)play {
  ScheduleBassTapInstall(self.currentItem);
  %orig;
}
%end

%hook AVSampleBufferAudioRenderer
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
  ProcessHAMSampleBuffer(self, sampleBuffer);
  %orig(sampleBuffer);
}
%end

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
  if (!IsVolumeBoostMasterEnabled() || !IsBassBoostEnabled()) {
    %orig(event);
    return;
  }
  if (self.screen != [UIScreen mainScreen]) {
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
        bassGestureStartAmount = GetBassAmount();
        [[YTBassHUD sharedHUD] showWithValue:bassGestureStartAmount];
        return;
      } else if (dy > 20.0f || dx < -10.0f) {
        possibleBassGesture = NO;
      } else {
        return;
      }
    }

    if (trackingBassGesture) {
      CGFloat translationY = location.y - bassInitialTouchPoint.y;
      float amount = bassGestureStartAmount - (float)translationY / 570.0f;
      SetBassAmount(amount);
      [[YTBassHUD sharedHUD] showWithValue:GetBassAmount()];
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

// -----------------------------------------------------------------------------
// YouTube settings.
// -----------------------------------------------------------------------------

%group YouTubeBassSettings

%hook YTSettingsGroupData
- (NSArray<NSNumber *> *)orderedCategories {
  if (self.type != 1)
    return %orig;
  if (class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)))
    return %orig;

  NSArray<NSNumber *> *categories = %orig;
  if ([categories containsObject:@(BassTweakSection)])
    return categories;
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
  if ([order containsObject:@(BassTweakSection)])
    return order;
  NSUInteger index = [order indexOfObject:@(1)];
  if (index == NSNotFound)
    return order;
  NSMutableArray<NSNumber *> *mutable = [order mutableCopy];
  [mutable insertObject:@(BassTweakSection) atIndex:index + 1];
  return mutable.copy;
}
%end

%hook YTSettingsSectionItemManager
%new(v@:@)
- (void)updateVolumeBoostYTBassSectionWithEntry:(id)entry {
  Class itemClass = %c(YTSettingsSectionItem);
  if (!itemClass)
    return;

  NSMutableArray<YTSettingsSectionItem *> *items = [NSMutableArray array];
  YTSettingsViewController *controller =
      [self valueForKey:@"_settingsViewControllerDelegate"];

  YTSettingsSectionItem *enable = [itemClass
      switchItemWithTitle:@"Enable Bass Boost"
      titleDescription:nil
      accessibilityIdentifier:nil
      switchOn:IsBassBoostEnabled()
      switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
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
      switchOn:IsRememberBassEnabled()
      switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        float amount = GetBassAmount();
        [defaults setBool:enabled forKey:kRememberBassEnabledKey];
        if (enabled)
          [defaults setFloat:amount forKey:kCustomYouTubeBassAmountKey];
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
    [self updateVolumeBoostYTBassSectionWithEntry:entry];
    return;
  }
  %orig;
}
%end

%end

%ctor {
  NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
  if ([bundleID isEqualToString:@"com.apple.springboard"])
    return;

  // YouTube class detection keeps this out of every other UIKit process while
  // still supporting sideloaded YouTube builds whose bundle ID is changed.
  if (!NSClassFromString(@"YTSettingsGroupData"))
    return;

  GetBassAmount();
  %init(BassCore);
  %init(YouTubeBassSettings);
}
