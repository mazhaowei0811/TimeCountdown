#import "SetupViewController.h"
#import "TDConfig.h"
#import "TDEngine.h"
#import "TDLog.h"
#import "HUDHelper.h"

#import <QuartzCore/QuartzCore.h>

#define TD_ACCENT   [UIColor colorWithRed:0.176 green:0.831 blue:0.749 alpha:1.0]
#define TD_CARD     [UIColor colorWithRed:0.090 green:0.114 blue:0.141 alpha:1.0]
#define TD_TEXT     [UIColor colorWithRed:0.910 green:0.929 blue:0.953 alpha:1.0]
#define TD_DIM      [UIColor colorWithRed:0.545 green:0.596 blue:0.667 alpha:1.0]

@interface SetupViewController ()
- (UILabel *)sectionTitle:(NSString *)text;
- (UILabel *)hintLabel:(NSString *)text;
- (UILabel *)fieldLabel:(NSString *)text;
- (UIView *)cardWithViews:(NSArray<UIView *> *)views;
- (UIStackView *)rowWithViews:(NSArray<UIView *> *)views;
- (UITextField *)numberField;
- (UIButton *)plainButton:(NSString *)title;
- (UIView *)sliderRowTitle:(NSString *)title slider:(UISlider *)slider valueLab:(UILabel *)valueLab;
- (UIView *)switchRowTitle:(NSString *)title toggle:(UISwitch *)toggle;
- (void)buildStatusCard;
- (void)buildRegionCard;
- (void)buildHudCard;
- (void)buildActionCard;
- (void)buildLogCard;
- (void)loadFromConfig;
- (void)sliderChanged;
- (void)writeToConfig;
- (void)saveConfig;
- (void)refreshHUDState;
- (void)toggleHUD;
- (void)runTest;
- (void)showTestResult:(NSDictionary *)res;
- (void)showHUDLog;
- (void)runProbe;
- (void)clearLog;
@end

@implementation SetupViewController {
    UIScrollView *_scroll;
    UIStackView *_stack;

    UILabel *_hudStatusLabel;
    UIButton *_toggleButton;

    UITextField *_fx, *_fy, *_fw, *_fh;
    UISegmentedControl *_coordSeg;

    UISlider *_fontSlider;      UILabel *_fontValue;
    UISlider *_intervalSlider;  UILabel *_intervalValue;
    UISlider *_posXSlider;      UILabel *_posXValue;
    UISlider *_posYSlider;      UILabel *_posYValue;
    UISwitch *_statusSwitch;
    UISwitch *_borderSwitch;
    UISwitch *_hostSwitch;
    UISwitch *_respawnSwitch;
    UISwitch *_secureSwitch;

    UITextView *_logView;
}

#pragma mark - 生命周期

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"倒计时识别";
    self.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.067 blue:0.086 alpha:1.0];
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationController.navigationBar.tintColor = TD_ACCENT;

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _stack = [[UIStackView alloc] init];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 14;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:16],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:16],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor constant:-16],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-28],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.widthAnchor constant:-32],
    ]];

    [self buildStatusCard];
    [self buildRegionCard];
    [self buildHudCard];
    [self buildActionCard];
    [self buildLogCard];
    [self loadFromConfig];

    // 上次如果连续启动都没跑住，说明系统当时出事了 —— 直接摆在最前面
    int streak = TDBootGuardPeek();
    if (streak >= 3) {
        _logView.text = [NSString stringWithFormat:
                         @"⚠️ 上一次悬浮窗连续启动了 %d 次都没跑住（黑屏转圈）。\n"
                         @"保护机制已经把它停住了。\n\n"
                         @"建议：先把「窗口托管」关掉，点「安全诊断 12s」，\n"
                         @"确认识别本身没问题，再看日志找原因。\n\n"
                         @"──── 运行日志 ────\n%@", streak, TDLogReadAll()];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshHUDState];
}

#pragma mark - 构建界面

- (UILabel *)sectionTitle:(NSString *)text
{
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    l.textColor = TD_DIM;
    return l;
}

- (UIView *)cardWithViews:(NSArray<UIView *> *)views
{
    UIStackView *inner = [[UIStackView alloc] initWithArrangedSubviews:views];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = 10;

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = TD_CARD;
    card.layer.cornerRadius = 14.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    return card;
}

- (UIStackView *)rowWithViews:(NSArray<UIView *> *)views
{
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionFill;
    return row;
}

