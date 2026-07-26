//
//  WLControlsDockViewController.m
//  OBSLabs
//
//  控制 Dock：开始直播 / 开始录制 / 设置 / 退出。
//  深色 OBS 风格，发丝描边 + hover/press 反馈 + 视觉层次。
//

#import "WLControlsDockViewController.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kRowHeight   = 36.0;
static const CGFloat kRowSpacing  = 8.0;
static const CGFloat kRowMarginH  = 12.0;
static const CGFloat kCornerRadius = 6.0;

// ══════════════ 颜色常量 ══════════════

// 背景层次（避免纯黑 #000，防 OLED smear）
static NSColor *kBgIdle(void)    { return [NSColor colorWithWhite:0.07 alpha:1]; }  // #121212
static NSColor *kBgHover(void)   { return [NSColor colorWithWhite:0.10 alpha:1]; }  // #1A1A1A
static NSColor *kBgPress(void)   { return [NSColor colorWithWhite:0.06 alpha:1]; }  // #0F0F0F

// 边框（发丝描边，低存在感）
static NSColor *kBorderIdle(void)  { return [NSColor colorWithWhite:1.0 alpha:0.06]; }
static NSColor *kBorderHover(void) { return [NSColor colorWithWhite:1.0 alpha:0.12]; }

// 文字
static NSColor *kTextIdle(void)  { return [NSColor colorWithWhite:0.75 alpha:1]; }
static NSColor *kTextHover(void) { return [NSColor colorWithWhite:0.95 alpha:1]; }

// 强调色
static NSColor *kAccentGreen(void)     { return [NSColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1]; }  // #22C55E
static NSColor *kAccentGreenHover(void){ return [NSColor colorWithRed:0.15 green:0.85 blue:0.42 alpha:1]; }
static NSColor *kAccentGreenBg(void)   { return [NSColor colorWithRed:0.08 green:0.25 blue:0.12 alpha:1]; }
static NSColor *kAccentGreenBgH(void)  { return [NSColor colorWithRed:0.10 green:0.30 blue:0.15 alpha:1]; }

static NSColor *kDestructive(void)     { return [NSColor colorWithRed:0.94 green:0.27 blue:0.27 alpha:1]; }  // #EF4444
static NSColor *kDestructiveHover(void){ return [NSColor colorWithRed:1.0  green:0.35 blue:0.35 alpha:1]; }
static NSColor *kDestructiveBg(void)   { return [NSColor colorWithRed:0.25 green:0.08 blue:0.08 alpha:1]; }
static NSColor *kDestructiveBgH(void)  { return [NSColor colorWithRed:0.30 green:0.10 blue:0.10 alpha:1]; }

// ══════════════ 自定义按钮 ══════════════

typedef NS_ENUM(NSInteger, WLControlButtonStyle) {
    WLControlButtonStyleNormal,
    WLControlButtonStyleAccent,    // 直播：绿色
    WLControlButtonStyleDanger,    // 退出：红色
};

@interface WLControlButton : NSView
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, assign) WLControlButtonStyle style;
@property (nonatomic, strong) CALayer *bgLayer;
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, assign) BOOL hovering;
@property (nonatomic, assign) BOOL pressed;
@property (nonatomic, weak)   id target;
@property (nonatomic, assign) SEL action;
@end

@implementation WLControlButton

- (instancetype)initWithTitle:(NSString *)title style:(WLControlButtonStyle)style {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _title = [title copy];
        _style = style;
        self.wantsLayer = YES;

        _bgLayer = [CALayer layer];
        _bgLayer.cornerRadius = kCornerRadius;
        _bgLayer.borderWidth = 1.0;
        [self.layer addSublayer:_bgLayer];

        _label = [NSTextField labelWithString:title];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.alignment = NSTextAlignmentCenter;
        _label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        [self addSubview:_label];

        [NSLayoutConstraint activateConstraints:@[
            [_label.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];

        NSTrackingArea *area = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                   owner:self
                userInfo:nil];
        [self addTrackingArea:area];

        [self updateAppearance:NO];
    }
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.bgLayer.frame = self.bounds;
    [CATransaction commit];
}

