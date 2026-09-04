#import "VBYAudio.h"
#import "YTVolumeHUD.h"
#import <UIKit/UIKit.h>
#include <math.h>

@interface VBYAudioPanelController : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, strong) UIButton *iconButton;
@property(nonatomic, strong) UIVisualEffectView *panel;
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIView *contentRoot;
@property(nonatomic, strong) UIScreenEdgePanGestureRecognizer *legacyPan;
@property(nonatomic, weak) AVPlayer *activePlayer;
@property(nonatomic, assign) BOOL expanded;
@property(nonatomic, assign) BOOL playerPlaying;
@property(nonatomic, assign) CGFloat contentHeight;
@property(nonatomic, assign) float legacyStartVolume;
@property(nonatomic, assign) BOOL panelLegacyMode;
@end

static UIWindow *VBYFindWindow(void) {
  UIApplication *app = [UIApplication sharedApplication];
  if (@available(iOS 13.0, *)) {
    for (UIScene *scene in app.connectedScenes) {
      if (![scene isKindOfClass:[UIWindowScene class]]) continue;
      UIWindowScene *windowScene = (UIWindowScene *)scene;
      if (windowScene.activationState != UISceneActivationStateForegroundActive)
        continue;
      for (UIWindow *window in windowScene.windows) {
        if (window.isKeyWindow && !window.hidden) return window;
      }
      for (UIWindow *window in windowScene.windows) {
        if (!window.hidden && window.alpha > 0.01 &&
            window.screen == [UIScreen mainScreen])
          return window;
      }
    }
  }
  return app.keyWindow;
}

@implementation VBYAudioPanelController

+ (instancetype)sharedController {
  static VBYAudioPanelController *controller = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    controller = [[self alloc] init];
  });
  return controller;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(environmentChanged)
               name:UIApplicationDidBecomeActiveNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(environmentChanged)
               name:UIWindowDidBecomeKeyNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(environmentChanged)
               name:UIDeviceOrientationDidChangeNotification
             object:nil];
  }
  return self;
}

- (void)environmentChanged {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self refresh];
  });
}

- (void)attachToWindow:(UIWindow *)window {
  if (!window || self.window == window) return;

  if (self.legacyPan && self.window)
    [self.window removeGestureRecognizer:self.legacyPan];

  [self.iconButton removeFromSuperview];
  [self.panel removeFromSuperview];

  self.window = window;

  if (!self.iconButton) {
    self.iconButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.iconButton.tintColor = [UIColor whiteColor];
    self.iconButton.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.54];
    self.iconButton.layer.cornerRadius = 19.0;
    self.iconButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconButton.layer.borderWidth = 0.5;
    self.iconButton.layer.borderColor =
        [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    self.iconButton.clipsToBounds = YES;
    [self.iconButton addTarget:self
                        action:@selector(togglePanel)
              forControlEvents:UIControlEventTouchUpInside];
  }

  if (!self.legacyPan) {
    self.legacyPan = [[UIScreenEdgePanGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleLegacyPan:)];
    self.legacyPan.edges = UIRectEdgeRight;
    self.legacyPan.delegate = self;
    self.legacyPan.cancelsTouchesInView = NO;
    self.legacyPan.maximumNumberOfTouches = 1;
  }

  [window addSubview:self.iconButton];
  [window addGestureRecognizer:self.legacyPan];

  if (self.panel) [window addSubview:self.panel];

  [self layoutViews];
}

