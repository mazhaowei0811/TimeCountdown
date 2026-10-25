#import "TDEngine.h"
#import "TDConfig.h"
#import "TDLog.h"
#import "TDPrivate.h"

#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <os/log.h>

#pragma mark - IOSurface 运行时桥

// IOSurface 在 SDK 里的位置各版本不一致，直接 -framework 链接有失败风险。
// 这里全部走 dlopen + dlsym，链接期零依赖。
typedef struct __TDIOSurface *TDIOSurfaceRef;

static TDIOSurfaceRef (*td_surface_create)(CFDictionaryRef) = NULL;
static int   (*td_surface_lock)(TDIOSurfaceRef, uint32_t, void *) = NULL;
static int   (*td_surface_unlock)(TDIOSurfaceRef, uint32_t, void *) = NULL;
static size_t(*td_surface_bpr)(TDIOSurfaceRef) = NULL;
static void *(*td_surface_base)(TDIOSurfaceRef) = NULL;
static TDRenderDisplayFn td_render_display = NULL;

static bool TDLoadSurfaceSymbols(void)
{
    static dispatch_once_t once;
    static bool ok = false;
    dispatch_once(&once, ^{
        void *h = NULL;
        const char *candidates[] = {
            "/System/Library/Frameworks/IOSurface.framework/IOSurface",
            "/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface",
            "/usr/lib/libIOSurface.dylib",
        };
        for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]) && !h; i++)
            h = dlopen(candidates[i], RTLD_LAZY | RTLD_LOCAL);

        if (!h) {
            os_log_error(OS_LOG_DEFAULT, "[TD] 打不开 IOSurface: %{public}s", dlerror());
        } else {
            td_surface_create = (TDIOSurfaceRef (*)(CFDictionaryRef))dlsym(h, "IOSurfaceCreate");
            td_surface_lock   = (int (*)(TDIOSurfaceRef, uint32_t, void *))dlsym(h, "IOSurfaceLock");
            td_surface_unlock = (int (*)(TDIOSurfaceRef, uint32_t, void *))dlsym(h, "IOSurfaceUnlock");
            td_surface_bpr    = (size_t (*)(TDIOSurfaceRef))dlsym(h, "IOSurfaceGetBytesPerRow");
            td_surface_base   = (void *(*)(TDIOSurfaceRef))dlsym(h, "IOSurfaceGetBaseAddress");
        }

        // CARenderServerRenderDisplay 在 QuartzCore 里，QuartzCore 是链接进来的，
        // RTLD_DEFAULT 一定能找到。
        td_render_display = (TDRenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        if (!td_render_display && h)
            td_render_display = (TDRenderDisplayFn)dlsym(h, "CARenderServerRenderDisplay");
        if (!td_render_display)
            os_log_error(OS_LOG_DEFAULT, "[TD] 找不到 CARenderServerRenderDisplay");

        ok = (td_surface_create && td_surface_lock && td_surface_unlock &&
              td_surface_bpr && td_surface_base && td_render_display);
        if (!ok)
            os_log_error(OS_LOG_DEFAULT, "[TD] IOSurface 私有符号不完整，截屏不可用");
    });
    return ok;
}

#pragma mark - 图像工具

/// 等比放大。倒计时区域通常只有 200x36，字号太小 Vision 容易漏字。
static CGImageRef TDScaleImage(CGImageRef img, CGFloat scale)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    size_t nw = (size_t)(w * scale), nh = (size_t)(h * scale);
    if (nw < 1 || nh < 1 || nw > 8192 || nh > 8192)
        return CGImageRetain(img);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, nw, nh, 8, nw * 4, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    if (!ctx) { CGColorSpaceRelease(cs); return CGImageRetain(img); }

    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)nw, (CGFloat)nh), img);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return out ? out : CGImageRetain(img);
}

/// 反色。有些界面是深底白字，反成白底黑字识别率更高。
static CGImageRef TDInvertImage(CGImageRef img)
{
    @try {
        CIImage *ci = [CIImage imageWithCGImage:img];
        CIFilter *f = [CIFilter filterWithName:@"CIColorInvert"];
        if (!f) return NULL;
        [f setValue:ci forKey:kCIInputImageKey];
        CIImage *out = f.outputImage;
        if (!out) return NULL;

        static CIContext *tctx = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            tctx = [CIContext contextWithOptions:nil];
        });
        return [tctx createCGImage:out fromRect:out.extent];
    } @catch (NSException *e) {
        return NULL;
    }
}

