//
//  HUDApp —— 程序入口
//
//  同一个二进制四种身份：
//    (无参数)   普通 App，走 UIApplicationMain
//    -hud       悬浮窗进程，手动初始化 UIApplication 并以 root 身份运行
//    -probe     安全诊断：跑同样的初始化 + 连续识别，但**不建窗口、不注册窗口托管**，
//               12 秒后自己退出。用来把「识别循环」和「窗口托管」两个嫌疑分开。
//    -test      一次性自检（截一帧 + OCR，结果落盘）
//    -exit      杀掉正在跑的 HUD
//    -check     查询 HUD 是否在跑（exit code 非 0 表示在跑）
//
//  悬浮窗必须挂到 SpringBoard 的 accessibility 窗口层才能盖在其他 App 上，
//  而这一步要求进程有特权 —— 所以 HUD 不是 App 里的一个视图，
//  而是一个由 App 以 root 身份拉起来的独立进程。
//

#import <notify.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <unistd.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <stdio.h>
#import <dlfcn.h>

#import "HUDHelper.h"
#import "HUDMainWindow.h"
#import "HUDRootViewController.h"

#import "../app/MainApplication.h"
#import "../app/MainApplicationDelegate.h"
#import "../private_headers/TDPrivate.h"
#import "../private_headers/pac_helper.h"

#import "../core/TDConfig.h"
#import "../core/TDEngine.h"
#import "../core/TDLog.h"

static BOOL gTDTestMode = NO;
static BOOL gTDProbeMode = NO;

#pragma mark - 私有符号的运行时解析
//
// GSInitialize / GSEventInitialize / BKSDisplayServicesStart 都住在私有框架里，
// 而 Xcode 的 iPhoneOS SDK 并没有这些 .framework（写进 _PRIVATE_FRAMEWORKS
// 会让链接直接失败）。所以这里全部走 dlopen + dlsym：链接期零依赖，
// 真机上拿不到也只是这几个函数不可用，不会影响安装。
//
// 注意 SpringBoardServices 必须提前 dlopen —— 悬浮窗要用的
// SBSAccessibilityWindowHostingController 类只有该框架加载后才会注册。

static void *gGSServiceHandle   = NULL;
static void *gBackBoardHandle   = NULL;
static void *gSpringBoardHandle = NULL;
static void *gUIKitHandle       = NULL;

static void (*p_GSInitialize)(void)                        = NULL;
static void (*p_GSEventInitialize)(Boolean)                = NULL;
static void (*p_GSEventPushRunLoopMode)(CFStringRef)       = NULL;
static void (*p_BKSDisplayServicesStart)(void)             = NULL;
static void (*p_UIApplicationInitialize)(void)             = NULL;
static void (*p_UIApplicationInstantiateSingleton)(id)     = NULL;

/// 打开 /System/Library/{Private,}Frameworks/<name>.framework/<name>，结果缓存。
static void *TDLoadFramework(const char *name, void **cache)
{
    if (*cache) return *cache;

    char priv[512], pub[512];
    snprintf(priv, sizeof(priv), "/System/Library/PrivateFrameworks/%s.framework/%s", name, name);
    snprintf(pub,  sizeof(pub),  "/System/Library/Frameworks/%s.framework/%s", name, name);

    *cache = dlopen(priv, RTLD_LAZY | RTLD_LOCAL);
    if (!*cache)
        *cache = dlopen(pub, RTLD_LAZY | RTLD_LOCAL);
    if (!*cache) {
        const char *err = dlerror();
        TDLog(@"打不开框架 %s: %s", name, err ? err : "（无错误信息）");
    }
    return *cache;
}

/// 先在整个进程镜像里找（UIKit 之类已经链接进来的），找不到再按框架名 dlopen。
static void *TDSymbol(const char *sym, const char *framework, void **cache)
{
    void *p = dlsym(RTLD_DEFAULT, sym);
    if (p) return p;
    void *h = TDLoadFramework(framework, cache ? cache : &gUIKitHandle);
    return h ? dlsym(h, sym) : NULL;
}