- (void)buildPanel {
  [self.panel removeFromSuperview];
  self.panelLegacyMode = VBYIsLegacyUIEnabled();

  UIBlurEffect *effect =
      [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
  self.panel = [[UIVisualEffectView alloc] initWithEffect:effect];
  self.panel.clipsToBounds = YES;
  self.panel.layer.cornerRadius = 24.0;
  self.panel.layer.cornerCurve = kCACornerCurveContinuous;
  self.panel.layer.borderWidth = 0.5;
  self.panel.layer.borderColor =
      [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
  self.panel.contentView.backgroundColor =
      [UIColor colorWithWhite:0.02 alpha:0.18];

  self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
  self.scrollView.alwaysBounceVertical = NO;
  self.scrollView.showsVerticalScrollIndicator = NO;
  [self.panel.contentView addSubview:self.scrollView];

  CGFloat width = MIN(360.0, MAX(280.0, self.window.bounds.size.width - 24.0));
  self.contentRoot =
      [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 10)];
  [self.scrollView addSubview:self.contentRoot];

  CGFloat y = 12.0;

  UIImageView *headerIcon =
      [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:
                                             @"waveform.circle.fill"]];
  headerIcon.tintColor = [UIColor whiteColor];
  headerIcon.contentMode = UIViewContentModeScaleAspectFit;
  headerIcon.frame = CGRectMake(16.0, y + 2.0, 28.0, 28.0);
  [self.contentRoot addSubview:headerIcon];

  UILabel *header = [[UILabel alloc]
      initWithFrame:CGRectMake(52.0, y, width - 104.0, 32.0)];
  header.text = VBYIsLegacyUIEnabled() ? @"EQ & Pitch" : @"VolumeBoostYT Audio";
  header.textColor = [UIColor whiteColor];
  header.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
  header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [self.contentRoot addSubview:header];

  UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
  close.frame = CGRectMake(width - 48.0, y - 2.0, 36.0, 36.0);
  close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
  close.tintColor = [UIColor whiteColor];
  [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"]
         forState:UIControlStateNormal];
  [close addTarget:self
                action:@selector(closePanel)
      forControlEvents:UIControlEventTouchUpInside];
  [self.contentRoot addSubview:close];

  y += 42.0;

  if (!VBYIsLegacyUIEnabled()) {
    [self addSliderRowAtY:y
                   title:@"Volume Boost"
                     min:0.0f
                     max:20.0f
                   value:VBYGetVolumeMultiplier()
                     tag:100];
    y += 54.0;
  }

  [self addSliderRowAtY:y
                 title:@"Pitch"
                   min:-12.0f
                   max:12.0f
                 value:VBYGetPitchSemitones()
                   tag:200];
  y += 54.0;

  UILabel *eqTitle =
      [[UILabel alloc] initWithFrame:CGRectMake(16.0, y + 2.0, width - 32.0, 24.0)];
  eqTitle.text = @"Equalizer";
  eqTitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
  eqTitle.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
  eqTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [self.contentRoot addSubview:eqTitle];
  y += 28.0;

  NSArray<NSString *> *names =
      @[@"60 Hz", @"250 Hz", @"1 kHz", @"4 kHz", @"16 kHz"];
  for (NSUInteger i = 0; i < names.count; i++) {
    [self addSliderRowAtY:y
                   title:names[i]
                     min:-12.0f
                     max:12.0f
                   value:VBYGetEQGain(i)
                     tag:300 + i];
    y += 50.0;
  }

  UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
  reset.frame = CGRectMake(16.0, y + 4.0, width - 32.0, 38.0);
  reset.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  reset.layer.cornerRadius = 12.0;
  reset.layer.cornerCurve = kCACornerCurveContinuous;
  reset.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
  reset.tintColor = [UIColor whiteColor];
  reset.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
  [reset setTitle:@"Reset Audio" forState:UIControlStateNormal];
  [reset addTarget:self
                action:@selector(resetAudio)
      forControlEvents:UIControlEventTouchUpInside];
  [self.contentRoot addSubview:reset];

  y += 54.0;
  self.contentHeight = y;
  CGRect rootFrame = self.contentRoot.frame;
  rootFrame.size.height = self.contentHeight;
  self.contentRoot.frame = rootFrame;
  self.scrollView.contentSize = CGSizeMake(width, self.contentHeight);

  if (self.window) [self.window addSubview:self.panel];
  [self layoutViews];
}

