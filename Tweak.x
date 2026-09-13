#import "YTVolumeHUD.h"
#import <AVFoundation/AVFoundation.h>
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

static const NSInteger TweakSection = 'ndyt';
static NSString *const kVolumeBoostYTEnabledKey = @"VolumeBoostYTEnabled";
static NSString *const kRememberVolumeEnabledKey = @"RememberVolumeEnabled";
static NSString *const kShowGestureIndicatorKey = @"ShowGestureIndicator";
static NSString *const kCustomYouTubeVolumeScalarKey =
    @"CustomYouTubeVolumeScalar";

static BOOL cachedVolumeBoostEnabled = YES;
static BOOL cachedRememberVolumeEnabled = YES;
static BOOL cachedShowGestureIndicator = YES;
static BOOL supportsTweaksCategoryAPI = NO;
static float currentVolumeMultiplier = 1.0f;
static float cachedAudioMultiplier = 1.0f;
static BOOL preferencesLoaded = NO;

static NSHashTable *activeRenderers = nil;
static dispatch_once_t activeRenderersOnce;
static char kRendererRegisteredKey;
static char kGestureIndicatorKey;
static char kVolumePanRecognizerKey;
static char kVolumePanHandlerKey;

static const CGFloat kGestureRightInset = 44.0f;
static const CGFloat kGestureHitboxWidth = 84.0f;
static const CGFloat kGestureIndicatorWidth = 5.0f;
static const CGFloat kGestureIndicatorHeight = 62.0f;

typedef NS_ENUM(NSInteger, VBWindowMode) {
  VBWindowModeNormal = 0,
  VBWindowModeShorts = 1,
  VBWindowModeFullscreen = 2,
};

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

