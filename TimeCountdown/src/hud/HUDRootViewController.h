#import <UIKit/UIKit.h>

/// 悬浮窗本体：跑识别循环、把结果显示出来。
@interface HUDRootViewController : UIViewController

- (void)reloadConfig;
- (void)startLoop;
- (void)stopLoop;

@end
