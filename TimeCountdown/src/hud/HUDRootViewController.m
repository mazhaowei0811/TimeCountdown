#import "HUDRootViewController.h"
#import "HUDHelper.h"
#import "TDConfig.h"
#import "TDEngine.h"
#import "TDLog.h"
#import "TDPrivate.h"

#import <notify.h>
#import <mach/mach.h>
#import <QuartzCore/QuartzCore.h>

static NSString * const kLockStateNotification = @"com.apple.springboard.lockstate";

/// 查锁屏状态。用 Darwin 通知的 state 位，比 SBSSpringBoardServerPort +
/// SBGetScreenLockStatus 更省事 —— 那两个是 SpringBoardServices 里的私有
/// C 符号，声明签名对不上就会崩，这里直接绕开。
static BOOL TDIsScreenLocked(void)
{
    int token = 0;
    if (notify_register_check("com.apple.springboard.lockstate", &token) != NOTIFY_STATUS_OK)
        return NO;

    uint64_t state = 0;
    BOOL locked = (notify_get_state(token, &state) == NOTIFY_STATUS_OK) && state != 0;
    notify_cancel(token);
    return locked;
}

static void TDHandleLockStateChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo);

@implementation HUDRootViewController {
    UIView *_container;
    UILabel *_timeLabel;
    UILabel *_statusLabel;
    UIButton *_toggleBtn;
    UIButton *_testBtn;
    UIButton *_closeBtn;

    NSTimer *_timer;
    dispatch_queue_t _workQueue;
    BOOL _busy;
    BOOL _locked;
    BOOL _userPaused;   // 用户点了停止按钮后不再被配置刷新悄悄拉起来

    // 读数过滤：OCR 偶尔会把数字认错导致读数突跳
    NSInteger _lastValue;
    NSTimeInterval _lastStamp;
    NSInteger _rejectStreak;
    NSInteger _emptyStreak;
    NSInteger _captureFailStreak;
    BOOL _loggedFirst;
}

#pragma mark - 生命周期

- (instancetype)init
{
    if (self = [super init]) {
        _workQueue = dispatch_queue_create("com.tp2.timecountdown.work", DISPATCH_QUEUE_SERIAL);
        _lastValue = -1;
        _lastStamp = 0;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    _container = [[UIView alloc] initWithFrame:CGRectZero];
    _container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _container.layer.cornerRadius = 14.0;
    _container.layer.cornerCurve = kCACornerCurveContinuous;
    _container.layer.borderWidth = 0.0;
    _container.layer.borderColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:0.9].CGColor;
    _container.translatesAutoresizingMaskIntoConstraints = YES;
    [self.view addSubview:_container];

    _timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _timeLabel.textAlignment = NSTextAlignmentCenter;
    _timeLabel.textColor = [UIColor whiteColor];
    _timeLabel.adjustsFontSizeToFitWidth = YES;
    _timeLabel.minimumScaleFactor = 0.5;
    _timeLabel.layer.shadowColor = [UIColor blackColor].CGColor;
    _timeLabel.layer.shadowOpacity = 0.8;
    _timeLabel.layer.shadowRadius = 3.0;
    _timeLabel.layer.shadowOffset = CGSizeMake(0, 1);
    [_container addSubview:_timeLabel];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    _statusLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _statusLabel.adjustsFontSizeToFitWidth = YES;
    _statusLabel.minimumScaleFactor = 0.6;
    _statusLabel.text = @"启动中…";
    [_container addSubview:_statusLabel];

    _toggleBtn = [self makeHudButton:@"⏸" action:@selector(toggleRecognition)];
    [_container addSubview:_toggleBtn];

    _testBtn = [self makeHudButton:@"测" action:@selector(runOneTest)];
    _testBtn.backgroundColor = [UIColor colorWithRed:0.30 green:0.55 blue:1.0 alpha:0.30];
    [_container addSubview:_testBtn];

    _closeBtn = [self makeHudButton:@"✕" action:@selector(closeHUD)];
    _closeBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.45];
    [_container addSubview:_closeBtn];

    [self registerNotifications];
    [self applyConfig];
    TDLog(@"悬浮窗内容已就绪，开始识别循环");
    [self startLoop];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self layoutContainer];
}

