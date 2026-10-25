#import "HUDMainWindow.h"
#import "TDConfig.h"

@implementation HUDMainWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return YES; }

// 这两项默认关掉。secure 图层会被 render server 特殊处理（单独走 secure context
// 合成，截屏/录屏里被抹掉），我们只是显示一行字，用不上这种特殊待遇，
// 也就不该承担它带来的不确定性。App 里有开关可以打开做对照。
- (BOOL)_isSecure { return [TDConfig shared].secureWindow; }
- (BOOL)_shouldCreateContextAsSecure { return [TDConfig shared].secureWindow; }

@end