static void LoadPreferencesIfNeeded(void) {
  if (preferencesLoaded)
    return;

  preferencesLoaded = YES;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  if ([defaults objectForKey:kVolumeBoostYTEnabledKey] != nil) {
    cachedVolumeBoostEnabled =
        [defaults boolForKey:kVolumeBoostYTEnabledKey];
  }

  if ([defaults objectForKey:kRememberVolumeEnabledKey] != nil) {
    cachedRememberVolumeEnabled =
        [defaults boolForKey:kRememberVolumeEnabledKey];
  }

  if ([defaults objectForKey:kShowGestureIndicatorKey] != nil) {
    cachedShowGestureIndicator =
        [defaults boolForKey:kShowGestureIndicatorKey];
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

static inline BOOL IsGestureIndicatorVisible(void) {
  return cachedShowGestureIndicator;
}

static BOOL VBControllerIsShorts(UIViewController *controller) {
  if (!controller)
    return NO;

  NSString *className = NSStringFromClass(controller.class);
  return [className containsString:@"YTReelWatch"] ||
         [className containsString:@"YTShortsPlayer"];
}

static BOOL VBControllerReportsFullscreen(UIViewController *controller) {
  if (!controller)
    return NO;

  NSString *className = NSStringFromClass(controller.class);
  if (![className hasPrefix:@"YT"])
    return NO;

  BOOL likelyPlayerController =
      [className containsString:@"Watch"] ||
      [className containsString:@"Player"] ||
      [className containsString:@"Overlay"];
  if (!likelyPlayerController)
    return NO;

  SEL selector = NSSelectorFromString(@"isFullscreen");
  if (![controller respondsToSelector:selector])
    return NO;

  NSMethodSignature *signature =
      [controller methodSignatureForSelector:selector];
  if (!signature || signature.methodReturnLength != sizeof(BOOL))
    return NO;

  IMP implementation = [controller methodForSelector:selector];
  if (!implementation)
    return NO;

  BOOL (*isFullscreen)(id, SEL) = (BOOL (*)(id, SEL))implementation;
  return isFullscreen(controller, selector);
}

static BOOL VBControllerTreeContainsShorts(UIViewController *controller) {
  if (!controller)
    return NO;

  if (VBControllerIsShorts(controller))
    return YES;

  UIViewController *presented = controller.presentedViewController;
  if (presented && !presented.isBeingDismissed &&
      VBControllerTreeContainsShorts(presented)) {
    return YES;
  }

  if ([controller isKindOfClass:[UINavigationController class]]) {
    UIViewController *visible =
        ((UINavigationController *)controller).visibleViewController;
    if (visible && visible != controller &&
        VBControllerTreeContainsShorts(visible)) {
      return YES;
    }
  }

  if ([controller isKindOfClass:[UITabBarController class]]) {
    UIViewController *selected =
        ((UITabBarController *)controller).selectedViewController;
    if (selected && selected != controller &&
        VBControllerTreeContainsShorts(selected)) {
      return YES;
    }
  }

  for (UIViewController *child in controller.childViewControllers) {
    if (!child || child == controller)
      continue;

    UIView *childView = child.viewIfLoaded;
    if (childView && childView.window &&
        VBControllerTreeContainsShorts(child)) {
      return YES;
    }
  }

  return NO;
}

static BOOL VBControllerTreeReportsFullscreen(UIViewController *controller) {
  if (!controller)
    return NO;

  if (VBControllerReportsFullscreen(controller))
    return YES;

  UIViewController *presented = controller.presentedViewController;
  if (presented && !presented.isBeingDismissed &&
      VBControllerTreeReportsFullscreen(presented)) {
    return YES;
  }

  if ([controller isKindOfClass:[UINavigationController class]]) {
    UIViewController *visible =
        ((UINavigationController *)controller).visibleViewController;
    if (visible && visible != controller &&
        VBControllerTreeReportsFullscreen(visible)) {
      return YES;
    }
  }

  if ([controller isKindOfClass:[UITabBarController class]]) {
    UIViewController *selected =
        ((UITabBarController *)controller).selectedViewController;
    if (selected && selected != controller &&
        VBControllerTreeReportsFullscreen(selected)) {
      return YES;
    }
  }

  for (UIViewController *child in controller.childViewControllers) {
    if (!child || child == controller)
      continue;

    UIView *childView = child.viewIfLoaded;
    if (childView && childView.window &&
        VBControllerTreeReportsFullscreen(child)) {
      return YES;
    }
  }

  return NO;
}

static BOOL VBWindowIsShorts(UIWindow *window) {
  if (!window)
    return NO;
  return VBControllerTreeContainsShorts(window.rootViewController);
}

static BOOL VBWindowIsFullscreen(UIWindow *window) {
  if (!window || VBWindowIsShorts(window))
    return NO;

  if (VBControllerTreeReportsFullscreen(window.rootViewController))
    return YES;

  return window.bounds.size.width > window.bounds.size.height;
}

static VBWindowMode VBWindowModeForWindow(UIWindow *window) {
  if (VBWindowIsShorts(window))
    return VBWindowModeShorts;
  if (VBWindowIsFullscreen(window))
    return VBWindowModeFullscreen;
  return VBWindowModeNormal;
}

static BOOL VBControlsOverlayVisibleInViewTree(UIView *view,
                                               UIWindow *window,
                                               BOOL *foundOverlay) {
  if (!view)
    return NO;

  NSString *className = NSStringFromClass(view.class);
  if ([className containsString:@"YTMainAppControlsOverlayView"]) {
    if (foundOverlay)
      *foundOverlay = YES;

    BOOL visible = !view.hidden && view.alpha > 0.02f && view.window == window;
    @try {
      id overlayState = [view valueForKey:@"_isOverlayVisible"];
      if ([overlayState respondsToSelector:@selector(boolValue)]) {
        visible = visible && [overlayState boolValue];
      }
    } @catch (__unused NSException *exception) {
    }
    return visible;
  }

  for (UIView *subview in view.subviews) {
    BOOL childFound = NO;
    BOOL childVisible =
        VBControlsOverlayVisibleInViewTree(subview, window, &childFound);
    if (childFound) {
      if (foundOverlay)
        *foundOverlay = YES;
      if (childVisible)
        return YES;
    }
  }

  return NO;
}

static BOOL VBFullscreenControlsVisible(UIWindow *window) {
  if (!window)
    return YES;

  BOOL foundOverlay = NO;
  BOOL visible =
      VBControlsOverlayVisibleInViewTree(window, window, &foundOverlay);
  return foundOverlay ? visible : YES;
}

static CGFloat VBGestureCenterY(UIWindow *window, VBWindowMode mode) {
  CGFloat height = window.bounds.size.height;
  CGFloat safeTop = window.safeAreaInsets.top;
  CGFloat safeBottom = window.safeAreaInsets.bottom;

  if (mode == VBWindowModeShorts) {
    CGFloat centerY = MAX(safeTop + 150.0f, height * 0.30f);
    return MIN(centerY, height * 0.40f);
  }

  if (mode == VBWindowModeFullscreen) {
    CGFloat centerY = MAX(safeTop + 100.0f, height * 0.36f);
    return MIN(centerY, height - safeBottom - 100.0f);
  }

  return height * 0.50f;
}

static CGFloat VBGestureHitboxHeight(UIWindow *window, VBWindowMode mode) {
  CGFloat height = window.bounds.size.height;

  if (mode == VBWindowModeShorts)
    return MIN(300.0f, MAX(220.0f, height * 0.30f));

  if (mode == VBWindowModeFullscreen)
    return MIN(220.0f, MAX(160.0f, height * 0.48f));

  return MIN(300.0f, MAX(200.0f, height * 0.28f));
}

static CGRect VolumeGestureHitbox(UIWindow *window) {
  if (!window)
    return CGRectZero;

  VBWindowMode mode = VBWindowModeForWindow(window);
  CGFloat width = window.bounds.size.width;
  CGFloat hitboxHeight = VBGestureHitboxHeight(window, mode);
  CGFloat centerY = VBGestureCenterY(window, mode);
  CGFloat x = MAX(0.0f, width - kGestureRightInset - kGestureHitboxWidth);
  CGFloat y = MAX(0.0f, centerY - hitboxHeight * 0.5f);
  CGFloat maxY = window.bounds.size.height - hitboxHeight;
  y = MIN(y, MAX(0.0f, maxY));
  return CGRectMake(x, y, kGestureHitboxWidth, hitboxHeight);
}

static CGRect VolumeGestureIndicatorFrame(UIWindow *window) {
  CGRect hitbox = VolumeGestureHitbox(window);
  CGFloat x = CGRectGetMidX(hitbox) - kGestureIndicatorWidth * 0.5f;
  CGFloat y = CGRectGetMidY(hitbox) - kGestureIndicatorHeight * 0.5f;
  return CGRectMake(x, y, kGestureIndicatorWidth, kGestureIndicatorHeight);
}

static BOOL VBShouldShowGestureIndicator(UIWindow *window) {
  if (!window || !IsVolumeBoostYTEnabled() || !IsGestureIndicatorVisible() ||
      window.windowLevel != UIWindowLevelNormal) {
    return NO;
  }

  if (VBWindowModeForWindow(window) == VBWindowModeFullscreen)
    return VBFullscreenControlsVisible(window);

  return YES;
}

static void VBUpdateGestureIndicator(UIWindow *window) {
  if (!window || window.screen != [UIScreen mainScreen])
    return;

  UIView *indicator = objc_getAssociatedObject(window, &kGestureIndicatorKey);
  BOOL shouldShow = VBShouldShowGestureIndicator(window);

  if (!indicator && shouldShow) {
    indicator = [[UIView alloc] initWithFrame:CGRectZero];
    indicator.userInteractionEnabled = NO;
    indicator.accessibilityElementsHidden = YES;
    if ([UIColor respondsToSelector:@selector(secondaryLabelColor)]) {
      indicator.backgroundColor = [UIColor secondaryLabelColor];
    } else {
      indicator.backgroundColor = [UIColor colorWithWhite:0.72f alpha:1.0f];
    }
    indicator.alpha = 0.72f;
    indicator.layer.cornerRadius = kGestureIndicatorWidth * 0.5f;
    objc_setAssociatedObject(window, &kGestureIndicatorKey, indicator,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [window addSubview:indicator];
  }

  if (!indicator)
    return;

  indicator.hidden = !shouldShow;
  if (shouldShow) {
    indicator.frame = VolumeGestureIndicatorFrame(window);
    [window bringSubviewToFront:indicator];
  }
}

static void VBScheduleGestureIndicatorUpdate(UIWindow *window) {
  if (!window)
    return;

  dispatch_async(dispatch_get_main_queue(), ^{
    VBUpdateGestureIndicator(window);
  });

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(0.12 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   VBUpdateGestureIndicator(window);
                 });

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(0.35 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   VBUpdateGestureIndicator(window);
                 });
}

static void VBRefreshGestureIndicators(void) {
  if (@available(iOS 13.0, *)) {
    UIApplication *application = [UIApplication sharedApplication];
    for (UIScene *scene in application.connectedScenes) {
      if (![scene isKindOfClass:[UIWindowScene class]])
        continue;

      UIWindowScene *windowScene = (UIWindowScene *)scene;
      for (UIWindow *window in windowScene.windows) {
        VBUpdateGestureIndicator(window);
      }
    }
  }
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
    if ([renderer respondsToSelector:@selector(setVolume:)]) {
      [renderer setVolume:1.0f];
    }
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
  if (IsVolumeBoostYTEnabled()) {
    volume *= GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVAudioPlayerNode
- (void)setVolume:(float)volume {
  VBRegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume *= GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVAudioPlayer
- (void)setVolume:(float)volume {
  VBRegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume *= GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVSampleBufferAudioRenderer
- (void)setVolume:(float)volume {
  VBRegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume *= GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

@interface VBVolumePanGestureRecognizer : UIPanGestureRecognizer
@end

@implementation VBVolumePanGestureRecognizer

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)preventedGestureRecognizer {
  (void)preventedGestureRecognizer;
  return YES;
}

- (BOOL)canBePreventedByGestureRecognizer:
    (UIGestureRecognizer *)preventingGestureRecognizer {
  (void)preventingGestureRecognizer;
  return NO;
}

@end

@interface VBVolumeGestureHandler : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, assign) UIWindow *window;
@property(nonatomic, assign) float startMultiplier;
@end

@implementation VBVolumeGestureHandler

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
  (void)gestureRecognizer;
  UIWindow *window = self.window;
  if (!window || !IsVolumeBoostYTEnabled())
    return NO;

  if (window.screen != [UIScreen mainScreen] ||
      window.windowLevel != UIWindowLevelNormal) {
    return NO;
  }

  CGPoint location = [touch locationInView:window];
  return CGRectContainsPoint(VolumeGestureHitbox(window), location);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
  if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]])
    return YES;

  UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
  CGPoint velocity = [pan velocityInView:self.window];
  CGFloat horizontalVelocity = fabs(velocity.x);
  CGFloat verticalVelocity = fabs(velocity.y);

  if (horizontalVelocity < 6.0f && verticalVelocity < 6.0f)
    return NO;

  if (verticalVelocity >= horizontalVelocity * 0.55f)
    return YES;

  return velocity.x < 0.0f;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
  (void)gestureRecognizer;
  (void)otherGestureRecognizer;
  return NO;
}

