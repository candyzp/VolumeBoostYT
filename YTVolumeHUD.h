#import <UIKit/UIKit.h>

typedef void (^YTVolumeHUDChangeBlock)(float value);

@interface YTVolumeHUD : UIView
+ (instancetype)sharedHUD;
- (BOOL)isPresentedOrTransitioning;
- (void)showWithValue:(float)value;
- (void)showInteractiveWithValue:(float)value
                     changeBlock:(YTVolumeHUDChangeBlock)changeBlock;
- (void)toggleInteractiveWithValue:(float)value
                       changeBlock:(YTVolumeHUDChangeBlock)changeBlock;
- (void)scheduleHideAfterDelay:(NSTimeInterval)delay;
- (void)hide;
@end
