#import <AVFoundation/AVFoundation.h>

extern void VBRegisterRenderer(id renderer);
extern void VBApplyBaseVolume(id renderer);
extern void VBReapplyTrackedRenderers(void);

static BOOL repairBurstActive = NO;
static BOOL repairBurstNeedsTail = NO;

static void StartRepairBurstOnMain(void);

static inline void ScheduleTrackedReapply(NSTimeInterval delay) {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        VBReapplyTrackedRenderers();
      });
}

static void FinishRepairBurstOnMain(void) {
  VBReapplyTrackedRenderers();

  BOOL needsTail = repairBurstNeedsTail;
  repairBurstActive = NO;
  repairBurstNeedsTail = NO;

  if (needsTail) {
    StartRepairBurstOnMain();
  }
}

static void StartRepairBurstOnMain(void) {
  if (repairBurstActive) {
    repairBurstNeedsTail = YES;
    return;
  }

  repairBurstActive = YES;
  repairBurstNeedsTail = NO;

  ScheduleTrackedReapply(0.06);
  ScheduleTrackedReapply(0.22);
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        FinishRepairBurstOnMain();
      });
}

static void RequestRepair(id renderer) {
  __weak id weakRenderer = renderer;

  void (^work)(void) = ^{
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
