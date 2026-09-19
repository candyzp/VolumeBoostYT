#import "YTVolumeHUD.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>

typedef NS_ENUM(NSInteger, YTVolumeHUDTransitionPhase) {
  YTVolumeHUDTransitionPhaseIdle = 0,
  YTVolumeHUDTransitionPhaseEntering = 1,
  YTVolumeHUDTransitionPhaseExpanding = 2,
  YTVolumeHUDTransitionPhaseShrinking = 3,
  YTVolumeHUDTransitionPhaseLeaving = 4,
};

@interface VBPrecisionSlider : UISlider
@property(nonatomic, assign) CGFloat lastTrackingX;
@property(nonatomic, assign) NSTimeInterval lastTrackingTime;
@property(nonatomic, assign) CGFloat scrubGain;
@end

@implementation VBPrecisionSlider

- (BOOL)beginTracking:(UITouch *)touch withEvent:(UIEvent *)event {
  (void)event;

  CGPoint point = [touch locationInView:self];
  self.lastTrackingX = point.x;
  self.lastTrackingTime = touch.timestamp;
  self.scrubGain = 1.0f;

  CGRect track = [self trackRectForBounds:self.bounds];
  CGRect thumb = [self thumbRectForBounds:self.bounds
                                 trackRect:track
                                     value:self.value];
  CGRect hitThumb = CGRectInset(thumb, -18.0f, -18.0f);

  if (!CGRectContainsPoint(hitThumb, point)) {
    CGFloat usableWidth = MAX(1.0f, CGRectGetWidth(track));
    CGFloat fraction =
        (point.x - CGRectGetMinX(track)) / usableWidth;
    fraction = MIN(1.0f, MAX(0.0f, fraction));
    float value =
        self.minimumValue +
        (self.maximumValue - self.minimumValue) * fraction;
    [self setValue:value animated:NO];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
  }

  return YES;
}

- (BOOL)continueTracking:(UITouch *)touch withEvent:(UIEvent *)event {
  (void)event;

  CGPoint point = [touch locationInView:self];
  NSTimeInterval now = touch.timestamp;
  NSTimeInterval dt = MAX(0.001, now - self.lastTrackingTime);
  CGFloat dx = point.x - self.lastTrackingX;
  CGFloat speed = fabs(dx) / dt;

  CGFloat targetGain = 0.18f;
  if (speed >= 500.0f)
    targetGain = 1.0f;
  else if (speed >= 250.0f)
    targetGain = 0.76f;
  else if (speed >= 120.0f)
    targetGain = 0.52f;
  else if (speed >= 50.0f)
    targetGain = 0.32f;

  self.scrubGain =
      self.scrubGain * 0.72f + targetGain * 0.28f;

  CGRect track = [self trackRectForBounds:self.bounds];
  CGFloat usableWidth = MAX(1.0f, CGRectGetWidth(track));
  float range = self.maximumValue - self.minimumValue;
  float delta =
      (float)(dx / usableWidth) * range * (float)self.scrubGain;
  float value =
      MIN(self.maximumValue, MAX(self.minimumValue, self.value + delta));

  [self setValue:value animated:NO];
  [self sendActionsForControlEvents:UIControlEventValueChanged];

  self.lastTrackingX = point.x;
  self.lastTrackingTime = now;
  return YES;
}

- (void)endTracking:(UITouch *)touch withEvent:(UIEvent *)event {
  (void)touch;
  (void)event;
  self.scrubGain = 1.0f;
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
  (void)event;
  self.scrubGain = 1.0f;
}

@end

@interface YTVolumeHUD ()
@property(nonatomic, strong) UIVisualEffectView *backgroundView;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, strong) VBPrecisionSlider *slider;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, assign) NSInteger lastDisplayedPercent;
@property(nonatomic, assign) NSInteger animationToken;
@property(nonatomic, assign) YTVolumeHUDTransitionPhase transitionPhase;
@property(nonatomic, assign) BOOL interactiveMode;
@property(nonatomic, assign) BOOL autoHideEnabled;
@property(nonatomic, assign) BOOL targetPresented;
@property(nonatomic, copy) YTVolumeHUDChangeBlock changeBlock;
@end

@implementation YTVolumeHUD

