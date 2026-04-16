//
//  WLTransitionPanel.m
//  WorkLabs
//

#import "WLTransitionPanel.h"
#import <Masonry.h>
#import "NSView+BackgroundColor.h"
#import "WLEvent.h"
#import "WLToolbarButton.h"

@interface WLTransitionPanel () <NSTextFieldDelegate>

@property (nonatomic, strong) NSView *titleBar;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSView *toolbarView;
@property (nonatomic, strong) NSPopUpButton *transitionTypeButton;
@property (nonatomic, strong) NSTextField *durationField;
@property (nonatomic, strong) NSStepper *durationStepper;

@end

@implementation WLTransitionPanel

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    [self backgroundColorWithHex:0x1E1E1E];

    // 标题栏
    self.titleBar = [[NSView alloc] init];
    [self.titleBar backgroundColorWithHex:0x252525];
    [self addSubview:self.titleBar];
    [self.titleBar mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(self);
        make.height.mas_equalTo(30);
    }];

    NSImageView *iconView = [[NSImageView alloc] init];
    iconView.image = [NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath"
                                  accessibilityDescription:nil];
    iconView.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.titleBar addSubview:iconView];
    [iconView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.titleBar).offset(8);
        make.centerY.equalTo(self.titleBar);
        make.width.height.mas_equalTo(14);
    }];

    NSTextField *titleLabel = [NSTextField labelWithString:@"转场动画"];
    titleLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    titleLabel.font = [NSFont systemFontOfSize:12.0];
    [self.titleBar addSubview:titleLabel];
    [titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(iconView.mas_right).offset(5);
        make.centerY.equalTo(self.titleBar);
    }];

    // 底部工具栏
    self.toolbarView = [[NSView alloc] init];
    [self.toolbarView backgroundColorWithHex:0x1A1A1A];
    [self addSubview:self.toolbarView];
    [self.toolbarView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.left.right.equalTo(self);
        make.height.mas_equalTo(32);
    }];
    [self setupToolbar];

    // 分隔线
    NSView *topSep = [[NSView alloc] init];
    [topSep backgroundColorWithHex:0x3C3C3C];
    [self addSubview:topSep];
    [topSep mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.titleBar.mas_bottom);
        make.left.right.equalTo(self);
        make.height.mas_equalTo(1);
    }];

    NSView *bottomSep = [[NSView alloc] init];
    [bottomSep backgroundColorWithHex:0x3C3C3C];
    [self addSubview:bottomSep];
    [bottomSep mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.equalTo(self.toolbarView.mas_top);
        make.left.right.equalTo(self);
        make.height.mas_equalTo(1);
    }];

    // 内容区
    self.contentView = [[NSView alloc] init];
    [self.contentView backgroundColorWithHex:0x1E1E1E];
    [self addSubview:self.contentView];
    [self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(topSep.mas_bottom);
        make.left.right.equalTo(self);
        make.bottom.equalTo(bottomSep.mas_top);
    }];

    [self setupContent];
}

