#import "YTVolumeHUD.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>

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
+ (instancetype)itemWithTitle:(NSString *)title
             titleDescription:(NSString *)titleDescription
      accessibilityIdentifier:(NSString *)accessibilityIdentifier
              detailTextBlock:(NSString *(^)(void))detailTextBlock
                  selectBlock:(BOOL (^)(YTSettingsCell *cell,
                                        NSUInteger sectionItemIndex))selectBlock;
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
- (void)reloadData;
@end

@interface YTSettingsGroupData : NSObject
@property(nonatomic, assign) NSInteger type;
- (NSArray<NSNumber *> *)orderedCategories;
@end

@interface YTAppSettingsPresentationData : NSObject
+ (NSArray<NSNumber *> *)settingsCategoryOrder;
@end

@interface YTSettingsSectionItemManager : NSObject
- (void)updateVolumeBoostYTSectionWithEntry:(id)entry;
@end

typedef NS_ENUM(NSInteger, VBGestureMethod) {
  VBGestureMethodRightSide = 0,
  VBGestureMethodShake = 1,
};

static const NSInteger TweakSection = 'ndyt';

static NSString *const kVolumeBoostYTEnabledKey = @"VolumeBoostYTEnabled";
static NSString *const kRememberVolumeEnabledKey = @"RememberVolumeEnabled";
static NSString *const kCustomYouTubeVolumeScalarKey = @"CustomYouTubeVolumeScalar";
static NSString *const kGestureMethodKey = @"VolumeBoostYTGestureMethod";
static NSString *const kShakeSensitivityKey = @"VolumeBoostYTShakeSensitivity";
static NSString *const kHapticFeedbackEnabledKey = @"VolumeBoostYTHapticFeedbackEnabled";
static NSString *const kRightSideTipSeenKey = @"VolumeBoostYTRightSideTipSeen";
static NSString *const kGestureMethodCellID = @"VolumeBoostYTGestureMethodCell";
static NSString *const kShakeSensitivityCellID = @"VolumeBoostYTShakeSensitivityCell";

static BOOL cachedVolumeBoostEnabled = YES;
static BOOL cachedRememberVolumeEnabled = YES;
static BOOL cachedHapticFeedbackEnabled = YES;
static BOOL supportsTweaksCategoryAPI = NO;
static VBGestureMethod cachedGestureMethod = VBGestureMethodRightSide;
static float cachedShakeSensitivity = 0.5f;
static float currentVolumeMultiplier = 1.0f;
static float cachedAudioMultiplier = 1.0f;
static BOOL preferencesLoaded = NO;

static NSHashTable *activeRenderers = nil;
static dispatch_once_t activeRenderersOnce;
static char kRendererRegisteredKey;
static char kVolumeGestureRecognizerKey;
static char kVolumeGestureHandlerKey;
static char kGestureMenuButtonKey;
static char kSensitivitySliderKey;
static char kSensitivityLessLabelKey;
static char kSensitivityMoreLabelKey;
static char kRightSideHintKey;

static __weak YTSettingsViewController *activeSettingsViewController = nil;
static CMMotionManager *shakeMotionManager = nil;
static NSTimeInterval shakeLastPeakTime = 0.0;
static NSTimeInterval shakeLastTriggerTime = 0.0;
static CMAcceleration shakeLastPeakAcceleration = {0.0, 0.0, 0.0};

static inline float ClampVolumeMultiplier(float multiplier) {
  if (multiplier < 0.0f)
    return 0.0f;
  if (multiplier > 20.0f)
    return 20.0f;
  return multiplier;
}

static inline float CalculateAudioMultiplier(float multiplier) {
  if (multiplier <= 1.0f)
    return multiplier;
  return powf(200.0f, (multiplier - 1.0f) / 19.0f);
}

static BOOL VBGestureMethodAllowsRightSide(void) {
  return cachedGestureMethod == VBGestureMethodRightSide;
}

static BOOL VBGestureMethodAllowsShake(void) {
  return cachedGestureMethod == VBGestureMethodShake;
}

static NSString *VBGestureMethodName(VBGestureMethod method) {
  switch (method) {
  case VBGestureMethodRightSide:
    return @"Right Side";
  case VBGestureMethodShake:
    return @"Shake";
  }
  return @"Right Side";
}