+ (instancetype)sharedHUD {
  static YTVolumeHUD *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] initWithFrame:CGRectZero];
  });
  return sharedInstance;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (!self)
    return nil;

  self.clipsToBounds = NO;
  self.alpha = 0.0f;
  self.lastDisplayedPercent = NSIntegerMin;
  self.transitionPhase = YTVolumeHUDTransitionPhaseIdle;

  UIBlurEffect *blur =
      [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
  self.backgroundView = [[UIVisualEffectView alloc] initWithEffect:blur];
  self.backgroundView.userInteractionEnabled = NO;
  self.backgroundView.layer.cornerCurve = kCACornerCurveContinuous;
  self.backgroundView.layer.masksToBounds = YES;
  self.backgroundView.layer.borderWidth = 0.7f;
  self.backgroundView.layer.borderColor =
      [UIColor colorWithWhite:1.0f alpha:0.14f].CGColor;
  [self addSubview:self.backgroundView];

  UIImageSymbolConfiguration *iconConfig =
      [UIImageSymbolConfiguration configurationWithPointSize:22.0f
                                                       weight:UIImageSymbolWeightSemibold];
  UIImage *icon = [UIImage systemImageNamed:@"speaker.wave.2.fill"
                           withConfiguration:iconConfig];
  self.iconView = [[UIImageView alloc] initWithImage:icon];
  self.iconView.tintColor = [UIColor whiteColor];
  self.iconView.contentMode = UIViewContentModeScaleAspectFit;
  [self addSubview:self.iconView];

  self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.titleLabel.text = @"Volume Boost";
  self.titleLabel.textColor = [UIColor whiteColor];
  self.titleLabel.font =
      [UIFont systemFontOfSize:13.0f weight:UIFontWeightSemibold];
  self.titleLabel.textAlignment = NSTextAlignmentCenter;
  self.titleLabel.adjustsFontSizeToFitWidth = YES;
  self.titleLabel.minimumScaleFactor = 0.8f;
  [self addSubview:self.titleLabel];

  self.percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.percentLabel.textAlignment = NSTextAlignmentCenter;
  [self addSubview:self.percentLabel];

  self.slider = [[VBPrecisionSlider alloc] initWithFrame:CGRectZero];
  self.slider.minimumValue = 0.0f;
  self.slider.maximumValue = 20.0f;
  self.slider.minimumTrackTintColor = [UIColor systemBlueColor];
  self.slider.maximumTrackTintColor =
      [UIColor colorWithWhite:1.0f alpha:0.18f];
  self.slider.continuous = YES;
  [self.slider addTarget:self
                  action:@selector(sliderValueChanged:)
        forControlEvents:UIControlEventValueChanged];
  [self.slider addTarget:self
                  action:@selector(sliderInteractionEnded:)
        forControlEvents:UIControlEventTouchUpInside |
                         UIControlEventTouchUpOutside |
                         UIControlEventTouchCancel];
  [self addSubview:self.slider];

  self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
  UIImageSymbolConfiguration *closeConfig =
      [UIImageSymbolConfiguration configurationWithPointSize:16.0f
                                                       weight:UIImageSymbolWeightSemibold];
  UIImage *closeImage = [UIImage systemImageNamed:@"xmark"
                                 withConfiguration:closeConfig];
  [self.closeButton setImage:closeImage forState:UIControlStateNormal];
  self.closeButton.tintColor = [UIColor colorWithWhite:1.0f alpha:0.78f];
  self.closeButton.backgroundColor =
      [UIColor colorWithWhite:1.0f alpha:0.08f];
  self.closeButton.layer.cornerRadius = 14.0f;
  self.closeButton.layer.cornerCurve = kCACornerCurveContinuous;
  [self.closeButton addTarget:self
                       action:@selector(closePressed:)
             forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:self.closeButton];

  [self setExpandedVisuals:NO];
  return self;
}

- (UIWindow *)activeWindow {
  if ([self.superview isKindOfClass:[UIWindow class]]) {
    UIWindow *window = (UIWindow *)self.superview;
    if (!window.hidden && window.screen == [UIScreen mainScreen])
      return window;
  }

  if (@available(iOS 13.0, *)) {
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
      if (![scene isKindOfClass:[UIWindowScene class]] ||
          scene.activationState != UISceneActivationStateForegroundActive) {
        continue;
      }

      for (UIWindow *window in ((UIWindowScene *)scene).windows) {
        if (window.hidden || window.screen != [UIScreen mainScreen])
          continue;
        if (window.isKeyWindow)
          return window;
        if (!fallback && window.windowLevel == UIWindowLevelNormal)
          fallback = window;
      }
    }
    return fallback;
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
}

