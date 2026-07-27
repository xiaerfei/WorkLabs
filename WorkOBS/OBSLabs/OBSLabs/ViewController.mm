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
//  │              画布（16:9 居中）                  │  ← WLCanvasView + per-source 浮层
//  ├──────┬──────┬──────────┬──────────┬───────────┤
//  │Scenes│Sources│Audio Mixer│Transitions│ Controls │  ← WLDockManager 管理的 5 dock
//  └──────┴──────┴──────────┴──────────┴───────────┘
//
//  每个源有独立的 WLSourcePreview 浮层（拖拽/缩放/选中/右键）。
//  帧由 graphics 线程每 tick 逐源 push（WLCore::set_frame_output，对标 OBS
//  render_displays：渲染线程推、UI 不拉），hop 主线程后按 src 路由到浮层。
//

#import "ViewController.h"
#import "WLDockManager.h"
#import "WLCanvasView.h"
#import "WLCanvasLayout.h"
#import "WLSourcePreview.h"
#import "WLCore.hpp"
#import "WLSource.hpp"
#import <AVFoundation/AVFoundation.h>

// ── 源跟踪记录 ──
@interface WLSourceEntry : NSObject
@property (nonatomic, assign) WLSource *src;       // 借用；owner = WLCore
@property (nonatomic, copy)   NSString *sourceID;  // src 指针的字符串形式，做字典 key
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, strong) WLSourcePreview *preview;
@end
@implementation WLSourceEntry
@end

@interface ViewController () <WLSourcePreviewDelegate>
@property (nonatomic, strong) WLCanvasView    *canvasView;
@property (nonatomic, strong) WLCanvasLayout  *canvasLayout;
@property (nonatomic, strong) WLDockManager   *dockManager;
@property (nonatomic, strong) NSMutableArray<WLSourceEntry *> *sources;
@property (nonatomic, assign) NSUInteger       subTagSourceAdded;
@property (nonatomic, assign) NSUInteger       subTagSourceRemoved;
@property (nonatomic, assign) NSUInteger       subTagSourceSelection;
- (void)dispatchFrame:(CVPixelBufferRef)frame pts:(int64_t)pts_ns forSource:(WLSource *)src;
@end

static void onSourceFrame(WLSource *src, CVPixelBufferRef frame, int64_t pts_ns, void *ctx);

@implementation ViewController {
    BOOL _didSetInitialSize;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.sources = [NSMutableArray array];
    self.canvasLayout = [[WLCanvasLayout alloc] init];
    [self buildUI];
    [self subscribeEvents];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (WLCore::startup(30) != 0) {
        NSLog(@"[ViewController] WLCore::startup 失败");
        return;
    }
    NSWindow *win = self.view.window;
    win.title = @"OBSLabs";
    if (!_didSetInitialSize) {
        _didSetInitialSize = YES;
        [win setContentSize:NSMakeSize(960, 600)];
        [win center];
    }
    WLCore::set_frame_output(onSourceFrame, (__bridge void *)self);
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    WLCore::set_frame_output(NULL, NULL);   // 先掐输出，graphics 不再进回调
    [self.dockManager viewWillDisappear];
    WLCore::shutdown();                      // join 节拍/源线程，返回后无在途 libwl 调用
    // shutdown 已销毁所有 WLSource：把 UI 侧的裸指针和浮层一并清掉，
    // 否则重开窗口（点 Dock 图标）再 startup 时会用到悬垂 src。
    for (WLSourceEntry *e in self.sources) {
        [e.preview flush];
        [e.preview removeFromSuperview];
        [self.canvasLayout removeLayoutForSourceID:e.sourceID];
    }
    [self.sources removeAllObjects];
}

- (void)dealloc {
    [self.dockManager unsubscribeWithTag:self.subTagSourceAdded];
    [self.dockManager unsubscribeWithTag:self.subTagSourceRemoved];
    [self.dockManager unsubscribeWithTag:self.subTagSourceSelection];
}

#pragma mark - 事件订阅

