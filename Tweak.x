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

static const CGFloat kGestureRightInset = 10.0f;
static const CGFloat kGestureHitboxWidth = 40.0f;
static const CGFloat kGestureIndicatorWidth = 4.0f;
static const CGFloat kGestureIndicatorHeight = 56.0f;

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

static BOOL VBControllerTreeWantsIndicatorHidden(UIViewController *controller) {
  if (!controller)
    return NO;

  if (VBControllerIsShorts(controller) ||
      VBControllerReportsFullscreen(controller)) {
    return YES;
  }

  UIViewController *presented = controller.presentedViewController;
  if (presented && !presented.isBeingDismissed &&
      VBControllerTreeWantsIndicatorHidden(presented)) {
    return YES;
  }

  if ([controller isKindOfClass:[UINavigationController class]]) {
    UIViewController *visible =
        ((UINavigationController *)controller).visibleViewController;
    if (visible && visible != controller &&
        VBControllerTreeWantsIndicatorHidden(visible)) {
      return YES;
    }
  }

  if ([controller isKindOfClass:[UITabBarController class]]) {
    UIViewController *selected =
        ((UITabBarController *)controller).selectedViewController;
    if (selected && selected != controller &&
        VBControllerTreeWantsIndicatorHidden(selected)) {
      return YES;
    }
  }

  for (UIViewController *child in controller.childViewControllers) {
    if (!child || child == controller)
      continue;

    UIView *childView = child.viewIfLoaded;
    if (childView && childView.window &&
        VBControllerTreeWantsIndicatorHidden(child)) {
      return YES;
    }
  }

  return NO;
}

static BOOL VBShouldHideGestureIndicator(UIWindow *window) {
  if (!window)
    return NO;

  return VBControllerTreeWantsIndicatorHidden(window.rootViewController);
}

static CGRect VolumeGestureHitbox(UIWindow *window) {
  CGFloat width = window.bounds.size.width;
  CGFloat height = window.bounds.size.height;
  CGFloat hitboxHeight = MIN(240.0f, MAX(120.0f, height * 0.30f));
  CGFloat x = MAX(0.0f, width - kGestureRightInset - kGestureHitboxWidth);
  CGFloat y = MAX(0.0f, (height - hitboxHeight) * 0.5f);
  return CGRectMake(x, y, kGestureHitboxWidth, hitboxHeight);
}

static CGRect VolumeGestureIndicatorFrame(UIWindow *window) {
  CGFloat width = window.bounds.size.width;
  CGFloat height = window.bounds.size.height;
  CGFloat x = MAX(0.0f,
                  width - kGestureRightInset - kGestureIndicatorWidth);
  CGFloat y = MAX(0.0f, (height - kGestureIndicatorHeight) * 0.5f);
  return CGRectMake(x, y, kGestureIndicatorWidth, kGestureIndicatorHeight);
}

static void VBUpdateGestureIndicator(UIWindow *window) {
  if (!window || window.screen != [UIScreen mainScreen])
    return;

  UIView *indicator = objc_getAssociatedObject(window, &kGestureIndicatorKey);
  BOOL shouldShow = IsVolumeBoostYTEnabled() && IsGestureIndicatorVisible() &&
                    window.windowLevel == UIWindowLevelNormal &&
                    !VBShouldHideGestureIndicator(window);

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
  }
}

static void VBScheduleGestureIndicatorUpdate(UIWindow *window) {
  if (!window)
    return;

  dispatch_async(dispatch_get_main_queue(), ^{
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

static float gestureStartMultiplier = 1.0f;
static BOOL possibleVolumeGesture = NO;
static BOOL isTrackingVolumeGesture = NO;
static CGPoint initialTouchPoint;

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
  if (!IsVolumeBoostYTEnabled()) {
    %orig(event);
    VBUpdateGestureIndicator(self);
    return;
  }

  if (self.screen != [UIScreen mainScreen]) {
    %orig(event);
    return;
  }

  VBUpdateGestureIndicator(self);

  NSSet<UITouch *> *touches = [event allTouches];
  if (touches.count == 0) {
    %orig(event);
    VBScheduleGestureIndicatorUpdate(self);
    return;
  }

  UITouch *touch = [touches anyObject];
  CGPoint location = [touch locationInView:self];

  switch (touch.phase) {
  case UITouchPhaseBegan: {
    if (CGRectContainsPoint(VolumeGestureHitbox(self), location)) {
      possibleVolumeGesture = YES;
      isTrackingVolumeGesture = NO;
      initialTouchPoint = location;
      return;
    }
    break;
  }
  case UITouchPhaseMoved: {
    if (possibleVolumeGesture) {
      CGFloat dx = initialTouchPoint.x - location.x;
      CGFloat dy = fabs(location.y - initialTouchPoint.y);

      if (dx > 15.0f && dx > dy) {
        isTrackingVolumeGesture = YES;
        possibleVolumeGesture = NO;
        initialTouchPoint = location;
        gestureStartMultiplier = GetCustomVolumeMultiplier();

        YTVolumeHUD *hud = [YTVolumeHUD sharedHUD];
        [NSObject cancelPreviousPerformRequestsWithTarget:hud
                                                 selector:@selector(hide)
                                                   object:nil];
        [hud showWithValue:gestureStartMultiplier];
        return;
      } else if (dy > 20.0f || dx < -10.0f) {
        possibleVolumeGesture = NO;
      } else {
        return;
      }
    }

    if (isTrackingVolumeGesture) {
      CGFloat translationY = location.y - initialTouchPoint.y;
      float deltaMultiplier = -translationY / 30.0f;
      float newMultiplier =
          ClampVolumeMultiplier(gestureStartMultiplier + deltaMultiplier);

      if (SetCustomVolumeMultiplier(newMultiplier)) {
        [[YTVolumeHUD sharedHUD] showWithValue:newMultiplier];
      }
      return;
    }
    break;
  }
  case UITouchPhaseEnded:
  case UITouchPhaseCancelled: {
    if (possibleVolumeGesture) {
      possibleVolumeGesture = NO;
      return;
    }
    if (isTrackingVolumeGesture) {
      isTrackingVolumeGesture = NO;
      PersistCurrentVolumeIfNeeded();
      [[YTVolumeHUD sharedHUD] performSelector:@selector(hide)
                                    withObject:nil
                                    afterDelay:1.0];
      return;
    }
    break;
  }
  default:
    break;
  }

  %orig(event);
  VBUpdateGestureIndicator(self);
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