static void LoadPreferencesIfNeeded(void) {
  if (preferencesLoaded)
    return;

  preferencesLoaded = YES;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  if ([defaults objectForKey:kVolumeBoostYTEnabledKey] != nil)
    cachedVolumeBoostEnabled = [defaults boolForKey:kVolumeBoostYTEnabledKey];

  if ([defaults objectForKey:kRememberVolumeEnabledKey] != nil)
    cachedRememberVolumeEnabled = [defaults boolForKey:kRememberVolumeEnabledKey];

  if ([defaults objectForKey:kHapticFeedbackEnabledKey] != nil)
    cachedHapticFeedbackEnabled = [defaults boolForKey:kHapticFeedbackEnabledKey];

  if ([defaults objectForKey:kGestureMethodKey] != nil) {
    NSInteger storedMethod = [defaults integerForKey:kGestureMethodKey];
    cachedGestureMethod =
        storedMethod == VBGestureMethodShake ? VBGestureMethodShake
                                             : VBGestureMethodRightSide;
    if (storedMethod != VBGestureMethodRightSide &&
        storedMethod != VBGestureMethodShake) {
      [defaults setInteger:VBGestureMethodRightSide forKey:kGestureMethodKey];
    }
  }

  if ([defaults objectForKey:kShakeSensitivityKey] != nil) {
    cachedShakeSensitivity =
        fminf(1.0f, fmaxf(0.0f, [defaults floatForKey:kShakeSensitivityKey]));
  }

  if (cachedRememberVolumeEnabled &&
      [defaults objectForKey:kCustomYouTubeVolumeScalarKey] != nil) {
    currentVolumeMultiplier = ClampVolumeMultiplier(
        [defaults floatForKey:kCustomYouTubeVolumeScalarKey]);
  }

  cachedAudioMultiplier = CalculateAudioMultiplier(currentVolumeMultiplier);
}

BOOL VBIsEnabled(void) {
  return cachedVolumeBoostEnabled;
}

static inline BOOL IsVolumeBoostYTEnabled(void) {
  return cachedVolumeBoostEnabled;
}

static inline BOOL IsRememberVolumeEnabled(void) {
  return cachedRememberVolumeEnabled;
}

static inline BOOL IsHapticFeedbackEnabled(void) {
  return cachedHapticFeedbackEnabled;
}