#pragma mark - OCR

static NSArray<NSString *> *TDRecognize(CGImageRef img)
{
    NSMutableArray<NSString *> *out = [NSMutableArray array];

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = NO;
    // 中文识别能力 iOS 13 起由系统自带；本工程最低支持 14.0，直接用即可。
    req.recognitionLanguages = @[ @"zh-Hans", @"en-US" ];

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
    NSError *err = nil;
    if (![handler performRequests:@[ req ] error:&err] || err)
        return out;

    for (VNObservation *obs in req.results) {
        if (![obs isKindOfClass:[VNRecognizedTextObservation class]])
            continue;
        VNRecognizedText *best = [[(VNRecognizedTextObservation *)obs topCandidates:1] firstObject];
        if (best.string.length > 0)
            [out addObject:best.string];
    }
    return out;
}

#pragma mark - 文本解析

/// 全角转半角 + OCR 常见混淆字纠正。
static NSString *TDPrepare(NSString *src)
{
    if (src.length == 0) return @"";
    NSMutableString *m = [src mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)m, NULL,
                      kCFStringTransformFullwidthHalfwidth, false);

    // 这些字是实测里 Vision 最常把「分/秒/时」认成的东西
    NSDictionary<NSString *, NSString *> *fix = @{
        @"刃": @"分", @"汾": @"分", @"盼": @"分", @"份": @"分", @"方": @"分", @"万": @"分",
        @"杪": @"秒", @"妙": @"秒", @"抄": @"秒", @"移": @"秒", @"秋": @"秒", @"砂": @"秒",
        @"申": @"时", @"寸": @"时",
    };
    for (NSString *k in fix) {
        if ([m containsString:k])
            m = [[m stringByReplacingOccurrencesOfString:k withString:fix[k]] mutableCopy];
    }
    return m;
}

static NSInteger TDFirstInt(NSString *s, NSTextCheckingResult *m, NSUInteger idx)
{
    NSRange r = [m rangeAtIndex:idx];
    if (r.location == NSNotFound || r.length == 0) return -1;
    return [[s substringWithRange:r] integerValue];
}

/// 从 OCR 文本里抠出剩余秒数。-1 表示没能解析出倒计时。
static NSInteger TDParseRemaining(NSString *text)
{
    if (text.length == 0) return -1;
    NSString *s = TDPrepare(text);
    NSRange all = NSMakeRange(0, s.length);

    NSRegularExpression *re;
    NSTextCheckingResult *m;

#define TD_TRY(pattern) \
    re = [NSRegularExpression regularExpressionWithPattern:(pattern) options:0 error:nil]; \
    m = [re firstMatchInString:s options:0 range:all];

    // 1) HH:MM:SS（最明确，先试）
    TD_TRY(@"([0-9]{1,3})\\s*[:]\\s*([0-9]{1,2})\\s*[:]\\s*([0-9]{1,2})")
    if (m) {
        NSInteger a = TDFirstInt(s, m, 1), b = TDFirstInt(s, m, 2), c = TDFirstInt(s, m, 3);
        if (a >= 0 && b >= 0 && c >= 0) return a * 3600 + b * 60 + c;
    }

    // 2) X分Y秒
    TD_TRY(@"([0-9]{1,4})\\s*分\\s*([0-9]{1,3})\\s*秒")
    if (m) {
        NSInteger a = TDFirstInt(s, m, 1), b = TDFirstInt(s, m, 2);
        if (a >= 0 && b >= 0) return a * 60 + b;
    }

    // 3) MM:SS
    TD_TRY(@"([0-9]{1,4})\\s*[:]\\s*([0-9]{1,2})")
    if (m) {
        NSInteger a = TDFirstInt(s, m, 1), b = TDFirstInt(s, m, 2);
        if (a >= 0 && b >= 0) return a * 60 + b;
    }

    // 4) X分
    TD_TRY(@"([0-9]{1,4})\\s*分")
    if (m) {
        NSInteger a = TDFirstInt(s, m, 1);
        if (a >= 0) return a * 60;
    }

    // 5) X秒
    TD_TRY(@"([0-9]{1,5})\\s*秒")
    if (m) {
        NSInteger a = TDFirstInt(s, m, 1);
        if (a >= 0) return a;
    }

    // 6) 退化：整串就是个数字
    TD_TRY(@"^\\D*([0-9]{1,5})\\D*$")
    if (m) {
        NSInteger a = TDFirstInt(s, m, 1);
        if (a >= 0) return a;
    }

#undef TD_TRY
    return -1;
}

