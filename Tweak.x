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
  VBGestureMethodDoubleTapSlide = 0,
  VBGestureMethodShake = 1,
  VBGestureMethodBoth = 2,
  VBGestureMethodOff = 3,
};

static const NSInteger TweakSection = 'ndyt';

static NSString *const kVolumeBoostYTEnabledKey = @"VolumeBoostYTEnabled";
static NSString *const kRememberVolumeEnabledKey = @"RememberVolumeEnabled";
static NSString *const kCustomYouTubeVolumeScalarKey = @"CustomYouTubeVolumeScalar";
static NSString *const kGestureMethodKey = @"VolumeBoostYTGestureMethod";
static NSString *const kShakeSensitivityKey = @"VolumeBoostYTShakeSensitivity";
static NSString *const kHapticFeedbackEnabledKey = @"VolumeBoostYTHapticFeedbackEnabled";
static NSString *const kGestureMethodCellID = @"VolumeBoostYTGestureMethodCell";
static NSString *const kShakeSensitivityCellID = @"VolumeBoostYTShakeSensitivityCell";

static BOOL cachedVolumeBoostEnabled = YES;
static BOOL cachedRememberVolumeEnabled = YES;
static BOOL cachedHapticFeedbackEnabled = YES;
static BOOL supportsTweaksCategoryAPI = NO;
static VBGestureMethod cachedGestureMethod = VBGestureMethodDoubleTapSlide;
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

static __weak YTSettingsViewController *activeSettingsViewController = nil;
static CMMotionManager *shakeMotionManager = nil;
static NSTimeInterval shakeLastPeakTime = 0.0;
static NSTimeInterval shakeLastTriggerTime = 0.0;
static CMAcceleration shakeLastPeakAcceleration = {0.0, 0.0, 0.0};

static inline float ClampVolumeMultiplier(float multiplier) {
  if (multiplier < 1.0f)
    return 1.0f;
  if (multiplier > 20.0f)
    return 20.0f;
  return multiplier;
}

static inline float CalculateAudioMultiplier(float multiplier) {
  if (multiplier <= 1.0f)
    return multiplier;
  return powf(200.0f, (multiplier - 1.0f) / 19.0f);
}

static BOOL VBGestureMethodAllowsDoubleTap(void) {
  return cachedGestureMethod == VBGestureMethodDoubleTapSlide ||
         cachedGestureMethod == VBGestureMethodBoth;
}

static BOOL VBGestureMethodAllowsShake(void) {
  return cachedGestureMethod == VBGestureMethodShake ||
         cachedGestureMethod == VBGestureMethodBoth;
}

