//
//  TDConfig —— 主 App 与 HUD 进程共享的配置
//
//  两边都用绝对路径读写同一个 plist（进程沙盒不同，但不能依赖
//  NSUserDefaults 的 suite 隔离），改完发 Darwin 通知让对方重载。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// 坐标所处的空间。iPhone 的 framebuffer 永远是竖屏物理朝向，
// 所以横屏下拿到的坐标必须先旋转回竖屏才能裁剪。
extern NSString * const TDCoordSpacePortrait;        // 竖屏，直接用
extern NSString * const TDCoordSpaceLandscapeRight;  // 横屏，Home 在右
extern NSString * const TDCoordSpaceLandscapeLeft;   // 横屏，Home 在左

@interface TDConfig : NSObject

/// 识别区域，坐标含义由 coordSpace 决定
@property (nonatomic) double regionX;
@property (nonatomic) double regionY;
@property (nonatomic) double regionW;
@property (nonatomic) double regionH;
@property (nonatomic, copy) NSString *coordSpace;

/// 采样间隔（秒）
@property (nonatomic) double interval;

/// 悬浮窗外观
@property (nonatomic) double fontSize;
@property (nonatomic) BOOL showStatus;      // 是否显示第二行状态文字
@property (nonatomic) BOOL debugBorder;     // 显示边框，方便定位
@property (nonatomic) double hudNormX;      // 悬浮窗中心，相对屏幕的 0~1
@property (nonatomic) double hudNormY;

@property (nonatomic) BOOL enabled;         // 识别总开关（HUD 用）

/// 把 window 注册进 SpringBoard 的 accessibility 窗口层。
/// 这是「切到别的 App 也能看见悬浮窗」的唯一办法，但也是整套东西里
/// 最敏感的一步 —— 如果它把系统搞黑屏了，可以关掉它做对照实验。
@property (nonatomic) BOOL systemWindowHosting;

/// respring（SpringBoard 重启）后自动把悬浮窗拉起来。
/// 默认关：万一黑屏是悬浮窗引起的，自动重启会让设备陷在循环里出不来。
@property (nonatomic) BOOL respawnOnRespring;

/// 悬浮窗窗口是否使用 secure 图层。默认关 —— 我们只是显示文字，
/// 不需要 secure，而 secure 图层由 render server 特殊处理，风险更大。
@property (nonatomic) BOOL secureWindow;

+ (instancetype)shared;

- (void)reload;
- (void)save;
- (void)notifyReload;                        // 发 Darwin 通知让 HUD 重载

/// 把配置里的坐标换算成 framebuffer（竖屏物理像素）坐标。
- (CGRect)framebufferRectForCaptureSize:(CGSize)fbSize;

/// 悬浮窗卡片应有的尺寸（只由字号和状态行开关决定，固定不变，避免抖动）
- (CGSize)hudCardSize;

/// 悬浮窗窗口（比卡片大一圈，留点边距）在屏幕上的位置，居中于 (hudNormX, hudNormY)
- (CGRect)hudWindowFrameForScreenSize:(CGSize)screenSize;

@end

NS_ASSUME_NONNULL_END