- (CGFloat)topYForWindow:(UIWindow *)window {
  return MAX(window.safeAreaInsets.top + 8.0f, 14.0f);
}

- (CGSize)expandedSizeForWindow:(UIWindow *)window {
  CGFloat width = MIN(344.0f, MAX(270.0f, window.bounds.size.width - 28.0f));
  return CGSizeMake(width, 104.0f);
}

- (CGSize)collapsedSizeForWindow:(UIWindow *)window {
  CGFloat width = MIN(154.0f, MAX(142.0f, window.bounds.size.width * 0.38f));
  return CGSizeMake(width, 44.0f);
}

- (void)setGeometryForSize:(CGSize)size inWindow:(UIWindow *)window {
  CGFloat top = [self topYForWindow:window];
  self.bounds = CGRectMake(0.0f, 0.0f, size.width, size.height);
  self.center =
      CGPointMake(CGRectGetMidX(window.bounds), top + size.height * 0.5f);
}

- (void)setExpandedVisuals:(BOOL)expanded {
  self.titleLabel.hidden = !expanded;
  self.slider.hidden = !expanded;
  self.closeButton.hidden = !expanded;
  self.percentLabel.textColor =
      expanded ? [UIColor systemBlueColor] : [UIColor whiteColor];
  self.percentLabel.font =
      [UIFont systemFontOfSize:expanded ? 23.0f : 15.0f
                              weight:expanded ? UIFontWeightBold
                                              : UIFontWeightSemibold];
  self.backgroundView.layer.cornerRadius = expanded ? 24.0f : 22.0f;
  [self setNeedsLayout];
}

- (void)layoutSubviews {
  [super layoutSubviews];

  self.backgroundView.frame = self.bounds;

  CGFloat width = CGRectGetWidth(self.bounds);
  CGFloat height = CGRectGetHeight(self.bounds);

  if (height < 60.0f) {
    self.iconView.frame = CGRectMake(17.0f, 10.0f, 24.0f, 24.0f);
    self.percentLabel.frame =
        CGRectMake(48.0f, 5.0f, MAX(74.0f, width - 62.0f), 34.0f);
    self.titleLabel.frame = CGRectZero;
    self.slider.frame = CGRectZero;
    self.closeButton.frame = CGRectZero;
    return;
  }

  self.iconView.frame = CGRectMake(20.0f, 21.0f, 34.0f, 34.0f);
  self.titleLabel.frame = CGRectMake(68.0f, 10.0f, width - 136.0f, 22.0f);
  self.percentLabel.frame = CGRectMake(68.0f, 31.0f, width - 136.0f, 34.0f);
  self.slider.frame = CGRectMake(22.0f, height - 40.0f, width - 44.0f, 28.0f);
  self.closeButton.frame = CGRectMake(width - 40.0f, 12.0f, 28.0f, 28.0f);
}

- (void)updatePercentText:(float)value {
  NSInteger percent = lroundf(value * 100.0f);
  if (percent == self.lastDisplayedPercent)
    return;

  self.lastDisplayedPercent = percent;
  self.percentLabel.text =
      [NSString stringWithFormat:@"%ld%%", (long)percent];
}

- (void)updateDisplayedValue:(float)value {
  value = fminf(20.0f, fmaxf(0.0f, value));
  [self updatePercentText:value];

  if (fabsf(self.slider.value - value) > 0.002f)
    [self.slider setValue:value animated:NO];
}

- (void)prepareHiddenStateInWindow:(UIWindow *)window {
  CGSize collapsedSize = [self collapsedSizeForWindow:window];
  [self setGeometryForSize:collapsedSize inWindow:window];
  [self setExpandedVisuals:NO];
  self.transform =
      CGAffineTransformMakeTranslation(
          0.0f,
          -([self topYForWindow:window] + collapsedSize.height + 18.0f));
  self.alpha = 0.0f;
  [self layoutIfNeeded];
}

- (void)ensureAttachedToWindow:(UIWindow *)window {
  if (!window)
    return;

  if (self.superview != window) {
    [self removeFromSuperview];
    [window addSubview:self];
    [self prepareHiddenStateInWindow:window];
  }

  [window bringSubviewToFront:self];
}