- (void)addSliderRowAtY:(CGFloat)y
                  title:(NSString *)title
                    min:(float)min
                    max:(float)max
                  value:(float)value
                    tag:(NSInteger)tag {
  CGFloat width = self.contentRoot.bounds.size.width;
  UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 50.0)];
  row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

  UILabel *label =
      [[UILabel alloc] initWithFrame:CGRectMake(16.0, 0, 145.0, 20.0)];
  label.text = title;
  label.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
  label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
  [row addSubview:label];

  UILabel *valueLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(width - 126.0, 0, 110.0, 20.0)];
  valueLabel.tag = 42;
  valueLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
  valueLabel.textAlignment = NSTextAlignmentRight;
  valueLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.68];
  valueLabel.font =
      [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightMedium];
  [row addSubview:valueLabel];

  UISlider *slider =
      [[UISlider alloc] initWithFrame:CGRectMake(16.0, 20.0, width - 32.0, 28.0)];
  slider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  slider.minimumValue = min;
  slider.maximumValue = max;
  slider.value = value;
  slider.tag = tag;
  slider.continuous = YES;
  [slider addTarget:self
                action:@selector(sliderChanged:)
      forControlEvents:UIControlEventValueChanged];
  [row addSubview:slider];

  [self.contentRoot addSubview:row];
  [self updateValueLabelForSlider:slider];
}

- (void)updateValueLabelForSlider:(UISlider *)slider {
  UILabel *label = (UILabel *)[slider.superview viewWithTag:42];
  if (!label) return;

  if (slider.tag == 100) {
    label.text =
        [NSString stringWithFormat:@"%.0f%%", slider.value * 100.0f];
    return;
  }

  if (slider.tag == 200) {
    float value = fabsf(slider.value) < 0.05f ? 0.0f : slider.value;
    label.text = [NSString stringWithFormat:@"%+.1f st", value];
    return;
  }

  float value = fabsf(slider.value) < 0.05f ? 0.0f : slider.value;
  label.text = [NSString stringWithFormat:@"%+.1f dB", value];
}

- (void)sliderChanged:(UISlider *)slider {
  if (slider.tag == 100) {
    VBYSetVolumeMultiplier(slider.value);
  } else if (slider.tag == 200) {
    VBYSetPitchSemitones(slider.value);
  } else if (slider.tag >= 300 && slider.tag < 305) {
    VBYSetEQGain((NSUInteger)(slider.tag - 300), slider.value);
  }
  [self updateValueLabelForSlider:slider];
}

- (void)resetAudio {
  VBYSetVolumeMultiplier(1.0f);
  VBYSetPitchSemitones(0.0f);
  VBYResetEQ();
  [self buildPanel];
  self.expanded = YES;
  self.panel.hidden = NO;
  self.iconButton.hidden = YES;
  [self layoutViews];
}

- (void)togglePanel {
  if (!self.panel) [self buildPanel];
  self.expanded = !self.expanded;
  self.panel.hidden = !self.expanded;
  self.iconButton.hidden = self.expanded;
  [self layoutViews];
}

- (void)closePanel {
  self.expanded = NO;
  self.panel.hidden = YES;
  [self updateVisibility];
}

- (void)layoutViews {
  UIWindow *window = self.window;
  if (!window) return;

  CGFloat width = window.bounds.size.width;
  CGFloat height = window.bounds.size.height;
  UIEdgeInsets safe = window.safeAreaInsets;
  CGFloat top = safe.top + 8.0;

  self.iconButton.frame =
      CGRectMake((width - 52.0) * 0.5, top, 52.0, 38.0);

  if (self.panel) {
    CGFloat panelWidth = MIN(360.0, MAX(280.0, width - 24.0));
    CGFloat maxHeight = MAX(220.0, height - safe.top - safe.bottom - 16.0);
    CGFloat panelHeight = MIN(self.contentHeight, maxHeight);
    self.panel.frame =
        CGRectMake((width - panelWidth) * 0.5, top, panelWidth, panelHeight);
    self.scrollView.frame = self.panel.contentView.bounds;
    CGRect rootFrame = self.contentRoot.frame;
    rootFrame.size.width = panelWidth;
    rootFrame.size.height = self.contentHeight;
    self.contentRoot.frame = rootFrame;
    self.scrollView.contentSize = CGSizeMake(panelWidth, self.contentHeight);
  }

  [window bringSubviewToFront:self.iconButton];
  if (self.panel && !self.panel.hidden) [window bringSubviewToFront:self.panel];
}

