#import "VBYAudio.h"
#import <AVFoundation/AVFoundation.h>

static NSHashTable *playbackRenderers = nil;
static NSUInteger reapplyGeneration = 0;

static inline void RegisterPlaybackRenderer(id renderer) {
  if (!playbackRenderers) playbackRenderers = [NSHashTable weakObjectsHashTable];
  if (renderer) [playbackRenderers addObject:renderer];
}

static inline void ApplyBaseVolume(id renderer) {
  if (renderer && [renderer respondsToSelector:@selector(setVolume:)])
    [renderer setVolume:1.0f];
}

static void ReapplyTrackedRenderers(void) {
  for (id renderer in [playbackRenderers allObjects])
    ApplyBaseVolume(renderer);
}

static void QueueReapply(void) {
  NSUInteger generation = ++reapplyGeneration;

  dispatch_async(dispatch_get_main_queue(), ^{
    if (generation == reapplyGeneration) ReapplyTrackedRenderers();
  });

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (generation == reapplyGeneration) ReapplyTrackedRenderers();
      });

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (generation == reapplyGeneration) ReapplyTrackedRenderers();
      });
}

static inline void TrackRenderer(id renderer) {
  RegisterPlaybackRenderer(renderer);
  __weak id weakRenderer = renderer;
  dispatch_async(dispatch_get_main_queue(), ^{
    id strongRenderer = weakRenderer;
    if (strongRenderer) ApplyBaseVolume(strongRenderer);
  });
}

static inline void ReapplyVolumeBoost(AVPlayer *player) {
  RegisterPlaybackRenderer(player);
  ReapplyTrackedRenderers();
  QueueReapply();
}

%hook AVPlayer

- (instancetype)init {
  id result = %orig;
  TrackRenderer(result);
  return result;
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item {
  id result = %orig(item);
  TrackRenderer(result);
  if (item) VBYAudioPanelPlayerStateChanged(result);
  return result;
}

- (instancetype)initWithURL:(NSURL *)URL {
  id result = %orig(URL);
  TrackRenderer(result);
  VBYAudioPanelPlayerStateChanged(result);
  return result;
}

- (void)play {
  %orig;
  ReapplyVolumeBoost(self);
  VBYAudioPanelPlayerStateChanged(self);
}

- (void)pause {
  %orig;
  VBYAudioPanelPlayerStateChanged(self);
}

- (void)setRate:(float)rate {
  %orig(rate);
  if (rate > 0.0f) ReapplyVolumeBoost(self);
  VBYAudioPanelPlayerStateChanged(self);
}

- (void)playImmediatelyAtRate:(float)rate {
  %orig(rate);
  ReapplyVolumeBoost(self);
  VBYAudioPanelPlayerStateChanged(self);
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
  %orig(item);
  ReapplyVolumeBoost(self);
  VBYAudioPanelPlayerStateChanged(self);
}

%end

%hook AVSampleBufferAudioRenderer

- (instancetype)init {
  id result = %orig;
  TrackRenderer(result);
  return result;
}

%end

%hook AVAudioPlayerNode

- (instancetype)init {
  id result = %orig;
  TrackRenderer(result);
  return result;
}

%end

%hook AVAudioPlayer

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)outError {
  id result = %orig;
  TrackRenderer(result);
  return result;
}

- (instancetype)initWithData:(NSData *)data error:(NSError **)outError {
  id result = %orig;
  TrackRenderer(result);
  return result;
}

%end