- (void)expandFromCurrentWithToken:(NSInteger)token
                          inWindow:(UIWindow *)window {
  if (token != self.animationToken || !self.targetPresented)
    return;

  self.transitionPhase = YTVolumeHUDTransitionPhaseExpanding;
  [self setExpandedVisuals:YES];

  [UIView animateWithDuration:0.24
                        delay:0.03
       usingSpringWithDamping:0.84
        initialSpringVelocity:0.15
                      options:UIViewAnimationOptionBeginFromCurrentState |
                              UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     [self setGeometryForSize:[self expandedSizeForWindow:window]
                                    inWindow:window];
                     self.transform = CGAffineTransformIdentity;
                     self.alpha = 1.0f;
                     [self layoutIfNeeded];
                   }
                   completion:^(BOOL finished) {
                     if (!finished || token != self.animationToken ||
                         !self.targetPresented)
                       return;

                     self.transitionPhase = YTVolumeHUDTransitionPhaseIdle;
                     self.userInteractionEnabled = self.interactiveMode;
                   }];
}

- (void)enterFromCurrentWithToken:(NSInteger)token
                         inWindow:(UIWindow *)window {
  if (token != self.animationToken || !self.targetPresented)
    return;

  self.transitionPhase = YTVolumeHUDTransitionPhaseEntering;
  [self setExpandedVisuals:NO];

  [UIView animateWithDuration:0.18
                        delay:0.0
       usingSpringWithDamping:0.88
        initialSpringVelocity:0.2
                      options:UIViewAnimationOptionBeginFromCurrentState |
                              UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     [self setGeometryForSize:[self collapsedSizeForWindow:window]
                                    inWindow:window];
                     self.transform = CGAffineTransformIdentity;
                     self.alpha = 1.0f;
                     [self layoutIfNeeded];
                   }
                   completion:^(BOOL finished) {
                     if (!finished || token != self.animationToken ||
                         !self.targetPresented)
                       return;

                     [self expandFromCurrentWithToken:token inWindow:window];
                   }];
}

- (void)leaveFromCurrentWithToken:(NSInteger)token
                         inWindow:(UIWindow *)window {
  if (token != self.animationToken || self.targetPresented)
    return;

  self.transitionPhase = YTVolumeHUDTransitionPhaseLeaving;
  [self setExpandedVisuals:NO];

  CGFloat travel =
      [self topYForWindow:window] +
      [self collapsedSizeForWindow:window].height + 18.0f;

  [UIView animateWithDuration:0.20
                        delay:0.04
                      options:UIViewAnimationOptionBeginFromCurrentState |
                              UIViewAnimationOptionAllowUserInteraction |
                              UIViewAnimationOptionCurveEaseIn
                   animations:^{
                     [self setGeometryForSize:[self collapsedSizeForWindow:window]
                                    inWindow:window];
                     self.transform =
                         CGAffineTransformMakeTranslation(0.0f, -travel);
                     self.alpha = 0.0f;
                     [self layoutIfNeeded];
                   }
                   completion:^(BOOL finished) {
                     if (!finished || token != self.animationToken ||
                         self.targetPresented)
                       return;

                     self.transitionPhase = YTVolumeHUDTransitionPhaseIdle;
                     [self removeFromSuperview];
                     self.transform = CGAffineTransformIdentity;
                     self.userInteractionEnabled = NO;
                     self.changeBlock = nil;
                     self.interactiveMode = NO;
                     self.autoHideEnabled = NO;
                   }];
}

- (void)shrinkFromCurrentWithToken:(NSInteger)token
                          inWindow:(UIWindow *)window {
  if (token != self.animationToken || self.targetPresented)
    return;

  self.transitionPhase = YTVolumeHUDTransitionPhaseShrinking;
  [self setExpandedVisuals:NO];

  [UIView animateWithDuration:0.15
                        delay:0.0
                      options:UIViewAnimationOptionBeginFromCurrentState |
                              UIViewAnimationOptionAllowUserInteraction |
                              UIViewAnimationOptionCurveEaseInOut
                   animations:^{
                     [self setGeometryForSize:[self collapsedSizeForWindow:window]
                                    inWindow:window];
                     self.transform = CGAffineTransformIdentity;
                     self.alpha = 1.0f;
                     [self layoutIfNeeded];
                   }
                   completion:^(BOOL finished) {
                     if (!finished || token != self.animationToken ||
                         self.targetPresented)
                       return;

                     [self leaveFromCurrentWithToken:token inWindow:window];
                   }];
}

