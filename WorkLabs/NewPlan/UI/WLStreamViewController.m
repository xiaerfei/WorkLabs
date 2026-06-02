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

// Render 画布容器（背景色 = layer.backgroundColor，背景图 = layer.contents）
@property (nonatomic, strong) WLCanvasContainerView *canvasView;

// 编排核心 + 画布数据源
@property (nonatomic, strong) WLStreamsManager *manager;
@property (nonatomic, strong) WLCanvasModel *canvas;

// preview ↔ streamID ↔ source 映射
@property (nonatomic, strong) NSMapTable<WLStreamPreview *, NSString *> *previewToSID;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<WLStreamSourceProtocol>> *sidToSource;

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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [NSColor blackColor].CGColor;

    _previewToSID = [NSMapTable strongToStrongObjectsMapTable];
    _sidToSource = [NSMutableDictionary dictionary];

    _canvas = [[WLCanvasModel alloc] init];           // 默认 1920×1080
    _manager = [[WLStreamsManager alloc] initWithCanvas:_canvas];

    // 本阶段：合成帧仅用于验证 Mix 在工作（路线 A 不回显主画面预览）
    __block NSUInteger mixCount = 0;
    self.manager.mixedFrameOutput = ^(CVPixelBufferRef pb, Float64 pts) {
        if ((mixCount++ % 120) == 0) {
            NSLog(@"[WLVideoMix] composed #%lu  %zux%zu",
                  (unsigned long)mixCount,
                  CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb));
        }
        CVPixelBufferRelease(pb); // 所有权转移给 block
    };

    [self setupCanvas];
    [self setupSlider];
    [self setupToolbar];
    [self layoutUI];
}

#pragma mark - Setup

- (void)setupCanvas {
    WLCanvasContainerView *canvas = [[WLCanvasContainerView alloc] init];
    canvas.wantsLayer = YES;
    canvas.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:1.0].CGColor;
    canvas.layer.contentsGravity = kCAGravityResize; // 背景图拉伸铺满整张
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) wself = self;
    canvas.onBackgroundClick = ^{ [wself deselectAllPreviews]; };
    self.canvasView = canvas;
    [self.view addSubview:canvas];
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

- (void)layoutUI {
    [self.canvasView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(self.view);
        make.bottom.equalTo(self.progressSlider.mas_top);
    }];

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

#pragma mark - 背景设置

- (void)settingsClicked:(id)sender {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"设置背景色…" action:@selector(chooseBgColor:) keyEquivalent:@""];
    [menu addItemWithTitle:@"设置背景图…" action:@selector(chooseBgImage:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"清除背景"   action:@selector(clearBackground:) keyEquivalent:@""];
    for (NSMenuItem *item in menu.itemArray) item.target = self;

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

#pragma mark - Actions

- (void)recordClicked:(id)sender {
    NSLog(@"[WLStreamViewController] 录制 clicked");
}

- (void)liveClicked:(id)sender {
    NSLog(@"[WLStreamViewController] 直播 clicked");
}

- (void)addClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"mp4", @"mov", @"m4v", @"mkv", @"flv", @"ts", @"avi"];
    panel.allowsMultipleSelection = NO;
    __weak typeof(self) wself = self;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || panel.URLs.count == 0) return;
        [wself addMediaSourceWithPath:panel.URLs.firstObject.path];
    }];
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