- (void)handleVolumePan:(UIPanGestureRecognizer *)pan {
  UIWindow *window = self.window;
  if (!window)
    return;

  switch (pan.state) {
  case UIGestureRecognizerStateBegan: {
    self.startMultiplier = GetCustomVolumeMultiplier();
    [pan setTranslation:CGPointZero inView:window];

    YTVolumeHUD *hud = [YTVolumeHUD sharedHUD];
    [NSObject cancelPreviousPerformRequestsWithTarget:hud
                                             selector:@selector(hide)
                                               object:nil];
    [hud showWithValue:self.startMultiplier];
    break;
  }

  case UIGestureRecognizerStateChanged: {
    CGPoint translation = [pan translationInView:window];
    float deltaMultiplier = -translation.y / 30.0f;
    float newMultiplier =
        ClampVolumeMultiplier(self.startMultiplier + deltaMultiplier);

    if (SetCustomVolumeMultiplier(newMultiplier)) {
      [[YTVolumeHUD sharedHUD] showWithValue:newMultiplier];
    }
    break;
  }

  case UIGestureRecognizerStateEnded:
  case UIGestureRecognizerStateCancelled:
  case UIGestureRecognizerStateFailed: {
    PersistCurrentVolumeIfNeeded();
    [[YTVolumeHUD sharedHUD] performSelector:@selector(hide)
                                  withObject:nil
                                  afterDelay:1.0];
    break;
  }

  default:
    break;
  }
}

