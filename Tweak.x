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

@interface YTMainAppControlsOverlayView : UIView
@end

@interface YTReelWatchPlaybackOverlayView : UIView
@end

@interface VBYAudioButtonTarget : NSObject
+ (instancetype)sharedTarget;
- (void)openAudioControls:(id)sender;
@end

static const NSInteger TweakSection = 'ndyt';
static NSString *const kVolumeBoostYTEnabledKey = @"VolumeBoostYTEnabled";
static NSString *const kRememberVolumeEnabledKey = @"RememberVolumeEnabled";
static NSString *const kCustomYouTubeVolumeScalarKey = @"CustomYouTubeVolumeScalar";
static NSString *const kVBYLegacyUIKey = @"VBYLegacySwipeUI";
static NSString *const kVBYPlayerButtonEnabledKey = @"VBYPlayerAudioButtonEnabled";
static NSString *const kVBYShortsButtonEnabledKey = @"VBYShortsAudioButtonEnabled";

static float currentVolumeMultiplier = 1.0f;
static BOOL currentVolumeMultiplierInitialized = NO;
static NSHashTable *activeRenderers = nil;
static NSHashTable *playerControlViews = nil;
static NSHashTable *shortsControlViews = nil;
static char VBYPlayerButtonAssociation;
static char VBYShortsButtonAssociation;

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
        currentVolumeMultiplier = [defaults floatForKey:kCustomYouTubeVolumeScalarKey];
    }
    currentVolumeMultiplier = MAX(0.0f, MIN(20.0f, currentVolumeMultiplier));
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

static UIButton *VBYCreateAudioButton(NSString *identifier) {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  [button setImage:VBYAudioButtonImage() forState:UIControlStateNormal];
  button.tintColor = [UIColor whiteColor];
  button.accessibilityLabel = @"Audio controls";
  button.accessibilityIdentifier = identifier;
  button.clipsToBounds = YES;
  button.hidden = YES;
  [button addTarget:[VBYAudioButtonTarget sharedTarget]
                action:@selector(openAudioControls:)
      forControlEvents:UIControlEventTouchUpInside];
  return button;
}

static BOOL VBYViewVisible(UIView *view) {
  return view && !view.hidden && view.alpha > 0.05 &&
         CGRectGetWidth(view.bounds) > 0.5 && CGRectGetHeight(view.bounds) > 0.5;
}

static CGRect VBYFrameInRoot(UIView *view, UIView *root) {
  if (!view || !root) return CGRectNull;
  return [view convertRect:view.bounds toView:root];
}

static BOOL VBYLooksLikePausedPlayControl(UIView *view, UIView *root) {
  if (![view isKindOfClass:[UIControl class]] || !VBYViewVisible(view)) return NO;

  NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
  NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";

  BOOL saysPlay =
      [label isEqualToString:@"play"] ||
      [label hasPrefix:@"play "] ||
      [label containsString:@"play video"] ||
      [identifier containsString:@"play_button"] ||
      [identifier containsString:@"playbutton"];

  if (!saysPlay || [label containsString:@"pause"]) return NO;

  CGRect frame = VBYFrameInRoot(view, root);
  if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) return NO;

  CGFloat width = CGRectGetWidth(root.bounds);
  CGFloat height = CGRectGetHeight(root.bounds);
  CGFloat midX = CGRectGetMidX(frame);
  CGFloat midY = CGRectGetMidY(frame);

  return CGRectGetWidth(frame) >= 38.0 && CGRectGetHeight(frame) >= 38.0 &&
         fabs(midX - width * 0.5) <= width * 0.20 &&
         midY >= height * 0.18 && midY <= height * 0.82;
}

static BOOL VBYPlayerOverlayIsPausedRecursive(UIView *view, UIView *root) {
  if (VBYLooksLikePausedPlayControl(view, root)) return YES;
  for (UIView *subview in view.subviews) {
    if (VBYPlayerOverlayIsPausedRecursive(subview, root)) return YES;
  }
  return NO;
}

