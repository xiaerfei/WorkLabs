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
#import "WLSettingsWindowController.h"
#import "WLPusher.h"
#import "WLCameraSource.h"
#import "WLCameraSourceConfig.h"
#import "WLDevicesManager.h"
#import "WLRecorder.h"

static const CGFloat kIconBgAlpha = 0.05;

#pragma mark - WLIconButtonView

@interface WLIconButtonView : NSView
@property (nonatomic, strong) CALayer *bgLayer;
@property (nonatomic, strong) NSImageView *iconView;            // 图标（激活态改色用）
@property (nonatomic, strong, nullable) NSColor *idleIconColor; // 空闲图标色
@property (nonatomic, strong, nullable) NSColor *activeColor;   // 激活态圆底色（录制/直播 = 红）
@property (nonatomic, assign, getter=isActive) BOOL active;     // 进行中
@property (nonatomic, assign) BOOL hovering;
@property (nonatomic, assign) BOOL pressed;
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

// 统一按 激活 / hover / 按下 计算圆底色
- (void)updateBackground {
    if (self.active && self.activeColor) {
        NSColor *c = self.activeColor;
        if (self.pressed)       c = [self.activeColor highlightWithLevel:0.3];
        else if (self.hovering) c = [self.activeColor highlightWithLevel:0.15];
        self.bgLayer.backgroundColor = c.CGColor;
    } else {
        CGFloat a = kIconBgAlpha;
        if (self.pressed)       a = kIconBgAlpha * 4;
        else if (self.hovering) a = kIconBgAlpha * 2.5;
        self.bgLayer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:a].CGColor;
    }
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    if (active) {
        self.iconView.contentTintColor = [NSColor whiteColor];
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @1.0;
        pulse.toValue = @0.45;
        pulse.duration = 0.8;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.bgLayer addAnimation:pulse forKey:@"pulse"];
    } else {
        self.iconView.contentTintColor = self.idleIconColor;
        [self.bgLayer removeAnimationForKey:@"pulse"];
    }
    [self updateBackground];
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovering = YES;
    [self updateBackground];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovering = NO;
    [self updateBackground];
}

- (void)mouseDown:(NSEvent *)event {
    self.pressed = YES;
    [self updateBackground];
}

- (void)mouseUp:(NSEvent *)event {
    self.pressed = NO;
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL inside = NSPointInRect(loc, self.bounds);
    self.hovering = inside;
    [self updateBackground];
    if (inside && self.target && self.action) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.target performSelector:self.action withObject:self];
#pragma clang diagnostic pop
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

@interface WLStreamViewController () <WLStreamRenderingDelegate, WLSettingsWindowControllerDelegate, WLPusherDelegate>

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

// 推流
@property (nonatomic, strong) WLPusher *pusher;
@property (nonatomic, copy, nullable) NSString *pushURL;     // 服务器地址，如 rtmp://server/app
@property (nonatomic, copy, nullable) NSString *streamKey;   // 推流码 / Stream Key