@end

static void VBEnsureVolumeGestureRecognizer(UIWindow *window) {
  if (!window || window.screen != [UIScreen mainScreen])
    return;

  if (objc_getAssociatedObject(window, &kVolumePanRecognizerKey))
    return;

  VBVolumeGestureHandler *handler = [[VBVolumeGestureHandler alloc] init];
  handler.window = window;

  VBVolumePanGestureRecognizer *pan =
      [[VBVolumePanGestureRecognizer alloc] initWithTarget:handler
                                                   action:@selector(handleVolumePan:)];
  pan.delegate = handler;
  pan.cancelsTouchesInView = YES;
  pan.delaysTouchesBegan = NO;
  pan.delaysTouchesEnded = NO;
  pan.minimumNumberOfTouches = 1;
  pan.maximumNumberOfTouches = 1;

  objc_setAssociatedObject(window, &kVolumePanHandlerKey, handler,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(window, &kVolumePanRecognizerKey, pan,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [window addGestureRecognizer:pan];
}

static BOOL VBEventNeedsIndicatorRefresh(UIEvent *event) {
  NSSet<UITouch *> *touches = [event allTouches];
  if (touches.count == 0)
    return YES;

  for (UITouch *touch in touches) {
    if (touch.phase == UITouchPhaseBegan ||
        touch.phase == UITouchPhaseEnded ||
        touch.phase == UITouchPhaseCancelled) {
      return YES;
    }
  }

  return NO;
}

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
  BOOL mainScreenWindow = self.screen == [UIScreen mainScreen];
  BOOL shouldRefresh = VBEventNeedsIndicatorRefresh(event);

  if (mainScreenWindow) {
    VBEnsureVolumeGestureRecognizer(self);
    if (shouldRefresh)
      VBUpdateGestureIndicator(self);
  }

  %orig(event);

  if (mainScreenWindow && shouldRefresh)
    VBScheduleGestureIndicatorUpdate(self);
}
%end

%group YouTubeSettings

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
  if (self.type != 1)
    return %orig;

  if (supportsTweaksCategoryAPI) {
    return %orig;
  }

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

  if (![tweaks containsObject:@(TweakSection)]) {
    [tweaks addObject:@(TweakSection)];
  }
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

  YTSettingsSectionItem *enableTweak = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Enable VolumeBoostYT"
             titleDescription:@"Allow custom middle-right pan volume gesture"
      accessibilityIdentifier:nil
                     switchOn:IsVolumeBoostYTEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    cachedVolumeBoostEnabled = enabled;
                    [[NSUserDefaults standardUserDefaults]
                        setBool:enabled
                         forKey:kVolumeBoostYTEnabledKey];
                    VBReapplyTrackedRenderers();
                    VBRefreshGestureIndicators();
                    return YES;
                  }
                settingItemId:0];
  [sectionItems addObject:enableTweak];

  YTSettingsSectionItem *rememberVolume = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Remember Volume"
             titleDescription:nil
      accessibilityIdentifier:nil
                     switchOn:IsRememberVolumeEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
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

  YTSettingsSectionItem *showGestureIndicator = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Show Gesture Pill"
             titleDescription:nil
      accessibilityIdentifier:nil
                     switchOn:IsGestureIndicatorVisible()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    cachedShowGestureIndicator = enabled;
                    [[NSUserDefaults standardUserDefaults]
                        setBool:enabled
                         forKey:kShowGestureIndicatorKey];
                    VBRefreshGestureIndicators();
                    return YES;
                  }
                settingItemId:2];
  [sectionItems addObject:showGestureIndicator];

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

  %init;
}