- (void)animateToPresented:(BOOL)presented {
  UIWindow *window = [self activeWindow];
  if (!window && presented)
    return;

  YTVolumeHUDTransitionPhase oldPhase = self.transitionPhase;
  BOOL wasAttached = self.superview != nil;

  if (presented)
    [self ensureAttachedToWindow:window];

  if (!self.superview)
    return;

  window = (UIWindow *)self.superview;
  NSInteger token = ++self.animationToken;
  self.targetPresented = presented;

  if (presented) {
    if (!wasAttached || oldPhase == YTVolumeHUDTransitionPhaseEntering ||
        oldPhase == YTVolumeHUDTransitionPhaseLeaving) {
      [self enterFromCurrentWithToken:token inWindow:window];
      return;
    }

    if (oldPhase == YTVolumeHUDTransitionPhaseShrinking) {
      [self expandFromCurrentWithToken:token inWindow:window];
      return;
    }

    if (oldPhase == YTVolumeHUDTransitionPhaseExpanding ||
        oldPhase == YTVolumeHUDTransitionPhaseIdle) {
      [self expandFromCurrentWithToken:token inWindow:window];
      return;
    }
  }

  if (oldPhase == YTVolumeHUDTransitionPhaseEntering ||
      oldPhase == YTVolumeHUDTransitionPhaseLeaving) {
    [self leaveFromCurrentWithToken:token inWindow:window];
    return;
  }

  [self shrinkFromCurrentWithToken:token inWindow:window];
}

- (BOOL)isPresentedOrTransitioning {
  return self.superview != nil;
}

- (void)showWithValue:(float)value {
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(hide)
                                             object:nil];
  self.interactiveMode = NO;
  self.autoHideEnabled = NO;
  self.changeBlock = nil;
  self.userInteractionEnabled = NO;
  [self updateDisplayedValue:value];
  [self animateToPresented:YES];
}

- (void)showInteractiveWithValue:(float)value
                     changeBlock:(YTVolumeHUDChangeBlock)changeBlock {
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(hide)
                                             object:nil];
  self.interactiveMode = YES;
  self.autoHideEnabled = NO;
  self.changeBlock = changeBlock;
  self.userInteractionEnabled = YES;
  [self updateDisplayedValue:value];
  [self animateToPresented:YES];
}

- (void)toggleInteractiveWithValue:(float)value
                       changeBlock:(YTVolumeHUDChangeBlock)changeBlock {
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(hide)
                                             object:nil];
  self.interactiveMode = YES;
  self.autoHideEnabled = NO;
  self.changeBlock = changeBlock;
  self.userInteractionEnabled = YES;
  [self updateDisplayedValue:value];

  BOOL shouldPresent = !self.targetPresented;
  if (!self.superview)
    shouldPresent = YES;

  [self animateToPresented:shouldPresent];
}

- (void)sliderValueChanged:(UISlider *)slider {
  if (!self.interactiveMode)
    return;

  float value = fminf(20.0f, fmaxf(0.0f, slider.value));
  [self updatePercentText:value];

  if (self.changeBlock)
    self.changeBlock(value);

  if (self.autoHideEnabled)
    [self scheduleHideAfterDelay:2.6];
}

- (void)sliderInteractionEnded:(UISlider *)slider {
  if (!self.interactiveMode)
    return;

  float value = fminf(20.0f, fmaxf(0.0f, slider.value));
  [self updatePercentText:value];

  if (self.changeBlock)
    self.changeBlock(value);

  if (self.autoHideEnabled)
    [self scheduleHideAfterDelay:1.8];
}

- (void)closePressed:(UIButton *)button {
  (void)button;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(hide)
                                             object:nil];
  [self animateToPresented:NO];
}

- (void)scheduleHideAfterDelay:(NSTimeInterval)delay {
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(hide)
                                             object:nil];
  [self performSelector:@selector(hide) withObject:nil afterDelay:delay];
}

- (void)hide {
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(hide)
                                             object:nil];

  if (!self.superview)
    return;

  [self animateToPresented:NO];
}

@end
