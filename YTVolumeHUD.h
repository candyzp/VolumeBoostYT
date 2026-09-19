#import <UIKit/UIKit.h>

typedef void (^YTVolumeHUDChangeBlock)(float value);

@interface YTVolumeHUD : UIView
+ (instancetype)sharedHUD;
- (void)showWithValue:(float)value;
- (void)showInteractiveWithValue:(float)value
                     changeBlock:(YTVolumeHUDChangeBlock)changeBlock;
- (void)scheduleHideAfterDelay:(NSTimeInterval)delay;
- (void)hide;
@end