- (void)updateVisibility {
  BOOL enabled = VBYIsVolumeBoostYTEnabled();
  BOOL legacy = VBYIsLegacyUIEnabled();
  BOOL hasPlayer = self.activePlayer && self.activePlayer.currentItem != nil;

  self.legacyPan.enabled = enabled && legacy && hasPlayer;

  UIImage *icon =
      [UIImage systemImageNamed:legacy ? @"slider.horizontal.3"
                                      : @"speaker.wave.3.fill"];
  [self.iconButton setImage:icon forState:UIControlStateNormal];

  BOOL showIcon = NO;
  if (enabled && hasPlayer) {
    if (legacy)
      showIcon = !self.playerPlaying && !self.expanded;
    else
      showIcon = !self.expanded;
  }

  self.iconButton.hidden = !showIcon;
  self.panel.hidden = !(enabled && hasPlayer && self.expanded);

  if (!enabled || !hasPlayer) self.expanded = NO;

  [self layoutViews];
}

- (void)refresh {
  if (!NSClassFromString(@"YTSettingsGroupData")) {
    self.iconButton.hidden = YES;
    self.panel.hidden = YES;
    self.legacyPan.enabled = NO;
    return;
  }

  UIWindow *window = VBYFindWindow();
  if (window) [self attachToWindow:window];

  if (self.panel && self.panelLegacyMode != VBYIsLegacyUIEnabled()) {
    self.expanded = NO;
    [self buildPanel];
    self.panel.hidden = YES;
  }

  [self updateVisibility];
}

- (void)playerStateChanged:(AVPlayer *)player {
  if (!player) return;

  dispatch_async(dispatch_get_main_queue(), ^{
    self.activePlayer = player;
    self.playerPlaying = player.rate > 0.001f;
    if (self.playerPlaying) self.expanded = NO;

    UIWindow *window = VBYFindWindow();
    if (window) [self attachToWindow:window];

    [self updateVisibility];
  });
}

- (void)handleLegacyPan:(UIScreenEdgePanGestureRecognizer *)gesture {
  if (!VBYIsLegacyUIEnabled() || !VBYIsVolumeBoostYTEnabled()) return;

  if (gesture.state == UIGestureRecognizerStateBegan) {
    self.legacyStartVolume = VBYGetVolumeMultiplier();
    [[YTVolumeHUD sharedHUD] showWithValue:self.legacyStartVolume];
    return;
  }

  if (gesture.state == UIGestureRecognizerStateChanged) {
    CGPoint translation = [gesture translationInView:self.window];
    float value = self.legacyStartVolume - (float)translation.y / 30.0f;
    value = MAX(0.0f, MIN(20.0f, value));
    VBYSetVolumeMultiplier(value);
    [[YTVolumeHUD sharedHUD] showWithValue:value];
    return;
  }

  if (gesture.state == UIGestureRecognizerStateEnded ||
      gesture.state == UIGestureRecognizerStateCancelled ||
      gesture.state == UIGestureRecognizerStateFailed) {
    [[YTVolumeHUD sharedHUD] performSelector:@selector(hide)
                                  withObject:nil
                                  afterDelay:1.0];
  }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
  return YES;
}

@end

void VBYAudioPanelPlayerStateChanged(AVPlayer *player) {
  [[VBYAudioPanelController sharedController] playerStateChanged:player];
}

void VBYAudioPanelRefresh(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[VBYAudioPanelController sharedController] refresh];
  });
}
