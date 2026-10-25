#import "TDConfig.h"
#import <notify.h>
#import <sys/stat.h>

NSString * const TDCoordSpacePortrait       = @"portrait";
NSString * const TDCoordSpaceLandscapeRight = @"landscapeRight";
NSString * const TDCoordSpaceLandscapeLeft  = @"landscapeLeft";

@implementation TDConfig

+ (instancetype)shared
{
    static TDConfig *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[TDConfig alloc] init];
        [inst setDefaults];
        [inst reload];
    });
    return inst;
}

- (void)setDefaults
{
    // 默认值对齐用户给的场景：横屏 1334x750，区域 (1010,590,200,36)
    _regionX = 1010;
    _regionY = 590;
    _regionW = 200;
    _regionH = 36;
    _coordSpace = TDCoordSpaceLandscapeRight;
    _interval = 0.15;
    _fontSize = 34;
    _showStatus = YES;
    _debugBorder = NO;
    _hudNormX = 0.5;
    _hudNormY = 0.78;
    _enabled = NO;

    // 悬浮窗能不能盖在别的 App 上，全靠这一步
    _systemWindowHosting = YES;
    // 默认关：万一悬浮窗把 SpringBoard 弄挂了，自动重启会把设备拖进死循环
    _respawnOnRespring = NO;
    // 只是显示文字，用不上 secure 图层
    _secureWindow = NO;
}

- (void)reload
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:TD_PREFS_PATH];
    if (![d isKindOfClass:[NSDictionary class]] || d.count == 0)
        return;

    if (d[@"regionX"]) _regionX = [d[@"regionX"] doubleValue];
    if (d[@"regionY"]) _regionY = [d[@"regionY"] doubleValue];
    if (d[@"regionW"]) _regionW = [d[@"regionW"] doubleValue];
    if (d[@"regionH"]) _regionH = [d[@"regionH"] doubleValue];
    if ([d[@"coordSpace"] isKindOfClass:[NSString class]]) _coordSpace = d[@"coordSpace"];
    if (d[@"interval"]) _interval = [d[@"interval"] doubleValue];
    if (d[@"fontSize"]) _fontSize = [d[@"fontSize"] doubleValue];
    if (d[@"showStatus"]) _showStatus = [d[@"showStatus"] boolValue];
    if (d[@"debugBorder"]) _debugBorder = [d[@"debugBorder"] boolValue];
    if (d[@"hudNormX"]) _hudNormX = [d[@"hudNormX"] doubleValue];
    if (d[@"hudNormY"]) _hudNormY = [d[@"hudNormY"] doubleValue];
    if (d[@"enabled"]) _enabled = [d[@"enabled"] boolValue];
    if (d[@"systemWindowHosting"]) _systemWindowHosting = [d[@"systemWindowHosting"] boolValue];
    if (d[@"respawnOnRespring"]) _respawnOnRespring = [d[@"respawnOnRespring"] boolValue];
    if (d[@"secureWindow"]) _secureWindow = [d[@"secureWindow"] boolValue];

    if (_interval < 0.05) _interval = 0.05;
    if (_fontSize < 10) _fontSize = 10;
}

- (NSDictionary *)dictionary
{
    return @{
        @"regionX": @(_regionX),
        @"regionY": @(_regionY),
        @"regionW": @(_regionW),
        @"regionH": @(_regionH),
        @"coordSpace": _coordSpace ?: TDCoordSpaceLandscapeRight,
        @"interval": @(_interval),
        @"fontSize": @(_fontSize),
        @"showStatus": @(_showStatus),
        @"debugBorder": @(_debugBorder),
        @"hudNormX": @(_hudNormX),
        @"hudNormY": @(_hudNormY),
        @"enabled": @(_enabled),
        @"systemWindowHosting": @(_systemWindowHosting),
        @"respawnOnRespring": @(_respawnOnRespring),
        @"secureWindow": @(_secureWindow),
    };
}

- (void)save
{
    NSDictionary *d = [self dictionary];
    NSString *dir = [TD_PREFS_PATH stringByDeletingLastPathComponent];

    // 目录可能不存在（HUD 以 root 跑，主 App 是 mobile）
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0777}
                                                    error:nil];
    BOOL ok = [d writeToFile:TD_PREFS_PATH atomically:YES];
    if (!ok) {
        os_log_error(OS_LOG_DEFAULT, "[TD] 写配置失败: %{public}@", TD_PREFS_PATH);
        return;
    }
    // HUD 以 root 跑，必须让 mobile 也能改写，否则主 App 之后存不进去
    chmod([TD_PREFS_PATH UTF8String], 0666);
}

- (void)notifyReload
{
    notify_post(NOTIFY_RELOAD_HUD);
}

#pragma mark - 坐标换算

- (CGRect)framebufferRectForCaptureSize:(CGSize)fbSize
{
    CGFloat FW = fbSize.width;    // framebuffer 宽（竖屏物理宽，如 750）
    CGFloat FH = fbSize.height;   // framebuffer 高（竖屏物理高，如 1334）

    CGFloat x = _regionX, y = _regionY, w = _regionW, h = _regionH;
    if (w <= 0) w = 1;
    if (h <= 0) h = 1;

    NSString *space = _coordSpace ?: TDCoordSpaceLandscapeRight;

    if ([space isEqualToString:TDCoordSpacePortrait]) {
        return CGRectMake(x, y, w, h);
    }

    if ([space isEqualToString:TDCoordSpaceLandscapeLeft]) {
        // 横屏（Home 在左）：(u,v) = (y, FH-1-x)
        // 矩形映射后取 bounding box
        CGFloat u = y;
        CGFloat v = FH - x - w;
        return CGRectMake(u, v, h, w);
    }

    // 默认按 landscapeRight 处理（Home 在右）：(u,v) = (FW-1-y, x)
    CGFloat u = FW - y - h;
    CGFloat v = x;
    return CGRectMake(u, v, h, w);
}

#pragma mark - 悬浮窗几何

- (CGSize)hudCardSize
{
    CGFloat fs = _fontSize;
    if (fs < 10) fs = 10;

    // 宽度按最长的显示形态 "1:05:30"（7 个等宽字符）留量，
    // 再加上会话里可能出现的「分/秒」这类全角字。
    CGFloat w = round(fs * 4.8) + 24;
    CGFloat h = round(fs * 1.32) + (_showStatus ? 28.0 : 12.0);
    return CGSizeMake(w, h);
}

- (CGRect)hudWindowFrameForScreenSize:(CGSize)screenSize
{
    CGSize card = [self hudCardSize];
    CGSize win = CGSizeMake(card.width + 4.0, card.height + 4.0);

    if (screenSize.width < 1 || screenSize.height < 1)
        return CGRectMake(0, 0, win.width, win.height);

    if (win.width > screenSize.width - 8)  win.width  = screenSize.width - 8;
    if (win.height > screenSize.height - 8) win.height = screenSize.height - 8;

    CGFloat cx = screenSize.width * _hudNormX;
    CGFloat cy = screenSize.height * _hudNormY;

    CGFloat x = round(cx - win.width / 2.0);
    CGFloat y = round(cy - win.height / 2.0);

    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > screenSize.width - win.width)   x = screenSize.width - win.width;
    if (y > screenSize.height - win.height) y = screenSize.height - win.height;

    return CGRectMake(x, y, win.width, win.height);
}

@end