static void VBPerformHapticFeedback(void) {
  if (!cachedHapticFeedbackEnabled)
    return;

  UIImpactFeedbackGenerator *generator =
      [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
  [generator prepare];
  [generator impactOccurred];
}

static inline NSHashTable *RendererTable(void) {
  dispatch_once(&activeRenderersOnce, ^{
    activeRenderers = [NSHashTable weakObjectsHashTable];
  });
  return activeRenderers;
}

void VBRegisterRenderer(id renderer) {
  if (!renderer)
    return;

  if (objc_getAssociatedObject(renderer, &kRendererRegisteredKey))
    return;

  objc_setAssociatedObject(renderer, &kRendererRegisteredKey, @YES,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  NSHashTable *table = RendererTable();
  @synchronized(table) {
    [table addObject:renderer];
  }
}

void VBApplyBaseVolume(id renderer) {
  if (!renderer || ![renderer respondsToSelector:@selector(setVolume:)])
    return;

  VBRegisterRenderer(renderer);
  [renderer setVolume:1.0f];
}

void VBReapplyTrackedRenderers(void) {
  NSHashTable *table = RendererTable();
  NSArray *snapshot = nil;

  @synchronized(table) {
    if (table.count == 0)
      return;
    snapshot = [table allObjects];
  }

  for (id renderer in snapshot) {
    if ([renderer respondsToSelector:@selector(setVolume:)])
      [renderer setVolume:1.0f];
  }
}

static inline float GetCustomVolumeMultiplier(void) {
  return currentVolumeMultiplier;
}

static inline float GetLogarithmicAudioMultiplier(void) {
  return cachedAudioMultiplier;
}

static void PersistCurrentVolumeIfNeeded(void) {
  if (!cachedRememberVolumeEnabled)
    return;

  [[NSUserDefaults standardUserDefaults]
      setFloat:currentVolumeMultiplier
        forKey:kCustomYouTubeVolumeScalarKey];
}

static BOOL SetCustomVolumeMultiplier(float multiplier) {
  multiplier = ClampVolumeMultiplier(multiplier);

  if (fabsf(multiplier - currentVolumeMultiplier) < 0.0001f)
    return NO;

  currentVolumeMultiplier = multiplier;
  cachedAudioMultiplier = CalculateAudioMultiplier(multiplier);
  VBReapplyTrackedRenderers();
  return YES;
}

%hook AVPlayer
- (void)setVolume:(float)volume {
  VBRegisterRenderer(self);
  if (IsVolumeBoostYTEnabled())
    volume *= GetLogarithmicAudioMultiplier();
  %orig(volume);
}
%end

%hook AVAudioPlayerNode
- (void)setVolume:(float)volume {
  VBRegisterRenderer(self);
  if (IsVolumeBoostYTEnabled())
    volume *= GetLogarithmicAudioMultiplier();
  %orig(volume);
}
%end

%hook AVAudioPlayer
- (void)setVolume:(float)volume {
  VBRegisterRenderer(self);
  if (IsVolumeBoostYTEnabled())
    volume *= GetLogarithmicAudioMultiplier();
  %orig(volume);
}
%end

%hook AVSampleBufferAudioRenderer
- (void)setVolume:(float)volume {
  VBRegisterRenderer(self);
  if (IsVolumeBoostYTEnabled())
    volume *= GetLogarithmicAudioMultiplier();
  %orig(volume);
}
%end

static void VBShowShakeControl(void) {
  if (!IsVolumeBoostYTEnabled() || !VBGestureMethodAllowsShake())
    return;

  if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive)
    return;

  dispatch_async(dispatch_get_main_queue(), ^{
    if (!IsVolumeBoostYTEnabled() || !VBGestureMethodAllowsShake())
      return;

    YTVolumeHUD *hud = [YTVolumeHUD sharedHUD];
    if ([hud isPresentedOrTransitioning])
      return;

    [hud showInteractiveWithValue:GetCustomVolumeMultiplier()
                      changeBlock:^(float value) {
                        if (SetCustomVolumeMultiplier(value))
                          PersistCurrentVolumeIfNeeded();
                      }];
  });
}

static void VBStopShakeDetector(void) {
  if (shakeMotionManager.deviceMotionActive)
    [shakeMotionManager stopDeviceMotionUpdates];

  shakeLastPeakTime = 0.0;
  shakeLastTriggerTime = 0.0;
  shakeLastPeakAcceleration = (CMAcceleration){0.0, 0.0, 0.0};
}

static void VBConfigureShakeDetector(void) {
  if (!IsVolumeBoostYTEnabled() || !VBGestureMethodAllowsShake()) {
    VBStopShakeDetector();
    return;
  }

  if (!shakeMotionManager)
    shakeMotionManager = [[CMMotionManager alloc] init];

  if (!shakeMotionManager.deviceMotionAvailable ||
      shakeMotionManager.deviceMotionActive) {
    return;
  }

  shakeMotionManager.deviceMotionUpdateInterval = 1.0 / 25.0;
  shakeLastPeakTime = 0.0;
  shakeLastTriggerTime = 0.0;
  shakeLastPeakAcceleration = (CMAcceleration){0.0, 0.0, 0.0};

  [shakeMotionManager
      startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue]
                          withHandler:^(CMDeviceMotion *motion, NSError *error) {
                            (void)error;

                            if (!motion || !IsVolumeBoostYTEnabled() ||
                                !VBGestureMethodAllowsShake())
                              return;

                            CMAcceleration a = motion.userAcceleration;
                            double magnitude =
                                sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
                            double sensitivity = cachedShakeSensitivity;
                            double threshold = 2.35 - sensitivity * 1.30;

                            if (magnitude < threshold)
                              return;

                            NSTimeInterval now =
                                [NSProcessInfo processInfo].systemUptime;

                            if (now - shakeLastTriggerTime < 1.20)
                              return;

                            if (shakeLastPeakTime > 0.0) {
                              NSTimeInterval gap = now - shakeLastPeakTime;
                              double dot =
                                  a.x * shakeLastPeakAcceleration.x +
                                  a.y * shakeLastPeakAcceleration.y +
                                  a.z * shakeLastPeakAcceleration.z;
                              double reversalGate =
                                  -0.18 * threshold * threshold;

                              if (gap >= 0.055 && gap <= 0.46 &&
                                  dot <= reversalGate) {
                                shakeLastTriggerTime = now;
                                shakeLastPeakTime = 0.0;
                                shakeLastPeakAcceleration =
                                    (CMAcceleration){0.0, 0.0, 0.0};
                                VBPerformHapticFeedback();
                                VBShowShakeControl();
                                return;
                              }
                            }

                            shakeLastPeakTime = now;
                            shakeLastPeakAcceleration = a;
                          }];
}

static CGRect VBRightSideActivationRect(UIWindow *window) {
  if (!window)
    return CGRectZero;

  CGFloat width = CGRectGetWidth(window.bounds);
  CGFloat height = CGRectGetHeight(window.bounds);
  CGFloat bandHeight = MIN(320.0f, MAX(220.0f, height * 0.34f));

  if (width > height)
    bandHeight = MIN(220.0f, MAX(150.0f, height * 0.50f));

  CGFloat centerY = height * 0.52f;
  CGFloat y = centerY - bandHeight * 0.5f;
  y = MAX(window.safeAreaInsets.top + 8.0f, y);
  y = MIN(y, height - window.safeAreaInsets.bottom - bandHeight - 8.0f);

  return CGRectMake(MAX(0.0f, width - 34.0f), y, 34.0f, bandHeight);
}