static NSString *VBGestureMethodName(VBGestureMethod method) {
  switch (method) {
  case VBGestureMethodDoubleTapSlide:
    return @"Double Tap & Slide";
  case VBGestureMethodShake:
    return @"Shake";
  case VBGestureMethodBoth:
    return @"Both";
  case VBGestureMethodOff:
    return @"Off";
  }
  return @"Double Tap & Slide";
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
    if (storedMethod >= VBGestureMethodDoubleTapSlide &&
        storedMethod <= VBGestureMethodOff) {
      cachedGestureMethod = (VBGestureMethod)storedMethod;
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

    [[YTVolumeHUD sharedHUD]
        showInteractiveWithValue:GetCustomVolumeMultiplier()
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

@interface VBDoubleTapSlideGestureRecognizer : UIGestureRecognizer
@property(nonatomic, assign) NSInteger sequenceStage;
@property(nonatomic, assign) NSInteger timeoutToken;
@property(nonatomic, assign) CGPoint firstStartPoint;
@property(nonatomic, assign) CGPoint firstEndPoint;
@property(nonatomic, assign) CGPoint secondStartPoint;
@property(nonatomic, assign) CGPoint currentPoint;
@property(nonatomic, assign) CGPoint activationPoint;
@property(nonatomic, assign) NSTimeInterval firstStartTime;
@property(nonatomic, assign) NSTimeInterval firstEndTime;
@property(nonatomic, assign) NSTimeInterval secondStartTime;
@property(nonatomic, assign) BOOL activated;
- (CGFloat)effectiveTranslationY;
@end

@implementation VBDoubleTapSlideGestureRecognizer

- (void)reset {
  [super reset];
  self.sequenceStage = 0;
  self.timeoutToken += 1;
  self.firstStartPoint = CGPointZero;
  self.firstEndPoint = CGPointZero;
  self.secondStartPoint = CGPointZero;
  self.currentPoint = CGPointZero;
  self.activationPoint = CGPointZero;
  self.firstStartTime = 0.0;
  self.firstEndTime = 0.0;
  self.secondStartTime = 0.0;
  self.activated = NO;
}

- (CGFloat)effectiveTranslationY {
  if (!self.activated)
    return 0.0f;
  return self.currentPoint.y - self.activationPoint.y;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;

  if (touches.count != 1) {
    self.state = UIGestureRecognizerStateFailed;
    return;
  }

  UITouch *touch = touches.anyObject;
  CGPoint point = [touch locationInView:self.view];

  if (self.sequenceStage == 0) {
    self.sequenceStage = 1;
    self.firstStartPoint = point;
    self.firstStartTime = touch.timestamp;
    return;
  }

  if (self.sequenceStage != 2) {
    self.state = UIGestureRecognizerStateFailed;
    return;
  }

  NSTimeInterval gap = touch.timestamp - self.firstEndTime;
  CGFloat dx = point.x - self.firstEndPoint.x;
  CGFloat dy = point.y - self.firstEndPoint.y;
  CGFloat distance = hypot(dx, dy);

  if (gap < 0.025 || gap > 0.34 || distance > 74.0f) {
    self.state = UIGestureRecognizerStateFailed;
    return;
  }

  self.sequenceStage = 3;
  self.secondStartPoint = point;
  self.currentPoint = point;
  self.secondStartTime = touch.timestamp;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;

  UITouch *touch = touches.anyObject;
  if (!touch)
    return;

  CGPoint point = [touch locationInView:self.view];
  self.currentPoint = point;

  if (self.sequenceStage == 1) {
    CGFloat dx = point.x - self.firstStartPoint.x;
    CGFloat dy = point.y - self.firstStartPoint.y;
    if (hypot(dx, dy) > 11.0f)
      self.state = UIGestureRecognizerStateFailed;
    return;
  }

  if (self.sequenceStage != 3)
    return;

  CGFloat dx = point.x - self.secondStartPoint.x;
  CGFloat dy = point.y - self.secondStartPoint.y;
  CGFloat absX = fabs(dx);
  CGFloat absY = fabs(dy);
  NSTimeInterval held = touch.timestamp - self.secondStartTime;

  if (!self.activated) {
    if (absX > 22.0f && absX > absY * 1.35f) {
      self.state = UIGestureRecognizerStateFailed;
      return;
    }

    if (held < 0.045 || absY < 14.0f || absY < absX * 0.78f)
      return;

    self.activated = YES;
    self.activationPoint = point;
    self.state = UIGestureRecognizerStateBegan;
    return;
  }

  self.state = UIGestureRecognizerStateChanged;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;

  UITouch *touch = touches.anyObject;
  if (!touch) {
    self.state = self.activated ? UIGestureRecognizerStateEnded
                                : UIGestureRecognizerStateFailed;
    return;
  }

  CGPoint point = [touch locationInView:self.view];

  if (self.sequenceStage == 1) {
    CGFloat dx = point.x - self.firstStartPoint.x;
    CGFloat dy = point.y - self.firstStartPoint.y;
    NSTimeInterval duration = touch.timestamp - self.firstStartTime;

    if (duration > 0.22 || hypot(dx, dy) > 11.0f) {
      self.state = UIGestureRecognizerStateFailed;
      return;
    }

    self.firstEndPoint = point;
    self.firstEndTime = touch.timestamp;
    self.sequenceStage = 2;
    NSInteger token = ++self.timeoutToken;
    __weak typeof(self) weakSelf = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.36 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     VBDoubleTapSlideGestureRecognizer *strongSelf = weakSelf;
                     if (!strongSelf)
                       return;
                     if (strongSelf.state == UIGestureRecognizerStatePossible &&
                         strongSelf.sequenceStage == 2 &&
                         strongSelf.timeoutToken == token) {
                       strongSelf.state = UIGestureRecognizerStateFailed;
                     }
                   });
    return;
  }

  if (self.sequenceStage == 3) {
    self.currentPoint = point;
    self.state = self.activated ? UIGestureRecognizerStateEnded
                                : UIGestureRecognizerStateFailed;
    return;
  }

  self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event {
  (void)touches;
  (void)event;
  self.state = self.activated ? UIGestureRecognizerStateCancelled
                              : UIGestureRecognizerStateFailed;
}

@end

@interface VBVolumeGestureHandler : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, assign) float startMultiplier;
@end

@implementation VBVolumeGestureHandler

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
  (void)gestureRecognizer;

  UIWindow *window = self.window;
  if (!window || !IsVolumeBoostYTEnabled() ||
      !VBGestureMethodAllowsDoubleTap()) {
    return NO;
  }

  if (window.screen != [UIScreen mainScreen] ||
      window.windowLevel != UIWindowLevelNormal) {
    return NO;
  }

  UIView *view = touch.view;
  for (UIView *candidate = view; candidate && candidate != window;
       candidate = candidate.superview) {
    if ([candidate isKindOfClass:[UIControl class]] ||
        [candidate isKindOfClass:[UITextField class]] ||
        [candidate isKindOfClass:[UITextView class]]) {
      return NO;
    }
  }

  return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
  (void)gestureRecognizer;
  (void)otherGestureRecognizer;
  return NO;
}