static void VBYCollectPlayerTopControls(UIView *view, UIView *root,
                                        UIButton *audio,
                                        NSMutableArray<UIView *> *controls) {
  if (view != root && view != audio &&
      [view isKindOfClass:[UIControl class]] && VBYViewVisible(view)) {
    CGRect frame = VBYFrameInRoot(view, root);
    CGFloat width = CGRectGetWidth(root.bounds);
    CGFloat height = CGRectGetHeight(root.bounds);

    if (!CGRectIsNull(frame) && !CGRectIsEmpty(frame) &&
        CGRectGetWidth(frame) >= 24.0 && CGRectGetWidth(frame) <= 96.0 &&
        CGRectGetHeight(frame) >= 24.0 && CGRectGetHeight(frame) <= 72.0 &&
        CGRectGetMidX(frame) >= width * 0.35 &&
        CGRectGetMidY(frame) <= height * 0.30) {
      [controls addObject:view];
    }
  }

  for (UIView *subview in view.subviews)
    VBYCollectPlayerTopControls(subview, root, audio, controls);
}

static BOOL VBYRectCollides(CGRect frame, NSArray<UIView *> *views,
                            UIView *root) {
  CGRect padded = CGRectInset(frame, -4.0, -4.0);
  for (UIView *view in views) {
    CGRect candidate = VBYFrameInRoot(view, root);
    if (!CGRectIsNull(candidate) && !CGRectIsEmpty(candidate) &&
        CGRectIntersectsRect(padded, candidate))
      return YES;
  }
  return NO;
}

