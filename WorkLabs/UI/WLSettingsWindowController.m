//
//  WLSettingsWindowController.m
//  WorkLabs
//

#import "WLSettingsWindowController.h"
#import <Masonry/Masonry.h>
#import "WLBasicVideoFilter.h"
#import "WLEncoderConfig.h"
#import "WLAudioLevelMeterView.h"
#import "WLLog.h"

// scrollView documentView：翻转坐标系，使内容自上而下排布、初始显示在顶部
@interface WLFlippedView : NSView
@end
@implementation WLFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface WLSettingsWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *fixedCategories;    // 固定分类 {kind,title,symbol,panel}
@property (nonatomic, strong) NSArray<NSDictionary *> *sidebarItems;       // 实际渲染项：固定分类 + group + 各源
@property (nonatomic, strong) NSArray<NSDictionary *> *resolutionPresets;  // {t, w, h}
@property (nonatomic, strong) NSTableView *sidebar;
@property (nonatomic, strong) NSView *contentContainer;
@property (nonatomic, strong) NSArray<NSView *> *panels;                   // 固定面板：画布/背景/推流
@property (nonatomic, strong) NSPopUpButton *resolutionPopup;
@property (nonatomic, strong) NSColorWell *colorWell;
@property (nonatomic, strong) NSTextField *bgImageLabel;
@property (nonatomic, strong) NSTextField *pushURLField;
@property (nonatomic, strong) NSTextField *streamKeyField;
@property (nonatomic, strong) NSTextField *pushSavedLabel;
// 当前正在显示的源属性页
@property (nonatomic, copy, nullable) NSString *currentSourceSID;
@property (nonatomic, strong, nullable) NSSlider *sourceVolSlider;
@property (nonatomic, strong, nullable) NSTextField *sourceVolPercent;
@property (nonatomic, strong, nullable) NSButton *loopCheckbox;
// 电平表（分贝指示）：源属性页可见且源有音频时以 30Hz 轮询宿主刷新
@property (nonatomic, strong, nullable) WLAudioLevelMeterView *sourceLevelMeter;
@property (nonatomic, strong, nullable) NSTextField *sourceLevelDbLabel;
@property (nonatomic, strong, nullable) NSTimer *levelTimer;
// 当前源属性页的滤镜控件（key 见 WLBasicVideoFilter）→ 控件 / 数值标签
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSControl *> *filterControls;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSTextField *> *filterValueLabels;
// 编码页
@property (nonatomic, strong, nullable) WLEncoderConfig *encoderConfig;
@property (nonatomic, strong, nullable) NSSlider *encVideoSlider;
@property (nonatomic, strong, nullable) NSTextField *encVideoLabel;
@property (nonatomic, strong, nullable) NSSlider *encKeyframeSlider;
@property (nonatomic, strong, nullable) NSTextField *encKeyframeLabel;
@property (nonatomic, strong, nullable) NSPopUpButton *encFpsPopup;
@property (nonatomic, strong, nullable) NSPopUpButton *encAudioPopup;
// 测试页
@property (nonatomic, strong, nullable) NSTextField *testStatusLabel;
@property (nonatomic, strong, nullable) NSPopUpButton *logLevelPopup;
@end

@implementation WLSettingsWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 420)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"设置";
    window.minSize = NSMakeSize(560, 360);
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        window.delegate = self;   // windowWillClose: 停电平表轮询

        _currentCanvasSize = CGSizeMake(1920, 1080);
        _fixedCategories = @[
            @{@"kind": @"category", @"title": @"画布", @"symbol": @"display", @"panel": @0},
            @{@"kind": @"category", @"title": @"背景", @"symbol": @"photo",   @"panel": @1},
            @{@"kind": @"category", @"title": @"推流", @"symbol": @"antenna.radiowaves.left.and.right", @"panel": @2},
            @{@"kind": @"category", @"title": @"编码", @"symbol": @"slider.horizontal.3", @"panel": @3},
            @{@"kind": @"category", @"title": @"测试", @"symbol": @"ladybug", @"panel": @4},
        ];
        _resolutionPresets = @[
            @{@"t": @"1280×720 (720p)",   @"w": @1280, @"h": @720},
            @{@"t": @"1920×1080 (1080p)", @"w": @1920, @"h": @1080},
            @{@"t": @"2560×1440 (1440p)", @"w": @2560, @"h": @1440},
            @{@"t": @"1080×1920 (竖屏)",  @"w": @1080, @"h": @1920},
            @{@"t": @"720×1280 (竖屏)",   @"w": @720,  @"h": @1280},
        ];
        [self buildUI];
        [self rebuildSidebarItems];
        [self.sidebar reloadData];
        [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self showFixedPanelAtIndex:0];
    }
    return self;
}

#pragma mark - UI

- (void)buildUI {
    NSView *content = self.window.contentView;

    // 左侧 sidebar（source list 风格）
    NSVisualEffectView *sidebarBG = [[NSVisualEffectView alloc] init];
    sidebarBG.material = NSVisualEffectMaterialSidebar;
    sidebarBG.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    [content addSubview:sidebarBG];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    self.sidebar = [[NSTableView alloc] init];
    self.sidebar.headerView = nil;
    self.sidebar.backgroundColor = [NSColor clearColor];
    self.sidebar.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;
    self.sidebar.rowHeight = 30;
    self.sidebar.dataSource = self;
    self.sidebar.delegate = self;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"cat"];
    col.width = 160;
    [self.sidebar addTableColumn:col];
    scroll.documentView = self.sidebar;
    [sidebarBG addSubview:scroll];

    // 右侧内容容器
    self.contentContainer = [[NSView alloc] init];
    [content addSubview:self.contentContainer];

    [sidebarBG mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.bottom.equalTo(content);
        make.width.equalTo(@180);
    }];
    [scroll mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(sidebarBG).insets(NSEdgeInsetsMake(8, 6, 8, 6));
    }];
    [self.contentContainer mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.bottom.right.equalTo(content);
        make.left.equalTo(sidebarBG.mas_right);
    }];

    self.panels = @[[self buildCanvasPanel], [self buildBackgroundPanel], [self buildPushPanel], [self buildEncoderPanel], [self buildTestPanel]];
}

// 一行：左标题 + 右控件
- (NSView *)rowWithTitle:(NSString *)title control:(NSView *)control {
    NSView *row = [[NSView alloc] init];
    NSTextField *label = [NSTextField labelWithString:title];
    label.alignment = NSTextAlignmentRight;
    [row addSubview:label];
    [row addSubview:control];
    [label mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(row);
        make.centerY.equalTo(control);
        make.width.equalTo(@90);
    }];
    [control mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(label.mas_right).offset(12);
        make.top.bottom.equalTo(row);
        make.right.lessThanOrEqualTo(row);
    }];
    return row;
}