static void TDLoadPrivateSymbols(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p_GSInitialize         = (void (*)(void))TDSymbol("GSInitialize", "GraphicsServices", &gGSServiceHandle);
        p_GSEventInitialize    = (void (*)(Boolean))TDSymbol("GSEventInitialize", "GraphicsServices", &gGSServiceHandle);
        p_GSEventPushRunLoopMode = (void (*)(CFStringRef))TDSymbol("GSEventPushRunLoopMode", "GraphicsServices", &gGSServiceHandle);
        p_BKSDisplayServicesStart = (void (*)(void))TDSymbol("BKSDisplayServicesStart", "BackBoardServices", &gBackBoardHandle);

        p_UIApplicationInitialize = (void (*)(void))TDSymbol("UIApplicationInitialize", "UIKit", NULL);
        p_UIApplicationInstantiateSingleton = (void (*)(id))TDSymbol("UIApplicationInstantiateSingleton", "UIKit", NULL);

        // 这个 dlopen 纯粹是为了把类注册进来，符号本身不用
        (void)TDLoadFramework("SpringBoardServices", &gSpringBoardHandle);

        TDLog(@"私有符号 GS=%p GSEvent=%p PushMode=%p BKS=%p UIAppInit=%p UIAppSingleton=%p",
              (void *)p_GSInitialize, (void *)p_GSEventInitialize, (void *)p_GSEventPushRunLoopMode,
              (void *)p_BKSDisplayServicesStart, (void *)p_UIApplicationInitialize,
              (void *)p_UIApplicationInstantiateSingleton);
    });
}

#pragma mark - HUD 的 UIApplication

@interface HUDMainApplication : UIApplication
@end

@implementation HUDMainApplication

- (instancetype)init
{
    if (self = [super init]) {
        notify_post(NOTIFY_LAUNCHED_HUD);

        // HUD 以 plugin 形式跑，得手动把事件系统的 runloop source 装上，
        // 否则 UIApplication 跑不起来。
        do {
            UIEventDispatcher *dispatcher = (UIEventDispatcher *)[self valueForKey:@"eventDispatcher"];
            if (!dispatcher) {
                TDLog(@"取不到 eventDispatcher");
                break;
            }

            if ([dispatcher respondsToSelector:@selector(_installEventRunLoopSources:)]) {
                CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
                [dispatcher _installEventRunLoopSources:mainRunLoop];
                TDLog(@"事件源已安装（公开方法）");
            } else {
                // iOS 15.1 及以下走这条路：UIKit 内部已经把这个方法内联了，
                // 只能扫指令把真实地址找出来。
                IMP runMethodIMP = class_getMethodImplementation([self class], @selector(_run));
                if (!runMethodIMP) break;

                uint32_t *runMethodPtr = (uint32_t *)make_sym_readable((void *)runMethodIMP);
                void (*install)(id, SEL, CFRunLoopRef) = NULL;

                for (int i = 0; i < 0x140; i++) {
                    // mov x2, x0
                    if (runMethodPtr[i] != 0xaa0003e2 || (runMethodPtr[i + 1] & 0xff000000) != 0xaa000000)
                        continue;
                    // bl <target>
                    uint32_t blInst = runMethodPtr[i + 2];
                    if ((blInst & 0xfc000000) != 0x94000000)
                        continue;

                    int32_t blOffset = blInst & 0x03ffffff;
                    if (blOffset & 0x02000000) blOffset |= 0xfc000000;
                    blOffset <<= 2;

                    uint64_t blAddr = (uint64_t)&runMethodPtr[i + 2] + blOffset;
                    uint32_t cbzInst = *((uint32_t *)make_sym_readable((void *)blAddr));
                    if ((cbzInst & 0xff000000) != 0xb4000000)
                        continue;

                    install = (void (*)(id, SEL, CFRunLoopRef))make_sym_callable((void *)blAddr);
                }

                if (!install) {
                    TDLog(@"找不到 _installEventRunLoopSources:（事件系统可能不工作）");
                    break;
                }
                install(dispatcher, @selector(_installEventRunLoopSources:), CFRunLoopGetMain());
                TDLog(@"事件源已安装（扫描到的地址）");
            }

            UIEventFetcher *fetcher = [[objc_getClass("UIEventFetcher") alloc] init];
            [dispatcher setValue:fetcher forKey:@"eventFetcher"];
            if ([fetcher respondsToSelector:@selector(setEventFetcherSink:)])
                [fetcher setEventFetcherSink:dispatcher];
            else
                [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
        } while (NO);
    }
    return self;
}

@end

#pragma mark - HUD 的 AppDelegate

@interface HUDMainApplicationDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation HUDMainApplicationDelegate {
    HUDRootViewController *_rootViewController;
    id _windowHostingController;
    BOOL _registered;
}

/// 自检：在当前宿主里跑一次完整识别，把结论和裁剪图落盘，主 App 读走展示。
/// 特意走和 HUD 完全相同的初始化路径 —— 只有这样才能真正验证
/// 「HUD 在真机上能不能截到屏、能不能识别」这件事。
- (void)runSelfTestAndExit
{
    TDConfig *cfg = [TDConfig shared];
    [cfg reload];

    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *debugPath = [caches stringByAppendingPathComponent:@"test_crop.png"];

    CGSize fb = [[TDEngine shared] screenFramebufferSize];
    CGRect fbRect = [cfg framebufferRectForCaptureSize:fb];

    TDLog(@"自检：framebuffer %.0fx%.0f，裁剪 (%.0f, %.0f, %.0fx%.0f)",
          fb.width, fb.height, fbRect.origin.x, fbRect.origin.y, fbRect.size.width, fbRect.size.height);

    TDResult *r = [[TDEngine shared] recognizeRect:fbRect debugPath:debugPath];
    TDLog(@"自检结果 status=%ld text=%@ 截屏 %.0fms OCR %.0fms",
          (long)r.status, r.text ?: @"", r.captureMs, r.ocrMs);

    NSDictionary *out = @{
        @"status": @(r.status),
        @"text": r.text ?: @"",
        @"remaining": @(r.remaining),
        @"display": [r displayTime],
        @"detail": r.detail ?: @"",
        @"captureMs": @(r.captureMs),
        @"ocrMs": @(r.ocrMs),
        @"fbWidth": @(fb.width),
        @"fbHeight": @(fb.height),
        @"rectX": @(fbRect.origin.x),
        @"rectY": @(fbRect.origin.y),
        @"rectW": @(fbRect.size.width),
        @"rectH": @(fbRect.size.height),
        @"debugPath": debugPath,
    };

    NSString *outPath = [caches stringByAppendingPathComponent:@"test_result.json"];
    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:outPath atomically:YES];
    chmod([outPath UTF8String], 0666);
    if ([[NSFileManager defaultManager] fileExistsAtPath:debugPath])
        chmod([debugPath UTF8String], 0666);

    exit(0);
}