static void VBHideRightSideHint(UIWindow *window) {
  if (!window)
    return;

  UIView *hint = objc_getAssociatedObject(window, &kRightSideHintKey);
  if (!hint)
    return;

  objc_setAssociatedObject(window, &kRightSideHintKey, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  [UIView animateWithDuration:0.20
                   animations:^{
                     hint.alpha = 0.0f;
                   }
                   completion:^(BOOL finished) {
                     (void)finished;
                     [hint removeFromSuperview];
                   }];
}

static void VBJumpRightSideHint(UIWindow *window, UIView *hint) {
  if (!window || !hint || hint.superview != window)
    return;

  [UIView animateWithDuration:0.20
                        delay:0.0
       usingSpringWithDamping:0.58
        initialSpringVelocity:0.2
                      options:UIViewAnimationOptionBeginFromCurrentState |
                              UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     hint.transform =
                         CGAffineTransformMakeTranslation(-11.0f, 0.0f);
                   }
                   completion:^(BOOL finished) {
                     if (!finished || hint.superview != window)
                       return;

                     [UIView animateWithDuration:0.24
                                           delay:0.03
                          usingSpringWithDamping:0.72
                           initialSpringVelocity:0.1
                                         options:UIViewAnimationOptionBeginFromCurrentState |
                                                 UIViewAnimationOptionAllowUserInteraction
                                      animations:^{
                                        hint.transform =
                                            CGAffineTransformIdentity;
                                      }
                                      completion:nil];
                   }];
}

static void VBShowRightSideHintIfNeeded(UIWindow *window) {
  if (!window || window.screen != [UIScreen mainScreen] ||
      window.windowLevel != UIWindowLevelNormal || !window.isKeyWindow ||
      !IsVolumeBoostYTEnabled() || !VBGestureMethodAllowsRightSide()) {
    return;
  }

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults boolForKey:kRightSideTipSeenKey])
    return;

  [defaults setBool:YES forKey:kRightSideTipSeenKey];

  CGRect activationRect = VBRightSideActivationRect(window);
  CGFloat pillHeight = 58.0f;
  UIView *hint = [[UIView alloc]
      initWithFrame:CGRectMake(CGRectGetWidth(window.bounds) - 7.0f,
                               CGRectGetMidY(activationRect) -
                                   pillHeight * 0.5f,
                               5.0f, pillHeight)];
  hint.userInteractionEnabled = NO;
  hint.backgroundColor = [UIColor systemBlueColor];
  hint.layer.cornerRadius = 2.5f;
  hint.layer.shadowColor = [UIColor systemBlueColor].CGColor;
  hint.layer.shadowOpacity = 0.38f;
  hint.layer.shadowRadius = 7.0f;
  hint.layer.shadowOffset = CGSizeZero;
  hint.alpha = 0.0f;

  objc_setAssociatedObject(window, &kRightSideHintKey, hint,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [window addSubview:hint];
  [window bringSubviewToFront:hint];

  [UIView animateWithDuration:0.25
                   animations:^{
                     hint.alpha = 0.92f;
                   }];

  NSArray<NSNumber *> *delays = @[ @0.7, @2.8, @5.1, @7.5 ];
  for (NSNumber *delay in delays) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          if (objc_getAssociatedObject(window, &kRightSideHintKey) == hint)
            VBJumpRightSideHint(window, hint);
        });
  }

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(10.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (objc_getAssociatedObject(window, &kRightSideHintKey) ==
                       hint) {
                     VBHideRightSideHint(window);
                   }
                 });
}

@interface VBVolumeGestureHandler : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIWindow *window;
@end

@implementation VBVolumeGestureHandler

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
  (void)gestureRecognizer;

  UIWindow *window = self.window;
  if (!window || !IsVolumeBoostYTEnabled() ||
      !VBGestureMethodAllowsRightSide()) {
    return NO;
  }

  if (window.screen != [UIScreen mainScreen] ||
      window.windowLevel != UIWindowLevelNormal) {
    return NO;
  }

  CGPoint location = [touch locationInView:window];
  if (!CGRectContainsPoint(VBRightSideActivationRect(window), location))
    return NO;

  UIView *view = touch.view;
  for (UIView *candidate = view; candidate && candidate != window;
       candidate = candidate.superview) {
    if ([candidate isKindOfClass:[UITextField class]] ||
        [candidate isKindOfClass:[UITextView class]]) {
      return NO;
    }
  }

  return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
  if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]])
    return YES;

  UIPanGestureRecognizer *pan =
      (UIPanGestureRecognizer *)gestureRecognizer;
  CGPoint velocity = [pan velocityInView:self.window];

  if (velocity.x >= -35.0f)
    return NO;

  return fabs(velocity.x) > fabs(velocity.y) * 1.10f;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
  (void)gestureRecognizer;
  (void)otherGestureRecognizer;
  return NO;
}

