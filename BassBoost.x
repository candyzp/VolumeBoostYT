#import "YTBassHUD.h"
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>
#include <math.h>

// -----------------------------------------------------------------------------
// YouTube private settings declarations.
// These names are intentionally the same classes used by the existing tweak.
// Current YouTube headers also expose MLHAMPlayer/HAM and MLAVPlayer families,
// so the DSP below is attached below that player-family split at AudioConverter
// PCM output instead of assuming YouTube always uses AVPlayer.
// -----------------------------------------------------------------------------

@interface YTSettingsCell : UITableViewCell
@end

@interface YTSettingsSectionItem : NSObject
+ (instancetype)switchItemWithTitle:(NSString *)title
                   titleDescription:(NSString *)titleDescription
            accessibilityIdentifier:(NSString *)accessibilityIdentifier
                           switchOn:(BOOL)switchOn
                        switchBlock:(BOOL (^)(YTSettingsCell *cell,
                                              BOOL enabled))switchBlock
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

static float currentBassAmount = 0.0f; // 0.0 ... 1.0 = 0 ... 100%
static BOOL currentBassAmountInitialized = NO;
static volatile uint32_t bassDSPGeneration = 1;

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

  if (currentBassAmount < 0.0f)
    currentBassAmount = 0.0f;
  if (currentBassAmount > 1.0f)
    currentBassAmount = 1.0f;
  return currentBassAmount;
}

static void InvalidateBassDSP(void) {
  // Audio callbacks read this generation and reset their tiny filter history
  // on the next buffer. No audio graph teardown/rebuild is needed.
  bassDSPGeneration++;
  if (bassDSPGeneration == 0)
    bassDSPGeneration = 1;
}

static void SetBassAmount(float amount) {
  if (amount < 0.0f)
    amount = 0.0f;
  if (amount > 1.0f)
    amount = 1.0f;

  currentBassAmount = amount;
  currentBassAmountInitialized = YES;

  if (IsRememberBassEnabled()) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:amount forKey:kCustomYouTubeBassAmountKey];
    [defaults synchronize];
  }

  InvalidateBassDSP();
}

// -----------------------------------------------------------------------------
// Real bass DSP
// -----------------------------------------------------------------------------
// YouTube currently has both MLHAMPlayer/HAM and MLAVPlayer paths. HAM includes
// sample-buffer/SABR audio machinery, while the AV family wraps an AV asset
// player. Rather than attach only to one of those private player objects, this
// filter operates when their decode/conversion path produces Linear PCM through
// AudioConverterFillComplexBuffer.
//
// This is a real low-shelf EQ, not another volume multiplier. 100% maps to a
// conservative +12 dB shelf centered at 120 Hz.
// -----------------------------------------------------------------------------

#define BASS_MAX_CONVERTERS 24
#define BASS_MAX_CHANNELS 8

typedef struct {
  AudioConverterRef converter;
  double sampleRate;
  UInt32 channels;
  uint32_t generation;
  float b0, b1, b2, a1, a2;
  float z1[BASS_MAX_CHANNELS];
  float z2[BASS_MAX_CHANNELS];
  BOOL occupied;
} BassConverterState;

static BassConverterState bassStates[BASS_MAX_CONVERTERS];
static os_unfair_lock bassStatesLock = OS_UNFAIR_LOCK_INIT;
static BOOL didLogBassDSP = NO;

static void ResetBassState(BassConverterState *state) {
  if (!state)
    return;
  for (UInt32 c = 0; c < BASS_MAX_CHANNELS; c++) {
    state->z1[c] = 0.0f;
    state->z2[c] = 0.0f;
  }
}

static void ConfigureLowShelf(BassConverterState *state, double sampleRate,
                              UInt32 channels, float amount) {
  if (!state || sampleRate <= 0.0)
    return;

  const float gainDB = 12.0f * amount;
  const float shelfHz = 120.0f;
  const float A = powf(10.0f, gainDB / 40.0f);
  const float w0 = 2.0f * (float)M_PI * shelfHz / (float)sampleRate;
  const float cw = cosf(w0);
  const float sw = sinf(w0);
  // RBJ low-shelf with S = 1.0.
  const float alpha = 0.5f * sw * sqrtf(2.0f);
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
  state->sampleRate = sampleRate;
  state->channels = channels;
  state->generation = bassDSPGeneration;
  ResetBassState(state);
}

