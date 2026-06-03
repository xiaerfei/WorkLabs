//
//  WLStreamViewController.m
//  WorkLabs
//
//  推流主界面 — Render 所见即所得画布（背景层 + 两路 Stream 浮层）
//

#import "WLStreamViewController.h"
#import <Masonry/Masonry.h>
#import "WLStreamPreview.h"
#import "WLStreamsManager.h"
#import "WLCanvasModel.h"
#import "WLMediaSource.h"
#import "WLMicSource.h"
#import "WLCameraSource.h"
#import "WLCameraSourceConfig.h"
#import "WLDevicesManager.h"
#import "WLRecorder.h"

static const CGFloat kIconBgAlpha = 0.05;

#pragma mark - WLIconButtonView

@interface WLIconButtonView : NSView
@property (nonatomic, strong) CALayer *bgLayer;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
@end

@implementation WLIconButtonView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        _bgLayer = [CALayer layer];
        _bgLayer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:kIconBgAlpha].CGColor;
        _bgLayer.cornerRadius = 18;
        [self.layer addSublayer:_bgLayer];

        NSTrackingArea *area = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                   owner:self
                userInfo:nil];
        [self addTrackingArea:area];
    }
    return self;
}

- (void)layout {
    [super layout];
    self.bgLayer.frame = self.bounds;
}

- (void)mouseEntered:(NSEvent *)event {
    self.bgLayer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:kIconBgAlpha * 2.5].CGColor;
}

- (void)mouseExited:(NSEvent *)event {
    self.bgLayer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:kIconBgAlpha].CGColor;
}

- (void)mouseDown:(NSEvent *)event {
    self.bgLayer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:kIconBgAlpha * 4].CGColor;
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(loc, self.bounds)) {
        self.bgLayer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:kIconBgAlpha * 2.5].CGColor;
        if (self.target && self.action) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.action withObject:self];
#pragma clang diagnostic pop
        }
    } else {
        self.bgLayer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:kIconBgAlpha].CGColor;
    }
}

@end

#pragma mark - WLCanvasContainerView

@interface WLCanvasContainerView : NSView
@property (nonatomic, copy, nullable) void (^onBackgroundClick)(void);
@end

@implementation WLCanvasContainerView
- (void)mouseDown:(NSEvent *)event {
    if (self.onBackgroundClick) self.onBackgroundClick();
}
@end

#pragma mark - WLStreamViewController

@interface WLStreamViewController () <WLStreamRenderingDelegate>

// 可用区（黑底，letterbox 背景）
@property (nonatomic, strong) WLCanvasContainerView *canvasArea;
// Render 画布（按 canvasSize 锁宽高比，居中于可用区；背景色 = layer.backgroundColor，背景图 = layer.contents）
@property (nonatomic, strong) WLCanvasContainerView *canvasView;

// 编排核心 + 画布数据源
@property (nonatomic, strong) WLStreamsManager *manager;
@property (nonatomic, strong) WLCanvasModel *canvas;

// preview ↔ streamID ↔ source 映射
@property (nonatomic, strong) NSMapTable<WLStreamPreview *, NSString *> *previewToSID;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<WLStreamSourceProtocol>> *sidToSource;

// 录制
@property (nonatomic, strong) WLRecorder *recorder;
@property (nonatomic, copy, nullable) NSString *currentRecordPath;

// 进度条
@property (nonatomic, strong) NSSlider *progressSlider;
@property (nonatomic, assign) BOOL sliderVisible;

// 底部工具栏
@property (nonatomic, strong) NSView *toolbarView;
@property (nonatomic, strong) NSView *recordButton;
@property (nonatomic, strong) NSView *liveButton;
@property (nonatomic, strong) NSView *addButton;
@property (nonatomic, strong) NSView *settingsButton;

@end

@implementation WLStreamViewController

#pragma mark - Lifecycle

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [NSColor blackColor].CGColor;

    _previewToSID = [NSMapTable strongToStrongObjectsMapTable];
    _sidToSource = [NSMutableDictionary dictionary];

    _canvas = [[WLCanvasModel alloc] init];           // 默认 1920×1080
    _manager = [[WLStreamsManager alloc] initWithCanvas:_canvas];

    // 合成帧 → 录制器（未录制时 appendVideoPixelBuffer: 内部直接返回）
    __weak typeof(self) wself = self;
    self.manager.mixedFrameOutput = ^(CVPixelBufferRef pb, Float64 pts) {
        [wself.recorder appendVideoPixelBuffer:pb pts:pts];
        CVPixelBufferRelease(pb); // 所有权转移给 block
    };

    [self setupCanvas];
    [self setupSlider];
    [self setupToolbar];
    [self layoutUI];
}

