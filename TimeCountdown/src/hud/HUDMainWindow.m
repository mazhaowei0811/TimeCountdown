#import "HUDMainWindow.h"
#import "TDConfig.h"

@implementation HUDMainWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }

// 不能再写死 YES —— 写死 YES 的话所有触摸都会被窗口层忽略，
// 悬浮窗上的开始/停止按钮就永远点不到。改为在 hitTest 里做选择性穿透：
// 只有按在按钮上才接收，其余区域全部放行给下面的游戏。
- (BOOL)_ignoresHitTest { return NO; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    if ([hit isKindOfClass:[UIButton class]]) return hit;   // 按钮可点
    return nil;                                             // 其余穿透
}

// 这两项默认关掉。secure 图层会被 render server 特殊处理（单独走 secure context
// 合成，截屏/录屏里被抹掉），我们只是显示一行字，用不上这种特殊待遇，
// 也就不该承担它带来的不确定性。App 里有开关可以打开做对照。
- (BOOL)_isSecure { return [TDConfig shared].secureWindow; }
- (BOOL)_shouldCreateContextAsSecure { return [TDConfig shared].secureWindow; }

@end
