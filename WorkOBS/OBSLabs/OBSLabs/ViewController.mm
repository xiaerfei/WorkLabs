//
//  ViewController.mm
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//
//  .mm（Objective-C++）：OC 方法体里直接调 C++ 类（WLCore / WLSource）。
//
//  OBS 经典布局外壳：
//  ┌──────────────────────────────────────────────┐
//  │              预览（16:9 画布 + 红框边界）          │  ← 固定，不再浮动
//  ├──────┬──────┬──────────┬──────────┬───────────┤
//  │Scenes│Sources│Audio Mixer│Transitions│ Controls │  ← 底部一排 5 dock
//  └──────┴──────┴──────────┴──────────┴───────────┘
//
//  当前只有 Sources（增删源）+ 预览是"活的"；其余 dock 是占位框，功能随
//  里程碑填：场景≈M3 / 音频 M4 / 转场后续 / 录制·推流 M2·M5。
//  OBS 的"预览里拖源"（WYSIWYG）要等 M3 画布模型 + Metal 合成，故这里预览固定。
//
//  预览数据流不变：WLGraphics tick → set_frame_output（graphics 线程）
//    → onCompositedFrame（retain + hop 主线程）→ enqueue 到 AVSampleBufferDisplayLayer。
//

#import "ViewController.h"
#import "WLCore.hpp"
#import "WLSource.hpp"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// ══════════════ 预览画布（固定，videoLayer + 红框边界）══════════════
@interface WLPreviewView : NSView
@property (nonatomic, readonly) AVSampleBufferDisplayLayer *videoLayer;
@end
@implementation WLPreviewView
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.layer.borderColor = NSColor.systemRedColor.CGColor;   // 画布边界（OBS 感）
        self.layer.borderWidth = 2;

        _videoLayer = [AVSampleBufferDisplayLayer layer];
        _videoLayer.videoGravity = AVLayerVideoGravityResizeAspect; // 保宽高比，letterbox
        _videoLayer.backgroundColor = NSColor.blackColor.CGColor;
        [self.layer addSublayer:_videoLayer];
    }
    return self;
}
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];   // 禁隐式动画，缩放时视频层不滞后
    _videoLayer.frame = self.bounds;
    [CATransaction commit];
}
@end

// ══════════════ Dock 容器（深色标题栏 + 内容区，仿 OBS dock）══════════════
@interface WLDockView : NSView
@property (nonatomic, readonly) NSView *contentView;
- (instancetype)initWithTitle:(NSString *)title;
@end
@implementation WLDockView
- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithWhite:0.14 alpha:1].CGColor;
        self.layer.borderColor = [NSColor colorWithWhite:0.25 alpha:1].CGColor;
        self.layer.borderWidth = 1;

        NSView *header = [NSView new];
        header.translatesAutoresizingMaskIntoConstraints = NO;
        header.wantsLayer = YES;
        header.layer.backgroundColor = [NSColor colorWithWhite:0.18 alpha:1].CGColor;
        [self addSubview:header];

        NSTextField *label = [NSTextField labelWithString:title];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.textColor = [NSColor colorWithWhite:0.85 alpha:1];
        label.font = [NSFont boldSystemFontOfSize:11];
        [header addSubview:label];

        _contentView = [NSView new];
        _contentView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_contentView];

        [NSLayoutConstraint activateConstraints:@[
            [header.topAnchor      constraintEqualToAnchor:self.topAnchor],
            [header.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
            [header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [header.heightAnchor   constraintEqualToConstant:24],
            [label.leadingAnchor   constraintEqualToAnchor:header.leadingAnchor constant:8],
            [label.centerYAnchor   constraintEqualToAnchor:header.centerYAnchor],
            [_contentView.topAnchor      constraintEqualToAnchor:header.bottomAnchor],
            [_contentView.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
            [_contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_contentView.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
        ]];
    }
    return self;
}
@end

// ── 源列表一行的展示模型（纯 UI 记账，不进 libwl）──
@interface WLSourceRow : NSObject
@property (nonatomic, copy)   NSString *name;   // 实例名（媒体源 = 文件名）
@property (nonatomic, copy)   NSString *type;   // 类型显示名（info.type_name）
@property (nonatomic, assign) WLSource *src;    // 借用；owner = WLCore，勿 delete
@end
@implementation WLSourceRow
@end

static NSString *const kColName = @"name";

@interface ViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSMutableArray<WLSourceRow *> *rows;
@property (nonatomic, strong) WLPreviewView *previewView;
@property (nonatomic, strong) NSTableView    *tableView;
@property (nonatomic, strong) NSButton       *removeButton;
- (void)enqueuePreviewFrame:(CVPixelBufferRef)pixbuf pts:(int64_t)pts_ns;
@end

// ── 合成帧输出回调：graphics 线程被调 —— retain + 跳主线程 enqueue ──
static void onCompositedFrame(CVPixelBufferRef frame, int64_t pts_ns, void *ctx) {
    ViewController *vc = (__bridge ViewController *)ctx;
    CVPixelBufferRetain(frame);
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc enqueuePreviewFrame:frame pts:pts_ns];
        CVPixelBufferRelease(frame);
    });
}

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.rows = [NSMutableArray array];
    self.preferredContentSize = NSMakeSize(1200, 760);   // OBS 布局需要宽窗口
    [self buildUI];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (WLCore::startup(30) != 0) {
        NSLog(@"[ViewController] WLCore::startup 失败");
        return;
    }
    WLCore::set_frame_output(onCompositedFrame, (__bridge void *)self);
    self.view.window.title = @"OBSLabs";
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    WLCore::set_frame_output(NULL, NULL);   // 先摘回调，再 shutdown（下一 tick 不再回调）
    WLCore::shutdown();
    [self.rows removeAllObjects];
    [self.tableView reloadData];
    self.removeButton.enabled = NO;
    [self.previewView.videoLayer flush];
}