#pragma mark - Setup

- (void)setupCanvas {
    __weak typeof(self) wself = self;

    // 可用区（黑底，承载 letterbox 黑边）
    WLCanvasContainerView *area = [[WLCanvasContainerView alloc] init];
    area.wantsLayer = YES;
    area.layer.backgroundColor = [NSColor blackColor].CGColor;
    area.translatesAutoresizingMaskIntoConstraints = NO;
    area.onBackgroundClick = ^{ [wself deselectAllPreviews]; };
    self.canvasArea = area;
    [self.view addSubview:area];

    // 画布（按 canvasSize 锁宽高比，居中于可用区）
    WLCanvasContainerView *canvas = [[WLCanvasContainerView alloc] init];
    canvas.wantsLayer = YES;
    canvas.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:1.0].CGColor;
    canvas.layer.contentsGravity = kCAGravityResize; // 背景图拉伸铺满整张
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    canvas.onBackgroundClick = ^{ [wself deselectAllPreviews]; };
    self.canvasView = canvas;
    [area addSubview:canvas];

    // 窗口尺寸变化时重算浮层位置（画布坐标 → 视图坐标）
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(canvasFrameDidChange:)
               name:NSViewFrameDidChangeNotification
               object:canvas];
}

- (void)setupSlider {
    self.progressSlider = [[NSSlider alloc] init];
    self.progressSlider.minValue = 0;
    self.progressSlider.maxValue = 1;
    self.progressSlider.doubleValue = 0;
    self.progressSlider.target = self;
    self.progressSlider.action = @selector(sliderValueChanged:);
    self.progressSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressSlider.hidden = YES;
    [self.view addSubview:self.progressSlider];
}

- (void)setupToolbar {
    self.toolbarView = [[NSView alloc] init];
    self.toolbarView.wantsLayer = YES;
    self.toolbarView.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;
    self.toolbarView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.toolbarView];

    self.recordButton  = [self createIconButtonWithSymbol:@"record.circle"
                                                    size:20
                                                   color:[NSColor systemRedColor]
                                                  action:@selector(recordClicked:)];
    self.liveButton    = [self createIconButtonWithSymbol:@"antenna.radiowaves.left.and.right"
                                                    size:20
                                                   color:[NSColor systemGreenColor]
                                                  action:@selector(liveClicked:)];
    self.addButton     = [self createIconButtonWithSymbol:@"plus.circle.fill"
                                                    size:20
                                                   color:[NSColor whiteColor]
                                                  action:@selector(addClicked:)];
    self.settingsButton = [self createIconButtonWithSymbol:@"gearshape.fill"
                                                     size:20
                                                    color:[NSColor whiteColor]
                                                   action:@selector(settingsClicked:)];

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        self.recordButton, self.liveButton, self.addButton
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing = 24;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toolbarView addSubview:stack];
    [self.toolbarView addSubview:self.settingsButton];

    [stack mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.toolbarView).offset(20);
        make.centerY.equalTo(self.toolbarView);
    }];

    [self.settingsButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.right.equalTo(self.toolbarView).offset(-20);
        make.centerY.equalTo(self.toolbarView);
    }];
}

#pragma mark - Layout

- (void)canvasFrameDidChange:(NSNotification *)note {
    [self repositionAllPreviews];
}

- (void)layoutUI {
    [self.canvasArea mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(self.view);
        make.bottom.equalTo(self.progressSlider.mas_top);
    }];
    [self updateCanvasAspect];

    [self.progressSlider mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.view).offset(16);
        make.right.equalTo(self.view).offset(-16);
        make.height.mas_equalTo(20);
    }];

    [self.toolbarView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.progressSlider.mas_bottom);
        make.left.right.equalTo(self.view);
        make.bottom.equalTo(self.view);
        make.height.mas_equalTo(56);
    }];
}

#pragma mark - 坐标换算（canvasView 显示坐标 ↔ 画布像素坐标）

