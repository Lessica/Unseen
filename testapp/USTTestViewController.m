#import "USTTestViewController.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

static NSString *const USTLocalSimulationKey = @"USTLocalSimulation";
static const uint32_t USTCaptureHiddenMask = (1U << 1) | (1U << 4);

static UILabel *USTLabel(UIFont *font, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

static BOOL USTSetDisableUpdateMask(CALayer *layer, uint32_t mask) {
    SEL setter = NSSelectorFromString(@"setDisableUpdateMask:");
    if ([layer respondsToSelector:setter]) {
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(layer, setter, mask);
        return YES;
    }

    @try {
        [layer setValue:@(mask) forKey:@"disableUpdateMask"];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static UIView *USTFindSecureCanvas(UIView *root) {
    for (UIView *subview in root.subviews) {
        NSString *className = NSStringFromClass(subview.class);
        if ([className containsString:@"TextLayoutCanvasView"] ||
            [className containsString:@"TextFieldCanvasView"]) {
            return subview;
        }

        UIView *match = USTFindSecureCanvas(subview);
        if (match) {
            return match;
        }
    }
    return nil;
}

@interface USTTestViewController ()

@property(nonatomic, strong) UIStackView *stackView;
@property(nonatomic, strong) UIView *directMaskedContent;
@property(nonatomic, strong) UISwitch *directMaskSwitch;
@property(nonatomic, strong) UILabel *directMaskStatusLabel;
@property(nonatomic, strong) UITextField *secureTextField;
@property(nonatomic, strong) UILabel *secureCanvasStatusLabel;
@property(nonatomic, strong) UILabel *screenshotCountLabel;
@property(nonatomic, strong) UILabel *screenshotLastLabel;
@property(nonatomic, strong) UILabel *captureStateLabel;
@property(nonatomic, strong) UILabel *captureEventLabel;
@property(nonatomic, strong) UILabel *capturePollLabel;
@property(nonatomic, strong) NSTimer *captureTimer;
@property(nonatomic) NSUInteger systemScreenshotCount;
@property(nonatomic) NSUInteger localScreenshotCount;
@property(nonatomic) NSUInteger captureNotificationCount;
@property(nonatomic) NSUInteger capturePollCount;
@property(nonatomic) NSUInteger capturePollTransitionCount;
@property(nonatomic) BOOL hasLastPolledCaptureState;
@property(nonatomic) BOOL lastPolledCaptureState;

@end

@implementation USTTestViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Unseen Test";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    [self buildInterface];
    [self installObservers];
    [self applyDirectMask];
    [self updateScreenshotLabelsWithDate:nil local:NO];
    [self refreshCaptureStateFromNotification:NO];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self applyDirectMask];
    [self installSecureCanvasContent];
    [self startCapturePolling];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.captureTimer invalidate];
    self.captureTimer = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.captureTimer invalidate];
}

#pragma mark - Interface