// ══════════════ UI 搭建（全代码，深色 OBS 主题）══════════════

- (void)buildUI {
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [NSColor colorWithWhite:0.10 alpha:1].CGColor;

    // ── 预览区（画布外围深色，画布 16:9 居中）──
    NSView *previewArea = [NSView new];
    previewArea.translatesAutoresizingMaskIntoConstraints = NO;
    previewArea.wantsLayer = YES;
    previewArea.layer.backgroundColor = [NSColor colorWithWhite:0.06 alpha:1].CGColor;
    [self.view addSubview:previewArea];

    WLPreviewView *preview = [[WLPreviewView alloc] initWithFrame:NSZeroRect];
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewView = preview;
    [previewArea addSubview:preview];

    // 画布 aspect-fit：16:9、居中、尽量大但不超出（<= 优先级 + 期望宽高 750 优先级）
    NSLayoutConstraint *wantW = [preview.widthAnchor constraintEqualToAnchor:previewArea.widthAnchor constant:-24];
    wantW.priority = 750;
    NSLayoutConstraint *wantH = [preview.heightAnchor constraintEqualToAnchor:previewArea.heightAnchor constant:-24];
    wantH.priority = 750;

    // ── 底部 dock 栏（一排 5 个）──
    WLDockView *scenesDock   = [[WLDockView alloc] initWithTitle:@"场景 Scenes"];
    WLDockView *sourcesDock  = [[WLDockView alloc] initWithTitle:@"源 Sources"];
    WLDockView *audioDock    = [[WLDockView alloc] initWithTitle:@"混音器 Audio Mixer"];
    WLDockView *transDock    = [[WLDockView alloc] initWithTitle:@"转场 Transitions"];
    WLDockView *controlsDock = [[WLDockView alloc] initWithTitle:@"控制 Controls"];

    [self fillSourcesDock:sourcesDock];
    [self fillControlsDock:controlsDock];
    [self fillPlaceholderDock:scenesDock text:@"场景（≈M3）"];
    [self fillPlaceholderDock:audioDock  text:@"音频混音（M4）"];
    [self fillPlaceholderDock:transDock  text:@"转场（后续）"];

    NSStackView *dockBar = [NSStackView stackViewWithViews:@[scenesDock, sourcesDock, audioDock, transDock, controlsDock]];
    dockBar.translatesAutoresizingMaskIntoConstraints = NO;
    dockBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    dockBar.distribution = NSStackViewDistributionFillEqually;
    dockBar.spacing = 6;
    [self.view addSubview:dockBar];

    const CGFloat pad = 8;
    [NSLayoutConstraint activateConstraints:@[
        // 预览区：上部，底部让位 dock 栏
        [previewArea.topAnchor      constraintEqualToAnchor:self.view.topAnchor      constant:pad],
        [previewArea.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor  constant:pad],
        [previewArea.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [previewArea.bottomAnchor   constraintEqualToAnchor:dockBar.topAnchor        constant:-pad],
        // 画布 aspect-fit 居中
        [preview.centerXAnchor constraintEqualToAnchor:previewArea.centerXAnchor],
        [preview.centerYAnchor constraintEqualToAnchor:previewArea.centerYAnchor],
        [preview.widthAnchor   constraintEqualToAnchor:preview.heightAnchor multiplier:16.0/9.0],
        [preview.widthAnchor   constraintLessThanOrEqualToAnchor:previewArea.widthAnchor  constant:-24],
        [preview.heightAnchor  constraintLessThanOrEqualToAnchor:previewArea.heightAnchor constant:-24],
        wantW, wantH,
        // dock 栏：底部，固定高
        [dockBar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor  constant:pad],
        [dockBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [dockBar.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor   constant:-pad],
        [dockBar.heightAnchor   constraintEqualToConstant:200],
    ]];
}

// Sources dock：源列表（NSTableView 单列，无表头）+ 底部 +/− 工具条
- (void)fillSourcesDock:(WLDockView *)dock {
    NSView *c = dock.contentView;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;

    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.dataSource = self;
    table.delegate = self;
    table.headerView = nil;                 // OBS 源列表无表头
    table.backgroundColor = [NSColor colorWithWhite:0.16 alpha:1];
    table.rowHeight = 20;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:kColName];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [table addTableColumn:col];
    scroll.documentView = table;
    self.tableView = table;

    NSButton *add = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"添加源"]
                                       target:self action:@selector(pickAddSourceType:)];
    add.translatesAutoresizingMaskIntoConstraints = NO;
    add.bezelStyle = NSBezelStyleSmallSquare;
    add.toolTip = @"添加源";

    NSButton *remove = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"minus" accessibilityDescription:@"删除源"]
                                          target:self action:@selector(removeSelectedSource:)];
    remove.translatesAutoresizingMaskIntoConstraints = NO;
    remove.bezelStyle = NSBezelStyleSmallSquare;
    remove.enabled = NO;
    remove.toolTip = @"删除选中的源";
    self.removeButton = remove;

    [c addSubview:scroll];
    [c addSubview:add];
    [c addSubview:remove];

    const CGFloat btn = 24;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor      constraintEqualToAnchor:c.topAnchor      constant:2],
        [scroll.leadingAnchor  constraintEqualToAnchor:c.leadingAnchor  constant:2],
        [scroll.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-2],
        [scroll.bottomAnchor   constraintEqualToAnchor:add.topAnchor    constant:-4],
        [add.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:4],
        [add.bottomAnchor  constraintEqualToAnchor:c.bottomAnchor  constant:-4],
        [add.widthAnchor   constraintEqualToConstant:btn],
        [add.heightAnchor  constraintEqualToConstant:btn],
        [remove.leadingAnchor constraintEqualToAnchor:add.trailingAnchor constant:4],
        [remove.bottomAnchor  constraintEqualToAnchor:add.bottomAnchor],
        [remove.widthAnchor   constraintEqualToConstant:btn],
        [remove.heightAnchor  constraintEqualToConstant:btn],
    ]];
}