- (NSView *)buildCanvasPanel {
    NSView *panel = [[NSView alloc] init];

    self.resolutionPopup = [[NSPopUpButton alloc] init];
    for (NSDictionary *p in self.resolutionPresets) {
        [self.resolutionPopup addItemWithTitle:p[@"t"]];
        self.resolutionPopup.lastItem.representedObject = p;
    }
    self.resolutionPopup.target = self;
    self.resolutionPopup.action = @selector(resolutionChanged:);

    NSView *row = [self rowWithTitle:@"分辨率" control:self.resolutionPopup];
    [panel addSubview:row];
    [row mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(panel).offset(24);
        make.left.equalTo(panel).offset(24);
        make.right.equalTo(panel).offset(-24);
        make.height.equalTo(@24);
    }];
    return panel;
}

- (NSView *)buildBackgroundPanel {
    NSView *panel = [[NSView alloc] init];

    // 背景颜色
    self.colorWell = [[NSColorWell alloc] init];
    self.colorWell.color = [NSColor colorWithWhite:0.1 alpha:1.0];
    self.colorWell.target = self;
    self.colorWell.action = @selector(colorWellChanged:);
    NSView *colorRow = [self rowWithTitle:@"背景颜色" control:self.colorWell];
    [self.colorWell mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.equalTo(@48); make.height.equalTo(@24);
    }];

    // 背景图片
    NSButton *chooseBtn = [NSButton buttonWithTitle:@"选择图片…" target:self action:@selector(chooseBgImage:)];
    self.bgImageLabel = [NSTextField labelWithString:@"未选择"];
    self.bgImageLabel.textColor = [NSColor secondaryLabelColor];
    NSStackView *imgStack = [NSStackView stackViewWithViews:@[chooseBtn, self.bgImageLabel]];
    imgStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    imgStack.spacing = 10;
    imgStack.alignment = NSLayoutAttributeCenterY;
    NSView *imgRow = [self rowWithTitle:@"背景图片" control:imgStack];

    // 清除背景
    NSButton *clearBtn = [NSButton buttonWithTitle:@"清除背景" target:self action:@selector(clearBg:)];
    NSView *clearRow = [self rowWithTitle:@"" control:clearBtn];

    [panel addSubview:colorRow];
    [panel addSubview:imgRow];
    [panel addSubview:clearRow];
    [colorRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(panel).offset(24);
        make.left.equalTo(panel).offset(24);
        make.right.equalTo(panel).offset(-24);
        make.height.equalTo(@24);
    }];
    [imgRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(colorRow.mas_bottom).offset(16);
        make.left.right.equalTo(colorRow);
        make.height.equalTo(@24);
    }];
    [clearRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(imgRow.mas_bottom).offset(16);
        make.left.right.equalTo(colorRow);
        make.height.equalTo(@24);
    }];
    return panel;
}

- (NSView *)buildPushPanel {
    NSView *panel = [[NSView alloc] init];

    self.pushURLField = [[NSTextField alloc] init];
    self.pushURLField.placeholderString = @"rtmp://server/app";
    NSView *urlRow = [self rowWithTitle:@"推流地址" control:self.pushURLField];
    [self.pushURLField mas_makeConstraints:^(MASConstraintMaker *make) {
        make.right.equalTo(urlRow);
    }];

    self.streamKeyField = [[NSTextField alloc] init];
    self.streamKeyField.placeholderString = @"推流码 / Stream Key";
    NSView *keyRow = [self rowWithTitle:@"密钥" control:self.streamKeyField];
    [self.streamKeyField mas_makeConstraints:^(MASConstraintMaker *make) {
        make.right.equalTo(keyRow);
    }];

    NSTextField *hint = [NSTextField labelWithString:@"完整推流地址 = 推流地址 / 密钥；密钥留空则直接使用推流地址。"];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.font = [NSFont systemFontOfSize:11];
    hint.lineBreakMode = NSLineBreakByWordWrapping;
    hint.maximumNumberOfLines = 0;

    // 保存按钮（回车即可触发）+ 保存反馈
    NSButton *saveBtn = [NSButton buttonWithTitle:@"保存" target:self action:@selector(savePushSettings:)];
    saveBtn.keyEquivalent = @"\r";
    self.pushSavedLabel = [NSTextField labelWithString:@""];
    self.pushSavedLabel.textColor = [NSColor systemGreenColor];
    self.pushSavedLabel.font = [NSFont systemFontOfSize:12];

    [panel addSubview:urlRow];
    [panel addSubview:keyRow];
    [panel addSubview:hint];
    [panel addSubview:saveBtn];
    [panel addSubview:self.pushSavedLabel];
    [urlRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(panel).offset(24);
        make.left.equalTo(panel).offset(24);
        make.right.equalTo(panel).offset(-24);
        make.height.equalTo(@24);
    }];
    [keyRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(urlRow.mas_bottom).offset(16);
        make.left.right.equalTo(urlRow);
        make.height.equalTo(@24);
    }];
    [hint mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(keyRow.mas_bottom).offset(16);
        make.left.equalTo(urlRow).offset(102);
        make.right.equalTo(urlRow);
    }];
    [saveBtn mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(hint.mas_bottom).offset(20);
        make.right.equalTo(urlRow);
    }];
    [self.pushSavedLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(saveBtn);
        make.right.equalTo(saveBtn.mas_left).offset(-10);
    }];
    return panel;
}

#pragma mark - 编码页（码率/关键帧间隔/帧率/音频码率，推流 + 录制共用）