#pragma mark - 布局

- (UIButton *)makeHudButton:(NSString *)title action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.layer.cornerRadius = 10.0;
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    b.tintColor = [UIColor whiteColor];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)layoutContainer
{
    TDConfig *cfg = [TDConfig shared];
    CGSize bounds = self.view.bounds.size;
    if (bounds.width < 1 || bounds.height < 1) return;

    CGFloat fontSize = cfg.fontSize;
    _timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:fontSize weight:UIFontWeightBold];
    _statusLabel.font = [UIFont systemFontOfSize:MAX(fontSize * 0.30, 9.0) weight:UIFontWeightMedium];

    // 卡片尺寸是固定的（只由字号和状态行开关决定）。
    // 之前用 sizeThatFits 跟着文字走，字数一变窗口宽度就抖一下；
    // 而且窗口是整个屏幕大小 —— 那个大窗口正是最可疑的地方，现在窗口
    // 只比卡片大一圈，跟 Helium 那种「小窗口挂进 SpringBoard」的做法一致。
    CGSize card = [cfg hudCardSize];
    CGFloat w = MIN(card.width, bounds.width - 4);
    CGFloat h = MIN(card.height, bounds.height - 4);
    _container.frame = CGRectMake(round((bounds.width - w) / 2.0),
                                  round((bounds.height - h) / 2.0),
                                  round(w), round(h));

    _statusLabel.hidden = !cfg.showStatus;

    CGFloat pad = 8.0;
    CGFloat btnCol = 26.0;   // 右侧按钮列宽度
    CGFloat timeH = round(fontSize * 1.32);
    CGFloat textW = _container.bounds.size.width - pad * 2 - btnCol;
    _timeLabel.frame = CGRectMake(pad, 6.0, textW, timeH);
    if (cfg.showStatus) {
        _statusLabel.frame = CGRectMake(pad, 6.0 + timeH + 2.0, textW, 14.0);
    }

    CGFloat btnX = _container.bounds.size.width - btnCol - 2.0;
    CGFloat btnH = 20.0;
    _toggleBtn.frame = CGRectMake(btnX, 6.0, btnH, btnH);
    _testBtn.frame = CGRectMake(btnX, round((_container.bounds.size.height - btnH) / 2.0), btnH, btnH);
    _closeBtn.frame = CGRectMake(btnX, _container.bounds.size.height - btnH - 6.0, btnH, btnH);

    _container.layer.borderWidth = cfg.debugBorder ? 1.0 : 0.0;

    [self applyWindowFrame];
}

/// 位置由配置里的归一化坐标决定，窗口比卡片大 4pt 留出圆角阴影的余量。
/// 只在真的变了的时候动 frame —— 否则会在 layoutSubviews 里绕圈。
- (void)applyWindowFrame
{
    UIWindow *win = self.view.window;
    if (!win) return;

    TDConfig *cfg = [TDConfig shared];
    UIScreen *screen = win.screen ?: [UIScreen mainScreen];
    CGRect want = [cfg hudWindowFrameForScreenSize:screen.bounds.size];
    if (CGRectEqualToRect(win.frame, want)) return;

    win.frame = want;
    TDLog(@"悬浮窗位置更新 %@", NSStringFromCGRect(want));
}

- (void)reloadConfig
{
    [self applyConfig];
}

- (void)applyConfig
{
    TDConfig *cfg = [TDConfig shared];
    [cfg reload];
    [self layoutContainer];
    [self.view setNeedsLayout];

    if (cfg.enabled) {
        [self startLoop];
    } else {
        [self stopLoop];
        [self setStatusText:@"已停用"];
    }
    [self updateToggleUI];
}

#pragma mark - 通知