/// 安全诊断：走完整的 HUD 初始化，但既不建窗口也不注册窗口托管，
/// 只是按采样间隔连续识别 12 秒，每一步都先写日志再动手。
/// 这样万一某一次调用把系统卡住了，日志里能留下最后一条「做的事」。
- (void)runProbeAndExit
{
    TDLog(@"=== 安全诊断开始（不建窗口 / 不注册窗口托管）===");

    TDConfig *cfg = [TDConfig shared];
    [cfg reload];

    CGSize fb = [[TDEngine shared] screenFramebufferSize];
    CGRect rect = [cfg framebufferRectForCaptureSize:fb];
    TDLog(@"诊断：framebuffer %.0fx%.0f，裁剪 (%.0f, %.0f, %.0fx%.0f)，间隔 %.2fs",
          fb.width, fb.height, rect.origin.x, rect.origin.y,
          rect.size.width, rect.size.height, cfg.interval);

    __block int n = 0, ok = 0, noText = 0, parseFail = 0, capFail = 0;

    NSTimeInterval interval = MAX(cfg.interval, 0.1);
    NSTimer *timer = [NSTimer timerWithTimeInterval:interval
                                            repeats:YES
                                              block:^(NSTimer *t) {
        (void)t;
        n++;
        TDLog(@"诊断 #%d：开始截屏+识别", n);
        TDResult *r = [[TDEngine shared] recognizeRect:rect debugPath:nil];
        TDLog(@"诊断 #%d：status=%ld text=%@ 截屏 %.0fms OCR %.0fms",
              n, (long)r.status, r.text ?: @"", r.captureMs, r.ocrMs);

        switch (r.status) {
            case TDStatusOK:            ok++;        break;
            case TDStatusNoText:        noText++;    break;
            case TDStatusParseFailed:   parseFail++; break;
            case TDStatusCaptureFailed: capFail++;   break;
            default: break;
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TDLog(@"=== 安全诊断结束：共 %d 次，成功 %d / 无文字 %d / 解析失败 %d / 截屏失败 %d ===",
              n, ok, noText, parseFail, capFail);
        exit(0);
    });
}

#pragma mark 窗口

- (void)setupHUDWindow
{
    TDConfig *cfg = [TDConfig shared];
    [cfg reload];

    UIScreen *screen = [UIScreen mainScreen];
    CGRect frame = [cfg hudWindowFrameForScreenSize:screen.bounds.size];

    _rootViewController = [[HUDRootViewController alloc] init];

    self.window = [[HUDMainWindow alloc] initWithFrame:frame];
    [self.window setRootViewController:_rootViewController];
    [self.window setWindowLevel:10000010.0];
    [self.window setHidden:NO];
    [self.window makeKeyAndVisible];

    TDLog(@"窗口已建立 %@ (屏幕 %.0fx%.0f) level=%.0f secure=%d 托管=%d",
          NSStringFromCGRect(frame), screen.bounds.size.width, screen.bounds.size.height,
          self.window.windowLevel, (int)cfg.secureWindow, (int)cfg.systemWindowHosting);

    [self registerHostedWindowAttempt:0];
}

/// 把 window 注册进 SpringBoard 的 accessibility 窗口层。
///
/// 两个必须的防御：
///   1. contextId 必须等到非 0 才注册 —— 窗口刚 makeKeyAndVisible 时
///      CAContext 可能还没建好，`_contextId` 会返回 0。拿 0 去注册
///      等于让 SpringBoard 去找一个不存在的图层。
///   2. 注册过程包在 @try 里，并且实现之前先确认方法真的存在，
///      避免在这台设备上把一个 unrecognized selector 变成崩溃。
- (void)registerHostedWindowAttempt:(int)attempt
{
    if (_registered) return;

    TDConfig *cfg = [TDConfig shared];
    if (!cfg.systemWindowHosting) {
        TDLog(@"窗口托管已在配置里关闭，跳过注册（悬浮窗只在自身进程内可见）");
        return;
    }

    SEL sel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    Class cls = objc_getClass("SBSAccessibilityWindowHostingController");
    if (!cls) {
        TDLog(@"拿不到 SBSAccessibilityWindowHostingController，放弃注册");
        return;
    }
    if (![cls instancesRespondToSelector:sel]) {
        TDLog(@"这台系统的窗口托管类没有 registerWindowWithContextID:atLevel:，放弃注册");
        return;
    }

    unsigned int ctx = [self.window _contextId];
    if (ctx == 0) {
        if (attempt >= 50) {   // 约 5 秒
            TDLog(@"等不到有效的 contextId（窗口图层还没建好），放弃注册");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self registerHostedWindowAttempt:attempt + 1];
        });
        return;
    }

    id hosting = [[cls alloc] init];
    BOOL ok = NO;

    @try {
        double level = [self.window windowLevel];

        // 用 NSInvocation 而不是直接调用：这个方法的真实类型是
        // - (void)registerWindowWithContextID:(unsigned int) atLevel:(double)，
        // 直接调用会因为实参提升（unsigned int -> ...）而传错寄存器。
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:hosting];
        [inv setSelector:sel];
        [inv setArgument:&ctx atIndex:2];
        [inv setArgument:&level atIndex:3];
        [inv invoke];
        ok = YES;
    } @catch (NSException *e) {
        TDLog(@"注册窗口托管时抛异常: %@ — %@", e.name, e.reason);
    }

    _windowHostingController = ok ? hosting : nil;
    _registered = ok;
    TDLog(@"窗口托管注册%@ ctx=%u", ok ? @"成功" : @"失败", ctx);
}

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    (void)application; (void)launchOptions;
    TDLog(@"didFinishLaunching（test=%d probe=%d）", (int)gTDTestMode, (int)gTDProbeMode);

    if (gTDTestMode) {
        [self runSelfTestAndExit];
        return YES;
    }
    if (gTDProbeMode) {
        [self runProbeAndExit];
        return YES;
    }

    // 这一步必须在 objc_getClass("SBSAccessibilityWindowHostingController") 之前，
    // 那个类只有 SpringBoardServices 被 dlopen 之后才存在
    TDLoadPrivateSymbols();

    [self setupHUDWindow];
    return YES;
}