- (void)handleRightSidePan:(UIPanGestureRecognizer *)pan {
  if (pan.state != UIGestureRecognizerStateBegan)
    return;

  UIWindow *window = self.window;
  if (!window)
    return;

  VBHideRightSideHint(window);
  VBPerformHapticFeedback();

  [[YTVolumeHUD sharedHUD]
      toggleInteractiveWithValue:GetCustomVolumeMultiplier()
                     changeBlock:^(float value) {
                       if (SetCustomVolumeMultiplier(value))
                         PersistCurrentVolumeIfNeeded();
                     }];
}

@end

static void VBEnsureVolumeGestureRecognizer(UIWindow *window) {
  if (!window || window.screen != [UIScreen mainScreen])
    return;

  if (objc_getAssociatedObject(window, &kVolumeGestureRecognizerKey))
    return;

  VBVolumeGestureHandler *handler = [[VBVolumeGestureHandler alloc] init];
  handler.window = window;

  UIPanGestureRecognizer *pan =
      [[UIPanGestureRecognizer alloc] initWithTarget:handler
                                             action:@selector(handleRightSidePan:)];
  pan.delegate = handler;
  pan.cancelsTouchesInView = YES;
  pan.delaysTouchesBegan = NO;
  pan.delaysTouchesEnded = NO;
  pan.minimumNumberOfTouches = 1;
  pan.maximumNumberOfTouches = 1;

  objc_setAssociatedObject(window, &kVolumeGestureHandlerKey, handler,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(window, &kVolumeGestureRecognizerKey, pan,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [window addGestureRecognizer:pan];
}

static void VBScheduleRightSideHint(UIWindow *window) {
  if (!window)
    return;

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(0.65 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   VBShowRightSideHintIfNeeded(window);
                 });
}

%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
  if (self.screen == [UIScreen mainScreen]) {
    VBEnsureVolumeGestureRecognizer(self);
    VBShowRightSideHintIfNeeded(self);
  }
  %orig(event);
}

- (void)makeKeyAndVisible {
  %orig;
  VBEnsureVolumeGestureRecognizer(self);
  VBScheduleRightSideHint(self);
}

- (void)becomeKeyWindow {
  %orig;
  VBEnsureVolumeGestureRecognizer(self);
  VBScheduleRightSideHint(self);
}

%end

static void VBSetGestureMethod(VBGestureMethod method) {
  cachedGestureMethod = method;
  [[NSUserDefaults standardUserDefaults] setInteger:method
                                             forKey:kGestureMethodKey];

  [[YTVolumeHUD sharedHUD] hide];
  VBConfigureShakeDetector();

  YTSettingsViewController *controller = activeSettingsViewController;
  if (controller)
    [controller reloadData];
}

static UIMenu *VBBuildGestureMethodMenu(void) {
  NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
  NSArray<NSString *> *titles = @[ @"Right Side", @"Shake" ];

  for (NSInteger index = 0; index < (NSInteger)titles.count; index++) {
    VBGestureMethod method = (VBGestureMethod)index;
    UIAction *action =
        [UIAction actionWithTitle:titles[index]
                            image:nil
                       identifier:nil
                          handler:^(__kindof UIAction *selectedAction) {
                            (void)selectedAction;
                            VBSetGestureMethod(method);
                          }];
    action.state =
        cachedGestureMethod == method ? UIMenuElementStateOn
                                      : UIMenuElementStateOff;
    [actions addObject:action];
  }

  return [UIMenu menuWithTitle:@"" children:actions];
}

static BOOL VBViewContainsLabelText(UIView *view, NSString *text) {
  if (!view || text.length == 0)
    return NO;

  if ([view isKindOfClass:[UILabel class]]) {
    NSString *labelText = ((UILabel *)view).text;
    if ([labelText isEqualToString:text])
      return YES;
  }

  for (UIView *subview in view.subviews) {
    if (VBViewContainsLabelText(subview, text))
      return YES;
  }

  return NO;
}

static BOOL VBCellMatches(YTSettingsCell *cell, NSString *identifier,
                          NSString *title) {
  if (!cell)
    return NO;

  if ([cell.accessibilityIdentifier isEqualToString:identifier])
    return YES;

  return VBViewContainsLabelText(cell, title);
}

