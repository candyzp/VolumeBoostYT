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

@interface YTQTMButton : UIButton
+ (instancetype)iconButton;
@property(nonatomic, assign) CGFloat minHitTargetSize;
@end

@interface YTPlayerViewController : UIViewController
- (void)play;
- (void)pause;
@end

@interface YTMainAppControlsOverlayView : UIView
@property(nonatomic, strong) YTPlayerViewController *playerViewController;
+ (CGFloat)topButtonAdditionalPadding;
- (YTQTMButton *)buttonWithImage:(UIImage *)image
              accessibilityLabel:(NSString *)accessibilityLabel
          verticalContentPadding:(CGFloat)verticalContentPadding;
- (NSMutableArray *)topButtonControls;
- (NSMutableArray *)topControls;
- (void)setTopOverlayVisible:(BOOL)visible
      isAutonavCanceledState:(BOOL)canceledState;
@end

@interface YTReelWatchPlaybackOverlayView : UIView
- (NSArray<YTQTMButton *> *)orderedRightSideButtons;
@end

@interface VBYAudioButtonTarget : NSObject
+ (instancetype)sharedTarget;
- (void)openAudioControls:(id)sender;
@end

static const NSInteger TweakSection = 'ndyt';
static NSString *const kVolumeBoostYTEnabledKey = @"VolumeBoostYTEnabled";
static NSString *const kRememberVolumeEnabledKey = @"RememberVolumeEnabled";
static NSString *const kCustomYouTubeVolumeScalarKey =
    @"CustomYouTubeVolumeScalar";
static NSString *const kVBYLegacyUIKey = @"VBYLegacySwipeUI";
static NSString *const kVBYPlayerButtonEnabledKey =
    @"VBYPlayerAudioButtonEnabled";
static NSString *const kVBYShortsButtonEnabledKey =
    @"VBYShortsAudioButtonEnabled";

static float currentVolumeMultiplier = 1.0f;
static BOOL currentVolumeMultiplierInitialized = NO;
static NSHashTable *activeRenderers = nil;
static NSHashTable *playerControlViews = nil;
static NSHashTable *shortsControlViews = nil;
static char VBYPlayerButtonAssociation;
static char VBYShortsButtonAssociation;
static char VBYPlayerPausedAssociation;

static void VBYRefreshNativeButtons(void);

@implementation VBYAudioButtonTarget

+ (instancetype)sharedTarget {
  static VBYAudioButtonTarget *target = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    target = [[self alloc] init];
  });
  return target;
}

- (void)openAudioControls:(id)sender {
  VBYAudioPanelPresent();
}

@end

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
  VBYRefreshNativeButtons();
}

BOOL VBYIsPlayerButtonEnabled(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kVBYPlayerButtonEnabledKey] == nil) return YES;
  return [defaults boolForKey:kVBYPlayerButtonEnabledKey];
}

void VBYSetPlayerButtonEnabled(BOOL enabled) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:enabled forKey:kVBYPlayerButtonEnabledKey];
  [defaults synchronize];
  VBYRefreshNativeButtons();
}

BOOL VBYIsShortsButtonEnabled(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kVBYShortsButtonEnabledKey] == nil) return YES;
  return [defaults boolForKey:kVBYShortsButtonEnabledKey];
}

void VBYSetShortsButtonEnabled(BOOL enabled) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:enabled forKey:kVBYShortsButtonEnabledKey];
  [defaults synchronize];
  VBYRefreshNativeButtons();
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

static UIImage *VBYAudioButtonImage(void) {
  UIImageSymbolConfiguration *configuration =
      [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                      weight:UIImageSymbolWeightSemibold];
  UIImage *image = [UIImage systemImageNamed:@"slider.horizontal.3"];
  return [image imageWithConfiguration:configuration] ?: image;
}

static void VBYTrackPlayerControls(YTMainAppControlsOverlayView *view) {
  if (!playerControlViews) playerControlViews = [NSHashTable weakObjectsHashTable];
  if (view) [playerControlViews addObject:view];
}

static void VBYTrackShortsControls(YTReelWatchPlaybackOverlayView *view) {
  if (!shortsControlViews) shortsControlViews = [NSHashTable weakObjectsHashTable];
  if (view) [shortsControlViews addObject:view];
}

static BOOL VBYPlayerIsPaused(YTPlayerViewController *player) {
  if (!player) return NO;
  NSNumber *paused =
      objc_getAssociatedObject(player, &VBYPlayerPausedAssociation);
  return paused.boolValue;
}