static UIButton *VBYPlayerButton(YTMainAppControlsOverlayView *view) {
  UIButton *button = objc_getAssociatedObject(view, &VBYPlayerButtonAssociation);
  if (button) return button;

  button = VBYCreateAudioButton(@"VBY.Player.AudioControls");
  button.backgroundColor = [UIColor clearColor];
  button.layer.cornerRadius = 22.0;
  [view addSubview:button];

  objc_setAssociatedObject(view, &VBYPlayerButtonAssociation, button,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return button;
}

static void VBYLayoutPlayerAudioButton(YTMainAppControlsOverlayView *view) {
  if (!playerControlViews) playerControlViews = [NSHashTable weakObjectsHashTable];
  [playerControlViews addObject:view];

  UIButton *button = objc_getAssociatedObject(view, &VBYPlayerButtonAssociation);

  BOOL enabled = VBYIsVolumeBoostYTEnabled() && VBYIsPlayerButtonEnabled();
  BOOL paused = enabled && VBYPlayerOverlayIsPausedRecursive(view, view);

  if (!paused) {
    if (button) button.hidden = YES;
    VBYAudioPanelSetPlaying(YES);
    return;
  }

  VBYAudioPanelSetPlaying(NO);
  button = VBYPlayerButton(view);

  NSMutableArray<UIView *> *controls = [NSMutableArray array];
  VBYCollectPlayerTopControls(view, view, button, controls);

  CGFloat rootWidth = CGRectGetWidth(view.bounds);
  CGFloat rootHeight = CGRectGetHeight(view.bounds);
  CGFloat size = 44.0;
  CGFloat x = rootWidth - size - 8.0;
  CGFloat centerY = MAX(26.0, rootHeight * 0.10);

  if (controls.count > 0) {
    UIView *leftmost = nil;
    CGFloat minControlX = CGFLOAT_MAX;
    for (UIView *control in controls) {
      CGRect frame = VBYFrameInRoot(control, view);
      if (CGRectGetMinX(frame) < minControlX) {
        minControlX = CGRectGetMinX(frame);
        leftmost = control;
      }
    }

    if (leftmost) {
      CGRect frame = VBYFrameInRoot(leftmost, view);
      x = CGRectGetMinX(frame) - size - 8.0;
      centerY = CGRectGetMidY(frame);
    }
  }

  CGFloat minX = view.safeAreaInsets.left + 6.0;
  x = MAX(minX, x);
  CGRect target = CGRectMake(round(x), round(centerY - size * 0.5), size, size);

  while (VBYRectCollides(target, controls, view) &&
         CGRectGetMinX(target) - size - 8.0 >= minX) {
    target.origin.x -= size + 8.0;
  }

  if (VBYRectCollides(target, controls, view)) {
    button.hidden = YES;
    return;
  }

  button.frame = target;
  button.hidden = NO;
  button.alpha = 1.0;
  [view bringSubviewToFront:button];
}

static BOOL VBYKnownShortsAction(UIView *view) {
  NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
  NSString *label = view.accessibilityLabel.lowercaseString ?: @"";

  if ([identifier hasPrefix:@"vby."]) return NO;

  if ([identifier isEqualToString:@"id.reel_like_button"] ||
      [identifier isEqualToString:@"id.reel_comment_button"] ||
      [identifier isEqualToString:@"id.reel_share_button"] ||
      [identifier isEqualToString:@"id.reel_remix_button"] ||
      [identifier isEqualToString:@"id.reel_pivot_button"] ||
      [identifier containsString:@"reel_save"] ||
      [identifier containsString:@"reel_dislike"])
    return YES;

  return [label isEqualToString:@"like"] ||
         [label hasPrefix:@"comments"] ||
         [label isEqualToString:@"comment"] ||
         [label isEqualToString:@"save"] ||
         [label isEqualToString:@"share"] ||
         [label isEqualToString:@"remix"];
}

static void VBYCollectShortsActions(UIView *view, UIView *root,
                                    BOOL generic,
                                    NSMutableArray<UIView *> *actions) {
  if (view != root && [view isKindOfClass:[UIControl class]] &&
      VBYViewVisible(view)) {
    CGRect frame = VBYFrameInRoot(view, root);
    CGFloat width = CGRectGetWidth(root.bounds);
    CGFloat height = CGRectGetHeight(root.bounds);

    BOOL geometry =
        !CGRectIsNull(frame) && !CGRectIsEmpty(frame) &&
        CGRectGetWidth(frame) >= 24.0 && CGRectGetWidth(frame) <= 88.0 &&
        CGRectGetHeight(frame) >= 24.0 && CGRectGetHeight(frame) <= 88.0 &&
        CGRectGetMidX(frame) >= width * 0.70 &&
        CGRectGetMidY(frame) >= height * 0.18 &&
        CGRectGetMidY(frame) <= height * 0.94;

    if (geometry && (VBYKnownShortsAction(view) || generic))
      [actions addObject:view];
  }

  for (UIView *subview in view.subviews)
    VBYCollectShortsActions(subview, root, generic, actions);
}

static UIButton *VBYShortsButton(YTReelWatchPlaybackOverlayView *view) {
  UIButton *button = objc_getAssociatedObject(view, &VBYShortsButtonAssociation);
  if (button) return button;

  button = VBYCreateAudioButton(@"VBY.Shorts.AudioControls");
  button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.28];
  button.layer.cornerRadius = 22.0;
  button.layer.borderWidth = 0.5;
  button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
  [view addSubview:button];

  objc_setAssociatedObject(view, &VBYShortsButtonAssociation, button,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return button;
}

static NSComparisonResult VBYCompareViewsByY(id first, id second,
                                             void *context) {
  UIView *root = (__bridge UIView *)context;
  CGRect a = VBYFrameInRoot((UIView *)first, root);
  CGRect b = VBYFrameInRoot((UIView *)second, root);
  CGFloat ay = CGRectGetMinY(a);
  CGFloat by = CGRectGetMinY(b);
  if (ay < by) return NSOrderedAscending;
  if (ay > by) return NSOrderedDescending;
  return NSOrderedSame;
}

static void VBYLayoutShortsAudioButton(YTReelWatchPlaybackOverlayView *view) {
  if (!shortsControlViews) shortsControlViews = [NSHashTable weakObjectsHashTable];
  [shortsControlViews addObject:view];

  UIButton *button = objc_getAssociatedObject(view, &VBYShortsButtonAssociation);

  BOOL enabled = VBYIsVolumeBoostYTEnabled() && VBYIsShortsButtonEnabled();
  if (!enabled) {
    if (button) button.hidden = YES;
    return;
  }

  NSMutableArray<UIView *> *actions = [NSMutableArray array];
  VBYCollectShortsActions(view, view, NO, actions);
  if (actions.count == 0)
    VBYCollectShortsActions(view, view, YES, actions);

  if (actions.count == 0) {
    if (button) button.hidden = YES;
    return;
  }

  [actions sortUsingFunction:VBYCompareViewsByY context:(__bridge void *)view];

  button = VBYShortsButton(view);

  CGFloat size = 44.0;
  CGFloat gap = 10.0;
  CGFloat safeTop = view.safeAreaInsets.top + 8.0;
  CGFloat safeBottom = CGRectGetHeight(view.bounds) - view.safeAreaInsets.bottom - 8.0;

  CGRect first = VBYFrameInRoot(actions.firstObject, view);
  CGFloat centerX = CGRectGetMidX(first);
  CGRect target = CGRectMake(round(centerX - size * 0.5),
                             round(CGRectGetMinY(first) - gap - size),
                             size, size);

  BOOL found = CGRectGetMinY(target) >= safeTop &&
               !VBYRectCollides(target, actions, view);

  if (!found && actions.count > 1) {
    for (NSUInteger i = 0; i + 1 < actions.count; i++) {
      CGRect upper = VBYFrameInRoot(actions[i], view);
      CGRect lower = VBYFrameInRoot(actions[i + 1], view);
      CGFloat available = CGRectGetMinY(lower) - CGRectGetMaxY(upper);
      if (available < size + 8.0) continue;

      centerX = (CGRectGetMidX(upper) + CGRectGetMidX(lower)) * 0.5;
      target = CGRectMake(round(centerX - size * 0.5),
                          round(CGRectGetMaxY(upper) + (available - size) * 0.5),
                          size, size);

      if (!VBYRectCollides(target, actions, view)) {
        found = YES;
        break;
      }
    }
  }

  if (!found) {
    CGRect last = VBYFrameInRoot(actions.lastObject, view);
    centerX = CGRectGetMidX(last);
    target = CGRectMake(round(centerX - size * 0.5),
                        round(CGRectGetMaxY(last) + gap),
                        size, size);
    found = CGRectGetMaxY(target) <= safeBottom &&
            !VBYRectCollides(target, actions, view);
  }

  if (!found) {
    button.hidden = YES;
    return;
  }

  button.frame = target;
  button.hidden = NO;
  button.alpha = 1.0;
  [view bringSubviewToFront:button];
}

static void VBYRefreshNativeButtons(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    for (YTMainAppControlsOverlayView *view in [playerControlViews allObjects])
      [view setNeedsLayout];

    for (YTReelWatchPlaybackOverlayView *view in [shortsControlViews allObjects])
      [view setNeedsLayout];
  });
}