#pragma mark - TDResult

@implementation TDResult

- (instancetype)init
{
    if (self = [super init]) {
        _text = @"";
        _remaining = -1;
    }
    return self;
}

- (NSString *)displayTime
{
    if (_remaining < 0) return @"--:--";
    NSInteger t = _remaining;
    NSInteger h = t / 3600, m = (t % 3600) / 60, s = t % 60;
    if (h > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)m, (long)s];
}

@end

#pragma mark - TDEngine

@implementation TDEngine {
    TDIOSurfaceRef _surface;
    size_t _surfaceW, _surfaceH;
}

+ (instancetype)shared
{
    static TDEngine *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[TDEngine alloc] init];
    });
    return inst;
}

- (void)dealloc
{
    if (_surface) CFRelease((CFTypeRef)_surface);
}

- (CGSize)screenFramebufferSize
{
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat s = [UIScreen mainScreen].scale;
    CGFloat w = b.size.width * s;
    CGFloat h = b.size.height * s;
    // iPhone 的 framebuffer 固定是竖屏朝向，横屏时也要按竖屏取尺寸
    return CGSizeMake(MIN(w, h), MAX(w, h));
}

- (CGImageRef)captureScreen
{
    if (!TDLoadSurfaceSymbols())
        return NULL;

    CGSize fb = [self screenFramebufferSize];
    size_t w = (size_t)fb.width, h = (size_t)fb.height;
    if (w < 1 || h < 1) return NULL;

    // 复用 IOSurface，避免每帧都申请 4MB
    if (_surface && (_surfaceW != w || _surfaceH != h)) {
        CFRelease((CFTypeRef)_surface);
        _surface = NULL;
    }
    if (!_surface) {
        // Apple GPU 要求 IOSurface 的 bytesPerRow 64 字节对齐。
        // SE2 宽 750 -> 750*4=3000 不对齐，backboardd 的 Metal 渲染线程
        // 往这种 surface 里画帧会直接 abort（整机黑屏）。必须补齐到 3072。
        size_t bytesPerRow = (w * 4 + 63) & ~(size_t)63;
        // 这些 key 就是 kIOSurfaceWidth 等常量的字面值，写成字符串省掉符号依赖
        NSDictionary *props = @{
            @"IOSurfaceIsGlobal": @YES,
            @"IOSurfaceBytesPerElement": @4,
            @"IOSurfaceBytesPerRow": @(bytesPerRow),
            @"IOSurfaceWidth": @(w),
            @"IOSurfaceHeight": @(h),
            @"IOSurfacePixelFormat": @((uint32_t)0x42475241),   // 'BGRA'
            @"IOSurfaceAllocSize": @(bytesPerRow * h),
        };
        _surface = td_surface_create((__bridge CFDictionaryRef)props);
        if (!_surface) {
            os_log_error(OS_LOG_DEFAULT, "[TD] IOSurfaceCreate 失败 (%zux%zu)", w, h);
            return NULL;
        }
        _surfaceW = w;
        _surfaceH = h;
    }

    td_surface_lock(_surface, 0, NULL);
    CFTimeInterval renderStart = CACurrentMediaTime();
    td_render_display(0, CFSTR("LCD"), _surface, 0, 0);
    CFTimeInterval renderCost = CACurrentMediaTime() - renderStart;
    td_surface_unlock(_surface, 0, NULL);

    // 渲染服务器（backboardd）被卡住的信号：一次调用超过 500ms（正常 <30ms）。
    // 冷却一下再继续，避免 0.15s 间隔的连环请求把 render server 彻底打死；
    // 连续慢就重建 surface（surface 本身可能已进入坏状态）。
    if (renderCost > 0.5) {
        os_log_error(OS_LOG_DEFAULT, "[TD] 截屏渲染耗时 %.0fms，冷却并重建 surface", renderCost * 1000.0);
        TDLog(@"截屏渲染耗时 %.0fms（正常 <30ms），冷却 1s 并重建 surface", renderCost * 1000.0);
        [NSThread sleepForTimeInterval:1.0];
        CFRelease((CFTypeRef)_surface);
        _surface = NULL;
        _surfaceW = 0;
        _surfaceH = 0;
    }

    size_t bpr = td_surface_bpr(_surface);
    void *base = td_surface_base(_surface);
    if (!base || bpr < w * 4) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, base, bpr * h, NULL);
    CGImageRef src = provider
        ? CGImageCreate(w, h, 8, 32, bpr, cs,
                        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                        provider, NULL, true, kCGRenderingIntentDefault)
        : NULL;

    CGImageRef out = NULL;
    if (src) {
        // 立刻拷一份独立副本：surface 内容会在下一次渲染时被覆盖
        CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
        if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), src);
            out = CGBitmapContextCreateImage(ctx);
            CGContextRelease(ctx);
        }
        CGImageRelease(src);
    }
    if (provider) CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    return out;
}

