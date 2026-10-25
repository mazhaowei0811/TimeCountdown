#import <UIKit/UIKit.h>

/// HUD 的宿主 window。这几个私有属性决定了它能不能盖在别的 App 上面：
///   _isSystemWindow                —— 被当作系统级窗口对待
///   _isWindowServerHostingManaged  —— 不交给 WindowServer 托管，才允许跨进程挂载
///   _ignoresHitTest                —— 触摸穿透，悬浮窗不挡底下 App 的操作
///   _isSecure                      —— 参与安全图层，屏幕录制时不会被裁掉
@interface HUDMainWindow : UIWindow
@end