- (void)registerNotifications
{
    __weak typeof(self) weakSelf = self;

    int token = 0;
    notify_register_dispatch(NOTIFY_RELOAD_HUD, &token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        [weakSelf applyConfig];
    });

    // 锁屏时把悬浮窗收起来，解锁再放出来
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                   (__bridge const void *)self,
                                   TDHandleLockStateChanged,
                                   (__bridge CFStringRef)kLockStateNotification,
                                   NULL,
                                   CFNotificationSuspensionBehaviorCoalesce);
}

static void TDHandleLockStateChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo)
{
    (void)center; (void)name; (void)object; (void)userInfo;
    HUDRootViewController *vc = (__bridge HUDRootViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc handleLockStateChanged];
    });
}

- (void)handleLockStateChanged
{
    // 拿不到状态就不判断，直接当作没锁屏（宁可不隐藏也不要误隐藏）
    BOOL nowLocked = TDIsScreenLocked();
    if (nowLocked == _locked) return;

    TDLog(@"锁屏状态变化：%@", nowLocked ? @"已锁屏（收起悬浮窗）" : @"已解锁（恢复悬浮窗）");
    _locked = nowLocked;
    if (_locked) {
        [self stopLoop];
        self.view.hidden = YES;
    } else {
        self.view.hidden = NO;
        [self startLoop];
    }
}

#pragma mark - 识别循环

- (void)startLoop
{
    TDConfig *cfg = [TDConfig shared];
    if (!cfg.enabled || _userPaused) return;

    [self stopLoop];
    _userPaused = NO;

    NSTimeInterval interval = MAX(cfg.interval, 0.05);
    _timer = [NSTimer timerWithTimeInterval:interval
                                     target:self
                                   selector:@selector(tick)
                                   userInfo:nil
                                    repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [self updateToggleUI];
}

- (void)stopLoop
{
    if (_timer) {
        [_timer invalidate];
        _timer = nil;
    }
}

- (void)updateToggleUI
{
    BOOL running = (_timer != nil);
    [_toggleBtn setTitle:(running ? @"⏸" : @"▶") forState:UIControlStateNormal];
    _toggleBtn.backgroundColor = running
        ? [UIColor colorWithWhite:1.0 alpha:0.16]
        : [UIColor colorWithRed:0.30 green:0.85 blue:0.45 alpha:0.30];
}

#pragma mark - 悬浮窗按钮

- (void)toggleRecognition
{
    if (_timer) {
        // 停止识别（悬浮窗保留在屏幕上）
        _userPaused = YES;
        [self stopLoop];
        _timeLabel.text = @"已停止";
        _timeLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        [self setStatusText:@"点 ▶ 重新开始识别"];
        TDLog(@"用户点悬浮窗按钮：停止识别");
    } else {
        _userPaused = NO;
        _timeLabel.textColor = [UIColor whiteColor];
        _timeLabel.text = @"--:--";
        [self setStatusText:@"启动中…"];
        TDLog(@"用户点悬浮窗按钮：开始识别");
        [self startLoop];
    }
    [self updateToggleUI];
}

- (void)closeHUD
{
    TDLog(@"用户点悬浮窗关闭按钮，退出 HUD 进程");
    dispatch_async(dispatch_get_main_queue(), ^{
        exit(0);
    });
}

- (void)runOneTest
{
    if (_busy) return;
    _busy = YES;
    [self setStatusText:@"测试识别中…"];
    TDLog(@"用户点悬浮窗按钮：测试识别");

    CGSize fb = [[TDEngine shared] screenFramebufferSize];
    CGRect fbRect = [[TDConfig shared] framebufferRectForCaptureSize:fb];

    __weak typeof(self) weakSelf = self;
    dispatch_async(_workQueue, ^{
        TDResult *r = [[TDEngine shared] recognizeRect:fbRect debugPath:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_busy = NO;
            switch (r.status) {
                case TDStatusOK:
                    [strongSelf setStatusText:[NSString stringWithFormat:
                        @"✅ 识别成功: %@（剩 %ld 秒）", [r displayTime], (long)r.remaining]];
                    break;
                case TDStatusNoText:
                    [strongSelf setStatusText:[NSString stringWithFormat:
                        @"⚠️ 区域内没文字（OCR %.0fms）", r.ocrMs]];
                    break;
                case TDStatusParseFailed:
                    [strongSelf setStatusText:[NSString stringWithFormat:
                        @"⚠️ 读到「%@」但不是倒计时", r.text ?: @""]];
                    break;
                default:
                    [strongSelf setStatusText:@"❌ 截屏失败"];
                    break;
            }
        });
    });
}