static void VBYSetPlayerPaused(YTPlayerViewController *player, BOOL paused) {
  if (!player) return;
  objc_setAssociatedObject(player, &VBYPlayerPausedAssociation, @(paused),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  dispatch_async(dispatch_get_main_queue(), ^{
    for (YTMainAppControlsOverlayView *view in [playerControlViews allObjects]) {
      if (view.playerViewController != player) continue;
      [view setNeedsLayout];
      [view layoutIfNeeded];
    }
  });
}

static BOOL VBYShouldShowPlayerButton(YTMainAppControlsOverlayView *view) {
  return VBYIsVolumeBoostYTEnabled() && VBYIsPlayerButtonEnabled() &&
         VBYPlayerIsPaused(view.playerViewController);
}

static YTQTMButton *VBYPlayerButton(YTMainAppControlsOverlayView *view) {
  YTQTMButton *button =
      objc_getAssociatedObject(view, &VBYPlayerButtonAssociation);
  if (button) return button;

  UIImage *image = VBYAudioButtonImage();
  CGFloat padding = 0.0;
  if ([[view class] respondsToSelector:@selector(topButtonAdditionalPadding)])
    padding = [[view class] topButtonAdditionalPadding];

  if ([view respondsToSelector:
                @selector(buttonWithImage:accessibilityLabel:
                             verticalContentPadding:)]) {
    button = [view buttonWithImage:image
                accessibilityLabel:@"Audio controls"
            verticalContentPadding:padding];
  }

  if (!button) {
    Class buttonClass = NSClassFromString(@"YTQTMButton");
    if ([buttonClass respondsToSelector:@selector(iconButton)])
      button = [buttonClass iconButton];
    else
      button = (YTQTMButton *)[UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:image forState:UIControlStateNormal];
  }

  button.tintColor = [UIColor whiteColor];
  button.accessibilityLabel = @"Audio controls";
  button.accessibilityIdentifier = @"VBY.Player.AudioControls";
  button.hidden = YES;
  button.alpha = 0.0;
  [button addTarget:[VBYAudioButtonTarget sharedTarget]
                action:@selector(openAudioControls:)
      forControlEvents:UIControlEventTouchUpInside];

  @try {
    UIView *container =
        [view valueForKey:@"_topControlsAccessibilityContainerView"];
    if (container)
      [container addSubview:button];
    else
      [view addSubview:button];
  } @catch (NSException *exception) {
    [view addSubview:button];
  }

  objc_setAssociatedObject(view, &VBYPlayerButtonAssociation, button,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return button;
}

static NSMutableArray *VBYPlayerControlsWithButton(
    YTMainAppControlsOverlayView *view, NSArray *original) {
  VBYTrackPlayerControls(view);

  YTQTMButton *button =
      objc_getAssociatedObject(view, &VBYPlayerButtonAssociation);
  BOOL show = VBYShouldShowPlayerButton(view);

  if (!show) {
    if (button) {
      button.hidden = YES;
      button.alpha = 0.0;
    }
    return [original mutableCopy] ?: [NSMutableArray array];
  }

  button = VBYPlayerButton(view);
  button.hidden = NO;

  NSMutableArray *controls =
      [original mutableCopy] ?: [NSMutableArray array];
  if (![controls containsObject:button]) {
    NSUInteger index = controls.count > 0 ? controls.count - 1 : 0;
    [controls insertObject:button atIndex:index];
  }
  return controls;
}

static YTQTMButton *VBYShortsButton(YTReelWatchPlaybackOverlayView *view) {
  YTQTMButton *button =
      objc_getAssociatedObject(view, &VBYShortsButtonAssociation);
  if (button) return button;

  Class buttonClass = NSClassFromString(@"YTQTMButton");
  if ([buttonClass respondsToSelector:@selector(iconButton)])
    button = [buttonClass iconButton];
  else
    button = (YTQTMButton *)[UIButton buttonWithType:UIButtonTypeSystem];

  [button setImage:VBYAudioButtonImage() forState:UIControlStateNormal];
  button.tintColor = [UIColor whiteColor];
  button.accessibilityLabel = @"Audio controls";
  button.accessibilityIdentifier = @"VBY.Shorts.AudioControls";
  if ([button respondsToSelector:@selector(setMinHitTargetSize:)])
    button.minHitTargetSize = 44.0;
  [button addTarget:[VBYAudioButtonTarget sharedTarget]
                action:@selector(openAudioControls:)
      forControlEvents:UIControlEventTouchUpInside];
  [view addSubview:button];

  objc_setAssociatedObject(view, &VBYShortsButtonAssociation, button,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return button;
}

static NSUInteger VBYShortsInsertionIndex(NSArray<YTQTMButton *> *buttons) {
  NSArray<NSString *> *preferred = @[
    @"id.reel_share_button",
    @"id.reel_remix_button",
    @"id.reel_pivot_button"
  ];

  for (NSString *identifier in preferred) {
    for (NSUInteger i = 0; i < buttons.count; i++) {
      NSString *candidate =
          buttons[i].accessibilityIdentifier.lowercaseString ?: @"";
      if ([candidate isEqualToString:identifier]) return i;
    }
  }

  return buttons.count;
}

static void VBYRefreshNativeButtons(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    for (YTMainAppControlsOverlayView *view in [playerControlViews allObjects]) {
      YTQTMButton *button =
          objc_getAssociatedObject(view, &VBYPlayerButtonAssociation);
      BOOL show = VBYShouldShowPlayerButton(view);
      if (button) {
        button.hidden = !show;
        if (!show) button.alpha = 0.0;
      }
      [view setNeedsLayout];
    }

    BOOL showShorts =
        VBYIsVolumeBoostYTEnabled() && VBYIsShortsButtonEnabled();
    for (YTReelWatchPlaybackOverlayView *view in
         [shortsControlViews allObjects]) {
      YTQTMButton *button =
          objc_getAssociatedObject(view, &VBYShortsButtonAssociation);
      if (button) button.hidden = !showShorts;
      [view setNeedsLayout];
    }
  });
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

%group NativePlayerControls

%hook YTPlayerViewController

- (void)play {
  %orig;
  VBYSetPlayerPaused(self, NO);
  VBYAudioPanelSetPlaying(YES);
}

- (void)pause {
  %orig;
  VBYSetPlayerPaused(self, YES);
  VBYAudioPanelSetPlaying(NO);
}

%end

%hook YTMainAppControlsOverlayView

- (NSMutableArray *)topButtonControls {
  NSArray *original = %orig;
  return VBYPlayerControlsWithButton(self, original);
}

- (NSMutableArray *)topControls {
  NSArray *original = %orig;
  return VBYPlayerControlsWithButton(self, original);
}

- (void)setTopOverlayVisible:(BOOL)visible
      isAutonavCanceledState:(BOOL)canceledState {
  %orig(visible, canceledState);
  VBYTrackPlayerControls(self);

  YTQTMButton *button =
      objc_getAssociatedObject(self, &VBYPlayerButtonAssociation);
  BOOL show = VBYShouldShowPlayerButton(self);

  if (show && !button) button = VBYPlayerButton(self);
  if (!button) return;

  button.hidden = !show;
  button.alpha = show && visible && !canceledState ? 1.0 : 0.0;
}

- (void)layoutSubviews {
  %orig;
  VBYTrackPlayerControls(self);

  YTQTMButton *button =
      objc_getAssociatedObject(self, &VBYPlayerButtonAssociation);
  if (!button) return;

  BOOL show = VBYShouldShowPlayerButton(self);
  button.hidden = !show;
  if (!show) button.alpha = 0.0;
}

%end

%end

%group ShortsControls

%hook YTReelWatchPlaybackOverlayView

- (NSArray<YTQTMButton *> *)orderedRightSideButtons {
  NSArray<YTQTMButton *> *original = %orig;
  VBYTrackShortsControls(self);

  YTQTMButton *button =
      objc_getAssociatedObject(self, &VBYShortsButtonAssociation);
  BOOL show = VBYIsVolumeBoostYTEnabled() && VBYIsShortsButtonEnabled();

  if (!show) {
    if (button) button.hidden = YES;
    return original;
  }

  button = VBYShortsButton(self);
  button.hidden = NO;
  button.alpha = 1.0;

  NSMutableArray<YTQTMButton *> *buttons =
      [original mutableCopy] ?: [NSMutableArray array];
  if (![buttons containsObject:button]) {
    NSUInteger index = VBYShortsInsertionIndex(buttons);
    [buttons insertObject:button atIndex:index];
  }

  return buttons.copy;
}

- (void)layoutSubviews {
  %orig;
  VBYTrackShortsControls(self);

  YTQTMButton *button =
      objc_getAssociatedObject(self, &VBYShortsButtonAssociation);
  if (button)
    button.hidden =
        !(VBYIsVolumeBoostYTEnabled() && VBYIsShortsButtonEnabled());
}

%end

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
                    VBYRefreshNativeButtons();
                    return YES;
                  }
                settingItemId:0];
  [sectionItems addObject:enable];

  YTSettingsSectionItem *playerButton = [itemClass
          switchItemWithTitle:@"Show Player Audio Button"
             titleDescription:nil
      accessibilityIdentifier:nil
                     switchOn:VBYIsPlayerButtonEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    VBYSetPlayerButtonEnabled(enabled);
                    return YES;
                  }
                settingItemId:1];
  [sectionItems addObject:playerButton];

  YTSettingsSectionItem *shortsButton = [itemClass
          switchItemWithTitle:@"Show Shorts Audio Button"
             titleDescription:nil
      accessibilityIdentifier:nil
                     switchOn:VBYIsShortsButtonEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    VBYSetShortsButtonEnabled(enabled);
                    return YES;
                  }
                settingItemId:2];
  [sectionItems addObject:shortsButton];

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
                settingItemId:3];
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
                settingItemId:4];
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
                settingItemId:5];
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
                settingItemId:6];
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
  if (!NSClassFromString(@"YTSettingsGroupData")) return;

  VBYAudioEngineInitialize();
  VBYAudioEngineSetMasterEnabled(VBYIsVolumeBoostYTEnabled());

  %init(YouTubeSettings);
  if (NSClassFromString(@"YTPlayerViewController") &&
      NSClassFromString(@"YTMainAppControlsOverlayView"))
    %init(NativePlayerControls);
  if (NSClassFromString(@"YTReelWatchPlaybackOverlayView"))
    %init(ShortsControls);

  %init;
  VBYAudioPanelRefresh();
  VBYRefreshNativeButtons();
}
