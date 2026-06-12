//
//  WLAddSourceWindowController.m
//  WorkLabs
//

#import "WLAddSourceWindowController.h"
#import <Masonry/Masonry.h>
#import <ReactiveObjC.h>
#import "WLDevicesManager.h"
#import "WLDefines.h"

// 支持的视频文件扩展名（与 NSOpenPanel / 拖放共用）
static NSArray<NSString *> *WLAddSourceVideoExtensions(void) {
    return @[@"mp4", @"mov", @"m4v", @"mkv", @"flv", @"ts", @"avi"];
}

#pragma mark - 拖放容器（整窗接收视频文件拖入）

@interface WLAddSourceDropView : NSView
@property (nonatomic, copy, nullable) void (^filesDropped)(NSArray<NSString *> *paths);
@property (nonatomic, assign) BOOL dragHighlighted;
@end

@implementation WLAddSourceDropView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

// 取出拖入项中扩展名匹配的视频文件路径
- (NSArray<NSString *> *)videoPathsFromDraggingInfo:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = [sender.draggingPasteboard
        readObjectsForClasses:@[NSURL.class]
                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSArray<NSString *> *exts = WLAddSourceVideoExtensions();
    for (NSURL *u in urls) {
        if ([exts containsObject:u.pathExtension.lowercaseString]) [paths addObject:u.path];
    }
    return paths;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if ([self videoPathsFromDraggingInfo:sender].count == 0) return NSDragOperationNone;
    self.dragHighlighted = YES;
    self.needsDisplay = YES;
    return NSDragOperationCopy;
}

- (void)draggingExited:(nullable id<NSDraggingInfo>)sender {
    self.dragHighlighted = NO;
    self.needsDisplay = YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.dragHighlighted = NO;
    self.needsDisplay = YES;
    NSArray<NSString *> *paths = [self videoPathsFromDraggingInfo:sender];
    if (paths.count == 0) return NO;
    if (self.filesDropped) self.filesDropped(paths);
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (!self.dragHighlighted) return;
    // 拖入悬停：描一圈强调色边框提示可放下
    NSRect r = NSInsetRect(self.bounds, 3, 3);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8];
    p.lineWidth = 3;
    [[NSColor controlAccentColor] setStroke];
    [p stroke];
}

@end

#pragma mark - 窗口控制器

@interface WLAddSourceWindowController () <NSTableViewDataSource, NSTableViewDelegate>
// 左栏：已添加的源
@property (nonatomic, strong) NSTextField *sourcesHeader;
@property (nonatomic, strong) NSTableView *sourcesTable;
@property (nonatomic, strong) NSTextField *sourcesEmptyLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *sources;
// 右栏：设备分区（rebuild 时整组替换）
@property (nonatomic, strong) NSStackView *cameraStack;
@property (nonatomic, strong) NSStackView *micStack;
@property (nonatomic, strong) NSArray<WLDeviceItem *> *cameraItems;
@property (nonatomic, strong) NSArray<WLDeviceItem *> *micItems;
// 设备热插拔订阅
@property (nonatomic, strong) RACDisposable *videoDisposable;
@property (nonatomic, strong) RACDisposable *audioDisposable;
@end

@implementation WLAddSourceWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 440)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"添加源";
    window.minSize = NSMakeSize(560, 380);
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        _sources = @[];
        _cameraItems = @[];
        _micItems = @[];
        [self buildUI];

        // 设备热插拔：列表实时刷新（信号在任意线程发，回主线程重建）
        @weakify(self);
        _videoDisposable = [[[WLDevicesManager manager].videoSignal deliverOnMainThread]
            subscribeNext:^(WLDeviceItem *item) {
                @strongify(self);
                [self reloadDevices];
            }];
        _audioDisposable = [[[WLDevicesManager manager].audioSignal deliverOnMainThread]
            subscribeNext:^(WLDeviceItem *item) {
                @strongify(self);
                [self reloadDevices];
            }];
    }
    return self;
}