@end

#pragma mark - main

static NSString *TDPIDFilePath(void)
{
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        path = [caches stringByAppendingPathComponent:@"hud.pid"];
    });
    return path;
}

static void TDWritePIDFile(pid_t pid)
{
    NSString *s = [NSString stringWithFormat:@"%d", pid];
    NSString *p = TDPIDFilePath();
    if ([s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil])
        chmod([p UTF8String], 0666);
}

static int TDRunHUD(void)
{
    pid_t pid = getpid();

    // 崩溃循环保护放在最前面：如果前几轮都把系统带崩了，
    // 这一轮什么都不做直接退出，让设备能自己恢复。
    int streak = TDBootGuardTick(120.0);
    TDLog(@"—— HUD 启动 pid=%d 连续第 %d 次（%s）",
          pid, streak, gTDProbeMode ? "probe" : "hud");
    if (!gTDProbeMode && streak > 3) {
        TDLog(@"连续启动 %d 次，判定为崩溃循环 —— 本次不建窗口、不注册，直接退出。"
              @"请重启设备后在 App 里点「启动悬浮窗」重试。", streak);
        exit(0);
    }

    // 诊断进程不写 pid 文件 —— 它不是常驻的悬浮窗，
    // 写了会让「悬浮窗是否在运行」的判断出现十几秒的假阳性
    if (!gTDProbeMode)
        TDWritePIDFile(pid);

    TDLoadPrivateSymbols();

    [UIScreen initialize];
    CFRunLoopGetCurrent();

    if (p_GSInitialize)            p_GSInitialize();
    if (p_BKSDisplayServicesStart) p_BKSDisplayServicesStart();
    if (p_UIApplicationInitialize) p_UIApplicationInitialize();

    if (p_UIApplicationInstantiateSingleton) {
        p_UIApplicationInstantiateSingleton((id)objc_getClass("HUDMainApplication"));
    } else {
        // 退化路径：让 UIKit 按 Info.plist 的 NSPrincipalClass 自己建单例
        (void)[UIApplication sharedApplication];
    }

    static id<UIApplicationDelegate> appDelegate = nil;
    appDelegate = [[objc_getClass("HUDMainApplicationDelegate") alloc] init];
    [UIApplication sharedApplication].delegate = appDelegate;
    [[UIApplication sharedApplication] _accessibilityInit];

    [NSRunLoop currentRunLoop];

    if (@available(iOS 15.0, *)) {
        if (p_GSEventInitialize)      p_GSEventInitialize(0);
        if (p_GSEventPushRunLoopMode) p_GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
    }

    [[UIApplication sharedApplication] __completeAndRunAsPlugin];
    TDLog(@"已作为 plugin 跑起来");

    // SpringBoard 重启（respring）后把自己拉起来，不然悬浮窗就永久消失了。
    // 默认关 —— 这条逻辑正是「黑屏转圈一直不停」的放大器：
    // 只要悬浮窗会让 SpringBoard 崩，它就会一轮接一轮地把它重新拉起来。
    if ([TDConfig shared].respawnOnRespring && !gTDProbeMode) {
        static int bootToken = 0;
        notify_register_dispatch("SBSpringBoardDidLaunchNotification", &bootToken,
                                 dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0),
                                 ^(int t) {
            notify_cancel(t);
            TDLog(@"SpringBoard 重新启动，重新拉起悬浮窗");
            SetHUDEnabled(YES);
            kill(pid, SIGKILL);
        });
        TDLog(@"已开启 respring 后自动重启");
    } else {
        TDLog(@"未开启 respring 后自动重启（保证崩溃不会变成死循环）");
    }

    CFRunLoopRun();
    return EXIT_SUCCESS;
}