- (CGRect)viewRectFromCanvasRect:(CGRect)cr {
    CGSize cs = self.canvas.canvasSize;
    CGSize vs = self.canvasView.bounds.size;
    if (cs.width <= 0 || cs.height <= 0 || vs.width <= 0 || vs.height <= 0) return cr;
    CGFloat fx = vs.width / cs.width, fy = vs.height / cs.height;
    return CGRectMake(cr.origin.x * fx, cr.origin.y * fy, cr.size.width * fx, cr.size.height * fy);
}

- (CGRect)canvasRectFromViewRect:(CGRect)vr {
    CGSize cs = self.canvas.canvasSize;
    CGSize vs = self.canvasView.bounds.size;
    if (cs.width <= 0 || cs.height <= 0 || vs.width <= 0 || vs.height <= 0) return vr;
    CGFloat fx = cs.width / vs.width, fy = cs.height / vs.height;
    return CGRectMake(vr.origin.x * fx, vr.origin.y * fy, vr.size.width * fx, vr.size.height * fy);
}

#pragma mark - 添加媒体源

- (void)addMediaSourceWithPath:(NSString *)path {
    if (path.length == 0) return;

    WLMediaSource *source = [[WLMediaSource alloc] initWithPath:path];

    // 初始布局：画布中央，占画布一半
    CGSize cs = self.canvas.canvasSize;
    CGRect canvasLayout = CGRectMake(cs.width * 0.25, cs.height * 0.25,
                                     cs.width * 0.5,  cs.height * 0.5);
    CGRect uiFrame = [self viewRectFromCanvasRect:canvasLayout];

    WLStreamPreview *preview = [[WLStreamPreview alloc] initWithFrame:uiFrame];
    preview.delegate = self;
    preview.translatesAutoresizingMaskIntoConstraints = YES;

    NSString *sid = [self.manager addSource:source previewOutput:preview];
    if (sid.length == 0) return;
    [self.manager setLayoutFrame:canvasLayout forStreamID:sid];

    [self.previewToSID setObject:sid forKey:preview];
    self.sidToSource[sid] = source;

    [self.canvasView addSubview:preview];

    NSError *err = nil;
    if (![source start:&err]) {
        NSLog(@"[WLStreamViewController] MediaSource start failed: %@", err);
    }
}

#pragma mark - 添加摄像头源

- (void)addCameraSourceWithDevice:(AVCaptureDevice *)device {
    if (!device) return;

    // 去重：同一摄像头不重复添加（避免争用同一 AVCaptureDevice）
    for (id<WLStreamSourceProtocol> s in self.sidToSource.allValues) {
        if ([s isKindOfClass:[WLCameraSource class]]) {
            AVCaptureDevice *d = [(WLCameraSource *)s config].device;
            if ([d.uniqueID isEqualToString:device.uniqueID]) {
                NSLog(@"[WLStreamViewController] 摄像头已添加: %@", device.localizedName);
                return;
            }
        }
    }

    WLCameraSourceConfig *config = [WLCameraSourceConfig configWithDevice:device];
    WLCameraSource *source = [[WLCameraSource alloc] initWithConfig:config];

    // 初始布局：画布中央，占画布一半（首帧到达后按真实比例自适应）
    CGSize cs = self.canvas.canvasSize;
    CGRect canvasLayout = CGRectMake(cs.width * 0.25, cs.height * 0.25,
                                     cs.width * 0.5,  cs.height * 0.5);
    CGRect uiFrame = [self viewRectFromCanvasRect:canvasLayout];

    WLStreamPreview *preview = [[WLStreamPreview alloc] initWithFrame:uiFrame];
    preview.delegate = self;
    preview.translatesAutoresizingMaskIntoConstraints = YES;

    NSString *sid = [self.manager addSource:source previewOutput:preview];
    if (sid.length == 0) return;
    [self.manager setLayoutFrame:canvasLayout forStreamID:sid];

    [self.previewToSID setObject:sid forKey:preview];
    self.sidToSource[sid] = source;

    [self.canvasView addSubview:preview];

    NSError *err = nil;
    if (![source start:&err]) {
        NSLog(@"[WLStreamViewController] CameraSource start failed: %@", err);
    }
}

