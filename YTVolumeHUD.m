#import "YTVolumeHUD.h"
#import <UIKit/UIKit.h>
#import <math.h>

@interface YTVolumeHUD ()
@property(nonatomic, assign) NSInteger lastDisplayedPercent;
@end

@implementation YTVolumeHUD

+ (instancetype)sharedHUD {
  static YTVolumeHUD *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init {
  self = [super initWithFrame:CGRectMake(0, 0, 200, 40)];
  if (self) {
    self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.8];
    self.layer.cornerRadius = 20;
    self.clipsToBounds = YES;
    self.userInteractionEnabled = NO;
    self.alpha = 0.0;
    self.lastDisplayedPercent = NSIntegerMin;

    self.textLabel = [[UILabel alloc] initWithFrame:self.bounds];
    self.textLabel.textColor = [UIColor whiteColor];
    self.textLabel.textAlignment = NSTextAlignmentCenter;
    self.textLabel.font = [UIFont boldSystemFontOfSize:16];
    [self addSubview:self.textLabel];
  }
  return self;
}

- (UIWindow *)activeWindow {
  if ([self.superview isKindOfClass:[UIWindow class]]) {
    UIWindow *currentWindow = (UIWindow *)self.superview;
    if (!currentWindow.hidden) {
      return currentWindow;
    }
  }

  if (@available(iOS 13.0, *)) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
      if (scene.activationState != UISceneActivationStateForegroundActive ||
          ![scene isKindOfClass:[UIWindowScene class]]) {
        continue;
      }

      for (UIWindow *window in ((UIWindowScene *)scene).windows) {
        if (window.isKeyWindow) {
          return window;
        }
      }
    }
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
  }

  return nil;
}

- (void)showWithValue:(float)value {
  NSInteger percent = lroundf(value * 100.0f);
  if (percent != self.lastDisplayedPercent) {
    self.lastDisplayedPercent = percent;
    self.textLabel.text =
        [NSString stringWithFormat:@"App Vol: %ld%%", (long)percent];
  }

  UIWindow *window = [self activeWindow];
  if (!window)
    return;

  BOOL newlyAdded = self.superview != window;
  if (newlyAdded) {
    [window addSubview:self];
    [window bringSubviewToFront:self];
  }

  CGPoint targetCenter = CGPointMake(window.bounds.size.width / 2.0, 80.0);
  if (!CGPointEqualToPoint(self.center, targetCenter)) {
    self.center = targetCenter;
  }

  if (self.alpha < 0.99) {
    [UIView animateWithDuration:0.15
                     animations:^{
                       self.alpha = 1.0;
                     }];
  }
}

- (void)hide {
  if (!self.superview)
    return;

  [UIView animateWithDuration:0.25
      animations:^{
        self.alpha = 0.0;
      }
      completion:^(BOOL finished) {
        if (finished) {
          [self removeFromSuperview];
        }
      }];
}

@end