- (void)subscribeEvents {
    __weak typeof(self) weakSelf = self;

    self.subTagSourceAdded = [self.dockManager subscribeEvent:WLEventTypeSourceAdded
                                                      handler:^(WLEventType event, id __nullable info) {
        [weakSelf handleSourceAdded:info];
    }];

    self.subTagSourceRemoved = [self.dockManager subscribeEvent:WLEventTypeSourceRemoved
                                                        handler:^(WLEventType event, id __nullable info) {
        [weakSelf handleSourceRemoved:info];
    }];

    self.subTagSourceSelection = [self.dockManager subscribeEvent:WLEventTypeSourceSelectionChanged
                                                          handler:^(WLEventType event, id __nullable info) {
        [weakSelf handleSourceSelectionChanged:info];
    }];
}

- (void)handleSourceAdded:(NSDictionary *)info {
    NSValue *srcVal = info[@"sourcePtr"];
    NSString *name  = info[@"name"];
    if (!srcVal) return;
    WLSource *src = (WLSource *)[srcVal pointerValue];
    if (!src) return;

    NSString *sid = [NSString stringWithFormat:@"%p", src];

    // 去重
    for (WLSourceEntry *e in self.sources) {
        if (e.src == src) return;
    }

    // 创建浮层：画布中央 50%
    CGSize cs = self.canvasLayout.canvasSize;
    CGRect canvasRect = CGRectMake(cs.width * 0.25, cs.height * 0.25,
                                   cs.width * 0.5,  cs.height * 0.5);
    CGRect viewRect = [self viewRectFromCanvasRect:canvasRect];

    WLSourcePreview *preview = [[WLSourcePreview alloc] initWithFrame:viewRect];
    preview.delegate = self;
    preview.translatesAutoresizingMaskIntoConstraints = YES;
    [self.canvasView addSubview:preview];

    WLSourceEntry *entry = [WLSourceEntry new];
    entry.src = src;
    entry.sourceID = sid;
    entry.name = name ?: @"源";
    entry.preview = preview;
    [self.sources addObject:entry];

    [self.canvasLayout setLayoutRect:canvasRect forSourceID:sid];
    NSLog(@"[ViewController] 浮层已创建: %@ (%@)", entry.name, sid);
}

- (void)handleSourceRemoved:(NSDictionary *)info {
    NSValue *srcVal = info[@"sourcePtr"];
    if (!srcVal) return;
    WLSource *src = (WLSource *)[srcVal pointerValue];

    for (NSInteger i = 0; i < (NSInteger)self.sources.count; i++) {
        WLSourceEntry *e = self.sources[i];
        if (e.src == src) {
            e.preview.selected = NO;
            [e.preview flush];
            [e.preview removeFromSuperview];
            [self.canvasLayout removeLayoutForSourceID:e.sourceID];
            [self.sources removeObjectAtIndex:i];
            NSLog(@"[ViewController] 浮层已移除: %@", e.name);
            return;
        }
    }
}

- (void)handleSourceSelectionChanged:(NSDictionary *)info {
    id srcVal = info[@"sourcePtr"];
    WLSource *selectedSrc = nil;
    if ([srcVal isKindOfClass:[NSValue class]]) {
        selectedSrc = (WLSource *)[srcVal pointerValue];
    }

    for (WLSourceEntry *e in self.sources) {
        e.preview.selected = (e.src == selectedSrc);
    }
}

#pragma mark - UI 搭建

