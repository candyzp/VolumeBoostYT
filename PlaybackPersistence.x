#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>

extern BOOL VBIsEnabled(void);
extern void VBRegisterRenderer(id renderer);
extern void VBApplyBaseVolume(id renderer);
extern void VBReapplyTrackedRenderers(void);

static BOOL repairBurstActive = NO;
static BOOL repairBurstNeedsTail = NO;
static CFAbsoluteTime repairBurstStartTime = 0.0;

static const NSTimeInterval kEarlyRepairDelay = 0.06;
static const NSTimeInterval kMidRepairDelay = 0.22;
static const NSTimeInterval kFinalRepairDelay = 0.60;

static void StartRepairBurstOnMain(void);

static inline void ResetRepairBurstState(void) {
  repairBurstActive = NO;
  repairBurstNeedsTail = NO;
  repairBurstStartTime = 0.0;
}

static inline void ScheduleTrackedReapply(NSTimeInterval delay) {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (VBIsEnabled()) {
          VBReapplyTrackedRenderers();
        }
      });
}

static void FinishRepairBurstOnMain(void) {
  if (VBIsEnabled()) {
    VBReapplyTrackedRenderers();
  }

  BOOL needsTail = repairBurstNeedsTail && VBIsEnabled();
  ResetRepairBurstState();

  if (needsTail) {
    StartRepairBurstOnMain();
  }
}

static void StartRepairBurstOnMain(void) {
  if (!VBIsEnabled()) {
    ResetRepairBurstState();
    return;
  }

  if (repairBurstActive) {
    if ((CFAbsoluteTimeGetCurrent() - repairBurstStartTime) >=
        kMidRepairDelay) {
      repairBurstNeedsTail = YES;
    }
    return;
  }

  repairBurstActive = YES;
  repairBurstNeedsTail = NO;
  repairBurstStartTime = CFAbsoluteTimeGetCurrent();

  ScheduleTrackedReapply(kEarlyRepairDelay);
  ScheduleTrackedReapply(kMidRepairDelay);
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(kFinalRepairDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        FinishRepairBurstOnMain();
      });
}

static void RequestRepair(id renderer) {
  if (!VBIsEnabled())
    return;

  __weak id weakRenderer = renderer;

  void (^work)(void) = ^{
    if (!VBIsEnabled())
      return;

    id strongRenderer = weakRenderer;
    if (strongRenderer) {
      VBApplyBaseVolume(strongRenderer);
    }
    StartRepairBurstOnMain();
  };

  if ([NSThread isMainThread]) {
    work();
  } else {
    dispatch_async(dispatch_get_main_queue(), work);
  }
}

static inline id TrackRenderer(id renderer) {
  if (renderer) {
    VBRegisterRenderer(renderer);
    RequestRepair(renderer);
  }
  return renderer;
}

%hook AVPlayer

- (instancetype)init {
  id orig = %orig;
  return TrackRenderer(orig);
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item {
  id orig = %orig(item);
  return TrackRenderer(orig);
}

- (instancetype)initWithURL:(NSURL *)URL {
  id orig = %orig(URL);
  return TrackRenderer(orig);
}

- (void)play {
  %orig;
  RequestRepair(self);
}

- (void)setRate:(float)rate {
  %orig(rate);
  if (rate > 0.0f) {
    RequestRepair(self);
  }
}

- (void)playImmediatelyAtRate:(float)rate {
  %orig(rate);
  RequestRepair(self);
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
  %orig(item);
  RequestRepair(self);
}

%end

%hook AVPlayerItem

- (instancetype)initWithURL:(NSURL *)URL {
  id orig = %orig(URL);
  RequestRepair(nil);
  return orig;
}

- (instancetype)initWithAsset:(AVAsset *)asset {
  id orig = %orig(asset);
  RequestRepair(nil);
  return orig;
}

- (instancetype)initWithAsset:(AVAsset *)asset
    automaticallyLoadedAssetKeys:(NSArray<NSString *> *)automaticallyLoadedAssetKeys {
  id orig = %orig(asset, automaticallyLoadedAssetKeys);
  RequestRepair(nil);
  return orig;
}

%end

%hook AVSampleBufferAudioRenderer

- (instancetype)init {
  id orig = %orig;
  return TrackRenderer(orig);
}

%end

%hook AVAudioPlayerNode

- (instancetype)init {
  id orig = %orig;
  return TrackRenderer(orig);
}

%end

%hook AVAudioPlayer

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)outError {
  id orig = %orig(url, outError);
  return TrackRenderer(orig);
}

- (instancetype)initWithData:(NSData *)data error:(NSError **)outError {
  id orig = %orig(data, outError);
  return TrackRenderer(orig);
}

%end