// Controls dock：占位按钮（功能待 M2 录制 / M5 推流）
- (void)fillControlsDock:(WLDockView *)dock {
    NSArray<NSString *> *titles = @[@"开始推流", @"开始录制", @"虚拟摄像头", @"Studio Mode", @"设置"];
    NSMutableArray<NSView *> *btns = [NSMutableArray array];
    for (NSString *t in titles) {
        NSButton *b = [NSButton buttonWithTitle:t target:nil action:nil];
        b.bezelStyle = NSBezelStyleRounded;
        b.enabled = NO;                    // 占位：录制/推流是 M2/M5
        [btns addObject:b];
    }
    NSStackView *sv = [NSStackView stackViewWithViews:btns];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.orientation = NSUserInterfaceLayoutOrientationVertical;
    sv.distribution = NSStackViewDistributionFillEqually;
    sv.spacing = 4;
    [dock.contentView addSubview:sv];
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor      constraintEqualToAnchor:dock.contentView.topAnchor      constant:8],
        [sv.leadingAnchor  constraintEqualToAnchor:dock.contentView.leadingAnchor  constant:8],
        [sv.trailingAnchor constraintEqualToAnchor:dock.contentView.trailingAnchor constant:-8],
        [sv.bottomAnchor   constraintLessThanOrEqualToAnchor:dock.contentView.bottomAnchor constant:-8],
    ]];
}