static BassConverterState *StateForConverter(AudioConverterRef converter,
                                              BOOL create) {
  if (!converter)
    return NULL;

  BassConverterState *freeSlot = NULL;
  os_unfair_lock_lock(&bassStatesLock);
  for (int i = 0; i < BASS_MAX_CONVERTERS; i++) {
    if (bassStates[i].occupied && bassStates[i].converter == converter) {
      os_unfair_lock_unlock(&bassStatesLock);
      return &bassStates[i];
    }
    if (!bassStates[i].occupied && freeSlot == NULL)
      freeSlot = &bassStates[i];
  }

  if (create && freeSlot) {
    memset(freeSlot, 0, sizeof(*freeSlot));
    freeSlot->converter = converter;
    freeSlot->occupied = YES;
  }
  os_unfair_lock_unlock(&bassStatesLock);
  return create ? freeSlot : NULL;
}

static void RemoveStateForConverter(AudioConverterRef converter) {
  if (!converter)
    return;
  os_unfair_lock_lock(&bassStatesLock);
  for (int i = 0; i < BASS_MAX_CONVERTERS; i++) {
    if (bassStates[i].occupied && bassStates[i].converter == converter) {
      memset(&bassStates[i], 0, sizeof(bassStates[i]));
      break;
    }
  }
  os_unfair_lock_unlock(&bassStatesLock);
}

static inline float ProcessBassSample(BassConverterState *state, UInt32 channel,
                                      float x) {
  float y = state->b0 * x + state->z1[channel];
  state->z1[channel] = state->b1 * x - state->a1 * y + state->z2[channel];
  state->z2[channel] = state->b2 * x - state->a2 * y;
  return y;
}

static inline int16_t ClampInt16(float sample) {
  if (sample > 32767.0f)
    return 32767;
  if (sample < -32768.0f)
    return -32768;
  return (int16_t)lrintf(sample);
}

static inline int32_t ClampInt32(double sample) {
  if (sample > 2147483647.0)
    return INT32_MAX;
  if (sample < -2147483648.0)
    return INT32_MIN;
  return (int32_t)llrint(sample);
}

