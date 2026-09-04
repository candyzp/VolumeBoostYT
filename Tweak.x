#import "VBYAudio.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <math.h>

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
static NSString *const kVBYLegacyUIKey = @"VBYLegacySwipeUI";
static float currentVolumeMultiplier = 1.0f;
static BOOL currentVolumeMultiplierInitialized = NO;
static NSHashTable *activeRenderers = nil;

BOOL VBYIsVolumeBoostYTEnabled(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kVolumeBoostYTEnabledKey] == nil) return YES;
  return [defaults boolForKey:kVolumeBoostYTEnabledKey];
}

BOOL VBYIsRememberVolumeEnabled(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kRememberVolumeEnabledKey] == nil) return YES;
  return [defaults boolForKey:kRememberVolumeEnabledKey];
}

BOOL VBYIsLegacyUIEnabled(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kVBYLegacyUIKey] == nil) return NO;
  return [defaults boolForKey:kVBYLegacyUIKey];
}

void VBYSetLegacyUIEnabled(BOOL enabled) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:enabled forKey:kVBYLegacyUIKey];
  [defaults synchronize];
  VBYAudioPanelRefresh();
}

static void RegisterRenderer(id renderer) {
  if (!activeRenderers) activeRenderers = [NSHashTable weakObjectsHashTable];
  if (renderer) [activeRenderers addObject:renderer];
}

float VBYGetVolumeMultiplier(void) {
  if (!currentVolumeMultiplierInitialized) {
    currentVolumeMultiplierInitialized = YES;
    if (VBYIsRememberVolumeEnabled()) {
      NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
      if ([defaults objectForKey:kCustomYouTubeVolumeScalarKey] != nil)
        currentVolumeMultiplier =
            [defaults floatForKey:kCustomYouTubeVolumeScalarKey];
    }
    currentVolumeMultiplier =
        MAX(0.0f, MIN(20.0f, currentVolumeMultiplier));
  }
  return currentVolumeMultiplier;
}

static float GetLogarithmicAudioMultiplier(void) {
  float value = VBYGetVolumeMultiplier();
  if (value <= 1.0f) return value;
  return powf(200.0f, (value - 1.0f) / 19.0f);
}

static void NotifyVolumeChange(void) {
  for (id renderer in [activeRenderers allObjects]) {
    if ([renderer respondsToSelector:@selector(setVolume:)])
      [renderer setVolume:1.0f];
  }
}

void VBYSetVolumeMultiplier(float multiplier) {
  multiplier = MAX(0.0f, MIN(20.0f, multiplier));
  currentVolumeMultiplier = multiplier;
  currentVolumeMultiplierInitialized = YES;

  if (VBYIsRememberVolumeEnabled()) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:multiplier forKey:kCustomYouTubeVolumeScalarKey];
    [defaults synchronize];
  }

  NotifyVolumeChange();
}

%hook AVPlayer

- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (VBYIsVolumeBoostYTEnabled())
    volume *= GetLogarithmicAudioMultiplier();
  %orig(volume);
}

%end

%hook AVAudioPlayerNode

- (instancetype)init {
  id result = %orig;
  RegisterRenderer(result);
  return result;
}

- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (VBYIsVolumeBoostYTEnabled())
    volume *= GetLogarithmicAudioMultiplier();
  %orig(volume);
}

%end

%hook AVAudioPlayer

- (instancetype)initWithContentsOfURL:(NSURL *)url
                                error:(NSError **)outError {
  id result = %orig(url, outError);
  RegisterRenderer(result);
  return result;
}

- (instancetype)initWithData:(NSData *)data error:(NSError **)outError {
  id result = %orig(data, outError);
  RegisterRenderer(result);
  return result;
}

- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (VBYIsVolumeBoostYTEnabled())
    volume *= GetLogarithmicAudioMultiplier();
  %orig(volume);
}

%end

%hook AVSampleBufferAudioRenderer

- (instancetype)init {
  id result = %orig;
  RegisterRenderer(result);
  return result;
}

- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (VBYIsVolumeBoostYTEnabled())
    volume *= GetLogarithmicAudioMultiplier();
  %orig(volume);
}

%end

%group YouTubeSettings

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
  if (self.type != 1) return %orig;

  if (class_getClassMethod(objc_getClass("YTSettingsGroupData"),
                           @selector(tweaks)))
    return %orig;

  NSArray<NSNumber *> *categories = %orig;
  if ([categories containsObject:@(TweakSection)]) return categories;

  NSMutableArray<NSNumber *> *mutableCategories = [categories mutableCopy];
  if (mutableCategories)
    [mutableCategories insertObject:@(TweakSection) atIndex:0];
  return mutableCategories.copy ?: categories;
}

