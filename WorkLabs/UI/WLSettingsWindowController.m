//
//  WLSettingsWindowController.m
//  WorkLabs
//

#import "WLSettingsWindowController.h"
#import <Masonry/Masonry.h>

@interface WLSettingsWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *categories;       // {title, symbol}
@property (nonatomic, strong) NSArray<NSDictionary *> *resolutionPresets; // {t, w, h}
@property (nonatomic, strong) NSTableView *sidebar;
@property (nonatomic, strong) NSView *contentContainer;
@property (nonatomic, strong) NSArray<NSView *> *panels;
@property (nonatomic, strong) NSPopUpButton *resolutionPopup;
@property (nonatomic, strong) NSColorWell *colorWell;
@property (nonatomic, strong) NSTextField *bgImageLabel;
@property (nonatomic, strong) NSSlider *mediaVolSlider;
@property (nonatomic, strong) NSSlider *micVolSlider;
@property (nonatomic, strong) NSTextField *mediaPercentLabel;
@property (nonatomic, strong) NSTextField *micPercentLabel;
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
        _categories = @[
            @{@"title": @"画布", @"symbol": @"display"},
            @{@"title": @"背景", @"symbol": @"photo"},
            @{@"title": @"音频", @"symbol": @"speaker.wave.2"},
        ];
        _resolutionPresets = @[
            @{@"t": @"1280×720 (720p)",   @"w": @1280, @"h": @720},
            @{@"t": @"1920×1080 (1080p)", @"w": @1920, @"h": @1080},
            @{@"t": @"2560×1440 (1440p)", @"w": @2560, @"h": @1440},
            @{@"t": @"1080×1920 (竖屏)",  @"w": @1080, @"h": @1920},
            @{@"t": @"720×1280 (竖屏)",   @"w": @720,  @"h": @1280},
        ];
        [self buildUI];
        [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self showPanelAtIndex:0];
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

    self.panels = @[[self buildCanvasPanel], [self buildBackgroundPanel], [self buildAudioPanel]];
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

- (NSView *)buildAudioPanel {
    NSView *panel = [[NSView alloc] init];

    self.mediaPercentLabel = [NSTextField labelWithString:@"100%"];
    self.micPercentLabel   = [NSTextField labelWithString:@"100%"];
    self.mediaVolSlider = [self volumeSliderForType:WLFromTypeMedia];
    self.micVolSlider   = [self volumeSliderForType:WLFromTypeMic];

    NSView *mediaRow = [self volumeRowTitle:@"媒体音量" slider:self.mediaVolSlider percent:self.mediaPercentLabel];
    NSView *micRow   = [self volumeRowTitle:@"麦克风音量" slider:self.micVolSlider   percent:self.micPercentLabel];

    [panel addSubview:mediaRow];
    [panel addSubview:micRow];
    [mediaRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(panel).offset(24);
        make.left.equalTo(panel).offset(24);
        make.right.equalTo(panel).offset(-24);
        make.height.equalTo(@24);
    }];
    [micRow mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(mediaRow.mas_bottom).offset(16);
        make.left.right.equalTo(mediaRow);
        make.height.equalTo(@24);
    }];
    return panel;
}

- (NSSlider *)volumeSliderForType:(WLFromType)type {
    NSSlider *slider = [NSSlider sliderWithValue:1.0 minValue:0.0 maxValue:2.0
                                          target:self action:@selector(volumeChanged:)];
    slider.tag = type;
    return slider;
}

- (NSView *)volumeRowTitle:(NSString *)title slider:(NSSlider *)slider percent:(NSTextField *)percent {
    [slider.widthAnchor constraintEqualToConstant:160].active = YES;
    [percent.widthAnchor constraintEqualToConstant:44].active = YES;
    NSStackView *stack = [NSStackView stackViewWithViews:@[slider, percent]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing = 10;
    stack.alignment = NSLayoutAttributeCenterY;
    return [self rowWithTitle:title control:stack];
}

- (void)volumeChanged:(NSSlider *)sender {
    float v = sender.floatValue;
    NSString *pct = [NSString stringWithFormat:@"%.0f%%", v * 100];
    if (sender.tag == WLFromTypeMedia)      self.mediaPercentLabel.stringValue = pct;
    else if (sender.tag == WLFromTypeMic)   self.micPercentLabel.stringValue = pct;
    if ([self.settingsDelegate respondsToSelector:@selector(settingsDidSetVolume:forFromType:)]) {
        [self.settingsDelegate settingsDidSetVolume:v forFromType:(WLFromType)sender.tag];
    }
}

- (void)showPanelAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.panels.count) return;
    for (NSView *v in self.contentContainer.subviews) [v removeFromSuperview];
    NSView *panel = self.panels[idx];
    [self.contentContainer addSubview:panel];
    [panel mas_remakeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.contentContainer);
    }];
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
    [self syncVolumesFromDelegate];
}

- (void)syncVolumesFromDelegate {
    if (![self.settingsDelegate respondsToSelector:@selector(settingsVolumeForFromType:)]) return;
    float mv = [self.settingsDelegate settingsVolumeForFromType:WLFromTypeMedia];
    float kv = [self.settingsDelegate settingsVolumeForFromType:WLFromTypeMic];
    self.mediaVolSlider.floatValue = mv;
    self.micVolSlider.floatValue = kv;
    self.mediaPercentLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", mv * 100];
    self.micPercentLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", kv * 100];
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

#pragma mark - NSTableView (sidebar)

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.categories.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
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
    NSDictionary *cat = self.categories[row];
    cell.textField.stringValue = cat[@"title"];
    if (@available(macOS 11.0, *)) {
        cell.imageView.image = [NSImage imageWithSystemSymbolName:cat[@"symbol"] accessibilityDescription:nil];
    }
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.sidebar.selectedRow;
    if (row >= 0) [self showPanelAtIndex:row];
}

@end
