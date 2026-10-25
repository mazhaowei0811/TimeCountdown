#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TDStatus) {
    TDStatusIdle = 0,
    TDStatusOK,              // 识别到并解析出秒数
    TDStatusNoText,          // 截到了，但 OCR 没读出任何文字
    TDStatusParseFailed,     // 读出了文字，但不是倒计时格式
    TDStatusCaptureFailed,   // 截屏本身失败（权限 / 区域越界）
};

@interface TDResult : NSObject
@property (nonatomic) TDStatus status;
@property (nonatomic, copy) NSString *text;      // OCR 原始文本
@property (nonatomic) NSInteger remaining;       // 解析出的剩余秒数，-1 = 未解析出
@property (nonatomic) NSTimeInterval timestamp;
@property (nonatomic) double captureMs;
@property (nonatomic) double ocrMs;
@property (nonatomic, copy, nullable) NSString *detail;

- (NSString *)displayTime;   // "22:06" / "1:05:30"
@end

@interface TDEngine : NSObject

+ (instancetype)shared;

/// framebuffer 的物理尺寸。iPhone 上永远是竖屏朝向（SE2 = 750x1334）。
- (CGSize)screenFramebufferSize;

/// 截一帧全屏。返回的 CGImage 由调用方释放。
- (CGImageRef _Nullable)captureScreen CF_RETURNS_RETAINED;

/// 截屏 -> 裁剪 -> 放大 -> OCR -> 解析。fbRect 是 framebuffer 坐标。
- (TDResult *)recognizeRect:(CGRect)fbRect debugPath:(nullable NSString *)debugPath;

@end

NS_ASSUME_NONNULL_END