- (TDResult *)recognizeRect:(CGRect)fbRect debugPath:(NSString *)debugPath
{
    TDResult *r = [[TDResult alloc] init];
    r.timestamp = [NSDate date].timeIntervalSince1970;

    CFTimeInterval t0 = CACurrentMediaTime();
    CGImageRef full = [self captureScreen];
    r.captureMs = (CACurrentMediaTime() - t0) * 1000.0;

    if (!full) {
        r.status = TDStatusCaptureFailed;
        r.detail = @"截屏失败（可能缺少截屏权限）";
        return r;
    }

    CGSize fb = [self screenFramebufferSize];
    CGRect rc = CGRectIntersection(fbRect, CGRectMake(0, 0, fb.width, fb.height));
    if (CGRectIsNull(rc) || rc.size.width < 1 || rc.size.height < 1) {
        CGImageRelease(full);
        r.status = TDStatusCaptureFailed;
        r.detail = [NSString stringWithFormat:@"区域越界 %.0f,%.0f %.0fx%.0f / framebuffer %.0fx%.0f",
                    fbRect.origin.x, fbRect.origin.y, fbRect.size.width, fbRect.size.height,
                    fb.width, fb.height];
        return r;
    }

    CGImageRef cropped = CGImageCreateWithImageInRect(full, rc);
    CGImageRelease(full);
    if (!cropped) {
        r.status = TDStatusCaptureFailed;
        r.detail = @"裁剪失败";
        return r;
    }

    CGImageRef scaled = TDScaleImage(cropped, 3.0);
    CGImageRelease(cropped);

    CFTimeInterval t1 = CACurrentMediaTime();
    NSMutableArray<NSString *> *lines = [TDRecognize(scaled) mutableCopy];
    NSString *joined = [lines componentsJoinedByString:@" "];

    if (joined.length == 0) {
        // 深底白字之类的情况，反色再试一次
        CGImageRef inv = TDInvertImage(scaled);
        if (inv) {
            NSArray<NSString *> *again = TDRecognize(inv);
            if (again.count > 0)
                joined = [again componentsJoinedByString:@" "];
            CGImageRelease(inv);
        }
    }
    r.ocrMs = (CACurrentMediaTime() - t1) * 1000.0;

    if (debugPath.length > 0) {
        @try {
            UIImage *img = [UIImage imageWithCGImage:scaled];
            NSData *png = UIImagePNGRepresentation(img);
            [png writeToFile:debugPath atomically:YES];
        } @catch (NSException *e) {
            os_log_error(OS_LOG_DEFAULT, "[TD] 保存调试图失败: %{public}@", e.reason);
        }
    }

    CGImageRelease(scaled);

    r.text = joined;
    if (joined.length == 0) {
        r.status = TDStatusNoText;
        r.detail = @"区域内没有识别到文字";
        return r;
    }

    NSInteger sec = TDParseRemaining(joined);
    r.remaining = sec;
    if (sec >= 0) {
        r.status = TDStatusOK;
    } else {
        r.status = TDStatusParseFailed;
        r.detail = @"文字里没有倒计时格式";
    }
    return r;
}

@end