- (void)buildInterface {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];

    self.stackView = [[UIStackView alloc] init];
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.stackView.axis = UILayoutConstraintAxisVertical;
    self.stackView.spacing = 12.0;
    self.stackView.layoutMargins = UIEdgeInsetsMake(20.0, 16.0, 32.0, 16.0);
    self.stackView.layoutMarginsRelativeArrangement = YES;
    [scrollView addSubview:self.stackView];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stackView.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [self.stackView.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [self.stackView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [self.stackView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [self.stackView.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
    ]];

    UILabel *intro = USTLabel([UIFont preferredFontForTextStyle:UIFontTextStyleBody], UIColor.secondaryLabelColor);
    intro.text = @"这是一个端到端测试器。请分别在关闭与开启 Unseen 后重启渲染服务，再执行同一组截图和录屏操作。";
    [self.stackView addArrangedSubview:intro];

    UILabel *process = USTLabel([UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular],
                                 UIColor.tertiaryLabelColor);
    process.text = [NSString stringWithFormat:@"pid=%d\n%@", getpid(), NSBundle.mainBundle.bundlePath];
    [self.stackView addArrangedSubview:process];

    [self addSectionTitle:@"1. 隐藏画面 / disableUpdateMask"];
    UILabel *maskHelp = [self addBodyText:
        @"下面三张卡片依次是普通参照、直接私有图层标记、secure UITextField 画布。未启用 Unseen 时，后两张应从截图/录屏中消失；启用后应与屏幕上看到的一致。"];
    maskHelp.accessibilityIdentifier = @"mask-help";

    [self.stackView addArrangedSubview:[self referenceCard]];
    [self.stackView addArrangedSubview:[self directMaskCard]];
    [self.stackView addArrangedSubview:[self secureCanvasCard]];

    [self addSectionTitle:@"2. 截图事件"];
    [self addBodyText:@"按下系统截图组合键。未启用过滤时“系统事件”会增加；启用后应保持为 0。本地模拟只验证 App 的观察者仍然可用，不经过 SpringBoard。"];

    UIView *screenshotStatus = [self statusPanel];
    UIStackView *screenshotStack = [self verticalStackInView:screenshotStatus];
    self.screenshotCountLabel = USTLabel([UIFont monospacedSystemFontOfSize:16.0 weight:UIFontWeightSemibold],
                                         UIColor.labelColor);
    self.screenshotLastLabel = USTLabel([UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
                                        UIColor.secondaryLabelColor);
    [screenshotStack addArrangedSubview:self.screenshotCountLabel];
    [screenshotStack addArrangedSubview:self.screenshotLastLabel];
    [self.stackView addArrangedSubview:screenshotStatus];

    UIStackView *screenshotButtons = [self horizontalButtonRow];
    [screenshotButtons addArrangedSubview:[self buttonWithTitle:@"本地模拟通知"
                                                         action:@selector(simulateScreenshotNotification:)]];
    [screenshotButtons addArrangedSubview:[self buttonWithTitle:@"清零"
                                                         action:@selector(resetScreenshotCounters:)]];
    [self.stackView addArrangedSubview:screenshotButtons];

    [self addSectionTitle:@"3. 录屏 / 投放状态"];
    [self addBodyText:@"从控制中心开始录屏，或用 QuickTime/隔空播放镜像。未启用屏蔽时状态应变为“正在捕获”并产生通知；启用后状态应保持“未捕获”，通知和轮询变化数均不增加。"];

    UIView *captureStatus = [self statusPanel];
    UIStackView *captureStack = [self verticalStackInView:captureStatus];
    self.captureStateLabel = USTLabel([UIFont preferredFontForTextStyle:UIFontTextStyleTitle3], UIColor.labelColor);
    self.captureStateLabel.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightBold];
    self.captureEventLabel = USTLabel([UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightRegular],
                                      UIColor.secondaryLabelColor);
    self.capturePollLabel = USTLabel([UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular],
                                     UIColor.tertiaryLabelColor);
    [captureStack addArrangedSubview:self.captureStateLabel];
    [captureStack addArrangedSubview:self.captureEventLabel];
    [captureStack addArrangedSubview:self.capturePollLabel];
    [self.stackView addArrangedSubview:captureStatus];
    [self.stackView addArrangedSubview:[self buttonWithTitle:@"重置录屏计数"
                                                    action:@selector(resetCaptureCounters:)]];

    [self addSectionTitle:@"判定矩阵"];
    [self addBodyText:
        @"基线（总开关关闭）：紫色/橙色内容在成片中不可见；系统截图事件 +1；录屏状态为正在捕获。\n\nUnseen 全开：紫色/橙色内容在成片中可见；系统截图事件保持 0；录屏状态保持未捕获。设置改变后必须重启 backboardd 与 SpringBoard。"];
}

- (void)addSectionTitle:(NSString *)title {
    UILabel *label = USTLabel([UIFont preferredFontForTextStyle:UIFontTextStyleHeadline], UIColor.labelColor);
    label.text = title;
    [self.stackView setCustomSpacing:28.0 afterView:self.stackView.arrangedSubviews.lastObject];
    [self.stackView addArrangedSubview:label];
}

- (UILabel *)addBodyText:(NSString *)text {
    UILabel *label = USTLabel([UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline],
                              UIColor.secondaryLabelColor);
    label.text = text;
    [self.stackView addArrangedSubview:label];
    return label;
}

- (UIView *)referenceCard {
    return [self visualCardWithColor:[UIColor colorWithRed:0.05 green:0.53 blue:0.45 alpha:1.0]
                                title:@"普通参照 • ALWAYS VISIBLE"
                             subtitle:@"截图和录屏中应始终存在"];
}

- (UIView *)directMaskCard {
    UIView *container = [self cardContainer];
    self.directMaskedContent = [self visualCardWithColor:[UIColor colorWithRed:0.42 green:0.28 blue:0.82 alpha:1.0]
                                                    title:@"私有图层 • MASK 0x12"
                                                 subtitle:@"Unseen 开启后应出现在成片中"];
    self.directMaskedContent.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.directMaskedContent];

    [NSLayoutConstraint activateConstraints:@[
        [self.directMaskedContent.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8.0],
        [self.directMaskedContent.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8.0],
        [self.directMaskedContent.topAnchor constraintEqualToAnchor:container.topAnchor constant:8.0],
        [self.directMaskedContent.heightAnchor constraintEqualToConstant:92.0],
    ]];

    UIStackView *controls = [[UIStackView alloc] init];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.alignment = UIStackViewAlignmentCenter;
    controls.spacing = 8.0;
    [container addSubview:controls];

    self.directMaskStatusLabel = USTLabel([UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
                                          UIColor.secondaryLabelColor);
    self.directMaskStatusLabel.text = @"正在检测私有属性…";
    self.directMaskSwitch = [[UISwitch alloc] init];
    self.directMaskSwitch.on = YES;
    [self.directMaskSwitch addTarget:self action:@selector(directMaskSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [controls addArrangedSubview:self.directMaskStatusLabel];
    [controls addArrangedSubview:self.directMaskSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [controls.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
        [controls.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],
        [controls.topAnchor constraintEqualToAnchor:self.directMaskedContent.bottomAnchor constant:8.0],
        [controls.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0],
    ]];
    return container;
}

- (UIView *)secureCanvasCard {
    UIView *container = [self cardContainer];
    UIView *host = [[UIView alloc] init];
    host.translatesAutoresizingMaskIntoConstraints = NO;
    host.backgroundColor = UIColor.clearColor;
    [container addSubview:host];

    self.secureTextField = [[UITextField alloc] init];
    self.secureTextField.translatesAutoresizingMaskIntoConstraints = NO;
    self.secureTextField.secureTextEntry = YES;
    self.secureTextField.userInteractionEnabled = NO;
    self.secureTextField.backgroundColor = UIColor.clearColor;
    self.secureTextField.textColor = UIColor.clearColor;
    self.secureTextField.tintColor = UIColor.clearColor;
    [host addSubview:self.secureTextField];

    self.secureCanvasStatusLabel = USTLabel([UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
                                            UIColor.secondaryLabelColor);
    self.secureCanvasStatusLabel.text = @"正在查找 secure canvas…";
    [container addSubview:self.secureCanvasStatusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [host.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8.0],
        [host.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8.0],
        [host.topAnchor constraintEqualToAnchor:container.topAnchor constant:8.0],
        [host.heightAnchor constraintEqualToConstant:92.0],
        [self.secureTextField.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [self.secureTextField.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [self.secureTextField.topAnchor constraintEqualToAnchor:host.topAnchor],
        [self.secureTextField.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [self.secureCanvasStatusLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
        [self.secureCanvasStatusLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],
        [self.secureCanvasStatusLabel.topAnchor constraintEqualToAnchor:host.bottomAnchor constant:8.0],
        [self.secureCanvasStatusLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-12.0],
    ]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self installSecureCanvasContent];
    });
    return container;
}

- (void)installSecureCanvasContent {
    [self.secureTextField layoutIfNeeded];
    UIView *canvas = USTFindSecureCanvas(self.secureTextField);
    if (!canvas) {
        id delegate = self.secureTextField.layer.sublayers.firstObject.delegate;
        if ([delegate isKindOfClass:[UIView class]]) {
            canvas = delegate;
        }
    }

    if (!canvas) {
        self.secureCanvasStatusLabel.text = @"secure canvas 不可用（此系统版本不支持该测试）";
        self.secureCanvasStatusLabel.textColor = UIColor.systemRedColor;
        return;
    }

    UIView *existing = [canvas viewWithTag:8202];
    if (!existing) {
        UIView *content = [self visualCardWithColor:[UIColor colorWithRed:0.94 green:0.38 blue:0.16 alpha:1.0]
                                               title:@"SECURE CANVAS • 7319"
                                            subtitle:@"Unseen 开启后应出现在成片中"];
        content.tag = 8202;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [canvas addSubview:content];
        [canvas bringSubviewToFront:content];
        [NSLayoutConstraint activateConstraints:@[
            [content.leadingAnchor constraintEqualToAnchor:canvas.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:canvas.trailingAnchor],
            [content.topAnchor constraintEqualToAnchor:canvas.topAnchor],
            [content.bottomAnchor constraintEqualToAnchor:canvas.bottomAnchor],
        ]];
    }

    self.secureCanvasStatusLabel.text = [NSString stringWithFormat:@"secure canvas 可用：%@", NSStringFromClass(canvas.class)];
    self.secureCanvasStatusLabel.textColor = UIColor.systemGreenColor;
}

- (UIView *)visualCardWithColor:(UIColor *)color title:(NSString *)title subtitle:(NSString *)subtitle {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = color;
    card.layer.cornerRadius = 14.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    [card.heightAnchor constraintEqualToConstant:92.0].active = YES;

    UIStackView *labels = [self verticalStackInView:card];
    labels.spacing = 4.0;
    labels.layoutMargins = UIEdgeInsetsMake(12.0, 14.0, 12.0, 14.0);
    labels.layoutMarginsRelativeArrangement = YES;

    UILabel *titleLabel = USTLabel([UIFont monospacedSystemFontOfSize:16.0 weight:UIFontWeightBold], UIColor.whiteColor);
    titleLabel.text = title;
    UILabel *subtitleLabel = USTLabel([UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
                                      [UIColor colorWithWhite:1.0 alpha:0.82]);
    subtitleLabel.text = subtitle;
    [labels addArrangedSubview:titleLabel];
    [labels addArrangedSubview:subtitleLabel];
    return card;
}

- (UIView *)cardContainer {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    container.layer.cornerRadius = 16.0;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    return container;
}

- (UIView *)statusPanel {
    UIView *panel = [self cardContainer];
    return panel;
}

- (UIStackView *)verticalStackInView:(UIView *)view {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 7.0;
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-14.0],
        [stack.topAnchor constraintEqualToAnchor:view.topAnchor constant:14.0],
        [stack.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-14.0],
    ]];
    return stack;
}

- (UIStackView *)horizontalButtonRow {
    UIStackView *row = [[UIStackView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 10.0;
    row.distribution = UIStackViewDistributionFillEqually;
    return row;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    button.layer.cornerRadius = 11.0;
    button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:46.0].active = YES;
    return button;
}

#pragma mark - Hidden Content

- (void)directMaskSwitchChanged:(UISwitch *)sender {
    [self applyDirectMask];
}

- (void)applyDirectMask {
    if (!self.directMaskedContent) {
        return;
    }
    uint32_t requestedMask = self.directMaskSwitch.isOn ? USTCaptureHiddenMask : 0;
    BOOL available = USTSetDisableUpdateMask(self.directMaskedContent.layer, requestedMask);
    if (available) {
        self.directMaskStatusLabel.text = [NSString stringWithFormat:@"私有属性可用 • mask=0x%02X", requestedMask];
        self.directMaskStatusLabel.textColor = self.directMaskSwitch.isOn ? UIColor.systemGreenColor
                                                                          : UIColor.secondaryLabelColor;
    } else {
        self.directMaskStatusLabel.text = @"私有属性不可用";
        self.directMaskStatusLabel.textColor = UIColor.systemRedColor;
    }
}

#pragma mark - Screenshot Events

- (void)installObservers {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(didTakeScreenshot:)
                   name:UIApplicationUserDidTakeScreenshotNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(captureStateDidChange:)
                   name:UIScreenCapturedDidChangeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
}

- (void)didTakeScreenshot:(NSNotification *)notification {
    BOOL local = [notification.userInfo[USTLocalSimulationKey] boolValue];
    if (local) {
        self.localScreenshotCount++;
    } else {
        self.systemScreenshotCount++;
    }
    [self updateScreenshotLabelsWithDate:NSDate.date local:local];
}

- (void)simulateScreenshotNotification:(id)sender {
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationUserDidTakeScreenshotNotification
                                                       object:self
                                                     userInfo:@{USTLocalSimulationKey : @YES}];
}

- (void)resetScreenshotCounters:(id)sender {
    self.systemScreenshotCount = 0;
    self.localScreenshotCount = 0;
    [self updateScreenshotLabelsWithDate:nil local:NO];
}

- (void)updateScreenshotLabelsWithDate:(NSDate *)date local:(BOOL)local {
    self.screenshotCountLabel.text = [NSString stringWithFormat:@"系统事件: %lu    本地模拟: %lu",
                                                               (unsigned long)self.systemScreenshotCount,
                                                               (unsigned long)self.localScreenshotCount];
    if (!date) {
        self.screenshotLastLabel.text = @"尚未收到通知";
        return;
    }
    self.screenshotLastLabel.text = [NSString stringWithFormat:@"最近一次：%@ • %@",
                                                               [self timeStringForDate:date],
                                                               local ? @"本地模拟" : @"系统截图"];
}

#pragma mark - Capture State

- (void)startCapturePolling {
    if (self.captureTimer) {
        return;
    }
    self.captureTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                        target:self
                                                      selector:@selector(capturePollTimerFired:)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)captureStateDidChange:(NSNotification *)notification {
    self.captureNotificationCount++;
    [self refreshCaptureStateFromNotification:YES];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self refreshCaptureStateFromNotification:NO];
}

- (void)capturePollTimerFired:(NSTimer *)timer {
    BOOL captured = UIScreen.mainScreen.isCaptured;
    self.capturePollCount++;
    if (self.hasLastPolledCaptureState && captured != self.lastPolledCaptureState) {
        self.capturePollTransitionCount++;
    }
    self.hasLastPolledCaptureState = YES;
    self.lastPolledCaptureState = captured;
    [self updateCaptureLabelsWithCaptured:captured];
}

- (void)refreshCaptureStateFromNotification:(BOOL)notification {
    [self updateCaptureLabelsWithCaptured:UIScreen.mainScreen.isCaptured];
}

- (void)resetCaptureCounters:(id)sender {
    self.captureNotificationCount = 0;
    self.capturePollCount = 0;
    self.capturePollTransitionCount = 0;
    self.hasLastPolledCaptureState = NO;
    [self refreshCaptureStateFromNotification:NO];
}

- (void)updateCaptureLabelsWithCaptured:(BOOL)captured {
    self.captureStateLabel.text = captured ? @"● 正在捕获" : @"● 未捕获";
    self.captureStateLabel.textColor = captured ? UIColor.systemRedColor : UIColor.systemGreenColor;
    self.captureEventLabel.text = [NSString stringWithFormat:@"状态通知: %lu    轮询变化: %lu",
                                                             (unsigned long)self.captureNotificationCount,
                                                             (unsigned long)self.capturePollTransitionCount];
    self.capturePollLabel.text = [NSString stringWithFormat:@"isCaptured=%@ • 已轮询 %lu 次 • %@",
                                                            captured ? @"YES" : @"NO",
                                                            (unsigned long)self.capturePollCount,
                                                            [self timeStringForDate:NSDate.date]];
}

- (NSString *)timeStringForDate:(NSDate *)date {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"HH:mm:ss";
    });
    return [formatter stringFromDate:date];
}

@end