// 设置窗口
@property (nonatomic, strong) WLSettingsWindowController *settingsWC;

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

    _pusher = [[WLPusher alloc] init];
    _pusher.delegate = self;
    _pushURL   = [[NSUserDefaults standardUserDefaults] stringForKey:@"WLPushURL"];
    _streamKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"WLStreamKey"];
    (void)self.recorder;   // 预热（消除合成线程与主线程 lazy 创建竞争）

    // 合成帧 / 混音音频 → 同时分发给录制器与推流器（各自内部按 isRecording/isPushing 判断）
    __weak typeof(self) wself = self;
    self.manager.mixedFrameOutput = ^(CVPixelBufferRef pb, Float64 pts) {
        [wself.recorder appendVideoPixelBuffer:pb pts:pts];
        [wself.pusher   appendVideoPixelBuffer:pb pts:pts];
        CVPixelBufferRelease(pb); // 所有权转移给 block（两个消费者各自 retain）
    };
    self.manager.audioBufferOutput = ^(CMSampleBufferRef sb) {
        [wself.recorder appendAudioSampleBuffer:sb];
        [wself.pusher   appendAudioSampleBuffer:sb];
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
    [self.settingsWC reloadSources];

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
    [self.settingsWC reloadSources];

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

- (void)renderingDidRequestRemove:(id<WLStreamRenderingProtocol>)rendering {
    if (![rendering isKindOfClass:[WLStreamPreview class]]) return;
    WLStreamPreview *preview = (WLStreamPreview *)rendering;
    NSString *sid = [self.previewToSID objectForKey:preview];
    if (sid.length == 0) return;
    id<WLStreamSourceProtocol> source = self.sidToSource[sid];

    if (source) [self.manager removeSource:source];   // 停源 + 从 mixer/canvas/mix 移除
    preview.selected = NO;
    [preview flush];
    [preview removeFromSuperview];
    [self.previewToSID removeObjectForKey:preview];
    [self.sidToSource removeObjectForKey:sid];
    [self syncPreviewZOrder];
    [self.settingsWC reloadSources];
    NSLog(@"[WLStreamViewController] 已移除源 sid=%@", sid);
}

- (void)renderingDidRequestProperties:(id<WLStreamRenderingProtocol>)rendering {
    if (![rendering isKindOfClass:[WLStreamPreview class]]) return;
    NSString *sid = [self.previewToSID objectForKey:(WLStreamPreview *)rendering];
    if (sid.length == 0) return;
    [self settingsClicked:nil];            // 打开设置窗口
    [self.settingsWC selectSourceID:sid];  // 跳到该源属性页
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

#pragma mark - 设置（独立窗口）

- (void)settingsClicked:(id)sender {
    if (!self.settingsWC) {
        self.settingsWC = [[WLSettingsWindowController alloc] init];
        self.settingsWC.settingsDelegate = self;
    }
    self.settingsWC.currentCanvasSize = self.canvas.canvasSize;
    [self.settingsWC showWindow:nil];
    [self.settingsWC.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - WLSettingsWindowControllerDelegate

- (void)settingsDidChooseBackgroundColor:(NSColor *)color {
    self.canvasView.layer.backgroundColor = color.CGColor;
    [self.manager setBackgroundColor:color];
}

- (void)settingsDidChooseBackgroundImage:(NSImage *)image {
    CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
    self.canvasView.layer.contents = (__bridge id)cg;
    [self.manager setBackgroundImage:image];
}

- (void)settingsDidClearBackground {
    self.canvasView.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:1.0].CGColor;
    self.canvasView.layer.contents = nil;
    [self.manager setBackgroundColor:nil];
    [self.manager setBackgroundImage:nil];
}

- (BOOL)settingsCanChangeCanvasSize {
    return !self.recorder.isRecording;
}

- (void)settingsDidSelectCanvasSize:(CGSize)size {
    [self applyCanvasSize:size];
}

- (NSArray<NSDictionary *> *)settingsSourceList {
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    for (NSString *sid in self.sidToSource) {
        id<WLStreamSourceProtocol> s = self.sidToSource[sid];
        BOOL hasAudio = (s.fromType == WLFromTypeMedia || s.fromType == WLFromTypeMic);
        [list addObject:@{@"sid": sid,
                          @"name": (s.displayName ?: @"源"),
                          @"fromType": @(s.fromType),
                          @"hasAudio": @(hasAudio)}];
    }
    return list;
}

- (void)settingsDidSetVolume:(float)volume forStreamID:(NSString *)streamID {
    [self.manager setVolume:volume forStreamID:streamID];
}

- (float)settingsVolumeForStreamID:(NSString *)streamID {
    return [self.manager volumeForStreamID:streamID];
}

- (NSDictionary *)settingsFilterParamsForStreamID:(NSString *)streamID {
    return [self.manager filterParamsForStreamID:streamID];
}

- (void)settingsDidSetFilterParams:(NSDictionary *)params forStreamID:(NSString *)streamID {
    [self.manager setFilterParams:params forStreamID:streamID];
}

- (void)settingsDidSetPushURL:(NSString *)url streamKey:(NSString *)streamKey {
    self.pushURL = url;
    self.streamKey = streamKey;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:(url ?: @"") forKey:@"WLPushURL"];
    [d setObject:(streamKey ?: @"") forKey:@"WLStreamKey"];
}

- (NSString *)settingsPushURL { return self.pushURL; }
- (NSString *)settingsStreamKey { return self.streamKey; }

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
        [self setRecordButtonActive:NO];
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
            [wself setRecordButtonActive:YES];
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
    if (self.pusher.isPushing) {
        [self.pusher stop];
        return;
    }

    NSString *url = [self fullPushURL];
    if (url.length == 0) {
        // 尚未配置推流地址 → 提示并打开设置（推流面板）
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"未配置推流地址";
        alert.informativeText = @"请先在「设置 › 推流」中填写推流地址和密钥。";
        [alert addButtonWithTitle:@"打开设置"];
        [alert addButtonWithTitle:@"取消"];
        if ([alert runModal] == NSAlertFirstButtonReturn) [self settingsClicked:nil];
        return;
    }

    BOOL audioEnabled = [self hasAudioCapableSource];
    [self setLiveButtonActive:YES];   // 连接中即给红色反馈
    [self.pusher startWithURL:url videoSize:self.canvas.canvasSize fps:30 audioEnabled:audioEnabled];
    NSLog(@"[WLStreamViewController] 推流连接中 → %@ (audio=%d)", url, audioEnabled);
}

// 拼接「推流地址 / 密钥」为完整 RTMP URL：去掉相接处多余斜杠；密钥为空则用纯地址。
- (NSString *)fullPushURL {
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *base = [(self.pushURL ?: @"") stringByTrimmingCharactersInSet:ws];
    NSString *key  = [(self.streamKey ?: @"") stringByTrimmingCharactersInSet:ws];
    if (base.length == 0) return @"";
    if (key.length == 0) return base;
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    while ([key hasPrefix:@"/"])  key  = [key substringFromIndex:1];
    return [NSString stringWithFormat:@"%@/%@", base, key];
}

// 直播按钮状态：active=红（连接中/推流中），否则绿（可推流）
- (void)setLiveButtonActive:(BOOL)active {
    WLIconButtonView *btn = (WLIconButtonView *)self.liveButton;
    btn.activeColor = [NSColor systemRedColor];   // 推流中：红底 + 白图标 + 呼吸
    btn.active = active;
}

- (void)setRecordButtonActive:(BOOL)active {
    WLIconButtonView *btn = (WLIconButtonView *)self.recordButton;
    btn.activeColor = [NSColor systemRedColor];   // 录制中：红底 + 白图标 + 呼吸
    btn.active = active;
}

#pragma mark - WLPusherDelegate

- (void)pusherDidStart:(WLPusher *)pusher {
    [self setLiveButtonActive:YES];
    NSLog(@"[WLStreamViewController] 推流已开始");
}

- (void)pusher:(WLPusher *)pusher didFailWithError:(NSError *)error {
    [self setLiveButtonActive:NO];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"推流出错";
    alert.informativeText = error.localizedDescription ?: @"未知错误";
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

- (void)pusherDidStop:(WLPusher *)pusher {
    [self setLiveButtonActive:NO];
    NSLog(@"[WLStreamViewController] 推流已停止");
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
    [self.settingsWC reloadSources];

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

    container.iconView = imageView;
    container.idleIconColor = color;
    container.target = self;
    container.action = action;
    return container;
}

@end
