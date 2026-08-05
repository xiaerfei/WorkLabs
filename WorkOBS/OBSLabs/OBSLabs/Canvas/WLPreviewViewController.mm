//
//  WLPreviewViewController.mm
//  OBSLabs
//
//  预览逻辑内聚（自 ViewController.mm 迁入）：
//  - 每个源一个 WLSourcePreview 浮层（拖拽/缩放/选中/右键），布局真值在
//    WLCanvasLayout（画布像素坐标），本 VC 负责显示坐标 ↔ 画布坐标换算。
//  - 帧由 graphics 线程每 tick 逐源 push（WLCore::SetFrameOutput，对标
//    OBS render_displays：渲染线程推、UI 不拉），hop 主线程后按 src 路由。
//  - 与 Sources dock 的增删/选中联动走 WLDockManager 事件总线（同步派发）。
//

#import "WLPreviewViewController.h"
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

@interface WLPreviewViewController () <WLSourcePreviewDelegate>
@property (nonatomic, weak)   WLDockManager   *manager;
@property (nonatomic, strong) WLCanvasView    *canvasView;
@property (nonatomic, strong) WLCanvasLayout  *canvasLayout;
@property (nonatomic, strong) NSMutableArray<WLSourceEntry *> *sources;
@property (nonatomic, assign) NSUInteger       subTagSourceAdded;
@property (nonatomic, assign) NSUInteger       subTagSourceRemoved;
@property (nonatomic, assign) NSUInteger       subTagSourceSelection;
- (void)dispatchFrame:(CVPixelBufferRef)frame pts:(int64_t)pts_ns forSource:(WLSource *)src;
@end

static void onSourceFrame(WLSource *src, CVPixelBufferRef frame, int64_t pts_ns, void *ctx);

@implementation WLPreviewViewController

#pragma mark - 生命周期

- (instancetype)initWithDockManager:(WLDockManager *)manager {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _manager = manager;
        _sources = [NSMutableArray array];
        _canvasLayout = [[WLCanvasLayout alloc] init];
    }
    return self;
}

- (void)loadView {
    // 预览外围深色区（原 previewArea），画布在其中 16:9 居中
    NSView *area = [NSView new];
    area.wantsLayer = YES;
    area.layer.backgroundColor = [NSColor colorWithWhite:0.06 alpha:1].CGColor;
    self.view = area;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildCanvas];
    [self subscribeEvents];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.manager unsubscribeWithTag:self.subTagSourceAdded];
    [self.manager unsubscribeWithTag:self.subTagSourceRemoved];
    [self.manager unsubscribeWithTag:self.subTagSourceSelection];
}

#pragma mark - 帧输出挂/摘（由父控制器编排：窗口可见挂、不可见摘，管线不动）

- (void)startFrameOutput {
    WLCore::SetFrameOutput(onSourceFrame, (__bridge void *)self);
}

- (void)stopFrameOutput {
    WLCore::SetFrameOutput(NULL, NULL);
}

#pragma mark - UI 搭建

- (void)buildCanvas {
    __weak typeof(self) weakSelf = self;
    WLCanvasView *canvas = [[WLCanvasView alloc] initWithFrame:NSZeroRect];
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    canvas.wantsLayer = YES;
    canvas.layer.backgroundColor = [NSColor colorWithWhite:0.10 alpha:1].CGColor;
    // NSView 默认不裁剪 subview：浮层缩放拖出画布会悬在深色区上穿帮。
    // 裁掉——对齐 OBS：源允许部分出画布，超出部分不显示
    canvas.layer.masksToBounds = YES;
    canvas.onBackgroundClick = ^{ [weakSelf deselectAllPreviews]; };
    self.canvasView = canvas;
    [self.view addSubview:canvas];

    NSLayoutConstraint *wantW = [canvas.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-24];
    wantW.priority = 250;
    NSLayoutConstraint *wantH = [canvas.heightAnchor constraintEqualToAnchor:self.view.heightAnchor constant:-24];
    wantH.priority = 250;

    [NSLayoutConstraint activateConstraints:@[
        [canvas.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [canvas.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [canvas.widthAnchor   constraintEqualToAnchor:canvas.heightAnchor multiplier:16.0/9.0],
        [canvas.widthAnchor   constraintLessThanOrEqualToAnchor:self.view.widthAnchor  constant:-24],
        [canvas.heightAnchor  constraintLessThanOrEqualToAnchor:self.view.heightAnchor constant:-24],
        [canvas.heightAnchor  constraintGreaterThanOrEqualToConstant:100],
        wantW, wantH,
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

#pragma mark - 事件订阅

- (void)subscribeEvents {
    __weak typeof(self) weakSelf = self;

    self.subTagSourceAdded = [self.manager subscribeEvent:WLEventTypeSourceAdded
                                                  handler:^(WLEventType event, id __nullable info) {
        [weakSelf handleSourceAdded:info];
    }];

    self.subTagSourceRemoved = [self.manager subscribeEvent:WLEventTypeSourceRemoved
                                                    handler:^(WLEventType event, id __nullable info) {
        [weakSelf handleSourceRemoved:info];
    }];

    self.subTagSourceSelection = [self.manager subscribeEvent:WLEventTypeSourceSelectionChanged
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
    NSLog(@"[WLPreview] 浮层已创建: %@ (%@)", entry.name, sid);
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
            NSLog(@"[WLPreview] 浮层已移除: %@", e.name);
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
    [self.manager sendEvent:WLEventTypeSourceSelectionChanged info:@{
        @"sourcePtr": sel ? [NSValue valueWithPointer:sel.src] : [NSNull null]
    }];
}

- (void)sourcePreviewDidRequestDeselect:(WLSourcePreview *)preview {
    [self deselectAllPreviews];
    [self.manager sendEvent:WLEventTypeSourceSelectionChanged info:@{
        @"sourcePtr": [NSNull null]
    }];
}

- (void)sourcePreviewDidRequestRemove:(WLSourcePreview *)preview {
    WLSourceEntry *e = [self entryForPreview:preview];
    if (!e) return;
    // 通过事件总线派发移除 → SourcesDock handler 会更新表格
    [self.manager sendEvent:WLEventTypeSourceRemoved info:@{
        @"sourcePtr": [NSValue valueWithPointer:e.src],
        @"name": e.name
    }];
    WLCore::RemoveSource(e.src);
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
    WLPreviewViewController *vc = (__bridge WLPreviewViewController *)ctx;
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