+ (NSMutableArray<NSNumber *> *)tweaks {
  NSMutableArray<NSNumber *> *tweaks = %orig;
  if (tweaks && ![tweaks containsObject:@(TweakSection)])
    [tweaks addObject:@(TweakSection)];
  return tweaks;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray<NSNumber *> *)settingsCategoryOrder {
  NSArray<NSNumber *> *order = %orig;
  if ([order containsObject:@(TweakSection)]) return order;

  NSUInteger insertIndex = [order indexOfObject:@(1)];
  if (insertIndex == NSNotFound) return order ?: %orig;

  NSMutableArray<NSNumber *> *mutableOrder = [order mutableCopy];
  [mutableOrder insertObject:@(TweakSection) atIndex:insertIndex + 1];
  return mutableOrder.copy;
}

%end

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)updateVolumeBoostYTSectionWithEntry:(id)entry {
  NSMutableArray<YTSettingsSectionItem *> *sectionItems =
      [NSMutableArray array];
  Class itemClass = %c(YTSettingsSectionItem);
  if (!itemClass) return;

  YTSettingsViewController *settingsViewController =
      [self valueForKey:@"_settingsViewControllerDelegate"];

  YTSettingsSectionItem *enable = [itemClass
          switchItemWithTitle:@"Enable VolumeBoostYT"
             titleDescription:nil
      accessibilityIdentifier:nil
                     switchOn:VBYIsVolumeBoostYTEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    NSUserDefaults *defaults =
                        [NSUserDefaults standardUserDefaults];
                    [defaults setBool:enabled
                               forKey:kVolumeBoostYTEnabledKey];
                    [defaults synchronize];
                    VBYAudioEngineSetMasterEnabled(enabled);
                    NotifyVolumeChange();
                    VBYAudioPanelRefresh();
                    return YES;
                  }
                settingItemId:0];
  [sectionItems addObject:enable];

  YTSettingsSectionItem *rememberVolume = [itemClass
          switchItemWithTitle:@"Remember Volume"
             titleDescription:nil
      accessibilityIdentifier:nil
                     switchOn:VBYIsRememberVolumeEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    NSUserDefaults *defaults =
                        [NSUserDefaults standardUserDefaults];
                    float value = VBYGetVolumeMultiplier();
                    [defaults setBool:enabled
                               forKey:kRememberVolumeEnabledKey];
                    if (enabled)
                      [defaults setFloat:value
                                  forKey:kCustomYouTubeVolumeScalarKey];
                    else
                      [defaults removeObjectForKey:
                                    kCustomYouTubeVolumeScalarKey];
                    [defaults synchronize];
                    return YES;
                  }
                settingItemId:1];
  [sectionItems addObject:rememberVolume];

  YTSettingsSectionItem *rememberPitch = [itemClass
          switchItemWithTitle:@"Remember Pitch"
             titleDescription:nil
      accessibilityIdentifier:nil
                     switchOn:VBYIsRememberPitchEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    VBYSetRememberPitchEnabled(enabled);
                    return YES;
                  }
                settingItemId:2];
  [sectionItems addObject:rememberPitch];

  YTSettingsSectionItem *rememberEQ = [itemClass
          switchItemWithTitle:@"Remember EQ"
             titleDescription:nil
      accessibilityIdentifier:nil
                     switchOn:VBYIsRememberEQEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    VBYSetRememberEQEnabled(enabled);
                    return YES;
                  }
                settingItemId:3];
  [sectionItems addObject:rememberEQ];

  YTSettingsSectionItem *legacyUI = [itemClass
          switchItemWithTitle:@"Use Legacy Swipe UI"
             titleDescription:nil
      accessibilityIdentifier:nil
                     switchOn:VBYIsLegacyUIEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    VBYSetLegacyUIEnabled(enabled);
                    return YES;
                  }
                settingItemId:4];
  [sectionItems addObject:legacyUI];

  if ([settingsViewController
          respondsToSelector:@selector(
              setSectionItems:forCategory:title:icon:titleDescription:
                  headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:TweakSection
                                      title:@"VolumeBoostYT"
                                       icon:nil
                           titleDescription:nil
                               headerHidden:NO];
  } else if ([settingsViewController
                 respondsToSelector:@selector(
                     setSectionItems:forCategory:title:titleDescription:
                         headerHidden:)]) {
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
  if ([bundleID isEqualToString:@"com.apple.springboard"]) return;

  VBYAudioEngineInitialize();
  VBYAudioEngineSetMasterEnabled(VBYIsVolumeBoostYTEnabled());

  if (NSClassFromString(@"YTSettingsGroupData")) %init(YouTubeSettings);

  %init;
  VBYAudioPanelRefresh();
}