// 占位 dock：居中灰字提示
- (void)fillPlaceholderDock:(WLDockView *)dock text:(NSString *)text {
    NSTextField *l = [NSTextField labelWithString:text];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.textColor = [NSColor colorWithWhite:0.5 alpha:1];
    l.font = [NSFont systemFontOfSize:11];
    [dock.contentView addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:dock.contentView.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:dock.contentView.centerYAnchor],
    ]];
}

// ══════════════ 预览：enqueue 合成帧 ══════════════

- (void)enqueuePreviewFrame:(CVPixelBufferRef)pixbuf pts:(int64_t)pts_ns {
    AVSampleBufferDisplayLayer *layer = self.previewView.videoLayer;
    if (!layer) return;
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush];

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixbuf, &fmt) != noErr) return;
    CMSampleTimingInfo timing;
    timing.duration = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTimeMake(pts_ns, NSEC_PER_SEC);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixbuf, fmt, &timing, &sb);
    CFRelease(fmt);
    if (st != noErr || !sb) return;

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sb, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    [layer enqueueSampleBuffer:sb];
    CFRelease(sb);
}

// ══════════════ 添加 / 删除源 ══════════════

- (void)pickAddSourceType:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"添加源"];
    NSMenuItem *item = [menu addItemWithTitle:@"媒体文件…"
                                       action:@selector(addSourceFromMenu:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = @"media_file";
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
}

- (void)addSourceFromMenu:(NSMenuItem *)item {
    if ([item.representedObject isEqualToString:@"media_file"]) [self addMediaFileSource];
}

- (void)addMediaFileSource {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择媒体文件";
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *path = panel.URLs.firstObject.path;
        if (path.length == 0) return;

        WLSource *src = WLCore::add_source("media_file", path.fileSystemRepresentation);
        if (!src) { [self warn:[NSString stringWithFormat:@"添加失败：%@", path.lastPathComponent]]; return; }
        if (src->start() != 0) {
            WLCore::remove_source(src);
            [self warn:[NSString stringWithFormat:@"启动失败：%@", path.lastPathComponent]];
            return;
        }
        WLSourceRow *row = [WLSourceRow new];
        row.src  = src;
        row.name = path.lastPathComponent;
        row.type = src->info.type_name ? @(src->info.type_name) : @"—";
        [self.rows addObject:row];
        [self.tableView reloadData];
        NSInteger i = (NSInteger)self.rows.count - 1;
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
        NSLog(@"[ViewController] 已添加源: %@", path);
    }];
}

- (void)removeSelectedSource:(id)sender {
    NSInteger idx = self.tableView.selectedRow;
    if (idx < 0 || idx >= (NSInteger)self.rows.count) return;
    WLSourceRow *row = self.rows[idx];
    WLSource *src = row.src;
    [self.rows removeObjectAtIndex:idx];   // 先摘展示模型，再交 WLCore 销毁（内部 delete）
    WLCore::remove_source(src);
    [self.tableView reloadData];
    self.removeButton.enabled = self.tableView.selectedRow >= 0;
    NSLog(@"[ViewController] 已删除源: %@", row.name);
}

- (void)warn:(NSString *)msg {
    NSLog(@"[ViewController] %@", msg);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = msg;
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

// ══════════════ NSTableView 数据源 / 委托 ══════════════

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.rows.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)column
                  row:(NSInteger)rowIndex {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:kColName owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = kColName;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell addSubview:tf];
        cell.textField = tf;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor  constraintEqualToAnchor:cell.leadingAnchor  constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    WLSourceRow *row = self.rows[rowIndex];
    cell.textField.stringValue = row.name;
    cell.textField.toolTip = [NSString stringWithFormat:@"%@（%@）", row.name, row.type];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    self.removeButton.enabled = self.tableView.selectedRow >= 0;
}

@end