static UIButton *VBInstallGestureMenuOnCell(YTSettingsCell *cell) {
  if (!cell)
    return nil;

  UIButton *button = objc_getAssociatedObject(cell, &kGestureMenuButtonKey);
  if (!button) {
    button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [UIColor clearColor];
    button.accessibilityLabel = @"Gesture Method";
    button.showsMenuAsPrimaryAction = YES;
    objc_setAssociatedObject(cell, &kGestureMenuButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cell.contentView addSubview:button];
  }

  button.menu = VBBuildGestureMethodMenu();
  button.hidden = NO;
  button.frame = cell.contentView.bounds;
  button.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [cell.contentView bringSubviewToFront:button];
  return button;
}

@interface VBSettingsControlBridge : NSObject
+ (instancetype)sharedBridge;
- (void)shakeSensitivityChanged:(UISlider *)slider;
@end

@implementation VBSettingsControlBridge

+ (instancetype)sharedBridge {
  static VBSettingsControlBridge *bridge = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    bridge = [[VBSettingsControlBridge alloc] init];
  });
  return bridge;
}

- (void)shakeSensitivityChanged:(UISlider *)slider {
  cachedShakeSensitivity = fminf(1.0f, fmaxf(0.0f, slider.value));
  [[NSUserDefaults standardUserDefaults] setFloat:cachedShakeSensitivity
                                           forKey:kShakeSensitivityKey];
}

@end

static UILabel *VBCreateSensitivityLabel(NSString *text) {
  UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
  label.text = text;
  label.font = [UIFont systemFontOfSize:11.0f weight:UIFontWeightRegular];
  label.textColor = [UIColor secondaryLabelColor];
  label.userInteractionEnabled = NO;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  return label;
}

static void VBConfigureSensitivityCell(YTSettingsCell *cell) {
  UISlider *slider = objc_getAssociatedObject(cell, &kSensitivitySliderKey);
  UILabel *lessLabel =
      objc_getAssociatedObject(cell, &kSensitivityLessLabelKey);
  UILabel *moreLabel =
      objc_getAssociatedObject(cell, &kSensitivityMoreLabelKey);

  if (!slider) {
    slider = [[UISlider alloc] initWithFrame:CGRectZero];
    slider.minimumValue = 0.0f;
    slider.maximumValue = 1.0f;
    slider.continuous = YES;
    slider.minimumTrackTintColor = [UIColor systemBlueColor];
    slider.maximumTrackTintColor =
        [UIColor colorWithWhite:1.0f alpha:0.20f];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider addTarget:[VBSettingsControlBridge sharedBridge]
                  action:@selector(shakeSensitivityChanged:)
        forControlEvents:UIControlEventValueChanged];

    lessLabel = VBCreateSensitivityLabel(@"Less");
    moreLabel = VBCreateSensitivityLabel(@"More");
    moreLabel.textAlignment = NSTextAlignmentRight;

    objc_setAssociatedObject(cell, &kSensitivitySliderKey, slider,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kSensitivityLessLabelKey, lessLabel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kSensitivityMoreLabelKey, moreLabel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [cell.contentView addSubview:slider];
    [cell.contentView addSubview:lessLabel];
    [cell.contentView addSubview:moreLabel];

    [NSLayoutConstraint activateConstraints:@[
      [lessLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor
                                              constant:16.0f],
      [lessLabel.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor
                                             constant:-10.0f],
      [lessLabel.widthAnchor constraintEqualToConstant:34.0f],
      [moreLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor
                                                constant:-16.0f],
      [moreLabel.bottomAnchor constraintEqualToAnchor:lessLabel.bottomAnchor],
      [moreLabel.widthAnchor constraintEqualToConstant:34.0f],
      [slider.leadingAnchor constraintEqualToAnchor:lessLabel.trailingAnchor
                                            constant:3.0f],
      [slider.trailingAnchor constraintEqualToAnchor:moreLabel.leadingAnchor
                                             constant:-3.0f],
      [slider.centerYAnchor constraintEqualToAnchor:lessLabel.centerYAnchor]
    ]];
  }

  slider.hidden = NO;
  lessLabel.hidden = NO;
  moreLabel.hidden = NO;
  slider.value = cachedShakeSensitivity;

  [cell.contentView bringSubviewToFront:slider];
  [cell.contentView bringSubviewToFront:lessLabel];
  [cell.contentView bringSubviewToFront:moreLabel];
}