#pragma mark - WLStreamRenderingDelegate（浮层拖拽/缩放 → 同步画布坐标）

- (void)rendering:(id<WLStreamRenderingProtocol>)rendering didUpdateFrame:(CGRect)frame {
    if (![rendering isKindOfClass:[WLStreamPreview class]]) return;
    NSString *sid = [self.previewToSID objectForKey:(WLStreamPreview *)rendering];
    if (sid.length == 0) return;
    CGRect canvasLayout = [self canvasRectFromViewRect:frame];
    [self.manager setLayoutFrame:canvasLayout forStreamID:sid];
}

- (void)renderingDidRequestSelect:(id<WLStreamRenderingProtocol>)rendering {
    // 单选：选中被点击的浮层，取消其它
    for (WLStreamPreview *p in [[self.previewToSID keyEnumerator] allObjects]) {
        p.selected = (p == rendering);
    }
}

- (void)deselectAllPreviews {
    for (WLStreamPreview *p in [[self.previewToSID keyEnumerator] allObjects]) {
        p.selected = NO;
    }
}

- (void)renderingDidRequestDeselect:(id<WLStreamRenderingProtocol>)rendering {
    [self deselectAllPreviews];
}

- (void)rendering:(id<WLStreamRenderingProtocol>)rendering
    didRequestZOrderAction:(WLZOrderAction)action {
    if (![rendering isKindOfClass:[WLStreamPreview class]]) return;
    NSString *sid = [self.previewToSID objectForKey:(WLStreamPreview *)rendering];
    if (sid.length == 0) return;

    switch (action) {
        case WLZOrderActionFront: [self.manager bringStreamToFront:sid]; break;
        case WLZOrderActionBack:  [self.manager sendStreamToBack:sid];   break;
        case WLZOrderActionUp:    [self.manager moveStreamUp:sid];       break;
        case WLZOrderActionDown:  [self.manager moveStreamDown:sid];     break;
    }
    [self syncPreviewZOrder];
}

// 按 canvas.streamOrder(从底到顶) 重排画布上的浮层，使预览叠放 = 合成 z-order
- (void)syncPreviewZOrder {
    for (NSString *sid in self.canvas.streamOrder) {
        WLStreamPreview *p = [self previewForStreamID:sid];
        if (p) [self.canvasView addSubview:p]; // 重新 addSubview = 移到最上
    }
}

- (WLStreamPreview *)previewForStreamID:(NSString *)sid {
    for (WLStreamPreview *p in [[self.previewToSID keyEnumerator] allObjects]) {
        if ([[self.previewToSID objectForKey:p] isEqualToString:sid]) return p;
    }
    return nil;
}

#pragma mark - 背景设置

- (void)settingsClicked:(id)sender {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"设置背景色…" action:@selector(chooseBgColor:) keyEquivalent:@""];
    [menu addItemWithTitle:@"设置背景图…" action:@selector(chooseBgImage:) keyEquivalent:@""];

    [menu addItem:[NSMenuItem separatorItem]];

    // 画布分辨率子菜单
    NSMenuItem *resItem = [menu addItemWithTitle:@"画布分辨率" action:nil keyEquivalent:@""];
    NSMenu *resMenu = [[NSMenu alloc] init];
    NSArray<NSDictionary *> *presets = @[
        @{@"t": @"1280×720 (720p)",   @"w": @1280, @"h": @720},
        @{@"t": @"1920×1080 (1080p)", @"w": @1920, @"h": @1080},
        @{@"t": @"2560×1440 (1440p)", @"w": @2560, @"h": @1440},
        @{@"t": @"1080×1920 (竖屏)",  @"w": @1080, @"h": @1920},
        @{@"t": @"720×1280 (竖屏)",   @"w": @720,  @"h": @1280},
    ];
    CGSize cur = self.canvas.canvasSize;
    for (NSDictionary *p in presets) {
        NSMenuItem *it = [resMenu addItemWithTitle:p[@"t"]
                                            action:@selector(resolutionSelected:)
                                     keyEquivalent:@""];
        it.target = self;
        it.representedObject = p;
        if ((int)cur.width == [p[@"w"] intValue] && (int)cur.height == [p[@"h"] intValue]) {
            it.state = NSControlStateValueOn;
        }
    }
    [menu setSubmenu:resMenu forItem:resItem];

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"清除背景" action:@selector(clearBackground:) keyEquivalent:@""];

    for (NSMenuItem *item in menu.itemArray) {
        if (item.action) item.target = self;
    }

    NSView *btn = [sender isKindOfClass:[NSView class]] ? (NSView *)sender : self.settingsButton;
    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0, NSHeight(btn.bounds))
                            inView:btn];
}

