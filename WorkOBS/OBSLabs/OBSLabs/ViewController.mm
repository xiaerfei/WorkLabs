//
//  ViewController.mm
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//
//  .mm（Objective-C++）：OC 方法体里直接调 C++ 类（WLCore / WLSource）。
//
//  源管理 UI（OBS Sources dock 形状）+ 预览画面。
//
//  ┌────────────────────────────┐
//  │        预览（合成帧）         │  ← AVSampleBufferDisplayLayer
//  ├────────────────────────────┤
//  │  源列表（NSTableView）        │  ← 增删源
//  ├────────────────────────────┤
//  │  [+] [−]                    │
//  └────────────────────────────┘
//
//  预览数据流（对齐 OBS「合成一次、多处消费」的 push 模型）：
//    WLGraphics 节拍线程每 tick 挑帧 → 合成（Step1=直显）→ set_frame_output 回调
//      → onCompositedFrame（在 graphics 线程！retain + hop 主线程）
//      → enqueuePreviewFrame（主线程 enqueue 到 AVSampleBufferDisplayLayer）
//  Step2(M3) 把 WLGraphics 里的"直显"换成 Metal 合成，这条 UI 通路不变。
//

#import "ViewController.h"
#import "WLCore.hpp"
#import "WLSource.hpp"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// ── 预览 view：可拖动 + 8-handle 缩放的浮动面板 ──
// videoLayer(AVSampleBufferDisplayLayer) 显示画面；上叠 border + 8 手柄，表示可操作。
// 注意：拖的是"预览框本身"在窗口里的位置/大小，与 libwl / 画布模型无关——
// OBS 式"拖源"（源在画布上的 transform）要等 M3 画布模型 + Metal 合成（见 ToDo）。
typedef NS_ENUM(NSInteger, WLPreviewHandle) {
    WLPreviewHandleNone = 0, WLPreviewHandleBody,
    WLPreviewHandleNW, WLPreviewHandleN, WLPreviewHandleNE, WLPreviewHandleE,
    WLPreviewHandleSE, WLPreviewHandleS, WLPreviewHandleSW, WLPreviewHandleW,
};

static const CGFloat kHandleSize  = 10;   // 手柄方块边长（也是命中容差基准）
static const CGFloat kMinPreviewW = 160;
static const CGFloat kMinPreviewH = 90;

@interface WLPreviewView : NSView
@property (nonatomic, readonly) AVSampleBufferDisplayLayer *videoLayer;
@property (nonatomic) BOOL userInteracted;   // 用户拖/缩放过一次后不再自动居中
@end

@implementation WLPreviewView {
    CALayer        *_border;
    CAShapeLayer   *_handles;
    WLPreviewHandle _active;      // 正在拖的手柄（Body = 整体移动）
    NSRect          _startFrame;  // mouseDown 时的 frame
    NSPoint         _startMouse;  // mouseDown 时鼠标（父坐标）
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;

        _videoLayer = [AVSampleBufferDisplayLayer layer];
        _videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;  // 保宽高比，letterbox
        _videoLayer.backgroundColor = NSColor.blackColor.CGColor;
        [self.layer addSublayer:_videoLayer];

        _border = [CALayer layer];
        _border.borderWidth = 1.5;
        _border.borderColor = NSColor.controlAccentColor.CGColor;
        [self.layer addSublayer:_border];

        _handles = [CAShapeLayer layer];
        _handles.fillColor   = NSColor.whiteColor.CGColor;
        _handles.strokeColor = NSColor.controlAccentColor.CGColor;
        _handles.lineWidth   = 1;
        [self.layer addSublayer:_handles];

        [self updateSublayerLayout];
    }
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateSublayerLayout];
}