- (UILabel *)fieldLabel:(NSString *)text
{
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    l.textColor = TD_TEXT;
    [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return l;
}

- (UITextField *)numberField
{
    UITextField *t = [[UITextField alloc] init];
    t.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    t.borderStyle = UITextBorderStyleRoundedRect;
    t.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    t.textColor = TD_TEXT;
    t.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
    t.textAlignment = NSTextAlignmentCenter;
    t.tintColor = TD_ACCENT;
    return t;
}

- (UIButton *)plainButton:(NSString *)title
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    b.tintColor = TD_TEXT;
    b.layer.cornerRadius = 11.0;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    return b;
}

- (UIView *)sliderRowTitle:(NSString *)title
                    slider:(UISlider *)slider
                  valueLab:(UILabel *)valueLab
{
    UILabel *t = [self fieldLabel:title];
    [t setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    valueLab.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    valueLab.textColor = TD_ACCENT;
    valueLab.textAlignment = NSTextAlignmentRight;
    [valueLab.widthAnchor constraintEqualToConstant:46].active = YES;
    [valueLab setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    return [self rowWithViews:@[ t, slider, valueLab ]];
}

- (UIView *)switchRowTitle:(NSString *)title toggle:(UISwitch *)toggle
{
    UILabel *t = [self fieldLabel:title];
    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    toggle.onTintColor = TD_ACCENT;
    return [self rowWithViews:@[ t, spacer, toggle ]];
}

- (void)buildStatusCard
{
    _hudStatusLabel = [[UILabel alloc] init];
    _hudStatusLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _hudStatusLabel.text = @"检测中…";

    _toggleButton = [self plainButton:@"启动悬浮窗"];
    [_toggleButton addTarget:self action:@selector(toggleHUD) forControlEvents:UIControlEventTouchUpInside];
    _toggleButton.tintColor = TD_ACCENT;

    UIView *card = [self cardWithViews:@[ _hudStatusLabel, _toggleButton ]];
    [_stack addArrangedSubview:card];
}

- (void)buildRegionCard
{
    _fx = [self numberField]; _fy = [self numberField];
    _fw = [self numberField]; _fh = [self numberField];

    UIView *r1 = [self rowWithViews:@[ [self fieldLabel:@"X"], _fx,
                                       [self fieldLabel:@"Y"], _fy ]];
    UIView *r2 = [self rowWithViews:@[ [self fieldLabel:@"宽"], _fw,
                                       [self fieldLabel:@"高"], _fh ]];

    _coordSeg = [[UISegmentedControl alloc] initWithItems:@[ @"竖屏", @"横屏·Home右", @"横屏·Home左" ]];
    _coordSeg.selectedSegmentIndex = 1;
    _coordSeg.tintColor = TD_ACCENT;
    if (@available(iOS 13.0, *)) {
        _coordSeg.selectedSegmentTintColor = TD_ACCENT;
        [_coordSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]}
                                 forState:UIControlStateSelected];
        [_coordSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: TD_TEXT}
                                 forState:UIControlStateNormal];
    }

    [_stack addArrangedSubview:[self cardWithViews:@[
        [self sectionTitle:@"识别区域"],
        r1, r2,
        [self sectionTitle:@"坐标所在的坐标系"],
        _coordSeg,
        [self hintLabel:@"屏幕是竖屏就选第一项；横屏时 framebuffer 仍是竖屏朝向，\n所以要告诉程序该往哪个方向转回去。"],
    ]]];
}

- (UILabel *)hintLabel:(NSString *)text
{
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.numberOfLines = 0;
    l.font = [UIFont systemFontOfSize:11.5];
    l.textColor = TD_DIM;
    return l;
}

