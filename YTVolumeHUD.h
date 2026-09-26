#import <UIKit/UIKit.h>

typedef void (^YTVolumeHUDChangeBlock)(float value);

@interface YTVolumeHUD : UIView
+ (instancetype)sharedHUD;
- (BOOL)isPresentedOrTransitioning;
- (BOOL)isTargetPresented;
- (BOOL)isNotchPresented;
- (void)showWithValue:(float)value;
- (void)showNotchWithValue:(float)value
              changeBlock:(YTVolumeHUDChangeBlock)changeBlock;
- (void)showInteractiveWithValue:(float)value
                     changeBlock:(YTVolumeHUDChangeBlock)changeBlock;
- (void)toggleInteractiveWithValue:(float)value
                       changeBlock:(YTVolumeHUDChangeBlock)changeBlock;
- (void)setInteractiveValue:(float)value;
- (void)scheduleHideAfterDelay:(NSTimeInterval)delay;
- (void)hide;
@end