- (NSView *)buildEncoderPanel {
    NSView *panel = [[NSView alloc] init];

    WLEncoderConfig *c = nil;
    if ([self.settingsDelegate respondsToSelector:@selector(settingsEncoderConfig)]) {
        c = [self.settingsDelegate settingsEncoderConfig];
    }
    if (!c) c = [WLEncoderConfig defaultConfig];
    self.encoderConfig = c;

    // 视频码率（Mbps）
    double mbps = c.videoBitrate / 1.0e6; if (mbps < 1) mbps = 8;
    self.encVideoLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%.1f Mbps", mbps]];
    self.encVideoSlider = [NSSlider sliderWithValue:mbps minValue:1 maxValue:20
                                             target:self action:@selector(encoderControlChanged:)];
    NSView *vRow = [self encSliderRow:@"视频码率" slider:self.encVideoSlider value:self.encVideoLabel resetID:@"video"];

    // 关键帧间隔（秒）
    self.encKeyframeLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%d 秒", c.keyframeIntervalSeconds]];
    self.encKeyframeSlider = [NSSlider sliderWithValue:c.keyframeIntervalSeconds minValue:1 maxValue:10
                                                target:self action:@selector(encoderControlChanged:)];
    self.encKeyframeSlider.numberOfTickMarks = 10;
    self.encKeyframeSlider.allowsTickMarkValuesOnly = YES;
    NSView *kRow = [self encSliderRow:@"关键帧间隔" slider:self.encKeyframeSlider value:self.encKeyframeLabel resetID:@"keyframe"];

    // 帧率
    self.encFpsPopup = [[NSPopUpButton alloc] init];
    for (NSNumber *f in @[@24, @25, @30, @48, @50, @60]) {
        [self.encFpsPopup addItemWithTitle:[NSString stringWithFormat:@"%@ fps", f]];
        self.encFpsPopup.lastItem.representedObject = f;
    }
    [self selectPopup:self.encFpsPopup value:@(c.fps)];
    self.encFpsPopup.target = self;
    self.encFpsPopup.action = @selector(encoderControlChanged:);
    NSView *fRow = [self rowWithTitle:@"帧率" control:self.encFpsPopup];

    // 音频码率
    self.encAudioPopup = [[NSPopUpButton alloc] init];
    for (NSNumber *kb in @[@96, @128, @160, @192, @256]) {
        [self.encAudioPopup addItemWithTitle:[NSString stringWithFormat:@"%@ kbps", kb]];
        self.encAudioPopup.lastItem.representedObject = @(kb.intValue * 1000);
    }
    [self selectPopup:self.encAudioPopup value:@(c.audioBitrate)];
    self.encAudioPopup.target = self;
    self.encAudioPopup.action = @selector(encoderControlChanged:);
    NSView *aRow = [self rowWithTitle:@"音频码率" control:self.encAudioPopup];

    NSTextField *hint = [NSTextField labelWithString:@"编码参数在下次开始录制 / 推流时生效；推流与录制共用同一套。"];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.font = [NSFont systemFontOfSize:11];
    hint.lineBreakMode = NSLineBreakByWordWrapping;
    hint.maximumNumberOfLines = 0;

    [panel addSubview:vRow];
    [panel addSubview:kRow];
    [panel addSubview:fRow];
    [panel addSubview:aRow];
    [panel addSubview:hint];
    [vRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(panel).offset(24);
        make.left.equalTo(panel).offset(24);
        make.right.equalTo(panel).offset(-24);
        make.height.equalTo(@24);
    }];
    [kRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(vRow.mas_bottom).offset(16);
        make.left.right.equalTo(vRow);
        make.height.equalTo(@24);
    }];
    [fRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(kRow.mas_bottom).offset(16);
        make.left.right.equalTo(vRow);
        make.height.equalTo(@24);
    }];
    [aRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(fRow.mas_bottom).offset(16);
        make.left.right.equalTo(vRow);
        make.height.equalTo(@24);
    }];
    [hint mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(aRow.mas_bottom).offset(18);
        make.left.equalTo(vRow).offset(102);
        make.right.equalTo(vRow);
    }];
    return panel;
}

#pragma mark - 测试页（调试 / 验证入口）

- (NSView *)buildTestPanel {
    NSView *panel = [[NSView alloc] init];

    NSButton *testBtn = [NSButton buttonWithTitle:@"模拟断流 3 秒" target:self action:@selector(testButtonClicked:)];
    testBtn.bezelStyle = NSBezelStyleRounded;

    self.testStatusLabel = [NSTextField labelWithString:@"录制中点击：人为制造 3 秒音频断流。"];
    self.testStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.testStatusLabel.font = [NSFont systemFontOfSize:11];

    NSTextField *hint = [NSTextField labelWithString:@"调试 / 验证入口。「模拟断流 3 秒」：录制时点击，混音器丢弃 3 秒输入，验证隐患 B（断流补静音、音视频不漂）。后续测试项可继续加到本页。"];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.font = [NSFont systemFontOfSize:11];
    hint.lineBreakMode = NSLineBreakByWordWrapping;
    hint.maximumNumberOfLines = 0;

    // 日志等级
    self.logLevelPopup = [[NSPopUpButton alloc] init];
    NSArray<NSDictionary *> *levels = @[
        @{@"t": @"错误 (Error)",   @"v": @(WLLogLevelError)},
        @{@"t": @"警告 (Warn)",    @"v": @(WLLogLevelWarn)},
        @{@"t": @"信息 (Info)",    @"v": @(WLLogLevelInfo)},
        @{@"t": @"调试 (Debug)",   @"v": @(WLLogLevelDebug)},
        @{@"t": @"详细 (Verbose)", @"v": @(WLLogLevelVerbose)},
    ];
    for (NSDictionary *l in levels) {
        [self.logLevelPopup addItemWithTitle:l[@"t"]];
        self.logLevelPopup.lastItem.representedObject = l[@"v"];
    }
    [self selectPopup:self.logLevelPopup value:@([WLLog globalLevel])];
    self.logLevelPopup.target = self;
    self.logLevelPopup.action = @selector(logLevelChanged:);
    NSView *logRow = [self rowWithTitle:@"日志等级" control:self.logLevelPopup];

    NSTextField *logHint = [NSTextField labelWithString:@"低于所选等级的日志不输出，立即生效并持久保存。注：调试/详细 两档的日志在 Release 构建被编译裁剪。"];
    logHint.textColor = [NSColor secondaryLabelColor];
    logHint.font = [NSFont systemFontOfSize:11];
    logHint.lineBreakMode = NSLineBreakByWordWrapping;
    logHint.maximumNumberOfLines = 0;

    [panel addSubview:testBtn];
    [panel addSubview:self.testStatusLabel];
    [panel addSubview:hint];
    [panel addSubview:logRow];
    [panel addSubview:logHint];
    [testBtn mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(panel).offset(24);
        make.left.equalTo(panel).offset(24);
    }];
    [self.testStatusLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(testBtn);
        make.left.equalTo(testBtn.mas_right).offset(12);
        make.right.lessThanOrEqualTo(panel).offset(-24);
    }];
    [hint mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(testBtn.mas_bottom).offset(18);
        make.left.equalTo(panel).offset(24);
        make.right.equalTo(panel).offset(-24);
    }];
    [logRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(hint.mas_bottom).offset(24);
        make.left.equalTo(panel).offset(24);
        make.right.equalTo(panel).offset(-24);
        make.height.equalTo(@24);
    }];
    [logHint mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(logRow.mas_bottom).offset(8);
        make.left.equalTo(logRow).offset(102);
        make.right.equalTo(logRow);
    }];
    return panel;
}

- (void)logLevelChanged:(NSPopUpButton *)sender {
    NSNumber *v = sender.selectedItem.representedObject;
    if (![v isKindOfClass:[NSNumber class]]) return;
    [WLLog setGlobalLevelPersisted:(WLLogLevel)v.integerValue];
    WLLogI(@"Settings", @"日志等级 → %@", sender.selectedItem.title);
}