%hook AVPlayer

- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (VBYIsVolumeBoostYTEnabled()) volume *= GetLogarithmicAudioMultiplier();
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
  if (VBYIsVolumeBoostYTEnabled()) volume *= GetLogarithmicAudioMultiplier();
  %orig(volume);
}

%end

%hook AVAudioPlayer

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)outError {
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
  if (VBYIsVolumeBoostYTEnabled()) volume *= GetLogarithmicAudioMultiplier();
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
  if (VBYIsVolumeBoostYTEnabled()) volume *= GetLogarithmicAudioMultiplier();
  %orig(volume);
}

%end

%group NativePlayerControls

%hook YTMainAppControlsOverlayView

- (void)layoutSubviews {
  %orig;
  VBYLayoutPlayerAudioButton(self);
}

%end

%end

%group ShortsControls

%hook YTReelWatchPlaybackOverlayView

- (void)layoutSubviews {
  %orig;
  VBYLayoutShortsAudioButton(self);
}

%end

%end

%group YouTubeSettings

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
  if (self.type != 1) return %orig;
  if (class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)))
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
  NSMutableArray<YTSettingsSectionItem *> *sectionItems = [NSMutableArray array];
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
                    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                    [defaults setBool:enabled forKey:kVolumeBoostYTEnabledKey];
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
                    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                    float value = VBYGetVolumeMultiplier();
                    [defaults setBool:enabled forKey:kRememberVolumeEnabledKey];
                    if (enabled)
                      [defaults setFloat:value forKey:kCustomYouTubeVolumeScalarKey];
                    else
                      [defaults removeObjectForKey:kCustomYouTubeVolumeScalarKey];
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
          respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:TweakSection
                                      title:@"VolumeBoostYT"
                                       icon:nil
                           titleDescription:nil
                               headerHidden:NO];
  } else if ([settingsViewController
                 respondsToSelector:@selector(setSectionItems:forCategory:title:titleDescription:headerHidden:)]) {
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
  if (NSClassFromString(@"YTMainAppControlsOverlayView"))
    %init(NativePlayerControls);
  if (NSClassFromString(@"YTReelWatchPlaybackOverlayView"))
    %init(ShortsControls);

  %init;
  VBYAudioPanelRefresh();
  VBYRefreshNativeButtons();
}