static void VBHideSensitivityControls(YTSettingsCell *cell) {
  UISlider *slider = objc_getAssociatedObject(cell, &kSensitivitySliderKey);
  UILabel *lessLabel =
      objc_getAssociatedObject(cell, &kSensitivityLessLabelKey);
  UILabel *moreLabel =
      objc_getAssociatedObject(cell, &kSensitivityMoreLabelKey);

  slider.hidden = YES;
  lessLabel.hidden = YES;
  moreLabel.hidden = YES;
}

%hook YTSettingsCell
- (void)layoutSubviews {
  %orig;

  BOOL gestureCell =
      VBCellMatches(self, kGestureMethodCellID, @"Gesture Method");
  BOOL sensitivityCell =
      VBCellMatches(self, kShakeSensitivityCellID, @"Shake Sensitivity");

  UIButton *menuButton =
      objc_getAssociatedObject(self, &kGestureMenuButtonKey);
  if (gestureCell) {
    VBInstallGestureMenuOnCell(self);
  } else if (menuButton) {
    menuButton.hidden = YES;
  }

  if (sensitivityCell)
    VBConfigureSensitivityCell(self);
  else
    VBHideSensitivityControls(self);
}
%end

%group YouTubeSettings

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
  if (self.type != 1)
    return %orig;

  if (supportsTweaksCategoryAPI)
    return %orig;

  NSArray<NSNumber *> *categories = %orig;
  NSMutableArray<NSNumber *> *mutableCategories = [categories mutableCopy];

  if (mutableCategories &&
      ![mutableCategories containsObject:@(TweakSection)]) {
    [mutableCategories insertObject:@(TweakSection) atIndex:0];
  }

  return mutableCategories.copy ?: categories;
}

+ (NSMutableArray<NSNumber *> *)tweaks {
  NSArray<NSNumber *> *original = %orig;
  NSMutableArray<NSNumber *> *tweaks =
      original ? [original mutableCopy] : [NSMutableArray array];

  if (![tweaks containsObject:@(TweakSection)])
    [tweaks addObject:@(TweakSection)];

  return tweaks;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray<NSNumber *> *)settingsCategoryOrder {
  NSArray<NSNumber *> *order = %orig;
  if (!order || [order containsObject:@(TweakSection)])
    return order;

  NSUInteger insertIndex = [order indexOfObject:@(1)];

  if (insertIndex != NSNotFound) {
    NSMutableArray<NSNumber *> *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(TweakSection) atIndex:insertIndex + 1];
    return mutableOrder.copy;
  }

  return order;
}