- (void)setupContent {
    // 转场类型下拉框
    self.transitionTypeButton = [[NSPopUpButton alloc] init];
    [self.transitionTypeButton addItemsWithTitles:@[@"淡入淡出", @"切换", @"滑入", @"滑出"]];
    self.transitionTypeButton.target = self;
    self.transitionTypeButton.action = @selector(transitionTypeChanged:);
    [self.contentView addSubview:self.transitionTypeButton];
    [self.transitionTypeButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.contentView).offset(14);
        make.left.equalTo(self.contentView).offset(10);
        make.right.equalTo(self.contentView).offset(-10);
        make.height.mas_equalTo(24);
    }];

    // 时长标签
    NSTextField *durationLabel = [NSTextField labelWithString:@"时长"];
    durationLabel.textColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    durationLabel.font = [NSFont systemFontOfSize:12.0];
    [self.contentView addSubview:durationLabel];
    [durationLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.transitionTypeButton.mas_bottom).offset(12);
        make.left.equalTo(self.contentView).offset(10);
        make.width.mas_equalTo(30);
    }];

    // 时长输入框
    self.durationField = [[NSTextField alloc] init];
    self.durationField.stringValue = @"300";
    self.durationField.font = [NSFont systemFontOfSize:12.0];
    self.durationField.alignment = NSTextAlignmentRight;
    self.durationField.delegate = self;
    NSNumberFormatter *fmt = [[NSNumberFormatter alloc] init];
    fmt.numberStyle = NSNumberFormatterDecimalStyle;
    fmt.minimum = @(0);
    fmt.maximum = @(10000);
    self.durationField.formatter = fmt;
    [self.contentView addSubview:self.durationField];
    [self.durationField mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(durationLabel);
        make.left.equalTo(durationLabel.mas_right).offset(8);
        make.width.mas_equalTo(55);
        make.height.mas_equalTo(22);
    }];

    // ms 单位标签
    NSTextField *msLabel = [NSTextField labelWithString:@"ms"];
    msLabel.textColor = [NSColor colorWithWhite:0.5 alpha:1.0];
    msLabel.font = [NSFont systemFontOfSize:11.0];
    [self.contentView addSubview:msLabel];
    [msLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(durationLabel);
        make.left.equalTo(self.durationField.mas_right).offset(4);
    }];

    // 步进器
    self.durationStepper = [[NSStepper alloc] init];
    self.durationStepper.minValue = 0;
    self.durationStepper.maxValue = 10000;
    self.durationStepper.increment = 50;
    self.durationStepper.doubleValue = 300;
    self.durationStepper.valueWraps = NO;
    self.durationStepper.target = self;
    self.durationStepper.action = @selector(durationStepperChanged:);
    [self.contentView addSubview:self.durationStepper];
    [self.durationStepper mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(durationLabel);
        make.right.equalTo(self.contentView).offset(-10);
        make.width.mas_equalTo(14);
        make.height.mas_equalTo(22);
    }];
}

- (void)setupToolbar {
    NSArray *configs = @[
        @[@"plus",       NSStringFromSelector(@selector(addTransition))],
        @[@"minus",      NSStringFromSelector(@selector(deleteTransition))],
        @[@"ellipsis",   NSStringFromSelector(@selector(moreOptions))],
    ];

    NSView *prev = nil;
    for (NSArray *cfg in configs) {
        WLToolbarButton *btn = [self makeToolbarButtonWithSymbolName:cfg[0]
                                                       action:NSSelectorFromString(cfg[1])];
        [self.toolbarView addSubview:btn];
        [btn mas_makeConstraints:^(MASConstraintMaker *make) {
            make.centerY.equalTo(self.toolbarView);
            make.width.height.mas_equalTo(24);
            if (prev) {
                make.left.equalTo(prev.mas_right).offset(2);
            } else {
                make.left.equalTo(self.toolbarView).offset(6);
            }
        }];
        prev = btn;
    }
}

- (WLToolbarButton *)makeToolbarButtonWithSymbolName:(NSString *)symbolName action:(SEL)action {
    WLToolbarButton *btn = [[WLToolbarButton alloc] init];
    btn.bezelStyle = NSBezelStyleSmallSquare;
    btn.bordered = NO;
    btn.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    btn.imagePosition = NSImageOnly;
    btn.target = self;
    btn.action = action;
    [btn setContentTintColor:[NSColor whiteColor]];
    
    NSTrackingArea *trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                                options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect | NSViewWidthSizable | NSViewHeightSizable)
                                                                  owner:btn
                                                               userInfo:nil];
    [btn addTrackingArea:trackingArea];
    
    return btn;
}

#pragma mark - Actions

- (void)transitionTypeChanged:(NSPopUpButton *)sender {
    WLSend().type(WLObserveTransitionChange).payload(sender.titleOfSelectedItem).send();
}

- (void)durationStepperChanged:(NSStepper *)sender {
    self.durationField.stringValue = [NSString stringWithFormat:@"%.0f", sender.doubleValue];
}

- (void)addTransition    {}
- (void)deleteTransition {}
- (void)moreOptions      {}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    double value = self.durationField.doubleValue;
    value = MAX(0, MIN(10000, value));
    self.durationField.doubleValue = value;
    self.durationStepper.doubleValue = value;
}

@end
