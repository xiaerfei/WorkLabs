//
//  WLSourcePanel.m
//  WorkLabs
//

#import "WLSourcePanel.h"
#import <Masonry.h>
#import "NSView+BackgroundColor.h"
#import "WLToolbarButton.h"
#import "WLSceneManager.h"
#import "WLMediaSourceItem.h"
#import "WLEvent.h"
#import "WLDevicesManager.h"
#import "WLCameraSourceConfig.h"

@interface WLSourcePanel () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSView *titleBar;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSView *toolbarView;

// 空状态相关
@property (nonatomic, strong) NSTextField *iconLabel;
@property (nonatomic, strong) NSTextField *hintLabel;

// 源列表
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;

// 事件
@property (nonatomic, strong) WLEventDisposeBag *bag;

@end

@implementation WLSourcePanel

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    [self backgroundColorWithHex:0x1E1E1E];

    // 标题栏
    self.titleBar = [[NSView alloc] init];
    [self.titleBar backgroundColorWithHex:0x252525];
    [self addSubview:self.titleBar];
    [self.titleBar mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(self);
        make.height.mas_equalTo(30);
    }];

    NSImageView *iconView = [[NSImageView alloc] init];
    iconView.image = [NSImage imageWithSystemSymbolName:@"square.stack.3d.up"
                                  accessibilityDescription:nil];
    iconView.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.titleBar addSubview:iconView];
    [iconView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.titleBar).offset(8);
        make.centerY.equalTo(self.titleBar);
        make.width.height.mas_equalTo(14);
    }];

    NSTextField *titleLabel = [NSTextField labelWithString:@"源"];
    titleLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    titleLabel.font = [NSFont systemFontOfSize:12.0];
    [self.titleBar addSubview:titleLabel];
    [titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(iconView.mas_right).offset(5);
        make.centerY.equalTo(self.titleBar);
    }];

    // 底部工具栏
    self.toolbarView = [[NSView alloc] init];
    [self.toolbarView backgroundColorWithHex:0x1A1A1A];
    [self addSubview:self.toolbarView];
    [self.toolbarView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.left.right.equalTo(self);
        make.height.mas_equalTo(32);
    }];
    [self setupToolbar];

    // 分隔线
    NSView *topSep = [[NSView alloc] init];
    [topSep backgroundColorWithHex:0x3C3C3C];
    [self addSubview:topSep];
    [topSep mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.titleBar.mas_bottom);
        make.left.right.equalTo(self);
        make.height.mas_equalTo(1);
    }];

    NSView *bottomSep = [[NSView alloc] init];
    [bottomSep backgroundColorWithHex:0x3C3C3C];
    [self addSubview:bottomSep];
    [bottomSep mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.equalTo(self.toolbarView.mas_top);
        make.left.right.equalTo(self);
        make.height.mas_equalTo(1);
    }];

    // 内容区：空状态占位
    self.contentView = [[NSView alloc] init];
    [self.contentView backgroundColorWithHex:0x1E1E1E];
    [self addSubview:self.contentView];
    [self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(topSep.mas_bottom);
        make.left.right.equalTo(self);
        make.bottom.equalTo(bottomSep.mas_top);
    }];

    [self setupEmptyState];
}

- (void)setupEmptyState {
    // 问号图标
    self.iconLabel = [NSTextField labelWithString:@"?"];
    self.iconLabel.font = [NSFont systemFontOfSize:36.0 weight:NSFontWeightThin];
    self.iconLabel.textColor = [NSColor colorWithWhite:0.35 alpha:1.0];
    self.iconLabel.alignment = NSTextAlignmentCenter;
    [self.contentView addSubview:self.iconLabel];
    [self.iconLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.equalTo(self.contentView);
        make.centerY.equalTo(self.contentView).offset(-20);
        make.width.mas_equalTo(50);
    }];

    // 提示文字
    self.hintLabel = [NSTextField labelWithString:@"您还没有添加任何源。\n点击下面的 + 按钮，\n或者右击此处添加一个。"];
    self.hintLabel.font = [NSFont systemFontOfSize:11.0];
    self.hintLabel.textColor = [NSColor colorWithWhite:0.45 alpha:1.0];
    self.hintLabel.alignment = NSTextAlignmentCenter;
    self.hintLabel.maximumNumberOfLines = 3;
    [self.contentView addSubview:self.hintLabel];
    [self.hintLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.iconLabel.mas_bottom).offset(6);
        make.left.equalTo(self.contentView).offset(8);
        make.right.equalTo(self.contentView).offset(-8);
    }];

    // 源列表
    [self setupTableView];

    // 事件监听
    [self registerEventObservers];

    [self updateContentViewVisibility];
}