- (void)chooseBgColor:(id)sender {
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    panel.target = self;
    panel.action = @selector(bgColorChanged:);
    [panel orderFront:nil];
}

- (void)bgColorChanged:(id)sender {
    NSColor *color = [NSColorPanel sharedColorPanel].color;
    self.canvasView.layer.backgroundColor = color.CGColor;
    [self.manager setBackgroundColor:color];
}

- (void)chooseBgImage:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"png", @"jpg", @"jpeg", @"heic", @"tiff", @"bmp", @"gif"];
    panel.allowsMultipleSelection = NO;
    __weak typeof(self) wself = self;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || panel.URLs.count == 0) return;
        NSImage *image = [[NSImage alloc] initWithContentsOfURL:panel.URLs.firstObject];
        if (!image) return;
        CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
        wself.canvasView.layer.contents = (__bridge id)cg;
        [wself.manager setBackgroundImage:image];
    }];
}

- (void)clearBackground:(id)sender {
    self.canvasView.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:1.0].CGColor;
    self.canvasView.layer.contents = nil;
    [self.manager setBackgroundColor:nil];
    [self.manager setBackgroundImage:nil];
}

#pragma mark - 画布分辨率

- (void)resolutionSelected:(NSMenuItem *)sender {
    NSDictionary *p = sender.representedObject;
    if (![p isKindOfClass:[NSDictionary class]]) return;
    CGSize size = CGSizeMake([p[@"w"] doubleValue], [p[@"h"] doubleValue]);

    if (self.recorder.isRecording) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"录制进行中";
        alert.informativeText = @"请先停止录制，再修改画布分辨率。";
        [alert addButtonWithTitle:@"好"];
        [alert runModal];
        return;
    }
    [self applyCanvasSize:size];
}

- (void)applyCanvasSize:(CGSize)size {
    [self.manager setCanvasSize:size];      // 缩放 layout + 同步 canvas/mix
    [self updateCanvasAspect];              // 更新画布预览宽高比
    // 立即布局：canvasView frame 变化会同步触发 NSViewFrameDidChange → 自动重摆浮层
    [self.view layoutSubtreeIfNeeded];
    NSLog(@"[WLStreamViewController] 画布分辨率 → %.0f×%.0f", size.width, size.height);
}

// 让画布预览按 canvasSize 锁宽高比、letterbox 居中于可用区
- (void)updateCanvasAspect {
    CGSize cs = self.canvas.canvasSize;
    CGFloat aspect = (cs.height > 0) ? (cs.width / cs.height) : (16.0 / 9.0);
    [self.canvasView mas_remakeConstraints:^(MASConstraintMaker *make) {
        make.center.equalTo(self.canvasArea);
        make.width.lessThanOrEqualTo(self.canvasArea);
        make.height.lessThanOrEqualTo(self.canvasArea);
        make.width.equalTo(self.canvasView.mas_height).multipliedBy(aspect);
        make.width.equalTo(self.canvasArea).priorityHigh();
        make.height.equalTo(self.canvasArea).priorityHigh();
    }];
}

- (void)repositionAllPreviews {
    for (WLStreamPreview *p in [[self.previewToSID keyEnumerator] allObjects]) {
        NSString *sid = [self.previewToSID objectForKey:p];
        if (sid.length == 0) continue;
        CGRect layout = [self.canvas layoutFrameForStreamID:sid];
        if (CGRectIsNull(layout)) continue;
        p.frame = [self viewRectFromCanvasRect:layout];
    }
}

#pragma mark - Actions

- (WLRecorder *)recorder {
    if (!_recorder) _recorder = [[WLRecorder alloc] init];
    return _recorder;
}

// 当前场景是否有会输出音频的源（目前仅媒体文件源产音频；摄像头无音频）
- (BOOL)hasAudioCapableSource {
    for (id<WLStreamSourceProtocol> s in self.sidToSource.allValues) {
        if ([s isKindOfClass:[WLMediaSource class]]) return YES;
    }
    return NO;
}