- (void)buildHudCard
{
    _fontSlider = [[UISlider alloc] init];
    _fontSlider.minimumValue = 16; _fontSlider.maximumValue = 72;
    _fontValue = [[UILabel alloc] init];

    _intervalSlider = [[UISlider alloc] init];
    _intervalSlider.minimumValue = 0.05; _intervalSlider.maximumValue = 1.0;
    _intervalValue = [[UILabel alloc] init];

    _posXSlider = [[UISlider alloc] init];
    _posXSlider.minimumValue = 0.05; _posXSlider.maximumValue = 0.95;
    _posXValue = [[UILabel alloc] init];

    _posYSlider = [[UISlider alloc] init];
    _posYSlider.minimumValue = 0.05; _posYSlider.maximumValue = 0.95;
    _posYValue = [[UILabel alloc] init];

    for (UISlider *s in @[ _fontSlider, _intervalSlider, _posXSlider, _posYSlider ]) {
        s.minimumTrackTintColor = TD_ACCENT;
        s.continuous = NO;
        [s addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
    }

    _statusSwitch = [[UISwitch alloc] init];
    _borderSwitch = [[UISwitch alloc] init];
    _hostSwitch = [[UISwitch alloc] init];
    _respawnSwitch = [[UISwitch alloc] init];
    _secureSwitch = [[UISwitch alloc] init];

    [_stack addArrangedSubview:[self cardWithViews:@[
        [self sectionTitle:@"悬浮窗"],
        [self sliderRowTitle:@"字号" slider:_fontSlider valueLab:_fontValue],
        [self sliderRowTitle:@"采样间隔" slider:_intervalSlider valueLab:_intervalValue],
        [self sliderRowTitle:@"位置 X" slider:_posXSlider valueLab:_posXValue],
        [self sliderRowTitle:@"位置 Y" slider:_posYSlider valueLab:_posYValue],
        [self switchRowTitle:@"显示状态行" toggle:_statusSwitch],
        [self switchRowTitle:@"调试边框" toggle:_borderSwitch],
        [self sectionTitle:@"高级（不确定就别动）"],
        [self switchRowTitle:@"窗口托管（覆盖其他 App）" toggle:_hostSwitch],
        [self switchRowTitle:@"Respring 后自动重启" toggle:_respawnSwitch],
        [self switchRowTitle:@"使用安全图层" toggle:_secureSwitch],
        [self hintLabel:@"窗口托管是让悬浮窗盖在其他 App 上的唯一办法，\n"
                       @"也是整套东西里最敏感的一步：如果一开悬浮窗就黑屏转圈，\n"
                       @"先把它关掉，再点「安全诊断」看连续识别本身有没有问题。"],
    ]]];
}

- (void)buildActionCard
{
    UIButton *save = [self plainButton:@"保存配置"];
    [save addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventTouchUpInside];

    UIButton *test = [self plainButton:@"测试识别"];
    test.tintColor = TD_ACCENT;
    [test addTarget:self action:@selector(runTest) forControlEvents:UIControlEventTouchUpInside];

    [_stack addArrangedSubview:[self cardWithViews:@[
        [self rowWithViews:@[ save, test ]],
    ]]];
}

- (void)buildLogCard
{
    _logView = [[UITextView alloc] init];
    _logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    _logView.textColor = TD_TEXT;
    _logView.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    _logView.editable = NO;
    _logView.scrollEnabled = YES;
    _logView.layer.cornerRadius = 8.0;
    _logView.text = @"点「测试识别」验证坐标对不对。\n\n自检会以 root 身份起一个临时进程，用和悬浮窗完全相同的方式截屏并 OCR。";
    [_logView.heightAnchor constraintEqualToConstant:240].active = YES;

    UIButton *logBtn = [self plainButton:@"运行日志"];
    [logBtn addTarget:self action:@selector(showHUDLog) forControlEvents:UIControlEventTouchUpInside];

    UIButton *probeBtn = [self plainButton:@"安全诊断 12s"];
    probeBtn.tintColor = TD_ACCENT;
    [probeBtn addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];

    UIButton *clearBtn = [self plainButton:@"清空"];
    [clearBtn addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];

    [_stack addArrangedSubview:[self cardWithViews:@[
        [self sectionTitle:@"结果 / 日志"],
        _logView,
        [self rowWithViews:@[ logBtn, probeBtn, clearBtn ]],
        [self hintLabel:@"「安全诊断」会以 root 起一个临时进程，连续识别 12 秒后自己退出，\n"
                       @"不建悬浮窗、也不挂 SpringBoard —— 用来判断问题出在识别本身\n"
                       @"还是出在把窗口挂进系统这一步。"],
    ]]];
}

- (void)showHUDLog
{
    _logView.text = TDLogReadAll();
    [_logView setContentOffset:CGPointZero animated:NO];
}

- (void)clearLog
{
    TDLogClear();
    _logView.text = @"日志已清空。";
}

- (void)runProbe
{
    [self.view endEditing:YES];
    [self writeToConfig];
    [[TDConfig shared] save];

    _logView.text = @"安全诊断中…约 12 秒，请不要退出这个页面。";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int code = TDRunSelfSync(@ "-probe");
        dispatch_async(dispatch_get_main_queue(), ^{
            _logView.text = [NSString stringWithFormat:
                             @"安全诊断结束（子进程退出码 %d）。\n"
                             @"下面是完整运行日志的末尾：\n\n%@",
                             code, TDLogReadAll()];
        });
    });
}