// sublayer 跟随 bounds；禁隐式动画，避免拖动时视频/手柄层滞后跳动
- (void)updateSublayerLayout {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _videoLayer.frame = self.bounds;
    _border.frame     = self.bounds;
    _handles.frame    = self.bounds;

    CGMutablePathRef path = CGPathCreateMutable();
    NSRect b = self.bounds;
    CGFloat h = kHandleSize;
    NSPoint c[8] = {
        {NSMinX(b), NSMaxY(b)}, {NSMidX(b), NSMaxY(b)}, {NSMaxX(b), NSMaxY(b)},
        {NSMaxX(b), NSMidY(b)}, {NSMaxX(b), NSMinY(b)}, {NSMidX(b), NSMinY(b)},
        {NSMinX(b), NSMinY(b)}, {NSMinX(b), NSMidY(b)},
    };
    for (int i = 0; i < 8; i++)
        CGPathAddRect(path, NULL, NSMakeRect(c[i].x - h/2, c[i].y - h/2, h, h));
    _handles.path = path;
    CGPathRelease(path);
    [CATransaction commit];
}

// 命中测试（view 本地坐标）：落在哪个手柄，否则 Body / None
- (WLPreviewHandle)handleAt:(NSPoint)pt {
    NSRect b = self.bounds;
    CGFloat h = kHandleSize;
    struct { WLPreviewHandle type; NSPoint c; } hs[8] = {
        {WLPreviewHandleNW, {NSMinX(b), NSMaxY(b)}}, {WLPreviewHandleN, {NSMidX(b), NSMaxY(b)}},
        {WLPreviewHandleNE, {NSMaxX(b), NSMaxY(b)}}, {WLPreviewHandleE, {NSMaxX(b), NSMidY(b)}},
        {WLPreviewHandleSE, {NSMaxX(b), NSMinY(b)}}, {WLPreviewHandleS, {NSMidX(b), NSMinY(b)}},
        {WLPreviewHandleSW, {NSMinX(b), NSMinY(b)}}, {WLPreviewHandleW, {NSMinX(b), NSMidY(b)}},
    };
    for (int i = 0; i < 8; i++) {
        NSRect r = NSMakeRect(hs[i].c.x - h/2, hs[i].c.y - h/2, h, h);
        if (NSPointInRect(pt, NSInsetRect(r, -3, -3))) return hs[i].type;   // 命中区放大 3pt
    }
    return NSPointInRect(pt, b) ? WLPreviewHandleBody : WLPreviewHandleNone;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    _active     = [self handleAt:local];
    _startFrame = self.frame;
    _startMouse = [self.superview convertPoint:event.locationInWindow fromView:nil];
    [self.superview addSubview:self positioned:NSWindowAbove relativeTo:nil];  // 点击置顶
}

- (void)mouseDragged:(NSEvent *)event {
    if (_active == WLPreviewHandleNone) return;
    self.userInteracted = YES;   // 用户接管摆放，viewDidLayout 不再自动居中
    NSPoint cur = [self.superview convertPoint:event.locationInWindow fromView:nil];
    CGFloat dx = cur.x - _startMouse.x, dy = cur.y - _startMouse.y;

    BOOL left   = (_active==WLPreviewHandleW || _active==WLPreviewHandleNW || _active==WLPreviewHandleSW);
    BOOL right  = (_active==WLPreviewHandleE || _active==WLPreviewHandleNE || _active==WLPreviewHandleSE);
    BOOL bottom = (_active==WLPreviewHandleS || _active==WLPreviewHandleSW || _active==WLPreviewHandleSE);
    BOOL top    = (_active==WLPreviewHandleN || _active==WLPreviewHandleNW || _active==WLPreviewHandleNE);

    NSRect f = _startFrame;
    if (_active == WLPreviewHandleBody) {
        f.origin.x += dx; f.origin.y += dy;
        NSRect pb = self.superview.bounds;   // 移动限制在父视图内
        f.origin.x = MAX(0, MIN(f.origin.x, NSWidth(pb)  - NSWidth(f)));
        f.origin.y = MAX(0, MIN(f.origin.y, NSHeight(pb) - NSHeight(f)));
    } else {
        if (left)   { f.origin.x += dx; f.size.width  -= dx; }
        if (right)  { f.size.width  += dx; }
        if (bottom) { f.origin.y += dy; f.size.height -= dy; }
        if (top)    { f.size.height += dy; }
        if (f.size.width < kMinPreviewW) {         // clamp 最小宽（保持对边固定）
            if (left) f.origin.x = NSMaxX(_startFrame) - kMinPreviewW;
            f.size.width = kMinPreviewW;
        }
        if (f.size.height < kMinPreviewH) {
            if (bottom) f.origin.y = NSMaxY(_startFrame) - kMinPreviewH;
            f.size.height = kMinPreviewH;
        }
    }
    self.frame = f;   // 触发 setFrameSize → sublayer 跟随
}