static void ProcessPCMBufferList(AudioConverterRef converter,
                                 const AudioStreamBasicDescription *asbd,
                                 AudioBufferList *bufferList,
                                 UInt32 outputPackets, float amount) {
  if (!converter || !asbd || !bufferList || amount <= 0.0001f)
    return;
  if (asbd->mFormatID != kAudioFormatLinearPCM)
    return;
  if (asbd->mSampleRate <= 0.0 || asbd->mChannelsPerFrame == 0 ||
      asbd->mChannelsPerFrame > BASS_MAX_CHANNELS)
    return;

  const BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
  const BOOL isSignedInt =
      (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
  const BOOL isNonInterleaved =
      (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  const UInt32 bits = asbd->mBitsPerChannel;
  const UInt32 channels = asbd->mChannelsPerFrame;
  const UInt32 framesPerPacket = asbd->mFramesPerPacket ? asbd->mFramesPerPacket : 1;
  UInt64 requestedFrames64 = (UInt64)outputPackets * framesPerPacket;
  if (requestedFrames64 == 0)
    return;
  UInt32 requestedFrames = requestedFrames64 > UINT32_MAX
                               ? UINT32_MAX
                               : (UInt32)requestedFrames64;

  if (!((isFloat && bits == 32) || (isSignedInt && (bits == 16 || bits == 32))))
    return;

  BassConverterState *state = StateForConverter(converter, YES);
  if (!state)
    return;

  if (state->generation != bassDSPGeneration ||
      fabs(state->sampleRate - asbd->mSampleRate) > 0.5 ||
      state->channels != channels) {
    ConfigureLowShelf(state, asbd->mSampleRate, channels, amount);
  }

  if (!didLogBassDSP) {
    didLogBassDSP = YES;
    NSLog(@"[VolumeBoostYT] Bass DSP active: %.0f Hz, %u channel(s), %u-bit %@ PCM",
          asbd->mSampleRate, (unsigned)channels, (unsigned)bits,
          isFloat ? @"float" : @"integer");
  }

  for (UInt32 b = 0; b < bufferList->mNumberBuffers; b++) {
    AudioBuffer *buffer = &bufferList->mBuffers[b];
    if (!buffer->mData || buffer->mDataByteSize == 0)
      continue;

    if (isNonInterleaved) {
      UInt32 channel = b;
      if (channel >= channels)
        continue;

      if (isFloat && bits == 32) {
        UInt32 availableFrames = buffer->mDataByteSize / sizeof(float);
        UInt32 frames = MIN(requestedFrames, availableFrames);
        float *samples = (float *)buffer->mData;
        for (UInt32 f = 0; f < frames; f++)
          samples[f] = ProcessBassSample(state, channel, samples[f]);
      } else if (isSignedInt && bits == 16) {
        UInt32 availableFrames = buffer->mDataByteSize / sizeof(int16_t);
        UInt32 frames = MIN(requestedFrames, availableFrames);
        int16_t *samples = (int16_t *)buffer->mData;
        for (UInt32 f = 0; f < frames; f++) {
          float y = ProcessBassSample(state, channel, (float)samples[f]);
          samples[f] = ClampInt16(y);
        }
      } else if (isSignedInt && bits == 32) {
        UInt32 availableFrames = buffer->mDataByteSize / sizeof(int32_t);
        UInt32 frames = MIN(requestedFrames, availableFrames);
        int32_t *samples = (int32_t *)buffer->mData;
        for (UInt32 f = 0; f < frames; f++) {
          float normalized = (float)((double)samples[f] / 2147483648.0);
          float y = ProcessBassSample(state, channel, normalized);
          samples[f] = ClampInt32((double)y * 2147483648.0);
        }
      }
      continue;
    }

    if (isFloat && bits == 32) {
      UInt32 availableFrames =
          buffer->mDataByteSize / (sizeof(float) * channels);
      UInt32 frames = MIN(requestedFrames, availableFrames);
      float *samples = (float *)buffer->mData;
      for (UInt32 f = 0; f < frames; f++) {
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 index = f * channels + c;
          samples[index] = ProcessBassSample(state, c, samples[index]);
        }
      }
    } else if (isSignedInt && bits == 16) {
      UInt32 availableFrames =
          buffer->mDataByteSize / (sizeof(int16_t) * channels);
      UInt32 frames = MIN(requestedFrames, availableFrames);
      int16_t *samples = (int16_t *)buffer->mData;
      for (UInt32 f = 0; f < frames; f++) {
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 index = f * channels + c;
          float y = ProcessBassSample(state, c, (float)samples[index]);
          samples[index] = ClampInt16(y);
        }
      }
    } else if (isSignedInt && bits == 32) {
      UInt32 availableFrames =
          buffer->mDataByteSize / (sizeof(int32_t) * channels);
      UInt32 frames = MIN(requestedFrames, availableFrames);
      int32_t *samples = (int32_t *)buffer->mData;
      for (UInt32 f = 0; f < frames; f++) {
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 index = f * channels + c;
          float normalized = (float)((double)samples[index] / 2147483648.0);
          float y = ProcessBassSample(state, c, normalized);
          samples[index] = ClampInt32((double)y * 2147483648.0);
        }
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Left-edge bass gesture
// -----------------------------------------------------------------------------

static float bassGestureStartAmount = 0.0f;
static BOOL possibleBassGesture = NO;
static BOOL isTrackingBassGesture = NO;
static CGPoint bassInitialTouchPoint;

%group BassCore

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
  case UITouchPhaseBegan: {
    // Mirror the existing volume gesture on the opposite side.
    if (location.x <= 25.0f) {
      possibleBassGesture = YES;
      isTrackingBassGesture = NO;
      bassInitialTouchPoint = location;
      return;
    }
    break;
  }
  case UITouchPhaseMoved: {
    if (possibleBassGesture) {
      CGFloat dx = location.x - bassInitialTouchPoint.x; // right = inward
      CGFloat dy = fabs(location.y - bassInitialTouchPoint.y);

      if (dx > 15.0f && dx > dy) {
        isTrackingBassGesture = YES;
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

    if (isTrackingBassGesture) {
      CGFloat translationY = location.y - bassInitialTouchPoint.y;
      // Roughly a full-height swipe maps 0 -> 100%, matching the feel of the
      // right-side volume control while keeping bass on a saner 0..100 scale.
      float newAmount = bassGestureStartAmount - (float)translationY / 570.0f;
      if (newAmount < 0.0f)
        newAmount = 0.0f;
      if (newAmount > 1.0f)
        newAmount = 1.0f;

      SetBassAmount(newAmount);
      [[YTBassHUD sharedHUD] showWithValue:newAmount];
      return;
    }
    break;
  }
  case UITouchPhaseEnded:
  case UITouchPhaseCancelled: {
    if (possibleBassGesture) {
      possibleBassGesture = NO;
      return;
    }
    if (isTrackingBassGesture) {
      isTrackingBassGesture = NO;
      [[YTBassHUD sharedHUD] performSelector:@selector(hide)
                                  withObject:nil
                                  afterDelay:1.0];
      return;
    }
    break;
  }
  default:
    break;
  }

  %orig(event);
}
%end

%hookf(OSStatus, AudioConverterFillComplexBuffer,
       AudioConverterRef inAudioConverter,
       AudioConverterComplexInputDataProc inInputDataProc,
       void *inInputDataProcUserData, UInt32 *ioOutputDataPacketSize,
       AudioBufferList *outOutputData,
       AudioStreamPacketDescription *outPacketDescription) {
  OSStatus status = %orig(inAudioConverter, inInputDataProc,
                          inInputDataProcUserData, ioOutputDataPacketSize,
                          outOutputData, outPacketDescription);

  if (status != noErr || !ioOutputDataPacketSize || !outOutputData)
    return status;
  if (!IsVolumeBoostMasterEnabled() || !IsBassBoostEnabled())
    return status;

  float amount = GetBassAmount();
  if (amount <= 0.0001f)
    return status;

  AudioStreamBasicDescription outputASBD = {0};
  UInt32 propertySize = sizeof(outputASBD);
  if (AudioConverterGetProperty(inAudioConverter,
                                kAudioConverterCurrentOutputStreamDescription,
                                &propertySize, &outputASBD) != noErr) {
    return status;
  }

  ProcessPCMBufferList(inAudioConverter, &outputASBD, outOutputData,
                       *ioOutputDataPacketSize, amount);
  return status;
}

%hookf(OSStatus, AudioConverterDispose, AudioConverterRef inAudioConverter) {
  RemoveStateForConverter(inAudioConverter);
  return %orig(inAudioConverter);
}

%end // BassCore

// -----------------------------------------------------------------------------
// YouTube Settings -> VolumeBoostYT -> Bass controls
// -----------------------------------------------------------------------------

%group YouTubeBassSettings

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
  if (self.type != 1)
    return %orig;

  if (class_getClassMethod(objc_getClass("YTSettingsGroupData"),
                           @selector(tweaks))) {
    return %orig;
  }

  NSArray<NSNumber *> *categories = %orig;
  if ([categories containsObject:@(BassTweakSection)])
    return categories;

  NSMutableArray<NSNumber *> *mutableCategories = [categories mutableCopy];
  if (mutableCategories)
    [mutableCategories insertObject:@(BassTweakSection) atIndex:0];
  return mutableCategories.copy ?: categories;
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

  NSUInteger insertIndex = [order indexOfObject:@(1)];
  if (insertIndex != NSNotFound) {
    NSMutableArray<NSNumber *> *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(BassTweakSection) atIndex:insertIndex + 1];
    return mutableOrder.copy;
  }
  return order;
}

%end

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)updateVolumeBoostYTBassSectionWithEntry:(id)entry {
  NSMutableArray<YTSettingsSectionItem *> *sectionItems =
      [NSMutableArray array];
  Class itemClass = %c(YTSettingsSectionItem);
  if (!itemClass)
    return;

  YTSettingsViewController *settingsViewController =
      [self valueForKey:@"_settingsViewControllerDelegate"];

  YTSettingsSectionItem *enableBass = [itemClass
          switchItemWithTitle:@"Enable Bass Boost"
             titleDescription:@"Allow custom left-edge pan bass gesture"
      accessibilityIdentifier:nil
                     switchOn:IsBassBoostEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                    [defaults setBool:enabled forKey:kBassBoostEnabledKey];
                    [defaults synchronize];
                    InvalidateBassDSP();
                    return YES;
                  }
                settingItemId:10];
  [sectionItems addObject:enableBass];

  YTSettingsSectionItem *rememberBass = [itemClass
          switchItemWithTitle:@"Remember Bass"
             titleDescription:nil
      accessibilityIdentifier:nil
                     switchOn:IsRememberBassEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                    float currentAmount = GetBassAmount();
                    [defaults setBool:enabled forKey:kRememberBassEnabledKey];
                    if (enabled)
                      [defaults setFloat:currentAmount forKey:kCustomYouTubeBassAmountKey];
                    else
                      [defaults removeObjectForKey:kCustomYouTubeBassAmountKey];
                    [defaults synchronize];
                    return YES;
                  }
                settingItemId:11];
  [sectionItems addObject:rememberBass];

  if ([settingsViewController
          respondsToSelector:@selector
          (setSectionItems:
               forCategory:title:icon:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:BassTweakSection
                                      title:@"Bass Boost"
                                       icon:nil
                           titleDescription:nil
                               headerHidden:NO];
  } else if ([settingsViewController
                 respondsToSelector:@selector
                 (setSectionItems:
                      forCategory:title:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:BassTweakSection
                                      title:@"Bass Boost"
                           titleDescription:nil
                               headerHidden:NO];
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

%end // YouTubeBassSettings

%ctor {
  NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
  if ([bundleID isEqualToString:@"com.apple.springboard"])
    return;

  // The plist loads broadly into UIKit apps, so bass hooks are intentionally
  // activated only in the YouTube process. This also works for sideloaded
  // YouTube builds whose bundle ID was changed.
  if (!NSClassFromString(@"YTSettingsGroupData"))
    return;

  GetBassAmount();
  %init(BassCore);
  %init(YouTubeBassSettings);
}
