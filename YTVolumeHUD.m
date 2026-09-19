#import "YTVolumeHUD.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface YTVolumeHUD ()
@property(nonatomic, strong) UIVisualEffectView *backgroundView;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, assign) NSInteger lastDisplayedPercent;
@property(nonatomic, assign) BOOL interactiveMode;
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
  self.backgroundView.layer.cornerRadius = 24.0f;
  self.backgroundView.layer.cornerCurve = kCACornerCurveContinuous;
  self.backgroundView.layer.masksToBounds = YES;
  self.backgroundView.layer.borderWidth = 0.7f;
  self.backgroundView.layer.borderColor =
      [UIColor colorWithWhite:1.0f alpha:0.13f].CGColor;
  [self addSubview:self.backgroundView];

  UIImageSymbolConfiguration *iconConfig =
      [UIImageSymbolConfiguration configurationWithPointSize:23.0f
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
  self.titleLabel.font = [UIFont systemFontOfSize:14.0f weight:UIFontWeightSemibold];
  self.titleLabel.adjustsFontSizeToFitWidth = YES;
  self.titleLabel.minimumScaleFactor = 0.8f;
  [self addSubview:self.titleLabel];

  self.percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.percentLabel.textColor = [UIColor systemBlueColor];
  self.percentLabel.textAlignment = NSTextAlignmentRight;
  self.percentLabel.font = [UIFont systemFontOfSize:23.0f weight:UIFontWeightBold];
  [self addSubview:self.percentLabel];

  self.slider = [[UISlider alloc] initWithFrame:CGRectZero];
  self.slider.minimumValue = 1.0f;
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

- (void)layoutSubviews {
  [super layoutSubviews];

  self.backgroundView.frame = self.bounds;

  CGFloat height = CGRectGetHeight(self.bounds);
  self.iconView.frame = CGRectMake(18.0f, 19.0f, 34.0f, 34.0f);

  CGFloat textX = 66.0f;
  CGFloat rightPadding = 18.0f;
  CGFloat width = CGRectGetWidth(self.bounds);
  CGFloat percentageWidth = 92.0f;
  CGFloat titleWidth =
      MAX(90.0f, width - textX - percentageWidth - rightPadding - 6.0f);

  self.titleLabel.frame = CGRectMake(textX, 15.0f, titleWidth, 24.0f);
  self.percentLabel.frame =
      CGRectMake(width - percentageWidth - rightPadding, 10.0f,
                 percentageWidth, 34.0f);
  self.slider.frame =
      CGRectMake(textX, height - 45.0f, width - textX - rightPadding, 31.0f);
}

- (void)updateDisplayedValue:(float)value {
  value = fminf(20.0f, fmaxf(1.0f, value));
  NSInteger percent = lroundf(value * 100.0f);

  if (percent != self.lastDisplayedPercent) {
    self.lastDisplayedPercent = percent;
    self.percentLabel.text =
        [NSString stringWithFormat:@"%ld%%", (long)percent];
  }

  if (fabsf(self.slider.value - value) > 0.002f)
    [self.slider setValue:value animated:NO];
}

- (void)attachToWindow:(UIWindow *)window {
  if (!window)
    return;

  CGFloat width = MIN(344.0f, MAX(270.0f, window.bounds.size.width - 28.0f));
  CGFloat safeTop = window.safeAreaInsets.top;
  CGFloat targetY = MAX(safeTop + 8.0f, 14.0f);
  CGRect targetFrame =
      CGRectMake((window.bounds.size.width - width) * 0.5f, targetY, width,
                 104.0f);

  BOOL newlyAdded = self.superview != window;
  if (newlyAdded) {
    [self removeFromSuperview];
    self.frame = targetFrame;
    self.transform =
        CGAffineTransformMakeTranslation(0.0f, -CGRectGetMaxY(targetFrame) - 18.0f);
    self.alpha = 0.0f;
    [window addSubview:self];
  } else {
    self.frame = targetFrame;
  }

  [window bringSubviewToFront:self];
  [self setNeedsLayout];
  [self layoutIfNeeded];

  [UIView animateWithDuration:newlyAdded ? 0.30 : 0.16
                        delay:0.0
       usingSpringWithDamping:0.86
        initialSpringVelocity:0.25
                      options:UIViewAnimationOptionBeginFromCurrentState |
                              UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     self.transform = CGAffineTransformIdentity;
                     self.alpha = 1.0f;
                   }
                   completion:nil];
}

- (void)showWithValue:(float)value {
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(hide)
                                             object:nil];
  self.interactiveMode = NO;
  self.changeBlock = nil;
  self.userInteractionEnabled = NO;
  self.slider.userInteractionEnabled = NO;
  [self updateDisplayedValue:value];
  [self attachToWindow:[self activeWindow]];
}

- (void)showInteractiveWithValue:(float)value
                     changeBlock:(YTVolumeHUDChangeBlock)changeBlock {
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(hide)
                                             object:nil];
  self.interactiveMode = YES;
  self.changeBlock = changeBlock;
  self.userInteractionEnabled = YES;
  self.slider.userInteractionEnabled = YES;
  [self updateDisplayedValue:value];
  [self attachToWindow:[self activeWindow]];
  [self scheduleHideAfterDelay:2.6];
}

- (void)sliderValueChanged:(UISlider *)slider {
  if (!self.interactiveMode)
    return;

  float value = fminf(20.0f, fmaxf(1.0f, slider.value));
  [self updateDisplayedValue:value];

  if (self.changeBlock)
    self.changeBlock(value);

  [self scheduleHideAfterDelay:2.6];
}

- (void)sliderInteractionEnded:(UISlider *)slider {
  (void)slider;
  if (self.interactiveMode)
    [self scheduleHideAfterDelay:1.8];
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

  UIWindow *window =
      [self.superview isKindOfClass:[UIWindow class]] ? (UIWindow *)self.superview
                                                       : nil;
  CGFloat travel =
      CGRectGetHeight(self.bounds) + (window ? window.safeAreaInsets.top : 0.0f) +
      28.0f;

  [UIView animateWithDuration:0.24
                        delay:0.0
                      options:UIViewAnimationOptionBeginFromCurrentState |
                              UIViewAnimationOptionCurveEaseIn
                   animations:^{
                     self.transform = CGAffineTransformMakeTranslation(0.0f, -travel);
                     self.alpha = 0.0f;
                   }
                   completion:^(BOOL finished) {
                     if (!finished)
                       return;
                     [self removeFromSuperview];
                     self.transform = CGAffineTransformIdentity;
                     self.changeBlock = nil;
                     self.interactiveMode = NO;
                     self.userInteractionEnabled = NO;
                   }];
}

@end