- (void)mouseUp:(NSEvent *)event { _active = WLPreviewHandleNone; }

@end

// ── 列表一行的展示模型（纯 UI 记账，不进 libwl）──
@interface WLSourceRow : NSObject
@property (nonatomic, copy)   NSString *name;   // 实例名（媒体源 = 文件名）
@property (nonatomic, copy)   NSString *type;   // 类型显示名（info.type_name）
@property (nonatomic, assign) WLSource *src;    // 借用；owner = WLCore，勿 delete
@end
@implementation WLSourceRow
@end

// 列标识（view-based table 复用 + 取值分流都靠它）
static NSString *const kColName = @"name";
static NSString *const kColType = @"type";

@interface ViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSMutableArray<WLSourceRow *> *rows;
@property (nonatomic, strong) WLPreviewView *previewView;
@property (nonatomic, strong) NSTableView    *tableView;
@property (nonatomic, strong) NSButton       *removeButton;
- (void)enqueuePreviewFrame:(CVPixelBufferRef)pixbuf pts:(int64_t)pts_ns;
@end

// ── 合成帧输出回调：在 graphics 线程被调 —— 只做轻量转发（retain + 跳主线程）──
// AVSampleBufferDisplayLayer 要在主线程 enqueue；且 frame 是 borrow，跨线程必须 retain。
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
    self.preferredContentSize = NSMakeSize(640, 520);
    [self buildUI];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    // 全局核心：注册内置源类型 + 启动 30fps 合成节拍。startup 幂等——放这里而非
    // viewDidLoad，是为了显隐多次时每次都确保节拍在跑（viewWillDisappear 会 shutdown）。
    if (WLCore::startup(30) != 0) {
        NSLog(@"[ViewController] WLCore::startup 失败");
        return;
    }
    // 注册预览输出（graphics 已在跑，set 线程安全）。self 不 retain，靠生命周期对齐：
    // viewWillDisappear 先注销再 shutdown，回调期间 self 必活。
    WLCore::set_frame_output(onCompositedFrame, (__bridge void *)self);
    self.view.window.title = @"OBSLabs — 源管理 + 预览";
}

// 预览是浮动层：只要用户没手动拖过，就随实际 bounds 自动居中到上部（保证可见 + 大小合适）。
// 关键——不能在 viewDidLoad 用写死 frame：那时 view 还是 storyboard 的 480×270，
// preferredContentSize 未生效，写死值会越界 + 被 autoresizing 推出屏。
- (void)viewDidLayout {
    [super viewDidLayout];
    if (self.previewView.userInteracted) return;
    NSRect target = [self defaultPreviewFrame];
    if (NSIsEmptyRect(target)) return;
    if (NSEqualRects(target, self.previewView.frame)) return;   // 已就位，别再改（防递归）
    // 不能在 layout pass 内同步改 frame：setFrameSize 会冒泡 setNeedsUpdateConstraints，
    // 在本轮布局里又请求新一轮 → 每帧递归、pass 次数超上限直接崩（上个版本的崩因）。
    // async 到 pass 之后再改；改完下一轮 target==frame，NSEqualRects 命中、自然收敛。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.previewView.userInteracted && !NSEqualRects(target, self.previewView.frame))
            self.previewView.frame = target;
    });
}