static int TDExitHUD(void)
{
    NSString *pidString = [NSString stringWithContentsOfFile:TDPIDFilePath()
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (pidString.length) {
        TDLog(@"退出悬浮窗 pid=%@", pidString);
        kill((pid_t)[pidString intValue], SIGKILL);
        [[NSFileManager defaultManager] removeItemAtPath:TDPIDFilePath() error:nil];
    }
    return EXIT_SUCCESS;
}

static int TDCheckHUD(void)
{
    NSString *pidString = [NSString stringWithContentsOfFile:TDPIDFilePath()
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (pidString.length == 0)
        return EXIT_SUCCESS;   // 没有 pid 文件 = 没在跑

    pid_t pid = (pid_t)[pidString intValue];
    // kill(pid, 0) 成功说明进程还活着
    return (kill(pid, 0) == 0) ? EXIT_FAILURE : EXIT_SUCCESS;
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        if (argc <= 1)
            return UIApplicationMain(argc, argv, @"MainApplication", @"MainApplicationDelegate");

        if (strcmp(argv[1], "-hud") == 0)
            return TDRunHUD();
        if (strcmp(argv[1], "-probe") == 0) {
            gTDProbeMode = YES;
            return TDRunHUD();
        }
        if (strcmp(argv[1], "-test") == 0) {
            gTDTestMode = YES;
            return TDRunHUD();
        }
        if (strcmp(argv[1], "-exit") == 0)
            return TDExitHUD();
        if (strcmp(argv[1], "-check") == 0)
            return TDCheckHUD();

        // 不认识的参数当普通启动处理
        return UIApplicationMain(argc, argv, @"MainApplication", @"MainApplicationDelegate");
    }
}