- (void)setupToolbar {
    NSArray *configs = @[
        @[@"plus",           NSStringFromSelector(@selector(addSource))],
        @[@"minus",          NSStringFromSelector(@selector(deleteSource))],
        @[@"gearshape",      NSStringFromSelector(@selector(sourceSettings))],
        @[@"chevron.up",     NSStringFromSelector(@selector(moveSourceUp))],
        @[@"chevron.down",   NSStringFromSelector(@selector(moveSourceDown))],
    ];

    NSView *prev = nil;
    for (NSArray *cfg in configs) {
        WLToolbarButton *btn = [self makeToolbarButtonWithSymbolName:cfg[0]
                                                       action:NSSelectorFromString(cfg[1])];
        [self.toolbarView addSubview:btn];
        [btn mas_makeConstraints:^(MASConstraintMaker *make) {
            make.centerY.equalTo(self.toolbarView);
            make.width.height.mas_equalTo(24);
            if (prev) {
                make.left.equalTo(prev.mas_right).offset(2);
            } else {
                make.left.equalTo(self.toolbarView).offset(6);
            }
        }];
        prev = btn;
    }
}

- (WLToolbarButton *)makeToolbarButtonWithSymbolName:(NSString *)symbolName action:(SEL)action {
    WLToolbarButton *btn = [[WLToolbarButton alloc] init];
    btn.bezelStyle = NSBezelStyleSmallSquare;
    btn.bordered = NO;
    btn.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    btn.imagePosition = NSImageOnly;
    btn.target = self;
    btn.action = action;
    [btn setContentTintColor:[NSColor whiteColor]];
    
    NSTrackingArea *trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                                options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect | NSViewWidthSizable | NSViewHeightSizable)
                                                                  owner:btn
                                                               userInfo:nil];
    [btn addTrackingArea:trackingArea];
    
    return btn;
}

#pragma mark - Toolbar Actions

- (void)addSource {
    NSMenu *menu = [[NSMenu alloc] init];

    // 摄像头源
    NSMenuItem *cameraItem = [[NSMenuItem alloc] initWithTitle:@"摄像头"
                                                        action:@selector(addCameraSourceMenuItem:)
                                                 keyEquivalent:@""];
    cameraItem.target = self;

    // 摄像头子菜单
    NSMenu *cameraSubMenu = [[NSMenu alloc] init];
    NSArray<WLDeviceItem *> *devices = [[WLDevicesManager manager] currentVideoDevices];
    if (devices.count > 0) {
        for (WLDeviceItem *item in devices) {
            NSMenuItem *deviceItem = [[NSMenuItem alloc] initWithTitle:item.localizedName ?: @""
                                                                action:@selector(addCameraWithDeviceItem:)
                                                         keyEquivalent:@""];
            deviceItem.target = self;
            deviceItem.representedObject = item.device;
            [cameraSubMenu addItem:deviceItem];
        }
    } else {
        NSMenuItem *noneItem = [[NSMenuItem alloc] initWithTitle:@"无可用摄像头" action:nil keyEquivalent:@""];
        noneItem.enabled = NO;
        [cameraSubMenu addItem:noneItem];
    }
    cameraItem.submenu = cameraSubMenu;
    [menu addItem:cameraItem];

    // 视频文件源
    NSMenuItem *videoItem = [[NSMenuItem alloc] initWithTitle:@"视频文件"
                                                       action:@selector(addVideoFileSource:)
                                                keyEquivalent:@""];
    videoItem.target = self;
    [menu addItem:videoItem];

    // 音频文件源
    NSMenuItem *audioItem = [[NSMenuItem alloc] initWithTitle:@"音频文件"
                                                       action:@selector(addAudioFileSource:)
                                                keyEquivalent:@""];
    audioItem.target = self;
    [menu addItem:audioItem];

    // 弹出菜单
    NSButton *plusBtn = [self findPlusButton];
    NSRect frame = plusBtn ? plusBtn.frame : NSMakeRect(0, 0, 0, 0);
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, frame.size.height) inView:plusBtn];
}

- (NSButton *)findPlusButton {
    for (NSView *subview in self.toolbarView.subviews) {
        if ([subview isKindOfClass:[NSButton class]]) {
            NSButton *btn = (NSButton *)subview;
            if (btn.action == @selector(addSource)) {
                return btn;
            }
        }
    }
    return nil;
}

- (void)addCameraWithDeviceItem:(NSMenuItem *)sender {
    AVCaptureDevice *device = sender.representedObject;
    if (!device) return;

    WLCameraSourceConfig *config = [[WLCameraSourceConfig alloc] init];
    config.device = device;
    config.sessionPreset = AVCaptureSessionPresetHigh;
    [[WLSceneManager manager] addCameraSourceWithConfig:config];
}