#pragma mark - 读写配置

- (void)loadFromConfig
{
    TDConfig *c = [TDConfig shared];
    [c reload];

    _fx.text = [NSString stringWithFormat:@"%.0f", c.regionX];
    _fy.text = [NSString stringWithFormat:@"%.0f", c.regionY];
    _fw.text = [NSString stringWithFormat:@"%.0f", c.regionW];
    _fh.text = [NSString stringWithFormat:@"%.0f", c.regionH];

    if ([c.coordSpace isEqualToString:TDCoordSpacePortrait])
        _coordSeg.selectedSegmentIndex = 0;
    else if ([c.coordSpace isEqualToString:TDCoordSpaceLandscapeLeft])
        _coordSeg.selectedSegmentIndex = 2;
    else
        _coordSeg.selectedSegmentIndex = 1;

    _fontSlider.value = c.fontSize;
    _intervalSlider.value = c.interval;
    _posXSlider.value = c.hudNormX;
    _posYSlider.value = c.hudNormY;
    _statusSwitch.on = c.showStatus;
    _borderSwitch.on = c.debugBorder;
    _hostSwitch.on = c.systemWindowHosting;
    _respawnSwitch.on = c.respawnOnRespring;
    _secureSwitch.on = c.secureWindow;

    [self sliderChanged];
}

- (void)sliderChanged
{
    _fontValue.text = [NSString stringWithFormat:@"%.0f", _fontSlider.value];
    _intervalValue.text = [NSString stringWithFormat:@"%.2f", _intervalSlider.value];
    _posXValue.text = [NSString stringWithFormat:@"%.2f", _posXSlider.value];
    _posYValue.text = [NSString stringWithFormat:@"%.2f", _posYSlider.value];
}

- (void)writeToConfig
{
    TDConfig *c = [TDConfig shared];

    double x = _fx.text.doubleValue, y = _fy.text.doubleValue;
    double w = _fw.text.doubleValue, h = _fh.text.doubleValue;
    if (w > 0) c.regionW = w;
    if (h > 0) c.regionH = h;
    c.regionX = x;
    c.regionY = y;

    NSInteger idx = _coordSeg.selectedSegmentIndex;
    c.coordSpace = (idx == 0) ? TDCoordSpacePortrait
                 : (idx == 2) ? TDCoordSpaceLandscapeLeft
                              : TDCoordSpaceLandscapeRight;

    c.fontSize = _fontSlider.value;
    c.interval = _intervalSlider.value;
    c.hudNormX = _posXSlider.value;
    c.hudNormY = _posYSlider.value;
    c.showStatus = _statusSwitch.on;
    c.debugBorder = _borderSwitch.on;
    c.systemWindowHosting = _hostSwitch.on;
    c.respawnOnRespring = _respawnSwitch.on;
    c.secureWindow = _secureSwitch.on;
}

- (void)saveConfig
{
    [self.view endEditing:YES];
    [self writeToConfig];
    [[TDConfig shared] save];
    [[TDConfig shared] notifyReload];

    _logView.text = [NSString stringWithFormat:
                     @"配置已保存。\n\n区域: (%.0f, %.0f) %.0fx%.0f\n坐标系: %@\n字体: %.0f\n采样间隔: %.2fs",
                     [TDConfig shared].regionX, [TDConfig shared].regionY,
                     [TDConfig shared].regionW, [TDConfig shared].regionH,
                     [_coordSeg titleForSegmentAtIndex:_coordSeg.selectedSegmentIndex],
                     [TDConfig shared].fontSize, [TDConfig shared].interval];
}

#pragma mark - 悬浮窗开关

- (void)refreshHUDState
{
    BOOL on = IsHUDEnabled();
    _hudStatusLabel.text = on ? @"● 悬浮窗运行中" : @"○ 悬浮窗未运行";
    _hudStatusLabel.textColor = on ? TD_ACCENT : [UIColor colorWithWhite:0.6 alpha:1.0];
    [_toggleButton setTitle:(on ? @"停止悬浮窗" : @"启动悬浮窗") forState:UIControlStateNormal];
}