- (void)dealloc {
    [self.videoDisposable dispose];
    [self.audioDisposable dispose];
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self reloadAll];
}

#pragma mark - 对外刷新

- (void)reloadSources {
    if (!self.window.isVisible) return;
    [self reloadAll];
}

- (void)reloadAll {
    self.sources = [self.addSourceDelegate respondsToSelector:@selector(addSourceCurrentSources)]
                 ? ([self.addSourceDelegate addSourceCurrentSources] ?: @[]) : @[];
    self.sourcesHeader.stringValue = [NSString stringWithFormat:@"已添加的源（%lu）",
                                      (unsigned long)self.sources.count];
    self.sourcesEmptyLabel.hidden = (self.sources.count > 0);
    [self.sourcesTable reloadData];
    [self reloadDevices];
}

- (void)reloadDevices {
    self.cameraItems = [[WLDevicesManager manager] currentVideoDevices] ?: @[];
    self.micItems    = [[WLDevicesManager manager] currentAudioDevices] ?: @[];
    [self rebuildDeviceStack:self.cameraStack
                       items:self.cameraItems
                      symbol:@"video.fill"
                   emptyText:@"未检测到摄像头"
                   addAction:@selector(cameraAddClicked:)];
    [self rebuildDeviceStack:self.micStack
                       items:self.micItems
                      symbol:@"mic.fill"
                   emptyText:@"未检测到麦克风"
                   addAction:@selector(micAddClicked:)];
}

// 已添加源的设备 uniqueID 集合（摄像头/麦克风「✓ 已添加」判定）
- (NSSet<NSString *> *)addedDeviceUIDs {
    NSMutableSet *set = [NSMutableSet set];
    for (NSDictionary *s in self.sources) {
        NSString *uid = s[@"deviceUID"];
        if (uid.length > 0) [set addObject:uid];
    }
    return set;
}

#pragma mark - UI 搭建

