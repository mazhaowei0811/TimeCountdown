//
//  TDPrivate.h —— 私有 API 声明
//
//  这些符号属于系统私有框架，符号本身存在但没有公开头文件，
//  所以只能自己声明。声明必须和 runtime 上的真实签名一致，
//  否则 arm64 上会因为参数错位而崩溃。
//

#ifndef TD_PRIVATE_H
#define TD_PRIVATE_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 截屏

// CoreGraphics / QuartzCore 私有函数：把显示内容渲染到 IOSurface。
// 第一个参数：老 iOS 上是 bootstrap 端口（传 0）；iOS 14+ 疑似要传
// CARenderServerCreate 创建的实例句柄，探针会两种都试。
// 声明成一个函数指针类型，实际地址由 TDEngine 在运行时 dlsym 取，
// 这样不依赖链接期的私有框架。
typedef void (*TDRenderDisplayFn)(void *server, CFStringRef display,
                                  void *surface, int x, int y);

// 更简单的私有入口，UIKit 内部就是用它转 IOSurface -> UIImage。
// 部分系统版本上可能不存在，所以用弱链接，取不到时回退到 CARenderServerRenderDisplay。
extern UIImage *_Nullable _UICreateScreenUIImage(void) __attribute__((weak_import));

#pragma mark - 悬浮窗

// 把本进程的 window 注册进 SpringBoard 的 accessibility 窗口层，
// 这样它才能盖在其他 App 上面。需要
// com.apple.springboard.accessibility-window-hosting 权限。
@interface SBSAccessibilityWindowHostingController : NSObject
- (void)registerWindowWithContextID:(unsigned int)arg1 atLevel:(double)arg2;
@end

@interface UIWindow (TDPrivate)
- (unsigned int)_contextId;
@end

#pragma mark - UIApplication 私有能力（HUD 模式手动初始化时用）

@interface UIApplication (TDPrivate)
- (void)_accessibilityInit;
- (void)__completeAndRunAsPlugin;
- (void)terminateWithSuccess;
- (void)suspend;
- (void)_run;
@end

#pragma mark - 事件系统（HUD 进程手动跑 UIApplication 时需要）

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __GSEvent *GSEventRef;

@class UIEventDispatcher;

@interface UIEventDispatcher : NSObject
- (void)_installEventRunLoopSources:(CFRunLoopRef)arg1;
@end

@interface UIEventFetcher : NSObject
- (void)setEventFetcherSink:(UIEventDispatcher *)arg1;
@end

#pragma mark - 屏幕方向

@interface FBSOrientationUpdate : NSObject
@property (nonatomic, readonly) long long orientation;
@property (nonatomic, readonly) double duration;
@end

@interface FBSOrientationObserver : NSObject
- (void)setHandler:(void (^)(FBSOrientationUpdate *update))handler;
- (void)invalidate;
@end

#pragma mark - 图形初始化
//
// 这一组全部住在私有框架里（GraphicsServices / BackBoardServices / UIKitCore），
// 而且是**运行时 dlopen + dlsym** 取地址后调用的（见 HUDApp.m 的 TDLoadPrivateSymbols），
// 所以这里只留签名说明，不要直接调用 —— 直接调用会让链接期依赖这些私有框架。
//
//   void GSInitialize(void);                        // GraphicsServices
//   void GSEventInitialize(Boolean registerPurple); // GraphicsServices
//   void GSEventPushRunLoopMode(CFStringRef mode);  // GraphicsServices
//   void BKSDisplayServicesStart(void);             // BackBoardServices
//   void UIApplicationInitialize(void);             // UIKitCore
//   void UIApplicationInstantiateSingleton(Class cls); // UIKitCore

NS_ASSUME_NONNULL_END

#endif /* TD_PRIVATE_H */
