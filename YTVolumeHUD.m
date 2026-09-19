#import "YTVolumeHUD.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>

@interface YTVolumeHUD ()
@property(nonatomic, strong) UIVisualEffectView *backgroundView;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) UIViewPropertyAnimator *transitionAnimator;
@property(nonatomic, assign) NSInteger lastDisplayedPercent;
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
  self.percentLabel.textColor = [UIColor systemBlueColor];
  self.percentLabel.font =
      [UIFont systemFontOfSize:23.0f weight:UIFontWeightBold];
  [self addSubview:self.percentLabel];

  self.slider = [[UISlider alloc] initWithFrame:CGRectZero];
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
  self.closeButton.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.08f];
  self.closeButton.layer.cornerRadius = 14.0f;
  self.closeButton.layer.cornerCurve = kCACornerCurveContinuous;
  [self.closeButton addTarget:self
                       action:@selector(closePressed:)
             forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:self.closeButton];

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

- (void)applyExpandedVisualState:(BOOL)expanded {
  self.titleLabel.alpha = expanded ? 1.0f : 0.0f;
  self.slider.alpha = expanded ? 1.0f : 0.0f;
  self.closeButton.alpha = expanded ? 1.0f : 0.0f;
  self.percentLabel.textColor =
      expanded ? [UIColor systemBlueColor] : [UIColor whiteColor];
  self.backgroundView.layer.cornerRadius = expanded ? 24.0f : 22.0f;
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
    self.percentLabel.font =
        [UIFont systemFontOfSize:15.0f weight:UIFontWeightSemibold];
    return;
  }

  self.iconView.frame = CGRectMake(20.0f, 21.0f, 34.0f, 34.0f);
  self.titleLabel.frame = CGRectMake(68.0f, 10.0f, width - 136.0f, 22.0f);
  self.percentLabel.frame = CGRectMake(68.0f, 31.0f, width - 136.0f, 34.0f);
  self.slider.frame = CGRectMake(22.0f, height - 40.0f, width - 44.0f, 28.0f);
  self.closeButton.frame = CGRectMake(width - 40.0f, 12.0f, 28.0f, 28.0f);
  self.percentLabel.font =
      [UIFont systemFontOfSize:23.0f weight:UIFontWeightBold];
}

- (void)updateDisplayedValue:(float)value {
  value = fminf(20.0f, fmaxf(0.0f, value));
  NSInteger percent = lroundf(value * 100.0f);

  if (percent != self.lastDisplayedPercent) {
    self.lastDisplayedPercent = percent;
    self.percentLabel.text =
        [NSString stringWithFormat:@"%ld%%", (long)percent];
  }

  if (fabsf(self.slider.value - value) > 0.002f)
    [self.slider setValue:value animated:NO];
}

- (void)prepareHiddenStateInWindow:(UIWindow *)window {
  CGSize collapsedSize = [self collapsedSizeForWindow:window];
  [self setGeometryForSize:collapsedSize inWindow:window];
  self.transform =
      CGAffineTransformMakeTranslation(0.0f,
                                       -([self topYForWindow:window] +
                                         collapsedSize.height + 16.0f));
  self.alpha = 0.0f;
  [self applyExpandedVisualState:NO];
  [self setNeedsLayout];
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

- (void)finishPresentationState:(BOOL)presented {
  self.targetPresented = presented;
  self.transitionAnimator = nil;

  if (presented) {
    self.userInteractionEnabled = self.interactiveMode;
    return;
  }

  [self removeFromSuperview];
  self.userInteractionEnabled = NO;
  self.changeBlock = nil;
  self.interactiveMode = NO;
  self.autoHideEnabled = NO;
}

- (void)animateToPresented:(BOOL)presented {
  UIWindow *window = [self activeWindow];
  if (!window && presented)
    return;

  if (presented)
    [self ensureAttachedToWindow:window];

  if (!self.superview)
    return;

  window = (UIWindow *)self.superview;

  if (self.transitionAnimator &&
      self.transitionAnimator.state == UIViewAnimatingStateActive) {
    if (presented == self.targetPresented)
      return;

    [self.transitionAnimator pauseAnimation];
    self.targetPresented = presented;
    self.transitionAnimator.reversed = !self.transitionAnimator.reversed;
    [self.transitionAnimator
        continueAnimationWithTimingParameters:nil
                               durationFactor:1.0f];
    return;
  }

  self.targetPresented = presented;

  [self.transitionAnimator stopAnimation:YES];
  self.transitionAnimator = nil;

  CGSize targetSize = presented ? [self expandedSizeForWindow:window]
                                : [self collapsedSizeForWindow:window];
  CGFloat hiddenTranslation =
      -([self topYForWindow:window] +
        [self collapsedSizeForWindow:window].height + 16.0f);

  __weak typeof(self) weakSelf = self;
  self.transitionAnimator =
      [[UIViewPropertyAnimator alloc] initWithDuration:0.36
                                         dampingRatio:0.88
                                          animations:^{
                                            YTVolumeHUD *strongSelf = weakSelf;
                                            if (!strongSelf)
                                              return;

                                            [strongSelf setGeometryForSize:targetSize
                                                                 inWindow:window];
                                            strongSelf.transform =
                                                presented
                                                    ? CGAffineTransformIdentity
                                                    : CGAffineTransformMakeTranslation(
                                                          0.0f,
                                                          hiddenTranslation);
                                            strongSelf.alpha =
                                                presented ? 1.0f : 0.0f;
                                            [strongSelf
                                                applyExpandedVisualState:presented];
                                            [strongSelf layoutIfNeeded];
                                          }];

  [self.transitionAnimator
      addCompletion:^(UIViewAnimatingPosition finalPosition) {
        YTVolumeHUD *strongSelf = weakSelf;
        if (!strongSelf)
          return;

        (void)finalPosition;
        [strongSelf finishPresentationState:strongSelf.targetPresented];
      }];

  [self.transitionAnimator startAnimation];
}

- (BOOL)isPresentedOrTransitioning {
  return self.superview != nil ||
         (self.transitionAnimator &&
          self.transitionAnimator.state == UIViewAnimatingStateActive);
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
  if (!self.superview && !self.transitionAnimator)
    shouldPresent = YES;

  [self animateToPresented:shouldPresent];
}

- (void)sliderValueChanged:(UISlider *)slider {
  if (!self.interactiveMode)
    return;

  float value = fminf(20.0f, fmaxf(0.0f, slider.value));
  [self updateDisplayedValue:value];

  if (self.changeBlock)
    self.changeBlock(value);

  if (self.autoHideEnabled)
    [self scheduleHideAfterDelay:2.6];
}

- (void)sliderInteractionEnded:(UISlider *)slider {
  (void)slider;
  if (self.interactiveMode && self.autoHideEnabled)
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

  if (!self.superview && !self.transitionAnimator)
    return;

  [self animateToPresented:NO];
}

@end