- (void)buildUI {
    WLAddSourceDropView *root = [[WLAddSourceDropView alloc] init];
    @weakify(self);
    root.filesDropped = ^(NSArray<NSString *> *paths) {
        @strongify(self);
        for (NSString *p in paths) {
            if ([self.addSourceDelegate respondsToSelector:@selector(addSourceDidPickMediaPath:)]) {
                [self.addSourceDelegate addSourceDidPickMediaPath:p];
            }
        }
    };
    self.window.contentView = root;

    // ===== 左栏：已添加的源 =====
    NSView *leftPane = [[NSView alloc] init];
    [root addSubview:leftPane];

    self.sourcesHeader = [NSTextField labelWithString:@"已添加的源（0）"];
    self.sourcesHeader.font = [NSFont boldSystemFontOfSize:13];
    [leftPane addSubview:self.sourcesHeader];

    self.sourcesTable = [[NSTableView alloc] init];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"source"];
    [self.sourcesTable addTableColumn:col];
    self.sourcesTable.headerView = nil;
    self.sourcesTable.rowHeight = 30;
    self.sourcesTable.style = NSTableViewStyleInset;
    self.sourcesTable.dataSource = self;
    self.sourcesTable.delegate = self;
    self.sourcesTable.allowsEmptySelection = YES;

    NSScrollView *tableScroll = [[NSScrollView alloc] init];
    tableScroll.documentView = self.sourcesTable;
    tableScroll.hasVerticalScroller = YES;
    tableScroll.autohidesScrollers = YES;
    tableScroll.borderType = NSBezelBorder;
    tableScroll.drawsBackground = YES;
    [leftPane addSubview:tableScroll];

    self.sourcesEmptyLabel = [NSTextField labelWithString:@"尚未添加任何源"];
    self.sourcesEmptyLabel.textColor = [NSColor secondaryLabelColor];
    self.sourcesEmptyLabel.font = [NSFont systemFontOfSize:12];
    [leftPane addSubview:self.sourcesEmptyLabel];

    [self.sourcesHeader mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(leftPane).offset(20);
        make.left.equalTo(leftPane).offset(20);
        make.right.lessThanOrEqualTo(leftPane).offset(-12);
    }];
    [tableScroll mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.sourcesHeader.mas_bottom).offset(10);
        make.left.equalTo(leftPane).offset(20);
        make.right.equalTo(leftPane).offset(-12);
        make.bottom.equalTo(leftPane).offset(-20);
    }];
    [self.sourcesEmptyLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.center.equalTo(tableScroll);
    }];

    // ===== 分隔线 =====
    NSBox *divider = [[NSBox alloc] init];
    divider.boxType = NSBoxSeparator;
    [root addSubview:divider];

    // ===== 右栏：添加新源 =====
    NSView *rightPane = [[NSView alloc] init];
    [root addSubview:rightPane];

    NSTextField *addHeader = [NSTextField labelWithString:@"添加新源"];
    addHeader.font = [NSFont boldSystemFontOfSize:13];
    [rightPane addSubview:addHeader];

    NSStackView *colStack = [[NSStackView alloc] init];
    colStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    colStack.alignment = NSLayoutAttributeLeading;
    colStack.spacing = 8;

    // —— 视频文件 ——
    [colStack addArrangedSubview:[self sectionHeader:@"视频文件" symbol:@"film.fill"]];
    NSButton *fileBtn = [NSButton buttonWithTitle:@"选择视频文件…" target:self
                                           action:@selector(chooseVideoFileClicked:)];
    [colStack addArrangedSubview:fileBtn];
    NSTextField *dropHint = [NSTextField labelWithString:@"也可以把视频文件直接拖进本窗口"];
    dropHint.textColor = [NSColor secondaryLabelColor];
    dropHint.font = [NSFont systemFontOfSize:11];
    [colStack addArrangedSubview:dropHint];
    [colStack setCustomSpacing:4 afterView:fileBtn];
    [colStack setCustomSpacing:16 afterView:dropHint];

    // —— 摄像头 ——
    [colStack addArrangedSubview:[self sectionHeader:@"摄像头" symbol:@"video.fill"]];
    self.cameraStack = [[NSStackView alloc] init];
    self.cameraStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.cameraStack.alignment = NSLayoutAttributeLeading;
    self.cameraStack.spacing = 2;
    [colStack addArrangedSubview:self.cameraStack];
    [colStack setCustomSpacing:16 afterView:self.cameraStack];
    [self.cameraStack mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.equalTo(colStack);
    }];

    // —— 麦克风 ——
    [colStack addArrangedSubview:[self sectionHeader:@"麦克风" symbol:@"mic.fill"]];
    self.micStack = [[NSStackView alloc] init];
    self.micStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.micStack.alignment = NSLayoutAttributeLeading;
    self.micStack.spacing = 2;
    [colStack addArrangedSubview:self.micStack];
    [self.micStack mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.equalTo(colStack);
    }];

    // 右栏滚动容器（外接设备多时可滚动）
    NSScrollView *rightScroll = [[NSScrollView alloc] init];
    rightScroll.drawsBackground = NO;
    rightScroll.hasVerticalScroller = YES;
    rightScroll.autohidesScrollers = YES;
    NSView *doc = [[NSView alloc] init];
    rightScroll.documentView = doc;
    [doc addSubview:colStack];
    [rightPane addSubview:rightScroll];

    [addHeader mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(rightPane).offset(20);
        make.left.equalTo(rightPane).offset(16);
    }];
    [rightScroll mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(addHeader.mas_bottom).offset(10);
        make.left.equalTo(rightPane).offset(16);
        make.right.bottom.equalTo(rightPane).offset(-16);
    }];
    [colStack mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.equalTo(doc);
        make.right.equalTo(doc);
        make.bottom.lessThanOrEqualTo(doc);
    }];
    [doc mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(rightScroll.contentView);
        make.width.equalTo(rightScroll.contentView);
        make.height.greaterThanOrEqualTo(colStack);
    }];

    // ===== 总布局：左 45% / 右 55% =====
    [leftPane mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.bottom.equalTo(root);
        make.width.equalTo(root).multipliedBy(0.45);
    }];
    [divider mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(leftPane.mas_right);
        make.top.equalTo(root).offset(12);
        make.bottom.equalTo(root).offset(-12);
        make.width.mas_equalTo(1);
    }];
    [rightPane mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(divider.mas_right);
        make.top.right.bottom.equalTo(root);
    }];
}