- (void)testButtonClicked:(id)sender {
    NSTimeInterval gap = 3.0;
    if ([self.settingsDelegate respondsToSelector:@selector(settingsDidRequestSimulateAudioGap:)]) {
        [self.settingsDelegate settingsDidRequestSimulateAudioGap:gap];
        self.testStatusLabel.stringValue = [NSString stringWithFormat:@"已触发模拟断流 %.0f 秒（录制中可观察音频补静音）", gap];
    } else {
        self.testStatusLabel.stringValue = @"未连接宿主，无法模拟断流。";
    }
    NSLog(@"[WLSettings] 触发模拟音频断流 %.1f 秒", gap);
}

// 编码页一行滑块：标题 + 滑块(160) + 数值(72) + 恢复默认小按钮
- (NSView *)encSliderRow:(NSString *)title slider:(NSSlider *)slider value:(NSTextField *)value resetID:(NSString *)resetID {
    [slider.widthAnchor constraintEqualToConstant:160].active = YES;
    [value.widthAnchor constraintEqualToConstant:72].active = YES;
    NSButton *reset = [self resetButtonWithAction:@selector(resetEncoderSlider:) identifier:resetID];
    NSStackView *stack = [NSStackView stackViewWithViews:@[slider, value, reset]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing = 10;
    stack.alignment = NSLayoutAttributeCenterY;
    return [self rowWithTitle:title control:stack];
}

- (void)selectPopup:(NSPopUpButton *)popup value:(NSNumber *)value {
    for (NSMenuItem *it in popup.itemArray) {
        if ([it.representedObject isEqual:value]) { [popup selectItem:it]; return; }
    }
}

- (void)encoderControlChanged:(id)sender {
    WLEncoderConfig *c = self.encoderConfig;
    if (!c) return;
    double mbps = self.encVideoSlider.doubleValue;
    c.videoBitrate = (int)llround(mbps * 1.0e6);
    self.encVideoLabel.stringValue = [NSString stringWithFormat:@"%.1f Mbps", mbps];
    int kf = (int)llround(self.encKeyframeSlider.doubleValue);
    c.keyframeIntervalSeconds = kf;
    self.encKeyframeLabel.stringValue = [NSString stringWithFormat:@"%d 秒", kf];
    c.fps = [[self.encFpsPopup.selectedItem representedObject] intValue];
    c.audioBitrate = [[self.encAudioPopup.selectedItem representedObject] intValue];
    if ([self.settingsDelegate respondsToSelector:@selector(settingsDidUpdateEncoderConfig:)]) {
        [self.settingsDelegate settingsDidUpdateEncoderConfig:c];
    }
}

// 单条编码滑块复位到默认值（identifier 区分 video / keyframe）
- (void)resetEncoderSlider:(NSButton *)sender {
    WLEncoderConfig *def = [WLEncoderConfig defaultConfig];
    NSString *which = (NSString *)sender.identifier;
    if ([which isEqualToString:@"video"]) {
        self.encVideoSlider.doubleValue = def.videoBitrate / 1.0e6;
    } else if ([which isEqualToString:@"keyframe"]) {
        self.encKeyframeSlider.doubleValue = def.keyframeIntervalSeconds;
    }
    [self encoderControlChanged:nil];
}

// 标题 + 滑块 + 百分比 的一行（音量用）
- (NSView *)volumeRowTitle:(NSString *)title slider:(NSSlider *)slider percent:(NSTextField *)percent {
    [slider.widthAnchor constraintEqualToConstant:160].active = YES;
    [percent.widthAnchor constraintEqualToConstant:44].active = YES;
    NSStackView *stack = [NSStackView stackViewWithViews:@[slider, percent]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing = 10;
    stack.alignment = NSLayoutAttributeCenterY;
    return [self rowWithTitle:title control:stack];
}

#pragma mark - 源属性页（每个流的配置容器：音量 + 基本滤镜）

- (NSView *)buildSourcePanelForItem:(NSDictionary *)item {
    NSString *name = item[@"name"] ?: @"源";
    NSString *sid = item[@"sid"] ?: @"";
    BOOL hasAudio = [item[@"hasAudio"] boolValue];
    WLFromType t = (WLFromType)[item[@"fromType"] integerValue];
    NSString *typeName = (t == WLFromTypeMic) ? @"麦克风"
                       : (t == WLFromTypeCamera) ? @"摄像头" : @"视频文件";
    BOOL isAudioOnly = (t == WLFromTypeMic);   // 纯音频源：只显示音量（及将来音频滤镜），无视频滤镜

    // 当前源滤镜初值（向宿主回读，无则默认）
    NSDictionary *fp = [WLBasicVideoFilter defaultParams];
    if ([self.settingsDelegate respondsToSelector:@selector(settingsFilterParamsForStreamID:)]) {
        NSDictionary *got = [self.settingsDelegate settingsFilterParamsForStreamID:sid];
        if (got.count) fp = got;
    }
    self.filterControls = [NSMutableDictionary dictionary];
    self.filterValueLabels = [NSMutableDictionary dictionary];

    // 滚动容器（控件较多，窗口偏矮时可滚动）
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    WLFlippedView *doc = [[WLFlippedView alloc] init];
    scroll.documentView = doc;

    NSStackView *col = [[NSStackView alloc] init];
    col.orientation = NSUserInterfaceLayoutOrientationVertical;
    col.alignment = NSLayoutAttributeLeading;
    col.spacing = 8;
    col.edgeInsets = NSEdgeInsetsMake(22, 24, 24, 24);
    [doc addSubview:col];

    // —— 标题 ——
    NSTextField *titleLabel = [NSTextField labelWithString:name];
    titleLabel.font = [NSFont boldSystemFontOfSize:15];
    titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSTextField *subLabel = [NSTextField labelWithString:typeName];
    subLabel.textColor = [NSColor secondaryLabelColor];
    subLabel.font = [NSFont systemFontOfSize:11];
    [col addArrangedSubview:titleLabel];
    [col addArrangedSubview:subLabel];
    [col setCustomSpacing:2 afterView:titleLabel];
    [col setCustomSpacing:18 afterView:subLabel];

    // —— 音量 ——
    if (hasAudio) {
        float vol = 1.0f;
        if ([self.settingsDelegate respondsToSelector:@selector(settingsVolumeForStreamID:)]) {
            vol = [self.settingsDelegate settingsVolumeForStreamID:sid];
        }
        NSTextField *vLabel = [NSTextField labelWithString:@"音量"];
        vLabel.alignment = NSTextAlignmentRight;
        [vLabel.widthAnchor constraintEqualToConstant:64].active = YES;
        self.sourceVolSlider = [NSSlider sliderWithValue:vol minValue:0.0 maxValue:2.0
                                                  target:self action:@selector(sourceVolumeChanged:)];
        [self.sourceVolSlider.widthAnchor constraintEqualToConstant:170].active = YES;
        self.sourceVolPercent = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0f%%", vol * 100]];
        [self.sourceVolPercent.widthAnchor constraintEqualToConstant:48].active = YES;
        NSButton *volReset = [self resetButtonWithAction:@selector(resetVolume:) identifier:nil];
        NSStackView *volRow = [NSStackView stackViewWithViews:@[vLabel, self.sourceVolSlider, self.sourceVolPercent, volReset]];
        volRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        volRow.spacing = 8;
        volRow.alignment = NSLayoutAttributeCenterY;
        [col addArrangedSubview:volRow];
        [col setCustomSpacing:8 afterView:volRow];

        // —— 电平（分贝指示）：混音节拍内实测、增益后（拖音量滑块表针随之变化） ——
        NSTextField *mLabel = [NSTextField labelWithString:@"电平"];
        mLabel.alignment = NSTextAlignmentRight;
        [mLabel.widthAnchor constraintEqualToConstant:64].active = YES;
        self.sourceLevelMeter = [[WLAudioLevelMeterView alloc] init];
        [self.sourceLevelMeter.widthAnchor constraintEqualToConstant:170].active = YES;
        [self.sourceLevelMeter.heightAnchor constraintEqualToConstant:8].active = YES;
        self.sourceLevelDbLabel = [NSTextField labelWithString:@"-∞ dB"];
        self.sourceLevelDbLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        self.sourceLevelDbLabel.textColor = [NSColor secondaryLabelColor];
        [self.sourceLevelDbLabel.widthAnchor constraintEqualToConstant:56].active = YES;
        NSStackView *meterRow = [NSStackView stackViewWithViews:@[mLabel, self.sourceLevelMeter, self.sourceLevelDbLabel]];
        meterRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        meterRow.spacing = 8;
        meterRow.alignment = NSLayoutAttributeCenterY;
        [col addArrangedSubview:meterRow];
        [col setCustomSpacing:18 afterView:meterRow];
    } else {
        self.sourceVolSlider = nil;
        self.sourceVolPercent = nil;
        self.sourceLevelMeter = nil;
        self.sourceLevelDbLabel = nil;
    }

    // —— 播放（仅视频文件源：摄像头/麦克风为实时源，无循环概念） ——
    if (t == WLFromTypeMedia) {
        NSButton *loopBox = [NSButton checkboxWithTitle:@"循环播放" target:self action:@selector(loopCheckboxChanged:)];
        BOOL loop = YES;
        if ([self.settingsDelegate respondsToSelector:@selector(settingsLoopEnabledForStreamID:)]) {
            loop = [self.settingsDelegate settingsLoopEnabledForStreamID:sid];
        }
        loopBox.state = loop ? NSControlStateValueOn : NSControlStateValueOff;
        self.loopCheckbox = loopBox;
        [col addArrangedSubview:loopBox];
        [col setCustomSpacing:18 afterView:loopBox];
    } else {
        self.loopCheckbox = nil;
    }

    // —— 视频滤镜（镜像/颜色校正/裁剪）：纯音频源不显示，位置预留给将来的音频滤镜 ——
    if (!isAudioOnly) {
        [self appendVideoFilterControlsToColumn:col params:fp];
    }

    // —— 移除此源 ——（音频源画布上无浮层，删除入口主要靠这里；视频源也多一个入口）
    NSButton *removeBtn = [NSButton buttonWithTitle:@"移除此源" target:self action:@selector(removeCurrentSource:)];
    NSMutableAttributedString *removeTitle =
        [[NSMutableAttributedString alloc] initWithString:@"移除此源"];
    [removeTitle addAttribute:NSForegroundColorAttributeName value:[NSColor systemRedColor]
                        range:NSMakeRange(0, removeTitle.length)];
    removeBtn.attributedTitle = removeTitle;
    [col addArrangedSubview:removeBtn];

    [col mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(doc);
    }];
    [doc mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(scroll.contentView);
        make.width.equalTo(scroll.contentView);
    }];
    return scroll;
}