- (void)toggleHUD
{
    [self.view endEditing:YES];
    BOOL on = IsHUDEnabled();

    BOOL target = !on;
    [self writeToConfig];
    [TDConfig shared].enabled = target;
    [[TDConfig shared] save];

    if (target) {
        // 用户明确要开，就把「连续启动」的计数清掉 —— 保护机制只该拦
        // 「自动重启」造成的循环，不该拦人
        TDBootGuardReset();
        TDLog(@"用户手动启动悬浮窗（托管=%d 自动重启=%d 安全图层=%d 间隔=%.2fs）",
              (int)[TDConfig shared].systemWindowHosting,
              (int)[TDConfig shared].respawnOnRespring,
              (int)[TDConfig shared].secureWindow,
              [TDConfig shared].interval);
    } else {
        TDLog(@"用户手动停止悬浮窗");
    }

    _toggleButton.enabled = NO;
    _hudStatusLabel.text = target ? @"启动中…" : @"停止中…";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SetHUDEnabled(target);
        waitForNotification(^{
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_toggleButton.enabled = YES;
                [self refreshHUDState];
            });
        }, target);
    });
}

#pragma mark - 自检

- (void)runTest
{
    [self.view endEditing:YES];
    [self writeToConfig];
    [[TDConfig shared] save];

    _logView.text = @"正在自检…（以 root 身份起一个临时进程，约 1~2 秒）";
    TDLog(@"用户发起自检");

    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *outPath = [caches stringByAppendingPathComponent:@"test_result.json"];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int code = TDRunSelfSync(@ "-test");
        NSDictionary *res = [NSDictionary dictionaryWithContentsOfFile:outPath];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![res isKindOfClass:[NSDictionary class]]) {
                self->_logView.text = [NSString stringWithFormat:
                    @"自检没有产出结果（子进程退出码 %d）。\n\n"
                    @"常见原因：应用没有以 TrollStore 安装（缺少 root helper 权限），"
                    @"或者 / 目录不可写。", code];
                return;
            }
            [self showTestResult:res];
        });
    });
}

- (void)showTestResult:(NSDictionary *)res
{
    NSInteger status = [res[@"status"] integerValue];
    NSString *text = res[@"text"] ?: @"";
    NSInteger remaining = [res[@"remaining"] integerValue];
    NSString *detail = res[@"detail"] ?: @"";
    double captureMs = [res[@"captureMs"] doubleValue];
    double ocrMs = [res[@"ocrMs"] doubleValue];
    NSString *debugPath = res[@"debugPath"] ?: @"";

    NSString *statusText;
    switch (status) {
        case 1: statusText = @"✅ 识别成功"; break;
        case 2: statusText = @"⚠️ 截到了，但没读到文字"; break;
        case 3: statusText = @"⚠️ 读到文字，但不是倒计时格式"; break;
        case 4: statusText = @"❌ 截屏失败"; break;
        default: statusText = @"❔ 未知状态"; break;
    }

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@\n\n", statusText];
    [s appendFormat:@"OCR 文本: %@\n", text.length ? text : @"（空）"];
    if (status == 1)
        [s appendFormat:@"剩余秒数: %ld  →  %@\n", (long)remaining, res[@"display"] ?: @""];
    if (detail.length)
        [s appendFormat:@"说明: %@\n", detail];
    [s appendFormat:@"\n耗时: 截屏 %.0fms / OCR %.0fms\n", captureMs, ocrMs];
    [s appendFormat:@"framebuffer: %.0f x %.0f\n",
        [res[@"fbWidth"] doubleValue], [res[@"fbHeight"] doubleValue]];
    [s appendFormat:@"实际裁剪: (%.0f, %.0f) %.0f x %.0f\n",
        [res[@"rectX"] doubleValue], [res[@"rectY"] doubleValue],
        [res[@"rectW"] doubleValue], [res[@"rectH"] doubleValue]];
    [s appendFormat:@"\n裁剪图: %@\n", debugPath];
    [s appendFormat:@"全屏校准图: %@\n", res[@"fullDebugPath"] ?: @"（本版没有生成）"];
    [s appendFormat:@"（都在「文件」App 的本应用目录里；全屏图上红框就是当前识别区域，"
                    @"红框没套住倒计时文字就说明坐标要调）"];

    if (status == 2 || status == 3) {
        [s appendString:@"\n提示：先看裁剪图对不对。如果图截错了区域，"
                      @"就把「坐标系」换成另一个横屏选项试试。"];
    }

    _logView.text = s;
}

@end