%end

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)updateVolumeBoostYTSectionWithEntry:(id)entry {
  (void)entry;

  NSMutableArray<YTSettingsSectionItem *> *sectionItems =
      [NSMutableArray array];
  Class YTSettingsSectionItemClass = %c(YTSettingsSectionItem);

  if (!YTSettingsSectionItemClass)
    return;

  YTSettingsViewController *settingsViewController = nil;

  @try {
    settingsViewController =
        [self valueForKey:@"_settingsViewControllerDelegate"];
  } @catch (__unused NSException *exception) {
    return;
  }

  if (!settingsViewController)
    return;

  activeSettingsViewController = settingsViewController;

  YTSettingsSectionItem *enableTweak = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Enable VolumeBoostYT"
             titleDescription:@"Allow custom Volume Boost gestures."
      accessibilityIdentifier:nil
                     switchOn:IsVolumeBoostYTEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    (void)cell;
                    cachedVolumeBoostEnabled = enabled;
                    [[NSUserDefaults standardUserDefaults]
                        setBool:enabled
                         forKey:kVolumeBoostYTEnabledKey];
                    VBReapplyTrackedRenderers();
                    VBConfigureShakeDetector();
                    if (!enabled)
                      [[YTVolumeHUD sharedHUD] hide];
                    return YES;
                  }
                settingItemId:0];
  [sectionItems addObject:enableTweak];

  YTSettingsSectionItem *(^sectionHeader)(NSString *) =
      ^YTSettingsSectionItem *(NSString *title) {
        return [YTSettingsSectionItemClass
            itemWithTitle:@"\t"
         titleDescription:title
  accessibilityIdentifier:nil
          detailTextBlock:nil
              selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                (void)cell;
                (void)index;
                return NO;
              }];
      };

  [sectionItems addObject:sectionHeader(@"GESTURE CONTROL")];

  YTSettingsSectionItem *gestureMethod = [YTSettingsSectionItemClass
          itemWithTitle:@"Gesture Method"
       titleDescription:@"Right Side swipes from the middle-right edge."
accessibilityIdentifier:kGestureMethodCellID
        detailTextBlock:^NSString * {
          return VBGestureMethodName(cachedGestureMethod);
        }
            selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
              (void)index;
              UIButton *button = VBInstallGestureMenuOnCell(cell);
              if (button) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  [button sendActionsForControlEvents:UIControlEventTouchUpInside];
                });
              }
              return YES;
            }];
  [sectionItems addObject:gestureMethod];

  YTSettingsSectionItem *shakeSensitivity = [YTSettingsSectionItemClass
          itemWithTitle:@"Shake Sensitivity"
       titleDescription:@"​"
accessibilityIdentifier:kShakeSensitivityCellID
        detailTextBlock:^NSString * {
          return @"Default";
        }
            selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
              (void)cell;
              (void)index;
              return NO;
            }];
  [sectionItems addObject:shakeSensitivity];

  [sectionItems addObject:sectionHeader(@"BEHAVIOR")];

  YTSettingsSectionItem *rememberVolume = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Remember Volume"
             titleDescription:@"Restore your last Volume Boost level when YouTube is reopened."
      accessibilityIdentifier:nil
                     switchOn:IsRememberVolumeEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    (void)cell;
                    NSUserDefaults *defaults =
                        [NSUserDefaults standardUserDefaults];
                    cachedRememberVolumeEnabled = enabled;
                    [defaults setBool:enabled
                               forKey:kRememberVolumeEnabledKey];

                    if (enabled) {
                      [defaults setFloat:GetCustomVolumeMultiplier()
                                  forKey:kCustomYouTubeVolumeScalarKey];
                    } else {
                      [defaults removeObjectForKey:kCustomYouTubeVolumeScalarKey];
                    }

                    return YES;
                  }
                settingItemId:1];
  [sectionItems addObject:rememberVolume];

  YTSettingsSectionItem *hapticFeedback = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Haptic Feedback"
             titleDescription:@"Vibrate when the gesture is activated."
      accessibilityIdentifier:nil
                     switchOn:IsHapticFeedbackEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    (void)cell;
                    cachedHapticFeedbackEnabled = enabled;
                    [[NSUserDefaults standardUserDefaults]
                        setBool:enabled
                         forKey:kHapticFeedbackEnabledKey];
                    if (enabled)
                      VBPerformHapticFeedback();
                    return YES;
                  }
                settingItemId:2];
  [sectionItems addObject:hapticFeedback];

  [sectionItems addObject:sectionHeader(@"ABOUT")];

  YTSettingsSectionItem *about = [YTSettingsSectionItemClass
          itemWithTitle:@"VolumeBoostYT"
       titleDescription:@"Simple. Louder. Better YouTube."
accessibilityIdentifier:nil
        detailTextBlock:nil
            selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
              (void)cell;
              (void)index;
              UIAlertController *alert =
                  [UIAlertController alertControllerWithTitle:@"VolumeBoostYT"
                                                     message:@"Simple. Louder. Better YouTube.\n0%–2000% Volume Boost"
                                              preferredStyle:UIAlertControllerStyleAlert];
              [alert addAction:[UIAlertAction actionWithTitle:@"Done"
                                                       style:UIAlertActionStyleCancel
                                                     handler:nil]];
              UIViewController *presenter = activeSettingsViewController;
              if (presenter.presentedViewController)
                presenter = presenter.presentedViewController;
              [presenter presentViewController:alert animated:YES completion:nil];
              return YES;
            }];
  [sectionItems addObject:about];

  if ([settingsViewController
          respondsToSelector:@selector
          (setSectionItems:
               forCategory:title:icon:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:TweakSection
                                      title:@"VolumeBoostYT"
                                       icon:nil
                           titleDescription:nil
                               headerHidden:NO];
  } else if ([settingsViewController
                 respondsToSelector:@selector
                 (setSectionItems:
                      forCategory:title:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:TweakSection
                                      title:@"VolumeBoostYT"
                           titleDescription:nil
                               headerHidden:NO];
  }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
  if (category == TweakSection) {
    [self updateVolumeBoostYTSectionWithEntry:entry];
    return;
  }
  %orig;
}

%end

%end

%ctor {
  NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
  BOOL isYouTubeProcess =
      [bundleID isEqualToString:@"com.google.ios.youtube"] ||
      NSClassFromString(@"YTSettingsGroupData") != Nil ||
      NSClassFromString(@"YTAppSettingsPresentationData") != Nil;

  if (!isYouTubeProcess)
    return;

  LoadPreferencesIfNeeded();

  Class settingsGroupClass = NSClassFromString(@"YTSettingsGroupData");
  if (settingsGroupClass) {
    supportsTweaksCategoryAPI =
        class_getClassMethod(settingsGroupClass, @selector(tweaks)) != NULL;
    %init(YouTubeSettings);
  }

  VBConfigureShakeDetector();
  %init;
}
