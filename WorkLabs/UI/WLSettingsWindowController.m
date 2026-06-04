//
//  WLSettingsWindowController.m
//  WorkLabs
//

#import "WLSettingsWindowController.h"
#import <Masonry/Masonry.h>

@interface WLSettingsWindowController () <NSTableViewDataSource, NSTableViewDelegate>
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
        _currentCanvasSize = CGSizeMake(1920, 1080);
        _fixedCategories = @[
            @{@"kind": @"category", @"title": @"画布", @"symbol": @"display", @"panel": @0},
            @{@"kind": @"category", @"title": @"背景", @"symbol": @"photo",   @"panel": @1},
            @{@"kind": @"category", @"title": @"推流", @"symbol": @"antenna.radiowaves.left.and.right", @"panel": @2},
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

    self.panels = @[[self buildCanvasPanel], [self buildBackgroundPanel], [self buildPushPanel]];
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

#pragma mark - 源属性页（每个流的配置容器：音量 + 预留滤镜）

- (NSView *)buildSourcePanelForItem:(NSDictionary *)item {
    NSView *panel = [[NSView alloc] init];
    NSString *name = item[@"name"] ?: @"源";
    BOOL hasAudio = [item[@"hasAudio"] boolValue];
    WLFromType t = (WLFromType)[item[@"fromType"] integerValue];
    NSString *typeName = (t == WLFromTypeMic) ? @"麦克风"
                       : (t == WLFromTypeCamera) ? @"摄像头" : @"视频文件";

    NSTextField *titleLabel = [NSTextField labelWithString:name];
    titleLabel.font = [NSFont boldSystemFontOfSize:15];
    titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSTextField *subLabel = [NSTextField labelWithString:typeName];
    subLabel.textColor = [NSColor secondaryLabelColor];
    subLabel.font = [NSFont systemFontOfSize:11];

    [panel addSubview:titleLabel];
    [panel addSubview:subLabel];
    [titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(panel).offset(22);
        make.left.equalTo(panel).offset(24);
        make.right.lessThanOrEqualTo(panel).offset(-24);
    }];
    [subLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(titleLabel.mas_bottom).offset(2);
        make.left.equalTo(titleLabel);
    }];

    NSView *anchor = subLabel;

    if (hasAudio) {
        float vol = 1.0f;
        if ([self.settingsDelegate respondsToSelector:@selector(settingsVolumeForStreamID:)]) {
            vol = [self.settingsDelegate settingsVolumeForStreamID:item[@"sid"]];
        }
        self.sourceVolPercent = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0f%%", vol * 100]];
        self.sourceVolSlider = [NSSlider sliderWithValue:vol minValue:0.0 maxValue:2.0
                                                  target:self action:@selector(sourceVolumeChanged:)];
        NSView *volRow = [self volumeRowTitle:@"音量" slider:self.sourceVolSlider percent:self.sourceVolPercent];
        [panel addSubview:volRow];
        [volRow mas_makeConstraints:^(MASConstraintMaker *make) {
            make.top.equalTo(subLabel.mas_bottom).offset(22);
            make.left.equalTo(panel).offset(24);
            make.right.equalTo(panel).offset(-24);
            make.height.equalTo(@24);
        }];
        anchor = volRow;
    } else {
        self.sourceVolSlider = nil;
        self.sourceVolPercent = nil;
        NSTextField *noAudio = [NSTextField labelWithString:@"此源无音频输出"];
        noAudio.textColor = [NSColor secondaryLabelColor];
        [panel addSubview:noAudio];
        [noAudio mas_makeConstraints:^(MASConstraintMaker *make) {
            make.top.equalTo(subLabel.mas_bottom).offset(22);
            make.left.equalTo(panel).offset(24);
        }];
        anchor = noAudio;
    }

    // 滤镜区占位（为将来 per-source filter 预留位置）
    NSTextField *filterTitle = [NSTextField labelWithString:@"滤镜"];
    filterTitle.font = [NSFont boldSystemFontOfSize:12];
    NSTextField *filterHint = [NSTextField labelWithString:@"镜像 / 裁剪等滤镜即将支持。"];
    filterHint.textColor = [NSColor secondaryLabelColor];
    filterHint.font = [NSFont systemFontOfSize:11];
    [panel addSubview:filterTitle];
    [panel addSubview:filterHint];
    [filterTitle mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(anchor.mas_bottom).offset(28);
        make.left.equalTo(panel).offset(24);
    }];
    [filterHint mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(filterTitle.mas_bottom).offset(6);
        make.left.equalTo(panel).offset(24);
        make.right.lessThanOrEqualTo(panel).offset(-24);
    }];
    return panel;
}

- (void)sourceVolumeChanged:(NSSlider *)sender {
    float v = sender.floatValue;
    self.sourceVolPercent.stringValue = [NSString stringWithFormat:@"%.0f%%", v * 100];
    if (self.currentSourceSID.length > 0 &&
        [self.settingsDelegate respondsToSelector:@selector(settingsDidSetVolume:forStreamID:)]) {
        [self.settingsDelegate settingsDidSetVolume:v forStreamID:self.currentSourceSID];
    }
}

#pragma mark - 面板切换

- (void)showFixedPanelAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.panels.count) return;
    self.currentSourceSID = nil;
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