// 视频滤镜控件区（镜像/颜色校正/裁剪 + 恢复默认）——仅含视频画面的源使用。
// 控件登记到 self.filterControls / filterValueLabels，供 collectFilterParams / 重置复用。
- (void)appendVideoFilterControlsToColumn:(NSStackView *)col params:(NSDictionary *)fp {
    // —— 镜像 ——
    NSTextField *mirrorTitle = [self filterSectionTitle:@"镜像"];
    [col addArrangedSubview:mirrorTitle];
    [col setCustomSpacing:8 afterView:mirrorTitle];
    NSButton *hMir = [NSButton checkboxWithTitle:@"水平翻转" target:self action:@selector(filterControlChanged:)];
    NSButton *vMir = [NSButton checkboxWithTitle:@"垂直翻转" target:self action:@selector(filterControlChanged:)];
    hMir.state = [fp[WLFilterKeyHMirror] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    vMir.state = [fp[WLFilterKeyVMirror] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.filterControls[WLFilterKeyHMirror] = hMir;
    self.filterControls[WLFilterKeyVMirror] = vMir;
    NSStackView *mirRow = [NSStackView stackViewWithViews:@[hMir, vMir]];
    mirRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    mirRow.spacing = 18;
    [col addArrangedSubview:mirRow];
    [col setCustomSpacing:18 afterView:mirRow];

    // —— 颜色校正 ——
    NSTextField *colorTitle = [self filterSectionTitle:@"颜色校正"];
    [col addArrangedSubview:colorTitle];
    [col setCustomSpacing:8 afterView:colorTitle];
    NSView *briRow = [self filterSliderRowTitle:@"亮度"   key:WLFilterKeyBrightness min:-1   max:1   value:[fp[WLFilterKeyBrightness] doubleValue]];
    NSView *conRow = [self filterSliderRowTitle:@"对比度" key:WLFilterKeyContrast   min:0    max:2   value:[fp[WLFilterKeyContrast] doubleValue]];
    NSView *satRow = [self filterSliderRowTitle:@"饱和度" key:WLFilterKeySaturation min:0    max:2   value:[fp[WLFilterKeySaturation] doubleValue]];
    NSView *hueRow = [self filterSliderRowTitle:@"色相"   key:WLFilterKeyHue        min:-180 max:180 value:[fp[WLFilterKeyHue] doubleValue]];
    [col addArrangedSubview:briRow];
    [col addArrangedSubview:conRow];
    [col addArrangedSubview:satRow];
    [col addArrangedSubview:hueRow];
    [col setCustomSpacing:18 afterView:hueRow];

    // —— 裁剪 ——
    NSTextField *cropTitle = [self filterSectionTitle:@"裁剪"];
    [col addArrangedSubview:cropTitle];
    [col setCustomSpacing:8 afterView:cropTitle];
    NSView *cropTopRow = [self filterSliderRowTitle:@"上" key:WLFilterKeyCropTop    min:0 max:0.45 value:[fp[WLFilterKeyCropTop] doubleValue]];
    NSView *cropBotRow = [self filterSliderRowTitle:@"下" key:WLFilterKeyCropBottom min:0 max:0.45 value:[fp[WLFilterKeyCropBottom] doubleValue]];
    NSView *cropLefRow = [self filterSliderRowTitle:@"左" key:WLFilterKeyCropLeft   min:0 max:0.45 value:[fp[WLFilterKeyCropLeft] doubleValue]];
    NSView *cropRigRow = [self filterSliderRowTitle:@"右" key:WLFilterKeyCropRight  min:0 max:0.45 value:[fp[WLFilterKeyCropRight] doubleValue]];
    [col addArrangedSubview:cropTopRow];
    [col addArrangedSubview:cropBotRow];
    [col addArrangedSubview:cropLefRow];
    [col addArrangedSubview:cropRigRow];
    [col setCustomSpacing:18 afterView:cropRigRow];

    // —— 重置 ——
    NSButton *resetBtn = [NSButton buttonWithTitle:@"恢复默认滤镜" target:self action:@selector(resetFilters:)];
    [col addArrangedSubview:resetBtn];
    [col setCustomSpacing:18 afterView:resetBtn];
}

// 滤镜分区标题
- (NSTextField *)filterSectionTitle:(NSString *)title {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont boldSystemFontOfSize:12];
    return label;
}

// 一行滤镜滑块：右对齐标题 + 滑块 + 当前值；控件登记到 filterControls/filterValueLabels
- (NSView *)filterSliderRowTitle:(NSString *)title key:(NSString *)key
                             min:(double)mn max:(double)mx value:(double)val {
    NSTextField *label = [NSTextField labelWithString:title];
    label.alignment = NSTextAlignmentRight;
    [label.widthAnchor constraintEqualToConstant:64].active = YES;
    NSSlider *slider = [NSSlider sliderWithValue:val minValue:mn maxValue:mx
                                          target:self action:@selector(filterControlChanged:)];
    [slider.widthAnchor constraintEqualToConstant:170].active = YES;
    NSTextField *value = [NSTextField labelWithString:[self filterDisplayForKey:key value:val]];
    [value.widthAnchor constraintEqualToConstant:48].active = YES;
    self.filterControls[key] = slider;
    self.filterValueLabels[key] = value;
    NSButton *reset = [self resetButtonWithAction:@selector(resetFilterSlider:) identifier:key];
    NSStackView *row = [NSStackView stackViewWithViews:@[label, slider, value, reset]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.alignment = NSLayoutAttributeCenterY;
    return row;
}

// 数值显示：裁剪→百分比、色相→角度、其余→两位小数
- (NSString *)filterDisplayForKey:(NSString *)key value:(double)v {
    if ([key hasPrefix:@"crop"]) return [NSString stringWithFormat:@"%.0f%%", v * 100];
    if ([key isEqualToString:WLFilterKeyHue]) return [NSString stringWithFormat:@"%.0f°", v];
    return [NSString stringWithFormat:@"%.2f", v];
}

- (void)sourceVolumeChanged:(NSSlider *)sender {
    float v = sender.floatValue;
    self.sourceVolPercent.stringValue = [NSString stringWithFormat:@"%.0f%%", v * 100];
    if (self.currentSourceSID.length > 0 &&
        [self.settingsDelegate respondsToSelector:@selector(settingsDidSetVolume:forStreamID:)]) {
        [self.settingsDelegate settingsDidSetVolume:v forStreamID:self.currentSourceSID];
    }
}

- (void)loopCheckboxChanged:(NSButton *)sender {
    if (self.currentSourceSID.length > 0 &&
        [self.settingsDelegate respondsToSelector:@selector(settingsDidSetLoopEnabled:forStreamID:)]) {
        [self.settingsDelegate settingsDidSetLoopEnabled:(sender.state == NSControlStateValueOn)
                                             forStreamID:self.currentSourceSID];
    }
}

// 任一滤镜控件变化：刷新数值标签 + 收集参数回调宿主
- (void)filterControlChanged:(id)sender {
    [self.filterValueLabels enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSTextField *value, BOOL *stop) {
        NSControl *c = self.filterControls[key];
        value.stringValue = [self filterDisplayForKey:key value:c.doubleValue];
    }];
    if (self.currentSourceSID.length > 0 &&
        [self.settingsDelegate respondsToSelector:@selector(settingsDidSetFilterParams:forStreamID:)]) {
        [self.settingsDelegate settingsDidSetFilterParams:[self collectFilterParams]
                                              forStreamID:self.currentSourceSID];
    }
}

// 从当前控件读出完整参数字典（以默认值打底，确保键齐全）
- (NSDictionary *)collectFilterParams {
    NSMutableDictionary *params = [[WLBasicVideoFilter defaultParams] mutableCopy];
    [self.filterControls enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSControl *c, BOOL *stop) {
        if ([c isKindOfClass:[NSButton class]]) {
            params[key] = @(((NSButton *)c).state == NSControlStateValueOn);
        } else {
            params[key] = @(c.doubleValue);
        }
    }];
    return params;
}