- (void)tick
{
    if (_busy) return;   // 上一帧还没跑完就跳过，避免堆积
    TDConfig *cfg = [TDConfig shared];
    if (!cfg.enabled) return;

    _busy = YES;

    CGSize fb = [[TDEngine shared] screenFramebufferSize];
    CGRect fbRect = [cfg framebufferRectForCaptureSize:fb];

    __weak typeof(self) weakSelf = self;
    dispatch_async(_workQueue, ^{
        TDResult *r = [[TDEngine shared] recognizeRect:fbRect debugPath:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_busy = NO;
            [strongSelf applyResult:r];
        });
    });
}

- (void)setStatusText:(NSString *)text
{
    // 只改文字，不触发重新布局（宽度已固定）
    _statusLabel.text = text ?: @"";
}

- (void)applyResult:(TDResult *)r
{
    if (!_loggedFirst) {
        _loggedFirst = YES;
        TDLog(@"悬浮窗首帧：status=%ld text=%@ 截屏 %.0fms OCR %.0fms",
              (long)r.status, r.text ?: @"", r.captureMs, r.ocrMs);
    }

    if (r.status == TDStatusCaptureFailed) {
        _captureFailStreak++;
        if (_captureFailStreak == 1 || _captureFailStreak % 20 == 0) {
            os_log_error(OS_LOG_DEFAULT, "[TD] 截屏失败: %{public}@", r.detail);
        }
        [self setStatusText:@"截屏失败"];
        _timeLabel.text = @"--:--";
        return;
    }
    _captureFailStreak = 0;

    if (r.status == TDStatusNoText) {
        // 连续几次都读不到 —— 大概率是倒计时文字消失了（解锁/开售）
        _emptyStreak++;
        if (_emptyStreak >= 3) {
            _timeLabel.text = @"已解锁";
            _timeLabel.textColor = [UIColor colorWithRed:0.36 green:0.92 blue:0.55 alpha:1.0];
            [self setStatusText:@"区域内已无倒计时文字"];
            _lastValue = -1;
            _lastStamp = 0;
        }
        return;
    }

    _emptyStreak = 0;

    if (r.status == TDStatusParseFailed) {
        [self setStatusText:[NSString stringWithFormat:@"识别到: %@", r.text]];
        return;
    }

    if (r.status != TDStatusOK) return;

    NSInteger value = r.remaining;
    NSTimeInterval now = r.timestamp;

    // 合理性过滤：正常的倒计时读数只应该随时间下降。
    // 明显偏大的读数基本是 OCR 认错了数字，直接丢弃。
    if (_lastValue >= 0 && _lastStamp > 0) {
        NSInteger elapsed = (NSInteger)(now - _lastStamp);
        if (elapsed < 0) elapsed = 0;
        NSInteger expected = _lastValue - elapsed;
        if (expected < 0) expected = 0;
        if (value - expected > 8) {
            _rejectStreak++;
            if (_rejectStreak < 5) return;   // 连续 5 次才接受，避免卡死
        }
    }
    _rejectStreak = 0;

    _lastValue = value;
    _lastStamp = now;

    _timeLabel.textColor = [UIColor whiteColor];
    _timeLabel.text = [r displayTime];

    if ([TDConfig shared].showStatus) {
        [self setStatusText:[NSString stringWithFormat:@"%@ · %.0fms",
                             (r.text.length ? r.text : @""),
                             r.captureMs + r.ocrMs]];
    }
}

@end