- (NSRect)defaultPreviewFrame {
    NSRect b = self.view.bounds;
    if (b.size.width < 100 || b.size.height < 100) return NSZeroRect;   // 尺寸还没定
    CGFloat w = b.size.width - 24;             // 左右各留 12
    CGFloat h = w * 9.0 / 16.0;
    CGFloat maxH = b.size.height * 0.62;       // 上部约 62%，给下方列表留空间
    if (h > maxH) { h = maxH; w = h * 16.0 / 9.0; }
    CGFloat x = (b.size.width - w) / 2.0;
    CGFloat y = b.size.height - h - 12;        // 贴顶部留 12
    return NSMakeRect(x, y, w, h);
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    // 顺序要害：先摘回调（graphics 还在，安全注销 → 下一 tick 不再回调），再 shutdown
    // 停节拍 join 线程。在途的 dispatch_async 到主线程时 self/layer 都还在，且帧已 retain。
    WLCore::set_frame_output(NULL, NULL);
    WLCore::shutdown();               // 停节拍 + delete 所有源 → rows 里的裸指针全悬空
    [self.rows removeAllObjects];
    [self.tableView reloadData];
    self.removeButton.enabled = NO;
    [self.previewView.videoLayer flush];
}

// ═════════════════ UI 搭建（全代码，无 IB outlet）═════════════════

- (void)buildUI {
    // 预览画面（可拖动 + 缩放的浮动面板；frame-based，不进 Auto Layout）
    WLPreviewView *preview = [[WLPreviewView alloc] initWithFrame:NSMakeRect(60, 190, 520, 300)];
    preview.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    self.previewView = preview;

    // 源列表（NSScrollView 包 NSTableView）
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;

    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.dataSource = self;
    table.delegate = self;
    table.usesAlternatingRowBackgroundColors = YES;
    table.rowHeight = 22;
    table.allowsMultipleSelection = NO;

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:kColName];
    nameCol.title = @"源";
    nameCol.width = 420;
    nameCol.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [table addTableColumn:nameCol];

    NSTableColumn *typeCol = [[NSTableColumn alloc] initWithIdentifier:kColType];
    typeCol.title = @"类型";
    typeCol.width = 150;
    typeCol.resizingMask = NSTableColumnUserResizingMask;
    [table addTableColumn:typeCol];

    scroll.documentView = table;
    self.tableView = table;

    // 底部 +/− 工具条
    NSButton *addButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"添加源"]
                                             target:self
                                             action:@selector(pickAddSourceType:)];
    addButton.translatesAutoresizingMaskIntoConstraints = NO;
    addButton.bezelStyle = NSBezelStyleSmallSquare;
    addButton.toolTip = @"添加源";

    NSButton *removeButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"minus" accessibilityDescription:@"删除源"]
                                                target:self
                                                action:@selector(removeSelectedSource:)];
    removeButton.translatesAutoresizingMaskIntoConstraints = NO;
    removeButton.bezelStyle = NSBezelStyleSmallSquare;
    removeButton.toolTip = @"删除选中的源";
    removeButton.enabled = NO;   // 无选中 → 不可删
    self.removeButton = removeButton;

    [self.view addSubview:scroll];
    [self.view addSubview:addButton];
    [self.view addSubview:removeButton];
    [self.view addSubview:preview];   // 最后 add → 浮在最上层

    const CGFloat pad = 12, btn = 28, gap = 8;
    [NSLayoutConstraint activateConstraints:@[
        // 列表 + 工具条走 Auto Layout 占满窗口；预览是浮动层（frame-based）盖在其上
        [scroll.topAnchor      constraintEqualToAnchor:self.view.topAnchor      constant:pad],
        [scroll.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor  constant:pad],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [scroll.bottomAnchor   constraintEqualToAnchor:addButton.topAnchor      constant:-gap],
        // + 按钮：左下角
        [addButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [addButton.bottomAnchor  constraintEqualToAnchor:self.view.bottomAnchor  constant:-pad],
        [addButton.widthAnchor   constraintEqualToConstant:btn],
        [addButton.heightAnchor  constraintEqualToConstant:btn],
        // − 按钮：紧挨 + 右侧
        [removeButton.leadingAnchor constraintEqualToAnchor:addButton.trailingAnchor constant:gap],
        [removeButton.bottomAnchor  constraintEqualToAnchor:addButton.bottomAnchor],
        [removeButton.widthAnchor   constraintEqualToConstant:btn],
        [removeButton.heightAnchor  constraintEqualToConstant:btn],
    ]];
}