- (void)resetFilters:(id)sender {
    NSDictionary *def = [WLBasicVideoFilter defaultParams];
    [self.filterControls enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSControl *c, BOOL *stop) {
        NSNumber *dv = def[key];
        if ([c isKindOfClass:[NSButton class]]) {
            ((NSButton *)c).state = dv.boolValue ? NSControlStateValueOn : NSControlStateValueOff;
        } else {
            c.doubleValue = dv.doubleValue;
        }
    }];
    [self filterControlChanged:nil];
}

// 单条滑块的「恢复默认」小按钮（SF Symbol：arrow.counterclockwise）
- (NSButton *)resetButtonWithAction:(SEL)action identifier:(nullable NSString *)ident {
    NSButton *btn = [[NSButton alloc] init];
    btn.bordered = NO;
    btn.imagePosition = NSImageOnly;
    btn.target = self;
    btn.action = action;
    btn.identifier = ident;
    btn.toolTip = @"恢复默认值";
    btn.contentTintColor = [NSColor secondaryLabelColor];
    if (@available(macOS 11.0, *)) {
        btn.image = [NSImage imageWithSystemSymbolName:@"arrow.counterclockwise"
                              accessibilityDescription:@"恢复默认值"];
    }
    [btn.widthAnchor constraintEqualToConstant:22].active = YES;
    return btn;
}