- (void)updateAppearance:(BOOL)animated {
    if (!animated) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
    }

    NSColor *bg, *border, *text;

    switch (self.style) {
        case WLControlButtonStyleAccent:
            bg     = self.pressed ? kAccentGreenBg()  : self.hovering ? kAccentGreenBgH() : kAccentGreenBg();
            border = self.pressed ? kAccentGreen()     : self.hovering ? kAccentGreen()     : [kAccentGreen() colorWithAlphaComponent:0.3];
            text   = self.pressed ? kAccentGreen()     : self.hovering ? kAccentGreenHover(): kAccentGreen();
            break;
        case WLControlButtonStyleDanger:
            bg     = self.pressed ? kDestructiveBg()   : self.hovering ? kDestructiveBgH() : kDestructiveBg();
            border = self.pressed ? kDestructive()      : self.hovering ? kDestructive()     : [kDestructive() colorWithAlphaComponent:0.3];
            text   = self.pressed ? kDestructive()      : self.hovering ? kDestructiveHover(): kDestructive();
            break;
        default:
            bg     = self.pressed ? kBgPress()  : self.hovering ? kBgHover()  : kBgIdle();
            border = self.pressed ? kBorderIdle(): self.hovering ? kBorderHover(): kBorderIdle();
            text   = self.pressed ? kTextHover() : self.hovering ? kTextHover() : kTextIdle();
            break;
    }

    self.bgLayer.backgroundColor = bg.CGColor;
    self.bgLayer.borderColor    = border.CGColor;
    self.label.textColor        = text;

    if (!animated) {
        [CATransaction commit];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovering = YES;
    [self updateAppearance:YES];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovering = NO;
    [self updateAppearance:YES];
}

- (void)mouseDown:(NSEvent *)event {
    self.pressed = YES;
    [self updateAppearance:YES];
}

- (void)mouseUp:(NSEvent *)event {
    self.pressed = NO;
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL inside = NSPointInRect(loc, self.bounds);
    self.hovering = inside;
    [self updateAppearance:YES];
    if (inside && self.target && self.action) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.target performSelector:self.action withObject:self];
#pragma clang diagnostic pop
    }
}

@end

// ══════════════ WLControlsDockViewController ══════════════

@implementation WLControlsDockViewController

- (instancetype)init {
    return [self initWithTitle:@"控制"];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NSView *content = self.dockContent;
    NSView *lastRow = nil;

    struct { NSString *title; SEL action; WLControlButtonStyle style; } items[] = {
        { @"开始直播", @selector(liveClicked:),    WLControlButtonStyleAccent  },
        { @"开始录制", @selector(recordClicked:),  WLControlButtonStyleNormal  },
        { @"设置",     @selector(settingsClicked:), WLControlButtonStyleNormal  },
        { @"退出",     @selector(quitClicked:),     WLControlButtonStyleDanger  },
    };

    for (int i = 0; i < 4; i++) {
        WLControlButton *row = [[WLControlButton alloc] initWithTitle:items[i].title
                                                                style:items[i].style];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.target = self;
        row.action = items[i].action;
        [content addSubview:row];

        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor  constant:kRowMarginH],
            [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-kRowMarginH],
            [row.heightAnchor   constraintEqualToConstant:kRowHeight],
        ]];

        if (lastRow) {
            [row.topAnchor constraintEqualToAnchor:lastRow.bottomAnchor constant:kRowSpacing].active = YES;
        } else {
            [row.topAnchor constraintEqualToAnchor:content.topAnchor constant:kRowSpacing].active = YES;
        }
        lastRow = row;
    }

    if (lastRow) {
        [lastRow.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-kRowSpacing].active = YES;
    }
}

#pragma mark - Actions

- (void)liveClicked:(id)sender {
    NSLog(@"[ControlsDock] 开始直播（待实现）");
}

- (void)recordClicked:(id)sender {
    NSLog(@"[ControlsDock] 开始录制（待实现）");
}

- (void)settingsClicked:(id)sender {
    NSLog(@"[ControlsDock] 设置（待实现）");
}

- (void)quitClicked:(id)sender {
    [NSApp terminate:nil];
}

@end
