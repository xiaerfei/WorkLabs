//
//  WLStreamViewController.m
//  WorkLabs
//
//  推流主界面
//

#import "WLStreamViewController.h"
#import <Masonry/Masonry.h>
#import "WLStreamPreview.h"

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

@interface WLStreamViewController ()

// 预览区域
@property (nonatomic, strong) WLStreamPreview *streamPreview;

// 进度条（仅本地视频时显示）
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

    [self setupPreview];
    [self setupSlider];
    [self setupToolbar];
    [self layoutUI];
}

#pragma mark - Setup

- (void)setupPreview {
    self.streamPreview = [[WLStreamPreview alloc] init];
    self.streamPreview.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.streamPreview];
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
    WLStreamPreview *preview = self.streamPreview;

    [preview mas_makeConstraints:^(MASConstraintMaker *make) {
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

#pragma mark - Public

- (void)showSlider:(BOOL)show animated:(BOOL)animated {
    if (self.sliderVisible == show) return;
    self.sliderVisible = show;
    self.progressSlider.hidden = !show;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = animated ? 0.25 : 0;
        [self.view layoutSubtreeIfNeeded];
    } completionHandler:nil];
}

- (void)updateSliderValue:(double)value {
    self.progressSlider.doubleValue = value;
}

#pragma mark - Actions

- (void)recordClicked:(id)sender {
    NSLog(@"[WLStreamViewController] 录制 clicked");
}

- (void)liveClicked:(id)sender {
    NSLog(@"[WLStreamViewController] 直播 clicked");
}

- (void)addClicked:(id)sender {
    NSLog(@"[WLStreamViewController] 添加 clicked");
}

- (void)settingsClicked:(id)sender {
    NSLog(@"[WLStreamViewController] 设置 clicked");
}

- (void)sliderValueChanged:(id)sender {
    NSLog(@"[WLStreamViewController] slider: %.2f", self.progressSlider.doubleValue);
}

#pragma mark - WLVideoOutputProtocol

- (WLNodeType)outputType {
    return WLNodeTypeVideo;
}

- (void)receiveVideoFrame:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    [self.streamPreview enqueuePixelBuffer:pixelBuffer pts:pts];
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