- (void)addVideoFileSource:(NSMenuItem *)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"mp4"],
        [UTType typeWithFilenameExtension:@"mov"],
        [UTType typeWithFilenameExtension:@"mkv"],
        [UTType typeWithFilenameExtension:@"avi"],
        [UTType typeWithFilenameExtension:@"m4v"],
    ];

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            [[WLSceneManager manager] addVideoSourceWithPath:panel.URL.path];
        }
    }];
}

- (void)addAudioFileSource:(NSMenuItem *)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"mp3"],
        [UTType typeWithFilenameExtension:@"aac"],
        [UTType typeWithFilenameExtension:@"wav"],
        [UTType typeWithFilenameExtension:@"m4a"],
        [UTType typeWithFilenameExtension:@"flac"],
    ];

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            [[WLSceneManager manager] addAudioSourceWithPath:panel.URL.path];
        }
    }];
}

- (void)deleteSource {
    WLMediaSourceItem *selected = [WLSceneManager manager].selectedSource;
    if (selected) {
        [[WLSceneManager manager] removeSource:selected];
    }
}

- (void)sourceSettings {
    // 待实现
}

- (void)moveSourceUp {
    WLSceneManager *sm = [WLSceneManager manager];
    WLMediaSourceItem *selected = sm.selectedSource;
    if (!selected) return;

    NSUInteger index = [sm.sources indexOfObject:selected];
    if (index == NSNotFound || index == 0) return;
    [sm moveSourceAtIndex:index toIndex:index - 1];
}

- (void)moveSourceDown {
    WLSceneManager *sm = [WLSceneManager manager];
    WLMediaSourceItem *selected = sm.selectedSource;
    if (!selected) return;

    NSUInteger index = [sm.sources indexOfObject:selected];
    if (index == NSNotFound || index >= sm.sources.count - 1) return;
    [sm moveSourceAtIndex:index toIndex:index + 1];
}

#pragma mark - TableView Setup

- (void)setupTableView {
    self.tableView = [[NSTableView alloc] init];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.headerView = nil;
    self.tableView.backgroundColor = [NSColor colorWithWhite:0.12 alpha:1.0];
    self.tableView.rowHeight = 28;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"source"];
    column.width = 200;
    [self.tableView addTableColumn:column];

    self.scrollView = [[NSScrollView alloc] init];
    self.scrollView.documentView = self.tableView;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.drawsBackground = NO;
    self.scrollView.hidden = YES;
    [self.contentView addSubview:self.scrollView];

    [self.scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.contentView);
    }];
}

#pragma mark - Event Observers

- (void)registerEventObservers {
    __weak typeof(self) weakSelf = self;
    self.bag = [WLEventDisposeBag new];

    WLObserve(@[@(WLObserveSourceChange)])
        .mainQueue()
        .dispose(self.bag)
        .block(^(WLObserve type, id payload) {
            [weakSelf.tableView reloadData];
            [weakSelf updateContentViewVisibility];
        });
}

- (void)updateContentViewVisibility {
    BOOL hasSources = [WLSceneManager manager].sources.count > 0;

    self.iconLabel.hidden = hasSources;
    self.hintLabel.hidden = hasSources;
    self.scrollView.hidden = !hasSources;
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [WLSceneManager manager].sources.count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSArray<WLMediaSourceItem *> *sources = [WLSceneManager manager].sources;
    if (row < 0 || row >= sources.count) return nil;

    WLMediaSourceItem *item = sources[row];

    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"SourceCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = @"SourceCell";

        NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(4, 4, 16, 16)];
        iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        iconView.tag = 100;
        [cell addSubview:iconView];

        NSTextField *textField = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 2, 180, 20)];
        textField.editable = NO;
        textField.bordered = NO;
        textField.backgroundColor = [NSColor clearColor];
        textField.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
        textField.font = [NSFont systemFontOfSize:11.0];
        textField.tag = 200;
        [cell addSubview:textField];
    }

    NSImageView *iconView = [cell viewWithTag:100];
    NSString *iconName = nil;
    switch (item.type) {
        case WLMediaSourceTypeCamera: iconName = @"camera.fill"; break;
        case WLMediaSourceTypeVideo:  iconName = @"film";       break;
        case WLMediaSourceTypeAudio:  iconName = @"music.note"; break;
    }
    iconView.image = [NSImage imageWithSystemSymbolName:iconName accessibilityDescription:nil];
    iconView.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];

    NSTextField *textField = [cell viewWithTag:200];
    textField.stringValue = item.name ?: @"";

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.tableView.selectedRow;
    NSArray<WLMediaSourceItem *> *sources = [WLSceneManager manager].sources;
    if (row >= 0 && row < sources.count) {
        [[WLSceneManager manager] selectSource:sources[row]];
    } else {
        [[WLSceneManager manager] deselectAll];
    }
}

@end