// 分区标题：SF Symbol + 文本
- (NSView *)sectionHeader:(NSString *)title symbol:(NSString *)symbol {
    NSImageView *icon = [NSImageView imageViewWithImage:
        [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]];
    icon.contentTintColor = [NSColor secondaryLabelColor];
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    label.textColor = [NSColor secondaryLabelColor];
    NSStackView *row = [NSStackView stackViewWithViews:@[icon, label]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 5;
    row.alignment = NSLayoutAttributeCenterY;
    return row;
}

// 重建一个设备分区：每行「图标 + 设备名 + （✓ 已添加 | [添加]）」
- (void)rebuildDeviceStack:(NSStackView *)stack
                     items:(NSArray<WLDeviceItem *> *)items
                    symbol:(NSString *)symbol
                 emptyText:(NSString *)emptyText
                 addAction:(SEL)addAction {
    for (NSView *v in stack.arrangedSubviews) [v removeFromSuperview];

    if (items.count == 0) {
        NSTextField *empty = [NSTextField labelWithString:emptyText];
        empty.textColor = [NSColor tertiaryLabelColor];
        empty.font = [NSFont systemFontOfSize:12];
        [stack addArrangedSubview:empty];
        return;
    }

    NSSet<NSString *> *addedUIDs = [self addedDeviceUIDs];
    for (NSUInteger i = 0; i < items.count; i++) {
        WLDeviceItem *item = items[i];

        NSImageView *icon = [NSImageView imageViewWithImage:
            [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]];
        icon.contentTintColor = [NSColor labelColor];

        NSTextField *name = [NSTextField labelWithString:(item.localizedName ?: @"未知设备")];
        name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSView *trailing;
        if (item.uniqueID.length > 0 && [addedUIDs containsObject:item.uniqueID]) {
            NSTextField *added = [NSTextField labelWithString:@"✓ 已添加"];
            added.textColor = [NSColor secondaryLabelColor];
            added.font = [NSFont systemFontOfSize:11];
            trailing = added;
        } else {
            NSButton *add = [NSButton buttonWithTitle:@"添加" target:self action:addAction];
            add.controlSize = NSControlSizeSmall;
            add.tag = (NSInteger)i;   // 行号 → cameraItems/micItems 下标
            trailing = add;
        }

        NSStackView *row = [NSStackView stackViewWithViews:@[icon, name, trailing]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 8;
        row.alignment = NSLayoutAttributeCenterY;
        row.distribution = NSStackViewDistributionFill;
        [row setHuggingPriority:NSLayoutPriorityDefaultLow
                 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [stack addArrangedSubview:row];
        [row mas_makeConstraints:^(MASConstraintMaker *make) {
            make.width.equalTo(stack);
            make.height.mas_equalTo(26);
        }];
    }
}

#pragma mark - Actions

- (void)chooseVideoFileClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = WLAddSourceVideoExtensions();
    panel.allowsMultipleSelection = YES;   // 一次可选多个文件
    @weakify(self);
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        @strongify(self);
        if (result != NSModalResponseOK) return;
        for (NSURL *url in panel.URLs) {
            if ([self.addSourceDelegate respondsToSelector:@selector(addSourceDidPickMediaPath:)]) {
                [self.addSourceDelegate addSourceDidPickMediaPath:url.path];
            }
        }
    }];
}