- (void)recordClicked:(id)sender {
    if (self.recorder.isRecording) {
        [self.recorder stopRecording];
        self.manager.audioBufferOutput = nil;   // 停止音频转发
        NSString *path = self.currentRecordPath;
        self.currentRecordPath = nil;
        NSLog(@"[WLStreamViewController] 录制已停止: %@", path);
        if (path) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"录制完成";
            alert.informativeText = [NSString stringWithFormat:@"已保存到：\n%@", path];
            [alert addButtonWithTitle:@"好"];
            [alert addButtonWithTitle:@"在 Finder 中显示"];
            if ([alert runModal] == NSAlertSecondButtonReturn) {
                [[NSWorkspace sharedWorkspace]
                    activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
            }
        }
        return;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"mp4"];
    panel.nameFieldStringValue = @"WorkLabs.mp4";
    __weak typeof(self) wself = self;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSError *err = nil;
        BOOL audioEnabled = [wself hasAudioCapableSource];
        if ([wself.recorder startRecordingToPath:panel.URL.path
                                       videoSize:wself.canvas.canvasSize
                                             fps:30
                                    audioEnabled:audioEnabled
                                           error:&err]) {
            wself.currentRecordPath = panel.URL.path;
            if (audioEnabled) {
                // 把源音频转发给录制器（弱引用避免 manager→block→controller 循环）
                wself.manager.audioBufferOutput = ^(CMSampleBufferRef sb) {
                    [wself.recorder appendAudioSampleBuffer:sb];
                };
            }
            NSLog(@"[WLStreamViewController] 开始录制 → %@ (audio=%d)", panel.URL.path, audioEnabled);
        } else {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"无法开始录制";
            alert.informativeText = err.localizedDescription ?: @"未知错误";
            [alert addButtonWithTitle:@"好"];
            [alert runModal];
        }
    }];
}

- (void)liveClicked:(id)sender {
    NSLog(@"[WLStreamViewController] 直播 clicked");
}

- (void)addClicked:(id)sender {
    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *fileItem = [menu addItemWithTitle:@"添加视频文件…"
                                           action:@selector(addVideoFileClicked:)
                                    keyEquivalent:@""];
    fileItem.target = self;

    // 「添加摄像头」子菜单：动态列出当前视频采集设备
    NSMenuItem *camItem = [menu addItemWithTitle:@"添加摄像头" action:nil keyEquivalent:@""];
    NSMenu *camMenu = [[NSMenu alloc] init];
    NSArray<WLDeviceItem *> *devices = [[WLDevicesManager manager] currentVideoDevices];
    if (devices.count == 0) {
        NSMenuItem *empty = [camMenu addItemWithTitle:@"未检测到摄像头" action:nil keyEquivalent:@""];
        empty.enabled = NO;
    } else {
        for (WLDeviceItem *item in devices) {
            NSMenuItem *di = [camMenu addItemWithTitle:(item.localizedName ?: @"未知设备")
                                                action:@selector(cameraDeviceSelected:)
                                         keyEquivalent:@""];
            di.target = self;
            di.representedObject = item.device;
        }
    }
    [menu setSubmenu:camMenu forItem:camItem];

    // 「添加麦克风」子菜单：动态列出当前音频采集设备
    NSMenuItem *micItem = [menu addItemWithTitle:@"添加麦克风" action:nil keyEquivalent:@""];
    NSMenu *micMenu = [[NSMenu alloc] init];
    NSArray<WLDeviceItem *> *audioDevices = [[WLDevicesManager manager] currentAudioDevices];
    if (audioDevices.count == 0) {
        NSMenuItem *empty = [micMenu addItemWithTitle:@"未检测到麦克风" action:nil keyEquivalent:@""];
        empty.enabled = NO;
    } else {
        for (WLDeviceItem *item in audioDevices) {
            NSMenuItem *di = [micMenu addItemWithTitle:(item.localizedName ?: @"未知设备")
                                                action:@selector(micDeviceSelected:)
                                         keyEquivalent:@""];
            di.target = self;
            di.representedObject = item.device;
        }
    }
    [menu setSubmenu:micMenu forItem:micItem];

    NSView *btn = [sender isKindOfClass:[NSView class]] ? (NSView *)sender : self.addButton;
    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0, NSHeight(btn.bounds))
                            inView:btn];
}