- (void)handleDoubleTapSlide:(VBDoubleTapSlideGestureRecognizer *)gesture {
  UIWindow *window = self.window;
  if (!window)
    return;

  switch (gesture.state) {
  case UIGestureRecognizerStateBegan:
    self.startMultiplier = GetCustomVolumeMultiplier();
    VBPerformHapticFeedback();
    [[YTVolumeHUD sharedHUD] showWithValue:self.startMultiplier];
    break;

  case UIGestureRecognizerStateChanged: {
    CGFloat travel = MAX(220.0f, window.bounds.size.height * 0.55f);
    float deltaMultiplier =
        (float)(-gesture.effectiveTranslationY / travel * 19.0f);
    float newMultiplier =
        ClampVolumeMultiplier(self.startMultiplier + deltaMultiplier);

    if (SetCustomVolumeMultiplier(newMultiplier))
      [[YTVolumeHUD sharedHUD] showWithValue:newMultiplier];
    break;
  }

  case UIGestureRecognizerStateEnded:
  case UIGestureRecognizerStateCancelled:
  case UIGestureRecognizerStateFailed:
    PersistCurrentVolumeIfNeeded();
    [[YTVolumeHUD sharedHUD] scheduleHideAfterDelay:0.9];
    break;

  default:
    break;
  }
}

@end

static void VBEnsureVolumeGestureRecognizer(UIWindow *window) {
  if (!window || window.screen != [UIScreen mainScreen])
    return;

  if (objc_getAssociatedObject(window, &kVolumeGestureRecognizerKey))
    return;

  VBVolumeGestureHandler *handler = [[VBVolumeGestureHandler alloc] init];
  handler.window = window;

  VBDoubleTapSlideGestureRecognizer *gesture =
      [[VBDoubleTapSlideGestureRecognizer alloc]
          initWithTarget:handler
                  action:@selector(handleDoubleTapSlide:)];
  gesture.delegate = handler;
  gesture.cancelsTouchesInView = YES;
  gesture.delaysTouchesBegan = NO;
  gesture.delaysTouchesEnded = NO;

  objc_setAssociatedObject(window, &kVolumeGestureHandlerKey, handler,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(window, &kVolumeGestureRecognizerKey, gesture,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [window addGestureRecognizer:gesture];
}

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
  if (self.screen == [UIScreen mainScreen])
    VBEnsureVolumeGestureRecognizer(self);
  %orig(event);
}
%end

static void VBSetGestureMethod(VBGestureMethod method) {
  cachedGestureMethod = method;
  [[NSUserDefaults standardUserDefaults] setInteger:method
                                             forKey:kGestureMethodKey];

  if (method == VBGestureMethodOff)
    [[YTVolumeHUD sharedHUD] hide];

  VBConfigureShakeDetector();

  YTSettingsViewController *controller = activeSettingsViewController;
  if (controller)
    [controller reloadData];
}

static UIMenu *VBBuildGestureMethodMenu(void) {
  NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
  NSArray<NSString *> *titles =
      @[ @"Double Tap & Slide", @"Shake", @"Both", @"Off" ];

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
  }

  slider.hidden = NO;
  lessLabel.hidden = NO;
  moreLabel.hidden = NO;
  slider.value = cachedShakeSensitivity;

  CGFloat width = CGRectGetWidth(cell.contentView.bounds);
  CGFloat height = CGRectGetHeight(cell.contentView.bounds);
  CGFloat y = MAX(30.0f, height - 34.0f);

  lessLabel.frame = CGRectMake(16.0f, y + 3.0f, 34.0f, 20.0f);
  moreLabel.frame = CGRectMake(width - 50.0f, y + 3.0f, 34.0f, 20.0f);
  slider.frame = CGRectMake(52.0f, y - 2.0f, MAX(90.0f, width - 104.0f), 31.0f);

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
       titleDescription:@"Choose how to activate Volume Boost."
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
       titleDescription:@"Only used when Shake is selected."
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
                                                     message:@"Simple. Louder. Better YouTube.\n100%–2000% Volume Boost"
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