- (void)buildUI {
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [NSColor colorWithWhite:0.10 alpha:1].CGColor;

    // ── 预览区（画布外围深色）──
    NSView *previewArea = [NSView new];
    previewArea.translatesAutoresizingMaskIntoConstraints = NO;
    previewArea.wantsLayer = YES;
    previewArea.layer.backgroundColor = [NSColor colorWithWhite:0.06 alpha:1].CGColor;
    [self.view addSubview:previewArea];

    // ── 画布容器（16:9 居中）──
    __weak typeof(self) weakSelf = self;
    WLCanvasView *canvas = [[WLCanvasView alloc] initWithFrame:NSZeroRect];
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    canvas.wantsLayer = YES;
    canvas.layer.backgroundColor = [NSColor colorWithWhite:0.10 alpha:1].CGColor;
    canvas.onBackgroundClick = ^{ [weakSelf deselectAllPreviews]; };
    self.canvasView = canvas;
    [previewArea addSubview:canvas];

    NSLayoutConstraint *wantW = [canvas.widthAnchor constraintEqualToAnchor:previewArea.widthAnchor constant:-24];
    wantW.priority = 250;
    NSLayoutConstraint *wantH = [canvas.heightAnchor constraintEqualToAnchor:previewArea.heightAnchor constant:-24];
    wantH.priority = 250;

    // ── 底部 dock 栏 ──
    self.dockManager = [WLDockManager new];
    [self.dockManager setupDefaultDocks];

    NSStackView *dockBar = self.dockManager.dockBar;
    [self.view addSubview:dockBar];

    const CGFloat pad = 8;
    [NSLayoutConstraint activateConstraints:@[
        [previewArea.topAnchor      constraintEqualToAnchor:self.view.topAnchor      constant:pad],
        [previewArea.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor  constant:pad],
        [previewArea.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [previewArea.bottomAnchor   constraintEqualToAnchor:dockBar.topAnchor        constant:-pad],
        [canvas.centerXAnchor constraintEqualToAnchor:previewArea.centerXAnchor],
        [canvas.centerYAnchor constraintEqualToAnchor:previewArea.centerYAnchor],
        [canvas.widthAnchor   constraintEqualToAnchor:canvas.heightAnchor multiplier:16.0/9.0],
        [canvas.widthAnchor   constraintLessThanOrEqualToAnchor:previewArea.widthAnchor  constant:-24],
        [canvas.heightAnchor  constraintLessThanOrEqualToAnchor:previewArea.heightAnchor constant:-24],
        [canvas.heightAnchor  constraintGreaterThanOrEqualToConstant:100],
        wantW, wantH,
        [dockBar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor  constant:pad],
        [dockBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [dockBar.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor   constant:-pad],
        [dockBar.heightAnchor   constraintEqualToConstant:200],
        [self.view.widthAnchor  constraintGreaterThanOrEqualToConstant:800],
    ]];

    // 窗口 resize 时重算浮层位置
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(canvasFrameDidChange:)
               name:NSViewFrameDidChangeNotification
               object:canvas];
}

- (void)canvasFrameDidChange:(NSNotification *)note {
    [self repositionAllPreviews];
}

#pragma mark - 坐标换算（canvasView 显示坐标 ↔ 画布像素坐标）

- (CGRect)viewRectFromCanvasRect:(CGRect)cr {
    CGSize cs = self.canvasLayout.canvasSize;
    CGSize vs = self.canvasView.bounds.size;
    if (cs.width <= 0 || cs.height <= 0 || vs.width <= 0 || vs.height <= 0) return cr;
    CGFloat fx = vs.width / cs.width, fy = vs.height / cs.height;
    return CGRectMake(cr.origin.x * fx, cr.origin.y * fy, cr.size.width * fx, cr.size.height * fy);
}

- (CGRect)canvasRectFromViewRect:(CGRect)vr {
    CGSize cs = self.canvasLayout.canvasSize;
    CGSize vs = self.canvasView.bounds.size;
    if (cs.width <= 0 || cs.height <= 0 || vs.width <= 0 || vs.height <= 0) return vr;
    CGFloat fx = cs.width / vs.width, fy = cs.height / vs.height;
    return CGRectMake(vr.origin.x * fx, vr.origin.y * fy, vr.size.width * fx, vr.size.height * fy);
}

- (void)repositionAllPreviews {
    for (WLSourceEntry *e in self.sources) {
        CGRect layout = [self.canvasLayout layoutRectForSourceID:e.sourceID];
        if (CGRectIsNull(layout)) continue;
        e.preview.frame = [self viewRectFromCanvasRect:layout];
    }
}

#pragma mark - 选中管理

- (void)deselectAllPreviews {
    for (WLSourceEntry *e in self.sources) {
        e.preview.selected = NO;
    }
}

- (WLSourceEntry *)entryForPreview:(WLSourcePreview *)preview {
    for (WLSourceEntry *e in self.sources) {
        if (e.preview == preview) return e;
    }
    return nil;
}

#pragma mark - WLSourcePreviewDelegate

- (void)sourcePreview:(WLSourcePreview *)preview didUpdateFrame:(CGRect)frame {
    WLSourceEntry *e = [self entryForPreview:preview];
    if (!e) return;
    CGRect canvasRect = [self canvasRectFromViewRect:frame];
    [self.canvasLayout setLayoutRect:canvasRect forSourceID:e.sourceID];
}

- (void)sourcePreviewDidRequestSelect:(WLSourcePreview *)preview {
    for (WLSourceEntry *e in self.sources) {
        e.preview.selected = (e.preview == preview);
    }
    // 广播选中 → Sources dock 表格联动
    WLSourceEntry *sel = [self entryForPreview:preview];
    [self.dockManager sendEvent:WLEventTypeSourceSelectionChanged info:@{
        @"sourcePtr": sel ? [NSValue valueWithPointer:sel.src] : [NSNull null]
    }];
}

- (void)sourcePreviewDidRequestDeselect:(WLSourcePreview *)preview {
    [self deselectAllPreviews];
    [self.dockManager sendEvent:WLEventTypeSourceSelectionChanged info:@{
        @"sourcePtr": [NSNull null]
    }];
}

- (void)sourcePreviewDidRequestRemove:(WLSourcePreview *)preview {
    WLSourceEntry *e = [self entryForPreview:preview];
    if (!e) return;
    // 通过事件总线派发移除 → SourcesDock handler 会更新表格
    [self.dockManager sendEvent:WLEventTypeSourceRemoved info:@{
        @"sourcePtr": [NSValue valueWithPointer:e.src],
        @"name": e.name
    }];
    WLCore::remove_source(e.src);
}

- (void)sourcePreview:(WLSourcePreview *)preview didRequestZOrderAction:(WLZOrderAction)action {
    WLSourceEntry *e = [self entryForPreview:preview];
    if (!e) return;
    switch (action) {
        case WLZOrderActionFront: [self.canvasLayout bringToFront:e.sourceID]; break;
        case WLZOrderActionBack:  [self.canvasLayout sendToBack:e.sourceID];   break;
        case WLZOrderActionUp:    [self.canvasLayout moveUp:e.sourceID];       break;
        case WLZOrderActionDown:  [self.canvasLayout moveDown:e.sourceID];     break;
    }
    [self syncPreviewZOrder];
}

- (void)syncPreviewZOrder {
    for (NSString *sid in self.canvasLayout.sourceOrder) {
        for (WLSourceEntry *e in self.sources) {
            if ([e.sourceID isEqualToString:sid]) {
                [self.canvasView addSubview:e.preview]; // 重排到最上
                break;
            }
        }
    }
}

#pragma mark - 帧输出（graphics 线程 push → 主线程 enqueue）

// graphics 线程每 tick 逐源回调。契约（见 WLGraphics.hpp）：
//   frame 仅回调内有效 → 跨线程先 retain；src 只当路由 key，不可解引用。
static void onSourceFrame(WLSource *src, CVPixelBufferRef frame, int64_t pts_ns, void *ctx) {
    ViewController *vc = (__bridge ViewController *)ctx;
    CVPixelBufferRetain(frame);
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc dispatchFrame:frame pts:pts_ns forSource:src];
        CVPixelBufferRelease(frame);
    });
}

// 主线程：按 src 指针路由到对应浮层。查不到 = 源刚被删，丢帧即可。
- (void)dispatchFrame:(CVPixelBufferRef)frame pts:(int64_t)pts_ns forSource:(WLSource *)src {
    for (WLSourceEntry *e in self.sources) {
        if (e.src == src) {
            [e.preview enqueuePixelBuffer:frame pts:(Float64)pts_ns / 1e9];
            return;
        }
    }
}

@end