- (void)addVideoFileClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"mp4", @"mov", @"m4v", @"mkv", @"flv", @"ts", @"avi"];
    panel.allowsMultipleSelection = NO;
    __weak typeof(self) wself = self;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || panel.URLs.count == 0) return;
        [wself addMediaSourceWithPath:panel.URLs.firstObject.path];
    }];
}

- (void)cameraDeviceSelected:(NSMenuItem *)sender {
    AVCaptureDevice *device = sender.representedObject;
    if (!device) return;

    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        [self addCameraSourceWithDevice:device];
    } else if (status == AVAuthorizationStatusNotDetermined) {
        __weak typeof(self) wself = self;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                 completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) [wself addCameraSourceWithDevice:device];
                else [wself showCameraAccessDeniedAlert];
            });
        }];
    } else {
        [self showCameraAccessDeniedAlert];
    }
}

- (void)showCameraAccessDeniedAlert {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"无法访问摄像头";
    alert.informativeText = @"请在「系统设置 ▸ 隐私与安全性 ▸ 摄像头」中允许 WorkLabs 访问摄像头。";
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

#pragma mark - 添加麦克风源

- (void)micDeviceSelected:(NSMenuItem *)sender {
    AVCaptureDevice *device = sender.representedObject;
    if (!device) return;

    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) {
        [self addMicSourceWithDevice:device];
    } else if (status == AVAuthorizationStatusNotDetermined) {
        __weak typeof(self) wself = self;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                 completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) [wself addMicSourceWithDevice:device];
                else [wself showMicAccessDeniedAlert];
            });
        }];
    } else {
        [self showMicAccessDeniedAlert];
    }
}

- (void)addMicSourceWithDevice:(AVCaptureDevice *)device {
    if (!device) return;

    // 去重：同一麦克风不重复添加
    for (id<WLStreamSourceProtocol> s in self.sidToSource.allValues) {
        if ([s isKindOfClass:[WLMicSource class]]) {
            if ([[(WLMicSource *)s device].uniqueID isEqualToString:device.uniqueID]) {
                NSLog(@"[WLStreamViewController] 麦克风已添加: %@", device.localizedName);
                return;
            }
        }
    }

    WLMicSource *source = [[WLMicSource alloc] initWithDevice:device];
    NSString *sid = [self.manager addSource:source previewOutput:nil]; // 纯音频，无画面
    if (sid.length == 0) return;
    self.sidToSource[sid] = source;

    NSError *err = nil;
    if (![source start:&err]) {
        NSLog(@"[WLStreamViewController] MicSource start failed: %@", err);
    }
}

- (void)showMicAccessDeniedAlert {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"无法访问麦克风";
    alert.informativeText = @"请在「系统设置 ▸ 隐私与安全性 ▸ 麦克风」中允许 WorkLabs 访问麦克风。";
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

- (void)sliderValueChanged:(id)sender {
    NSLog(@"[WLStreamViewController] slider: %.2f", self.progressSlider.doubleValue);
}

#pragma mark - Private

- (NSView *)createIconButtonWithSymbol:(NSString *)symbolName
                                  size:(CGFloat)size
                                 color:(NSColor *)color
                                action:(SEL)action {
    WLIconButtonView *container = [[WLIconButtonView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [container.widthAnchor constraintEqualToConstant:36].active = YES;
    [container.heightAnchor constraintEqualToConstant:36].active = YES;

    NSImageView *imageView = [[NSImageView alloc] init];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration *config =
            [NSImageSymbolConfiguration configurationWithPointSize:size
                                                           weight:NSFontWeightRegular];
        imageView.image = [[NSImage imageWithSystemSymbolName:symbolName
                                     accessibilityDescription:nil]
                           imageWithSymbolConfiguration:config];
        imageView.contentTintColor = color;
    }
    [container addSubview:imageView];
    [imageView.centerXAnchor constraintEqualToAnchor:container.centerXAnchor].active = YES;
    [imageView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor].active = YES;
    [imageView.widthAnchor constraintEqualToConstant:size].active = YES;
    [imageView.heightAnchor constraintEqualToConstant:size].active = YES;

    container.target = self;
    container.action = action;
    return container;
}

@end