- (void)cameraAddClicked:(NSButton *)sender {
    NSInteger i = sender.tag;
    if (i < 0 || i >= (NSInteger)self.cameraItems.count) return;
    AVCaptureDevice *device = self.cameraItems[(NSUInteger)i].device;
    if (device && [self.addSourceDelegate respondsToSelector:@selector(addSourceDidPickCameraDevice:)]) {
        [self.addSourceDelegate addSourceDidPickCameraDevice:device];
    }
}

- (void)micAddClicked:(NSButton *)sender {
    NSInteger i = sender.tag;
    if (i < 0 || i >= (NSInteger)self.micItems.count) return;
    AVCaptureDevice *device = self.micItems[(NSUInteger)i].device;
    if (device && [self.addSourceDelegate respondsToSelector:@selector(addSourceDidPickMicDevice:)]) {
        [self.addSourceDelegate addSourceDidPickMicDevice:device];
    }
}

- (void)removeSourceClicked:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.sources.count) return;
    NSDictionary *s = self.sources[(NSUInteger)row];
    NSString *sid = s[@"sid"];
    if (sid.length == 0) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"移除「%@」？", s[@"name"] ?: @"源"];
    alert.informativeText = @"将停止该源，并从画布、混音与合成中移除。";
    [alert addButtonWithTitle:@"移除"];
    [alert addButtonWithTitle:@"取消"];
    alert.buttons.firstObject.hasDestructiveAction = YES;
    @weakify(self);
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse code) {
        @strongify(self);
        if (code != NSAlertFirstButtonReturn) return;
        if ([self.addSourceDelegate respondsToSelector:@selector(addSourceDidRequestRemove:)]) {
            [self.addSourceDelegate addSourceDidRequestRemove:sid];
        }
    }];
}

#pragma mark - NSTableView（左栏已添加源）

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.sources.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.sources.count) return nil;
    NSDictionary *s = self.sources[(NSUInteger)row];
    WLFromType t = (WLFromType)[s[@"fromType"] integerValue];
    NSString *sym = (t == WLFromTypeMic) ? @"mic.fill"
                  : (t == WLFromTypeCamera) ? @"video.fill" : @"film.fill";

    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"sourceCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = @"sourceCell";

        NSImageView *icon = [[NSImageView alloc] init];
        icon.contentTintColor = [NSColor labelColor];
        [cell addSubview:icon];
        cell.imageView = icon;

        NSTextField *label = [NSTextField labelWithString:@""];
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell addSubview:label];
        cell.textField = label;

        NSButton *remove = [NSButton buttonWithImage:
            [NSImage imageWithSystemSymbolName:@"minus.circle" accessibilityDescription:@"移除"]
                                              target:self action:@selector(removeSourceClicked:)];
        remove.bordered = NO;
        remove.contentTintColor = [NSColor systemRedColor];
        remove.identifier = @"removeBtn";
        [cell addSubview:remove];

        [icon mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(cell).offset(4);
            make.centerY.equalTo(cell);
            make.width.height.mas_equalTo(16);
        }];
        [remove mas_makeConstraints:^(MASConstraintMaker *make) {
            make.right.equalTo(cell).offset(-6);
            make.centerY.equalTo(cell);
        }];
        [label mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(icon.mas_right).offset(7);
            make.right.lessThanOrEqualTo(remove.mas_left).offset(-6);
            make.centerY.equalTo(cell);
        }];
    }

    cell.imageView.image = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
    cell.textField.stringValue = s[@"name"] ?: @"源";
    for (NSView *v in cell.subviews) {
        if ([v.identifier isEqualToString:@"removeBtn"]) ((NSButton *)v).tag = row;
    }
    return cell;
}

@end
