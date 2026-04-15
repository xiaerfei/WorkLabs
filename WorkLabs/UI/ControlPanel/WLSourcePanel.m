//
//  WLSourcePanel.m
//  WorkLabs
//

#import "WLSourcePanel.h"
#import <Masonry.h>
#import "NSView+BackgroundColor.h"

@interface WLSourcePanel ()

@property (nonatomic, strong) NSView *titleBar;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSView *toolbarView;

@end

@implementation WLSourcePanel

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
    iconView.image = [NSImage imageWithSystemSymbolName:@"square.stack.3d.up"
                                  accessibilityDescription:nil];
    iconView.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.titleBar addSubview:iconView];
    [iconView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.titleBar).offset(8);
        make.centerY.equalTo(self.titleBar);
        make.width.height.mas_equalTo(14);
    }];

    NSTextField *titleLabel = [NSTextField labelWithString:@"源"];
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

    // 内容区：空状态占位
    self.contentView = [[NSView alloc] init];
    [self.contentView backgroundColorWithHex:0x1E1E1E];
    [self addSubview:self.contentView];
    [self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(topSep.mas_bottom);
        make.left.right.equalTo(self);
        make.bottom.equalTo(bottomSep.mas_top);
    }];

    [self setupEmptyState];
}

- (void)setupEmptyState {
    // 问号图标
    NSTextField *iconLabel = [NSTextField labelWithString:@"?"];
    iconLabel.font = [NSFont systemFontOfSize:36.0 weight:NSFontWeightThin];
    iconLabel.textColor = [NSColor colorWithWhite:0.35 alpha:1.0];
    iconLabel.alignment = NSTextAlignmentCenter;
    [self.contentView addSubview:iconLabel];
    [iconLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.equalTo(self.contentView);
        make.centerY.equalTo(self.contentView).offset(-20);
        make.width.mas_equalTo(50);
    }];

    // 提示文字
    NSTextField *hintLabel = [NSTextField labelWithString:@"您还没有添加任何源。\n点击下面的 + 按钮，\n或者右击此处添加一个。"];
    hintLabel.font = [NSFont systemFontOfSize:11.0];
    hintLabel.textColor = [NSColor colorWithWhite:0.45 alpha:1.0];
    hintLabel.alignment = NSTextAlignmentCenter;
    hintLabel.maximumNumberOfLines = 3;
    [self.contentView addSubview:hintLabel];
    [hintLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(iconLabel.mas_bottom).offset(6);
        make.left.equalTo(self.contentView).offset(8);
        make.right.equalTo(self.contentView).offset(-8);
    }];
}

- (void)setupToolbar {
    NSArray *configs = @[
        @[@"+", NSStringFromSelector(@selector(addSource))],
        @[@"−", NSStringFromSelector(@selector(deleteSource))],
        @[@"⚙", NSStringFromSelector(@selector(sourceSettings))],
        @[@"∧", NSStringFromSelector(@selector(moveSourceUp))],
        @[@"∨", NSStringFromSelector(@selector(moveSourceDown))],
    ];

    NSView *prev = nil;
    for (NSArray *cfg in configs) {
        NSButton *btn = [self makeToolbarButtonWithTitle:cfg[0]
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

- (NSButton *)makeToolbarButtonWithTitle:(NSString *)title action:(SEL)action {
    NSButton *btn = [[NSButton alloc] init];
    btn.title = title;
    btn.bezelStyle = NSBezelStyleSmallSquare;
    btn.bordered = NO;
    btn.font = [NSFont systemFontOfSize:13.0];
    btn.target = self;
    btn.action = action;
    [btn setContentTintColor:[NSColor colorWithWhite:0.65 alpha:1.0]];
    return btn;
}

#pragma mark - Toolbar Actions

- (void)addSource       {}
- (void)deleteSource    {}
- (void)sourceSettings  {}
- (void)moveSourceUp    {}
- (void)moveSourceDown  {}

@end