// 把某条滤镜滑块复位到其默认值（按钮 identifier 即参数 key）
- (void)resetFilterSlider:(NSButton *)sender {
    NSString *key = (NSString *)sender.identifier;
    if (key.length == 0) return;
    NSControl *c = self.filterControls[key];
    if (![c isKindOfClass:[NSSlider class]]) return;
    NSNumber *dv = [WLBasicVideoFilter defaultParams][key];
    ((NSSlider *)c).doubleValue = dv.doubleValue;
    [self filterControlChanged:nil];
}

// 音量复位到 100%
- (void)resetVolume:(id)sender {
    self.sourceVolSlider.doubleValue = 1.0;
    [self sourceVolumeChanged:self.sourceVolSlider];
}

// 「移除此源」：确认后请求宿主移除当前属性页对应的源（停源 + 从画布/混音/合成移除）
- (void)removeCurrentSource:(id)sender {
    NSString *sid = self.currentSourceSID;
    if (sid.length == 0) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"移除此输入源？";
    alert.informativeText = @"将停止该源，并从画布、混音与合成中移除。";
    [alert addButtonWithTitle:@"移除"];
    [alert addButtonWithTitle:@"取消"];
    alert.buttons.firstObject.hasDestructiveAction = YES;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    if ([self.settingsDelegate respondsToSelector:@selector(settingsDidRequestRemoveSource:)]) {
        [self.settingsDelegate settingsDidRequestRemoveSource:sid];
    }
}

#pragma mark - 面板切换

- (void)showFixedPanelAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.panels.count) return;
    self.currentSourceSID = nil;
    self.sourceLevelMeter = nil;
    self.sourceLevelDbLabel = nil;
    [self updateLevelTimer];
    for (NSView *v in self.contentContainer.subviews) [v removeFromSuperview];
    NSView *panel = self.panels[idx];
    [self.contentContainer addSubview:panel];
    [panel mas_remakeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.contentContainer);
    }];
}

- (void)showSourcePanelForItem:(NSDictionary *)item {
    self.currentSourceSID = item[@"sid"];
    for (NSView *v in self.contentContainer.subviews) [v removeFromSuperview];
    NSView *panel = [self buildSourcePanelForItem:item];
    [self.contentContainer addSubview:panel];
    [panel mas_remakeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.contentContainer);
    }];
    [self updateLevelTimer];
}

#pragma mark - 电平表轮询（源属性页可见且源有音频时 30Hz）

- (void)updateLevelTimer {
    BOOL need = (self.sourceLevelMeter != nil && self.currentSourceSID.length > 0 && self.window.isVisible);
    if (need && !self.levelTimer) {
        __weak typeof(self) wself = self;
        self.levelTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *t) {
            [wself levelTimerTick];
        }];
        // CommonModes：拖滑块/滚动期间表针不冻结
        [[NSRunLoop mainRunLoop] addTimer:self.levelTimer forMode:NSRunLoopCommonModes];
    } else if (!need && self.levelTimer) {
        [self.levelTimer invalidate];
        self.levelTimer = nil;
    }
}

- (void)levelTimerTick {
    if (!self.sourceLevelMeter || self.currentSourceSID.length == 0) return;
    float pk = 0;
    if ([self.settingsDelegate respondsToSelector:@selector(settingsAudioLevelForStreamID:)]) {
        pk = [self.settingsDelegate settingsAudioLevelForStreamID:self.currentSourceSID];
    }
    [self.sourceLevelMeter updateWithLinearPeak:pk];
    float db = self.sourceLevelMeter.displayDb;
    self.sourceLevelDbLabel.stringValue = (db <= -59.5f) ? @"-∞ dB"
                                        : [NSString stringWithFormat:@"%.0f dB", db];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.levelTimer invalidate];
    self.levelTimer = nil;
}

#pragma mark - sidebar 数据（固定分类 + 动态源）

- (void)rebuildSidebarItems {
    NSMutableArray<NSDictionary *> *items = [self.fixedCategories mutableCopy];
    NSArray<NSDictionary *> *sources = nil;
    if ([self.settingsDelegate respondsToSelector:@selector(settingsSourceList)]) {
        sources = [self.settingsDelegate settingsSourceList];
    }
    if (sources.count > 0) {
        [items addObject:@{@"kind": @"group", @"title": @"输入源"}];
        for (NSDictionary *s in sources) {
            WLFromType t = (WLFromType)[s[@"fromType"] integerValue];
            NSString *sym = (t == WLFromTypeMic) ? @"mic.fill"
                          : (t == WLFromTypeCamera) ? @"video.fill" : @"film.fill";
            [items addObject:@{@"kind": @"source",
                               @"sid": s[@"sid"] ?: @"",
                               @"name": s[@"name"] ?: @"源",
                               @"symbol": sym,
                               @"fromType": s[@"fromType"] ?: @0,
                               @"hasAudio": s[@"hasAudio"] ?: @NO}];
        }
    }
    self.sidebarItems = items;
}

// 源增删后由宿主调用：刷新左栏并尽量保持当前选中
- (void)reloadSources {
    NSString *keepSID = self.currentSourceSID;
    [self rebuildSidebarItems];
    [self.sidebar reloadData];
    if (keepSID.length > 0) {
        for (NSInteger i = 0; i < (NSInteger)self.sidebarItems.count; i++) {
            NSDictionary *it = self.sidebarItems[i];
            if ([it[@"kind"] isEqualToString:@"source"] && [it[@"sid"] isEqualToString:keepSID]) {
                [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
                return;
            }
        }
        // 原选中的源已被移除 → 回到第一项
        [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self showFixedPanelAtIndex:0];
    }
}

// 供右键「属性…」跳转：选中并显示某个源的属性页
- (void)selectSourceID:(NSString *)streamID {
    [self rebuildSidebarItems];
    [self.sidebar reloadData];
    for (NSInteger i = 0; i < (NSInteger)self.sidebarItems.count; i++) {
        NSDictionary *it = self.sidebarItems[i];
        if ([it[@"kind"] isEqualToString:@"source"] && [it[@"sid"] isEqualToString:streamID]) {
            [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            return;
        }
    }
}

#pragma mark - currentCanvasSize → 同步下拉选中

- (void)setCurrentCanvasSize:(CGSize)size {
    _currentCanvasSize = size;
    [self selectResolutionMatching:size];
}

- (void)selectResolutionMatching:(CGSize)size {
    NSInteger idx = 0;
    for (NSInteger i = 0; i < (NSInteger)self.resolutionPresets.count; i++) {
        NSDictionary *p = self.resolutionPresets[i];
        if ((int)size.width == [p[@"w"] intValue] && (int)size.height == [p[@"h"] intValue]) { idx = i; break; }
    }
    [self.resolutionPopup selectItemAtIndex:idx];
}

#pragma mark - 打开时同步当前状态

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self syncPushFromDelegate];
    [self reloadSources];
    [self selectPopup:self.logLevelPopup value:@([WLLog globalLevel])]; // 等级可能被代码改过，回显
    [self updateLevelTimer];   // 关窗后重开：若停在源属性页则恢复电平轮询
}

