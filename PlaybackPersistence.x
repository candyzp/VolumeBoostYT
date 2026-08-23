#import <AVFoundation/AVFoundation.h>

static inline void ReapplyVolumeBoost(AVPlayer *player) {
  if (player) {
    [player setVolume:1.0f];
  }
}

%hook AVPlayer

- (void)play {
  %orig;
  ReapplyVolumeBoost(self);
}

- (void)setRate:(float)rate {
  %orig(rate);
  if (rate > 0.0f) {
    ReapplyVolumeBoost(self);
  }
}

- (void)playImmediatelyAtRate:(float)rate {
  %orig(rate);
  ReapplyVolumeBoost(self);
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
  %orig(item);
  ReapplyVolumeBoost(self);
}

%end
