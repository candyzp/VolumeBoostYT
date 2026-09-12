#import "YTVolumeHUD.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
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
static NSString *const kCustomYouTubeVolumeScalarKey =
    @"CustomYouTubeVolumeScalar";

static BOOL cachedVolumeBoostEnabled = YES;
static BOOL cachedRememberVolumeEnabled = YES;
static float currentVolumeMultiplier = 1.0f;
static float cachedAudioMultiplier = 1.0f;
static BOOL preferencesLoaded = NO;

static NSHashTable *activeRenderers = nil;
static dispatch_once_t activeRenderersOnce;
static char kRendererRegisteredKey;

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

  if (cachedRememberVolumeEnabled &&
      [defaults objectForKey:kCustomYouTubeVolumeScalarKey] != nil) {
    currentVolumeMultiplier = ClampVolumeMultiplier(
        [defaults floatForKey:kCustomYouTubeVolumeScalarKey]);
  }

  cachedAudioMultiplier = CalculateAudioMultiplier(currentVolumeMultiplier);
}

static inline BOOL IsVolumeBoostYTEnabled(void) {
  return cachedVolumeBoostEnabled;
}

static inline BOOL IsRememberVolumeEnabled(void) {
  return cachedRememberVolumeEnabled;
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

static void SetCustomVolumeMultiplier(float multiplier) {
  multiplier = ClampVolumeMultiplier(multiplier);

  if (fabsf(multiplier - currentVolumeMultiplier) < 0.0001f)
    return;

  currentVolumeMultiplier = multiplier;
  cachedAudioMultiplier = CalculateAudioMultiplier(multiplier);
  VBReapplyTrackedRenderers();
}

%hook AVPlayer
- (instancetype)init {
  id orig = %orig;
  VBRegisterRenderer(orig);
  return orig;
}
- (void)setVolume:(float)volume {
  VBRegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume *= GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVAudioPlayerNode
- (instancetype)init {
  id orig = %orig;
  VBRegisterRenderer(orig);
  return orig;
}
- (void)setVolume:(float)volume {
  VBRegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume *= GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVAudioPlayer
- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)outError {
  id orig = %orig;
  VBRegisterRenderer(orig);
  return orig;
}
- (instancetype)initWithData:(NSData *)data error:(NSError **)outError {
  id orig = %orig;
  VBRegisterRenderer(orig);
  return orig;
}
- (void)setVolume:(float)volume {
  VBRegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume *= GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVSampleBufferAudioRenderer
- (instancetype)init {
  id orig = %orig;
  VBRegisterRenderer(orig);
  return orig;
}
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
    return;
  }

  if (self.screen != [UIScreen mainScreen]) {
    %orig(event);
    return;
  }

  NSSet<UITouch *> *touches = [event allTouches];
  if (touches.count == 0) {
    %orig(event);
    return;
  }

  UITouch *touch = [touches anyObject];
  CGPoint location = [touch locationInView:self];

  switch (touch.phase) {
  case UITouchPhaseBegan: {
    CGFloat screenWidth = self.bounds.size.width;
    if (location.x >= screenWidth - 25.0f) {
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
        [[YTVolumeHUD sharedHUD] showWithValue:gestureStartMultiplier];
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

      SetCustomVolumeMultiplier(newMultiplier);
      [[YTVolumeHUD sharedHUD] showWithValue:newMultiplier];
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
}
%end

%group YouTubeSettings

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
  if (self.type != 1)
    return %orig;

  if (class_getClassMethod(objc_getClass("YTSettingsGroupData"),
                           @selector(tweaks))) {
    return %orig;
  }

  NSArray<NSNumber *> *categories = %orig;
  NSMutableArray<NSNumber *> *mutableCategories = [categories mutableCopy];
  if (mutableCategories) {
    [mutableCategories insertObject:@(TweakSection) atIndex:0];
  }
  return mutableCategories.copy ?: categories;
}

+ (NSMutableArray<NSNumber *> *)tweaks {
  NSMutableArray<NSNumber *> *tweaks = %orig;
  if (tweaks && ![tweaks containsObject:@(TweakSection)]) {
    [tweaks addObject:@(TweakSection)];
  }
  return tweaks;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray<NSNumber *> *)settingsCategoryOrder {
  NSArray<NSNumber *> *order = %orig;
  NSUInteger insertIndex = [order indexOfObject:@(1)];

  if (insertIndex != NSNotFound) {
    NSMutableArray<NSNumber *> *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(TweakSection) atIndex:insertIndex + 1];
    return mutableOrder.copy;
  }

  return order ?: %orig;
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

  YTSettingsViewController *settingsViewController =
      [self valueForKey:@"_settingsViewControllerDelegate"];

  YTSettingsSectionItem *enableTweak = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Enable VolumeBoostYT"
             titleDescription:@"Allow custom right-edge pan volume gesture"
      accessibilityIdentifier:nil
                     switchOn:IsVolumeBoostYTEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    cachedVolumeBoostEnabled = enabled;
                    [[NSUserDefaults standardUserDefaults]
                        setBool:enabled
                         forKey:kVolumeBoostYTEnabledKey];
                    VBReapplyTrackedRenderers();
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
  if ([bundleID isEqualToString:@"com.apple.springboard"]) {
    return;
  }

  LoadPreferencesIfNeeded();

  if (NSClassFromString(@"YTSettingsGroupData")) {
    %init(YouTubeSettings);
  }

  %init;
}