- (void)syncPushFromDelegate {
    if ([self.settingsDelegate respondsToSelector:@selector(settingsPushURL)]) {
        self.pushURLField.stringValue = [self.settingsDelegate settingsPushURL] ?: @"";
    }
    if ([self.settingsDelegate respondsToSelector:@selector(settingsStreamKey)]) {
        self.streamKeyField.stringValue = [self.settingsDelegate settingsStreamKey] ?: @"";
    }
}

#pragma mark - Actions

- (void)resolutionChanged:(NSPopUpButton *)sender {
    NSDictionary *p = sender.selectedItem.representedObject;
    if (![p isKindOfClass:[NSDictionary class]]) return;

    if ([self.settingsDelegate respondsToSelector:@selector(settingsCanChangeCanvasSize)] &&
        ![self.settingsDelegate settingsCanChangeCanvasSize]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"录制进行中";
        alert.informativeText = @"请先停止录制，再修改画布分辨率。";
        [alert addButtonWithTitle:@"好"];
        [alert runModal];
        [self selectResolutionMatching:self.currentCanvasSize];   // 恢复原选中
        return;
    }
    CGSize size = CGSizeMake([p[@"w"] doubleValue], [p[@"h"] doubleValue]);
    _currentCanvasSize = size;
    if ([self.settingsDelegate respondsToSelector:@selector(settingsDidSelectCanvasSize:)]) {
        [self.settingsDelegate settingsDidSelectCanvasSize:size];
    }
}

- (void)colorWellChanged:(NSColorWell *)sender {
    if ([self.settingsDelegate respondsToSelector:@selector(settingsDidChooseBackgroundColor:)]) {
        [self.settingsDelegate settingsDidChooseBackgroundColor:sender.color];
    }
}

- (void)chooseBgImage:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"png", @"jpg", @"jpeg", @"heic", @"tiff", @"bmp", @"gif"];
    panel.allowsMultipleSelection = NO;
    __weak typeof(self) wself = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || panel.URLs.count == 0) return;
        NSURL *url = panel.URLs.firstObject;
        NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
        if (!image) return;
        wself.bgImageLabel.stringValue = url.lastPathComponent;
        if ([wself.settingsDelegate respondsToSelector:@selector(settingsDidChooseBackgroundImage:)]) {
            [wself.settingsDelegate settingsDidChooseBackgroundImage:image];
        }
    }];
}

- (void)clearBg:(id)sender {
    self.bgImageLabel.stringValue = @"未选择";
    self.colorWell.color = [NSColor colorWithWhite:0.1 alpha:1.0];
    if ([self.settingsDelegate respondsToSelector:@selector(settingsDidClearBackground)]) {
        [self.settingsDelegate settingsDidClearBackground];
    }
}

- (void)savePushSettings:(id)sender {
    if ([self.settingsDelegate respondsToSelector:@selector(settingsDidSetPushURL:streamKey:)]) {
        [self.settingsDelegate settingsDidSetPushURL:(self.pushURLField.stringValue ?: @"")
                                           streamKey:(self.streamKeyField.stringValue ?: @"")];
    }
    self.pushSavedLabel.stringValue = @"✓ 已保存";
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(clearPushSavedLabel) object:nil];
    [self performSelector:@selector(clearPushSavedLabel) withObject:nil afterDelay:2.0];
}

- (void)clearPushSavedLabel {
    self.pushSavedLabel.stringValue = @"";
}

#pragma mark - NSTableView (sidebar)

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.sidebarItems.count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.sidebarItems.count) return NO;
    return [self.sidebarItems[row][@"kind"] isEqualToString:@"group"];
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.sidebarItems.count) return NO;
    return ![self.sidebarItems[row][@"kind"] isEqualToString:@"group"];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSDictionary *item = self.sidebarItems[row];
    NSString *kind = item[@"kind"];

    if ([kind isEqualToString:@"group"]) {
        static NSString *kGroupId = @"WLSettingsGroupCell";
        NSTableCellView *cell = [tableView makeViewWithIdentifier:kGroupId owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] init];
            cell.identifier = kGroupId;
            NSTextField *tf = [NSTextField labelWithString:@""];
            tf.font = [NSFont boldSystemFontOfSize:11];
            tf.textColor = [NSColor secondaryLabelColor];
            [cell addSubview:tf];
            cell.textField = tf;
            [tf mas_makeConstraints:^(MASConstraintMaker *make) {
                make.left.equalTo(cell).offset(4);
                make.centerY.equalTo(cell);
                make.right.lessThanOrEqualTo(cell);
            }];
        }
        cell.textField.stringValue = item[@"title"];
        return cell;
    }

    static NSString *kId = @"WLSettingsCatCell";
    NSTableCellView *cell = [tableView makeViewWithIdentifier:kId owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = kId;
        NSImageView *iv = [[NSImageView alloc] init];
        NSTextField *tf = [NSTextField labelWithString:@""];
        [cell addSubview:iv];
        [cell addSubview:tf];
        cell.imageView = iv;
        cell.textField = tf;
        [iv mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(cell).offset(4);
            make.centerY.equalTo(cell);
            make.width.height.equalTo(@18);
        }];
        [tf mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(iv.mas_right).offset(8);
            make.centerY.equalTo(cell);
            make.right.lessThanOrEqualTo(cell);
        }];
    }
    cell.textField.stringValue = item[@"name"] ?: item[@"title"];
    cell.textField.lineBreakMode = NSLineBreakByTruncatingMiddle;
    if (@available(macOS 11.0, *)) {
        cell.imageView.image = [NSImage imageWithSystemSymbolName:item[@"symbol"] accessibilityDescription:nil];
    }
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.sidebar.selectedRow;
    if (row < 0 || row >= (NSInteger)self.sidebarItems.count) return;
    NSDictionary *item = self.sidebarItems[row];
    NSString *kind = item[@"kind"];
    if ([kind isEqualToString:@"category"]) {
        [self showFixedPanelAtIndex:[item[@"panel"] integerValue]];
    } else if ([kind isEqualToString:@"source"]) {
        [self showSourcePanelForItem:item];
    }
}

@end