// ═════════════════ 预览：enqueue 合成帧 ═════════════════

// 主线程调用：把 CVPixelBuffer 包成 CMSampleBuffer 喂给 display layer。
// 加 DisplayImmediately attachment → 立即显示（节奏由 graphics 30fps push 控制，
// layer 只负责显示最新帧，不自己按 PTS 调度 → 多源 PTS 跳变也不影响）。
- (void)enqueuePreviewFrame:(CVPixelBufferRef)pixbuf pts:(int64_t)pts_ns {
    AVSampleBufferDisplayLayer *layer = self.previewView.videoLayer;
    if (!layer) return;
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [layer flush];   // 解码错误/中断后要 flush 才能恢复
    }

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixbuf, &fmt) != noErr) {
        return;
    }
    CMSampleTimingInfo timing;
    timing.duration = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTimeMake(pts_ns, NSEC_PER_SEC);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixbuf, fmt, &timing, &sb);
    CFRelease(fmt);
    if (st != noErr || !sb) return;

    // DisplayImmediately：本帧一入队即渲染，不等 PTS
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sb, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }

    [layer enqueueSampleBuffer:sb];
    CFRelease(sb);
}

// ═════════════════ 添加源 ═════════════════

// + 按钮：弹类型菜单（对齐 OBS "点 + 选源类型"）。现在只有一种内置类型；
// 将来加 Camera / 图片源，这里多挂一个菜单项即可（representedObject 存 type_id）。
- (void)pickAddSourceType:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"添加源"];
    NSMenuItem *item = [menu addItemWithTitle:@"媒体文件…"
                                       action:@selector(addSourceFromMenu:)
                                keyEquivalent:@""];
    item.target = self;
    item.representedObject = @"media_file";   // = wl_source_type_info.id
    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0, NSHeight(sender.bounds))
                            inView:sender];
}

- (void)addSourceFromMenu:(NSMenuItem *)item {
    NSString *typeId = item.representedObject;
    if ([typeId isEqualToString:@"media_file"]) {
        [self addMediaFileSource];
    }
}

// 媒体文件源：选文件 → add_source + start → 建 row。
- (void)addMediaFileSource {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择媒体文件";
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;

    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *path = panel.URLs.firstObject.path;
        if (path.length == 0) return;

        WLSource *src = WLCore::add_source("media_file", path.fileSystemRepresentation);
        if (!src) {
            [self warn:[NSString stringWithFormat:@"添加失败：%@", path.lastPathComponent]];
            return;
        }
        if (src->start() != 0) {
            WLCore::remove_source(src);   // start 失败即回滚（出表 + delete）
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
        NSLog(@"[ViewController] 已添加源（预览应出画面，看 [get]/[gfx] 日志）: %@", path);
    }];
}

// ═════════════════ 删除源 ═════════════════

- (void)removeSelectedSource:(id)sender {
    NSInteger idx = self.tableView.selectedRow;
    if (idx < 0 || idx >= (NSInteger)self.rows.count) return;

    WLSourceRow *row = self.rows[idx];
    WLSource *src = row.src;

    // 顺序要害：先从展示模型摘掉（之后 UI 再也不碰这行），再交给 WLCore 销毁。
    // remove_source 内部 delete src → 走虚析构链 join 解码线程，可能略卡主线程，
    // 学习项目可接受（OBS 用引用计数 + defer 销毁避免这点，M 后期再论）。
    [self.rows removeObjectAtIndex:idx];
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

// ═════════════════ NSTableView 数据源 / 委托 ═════════════════

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.rows.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)column
                  row:(NSInteger)rowIndex {
    NSString *ident = column.identifier;
    NSTableCellView *cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        // 没在 IB 建原型 cell，手搓一个：NSTableCellView + 居中 label
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = ident;
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
    cell.textField.stringValue = [ident isEqualToString:kColType] ? row.type : row.name;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    self.removeButton.enabled = self.tableView.selectedRow >= 0;
}

@end
