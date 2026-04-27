//
//  WLAudioMixerPanel.m
//  WorkLabs
//

#import "WLAudioMixerPanel.h"
#import <Masonry.h>
#import "NSView+BackgroundColor.h"
#import "WLToolbarButton.h"
#import "WLMenuPanelViewController.h"

@interface WLAudioMixerPanel ()

@property (nonatomic, strong) NSView *titleBar;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSView *toolbarView;

@property (nonatomic, strong) WLToolbarButton *addButton;
@property (nonatomic, strong) NSPopover *addPopover;

@end

@implementation WLAudioMixerPanel

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    [self backgroundColorWithHex:0x1E1E1E];

    self.titleBar = [[NSView alloc] init];
    [self.titleBar backgroundColorWithHex:0x252525];
    [self addSubview:self.titleBar];
    [self.titleBar mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(self);
        make.height.mas_equalTo(30);
    }];

    NSImageView *iconView = [[NSImageView alloc] init];
    iconView.image = [NSImage imageWithSystemSymbolName:@"speaker.wave.2" accessibilityDescription:nil];
    iconView.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.titleBar addSubview:iconView];
    [iconView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.titleBar).offset(8);
        make.centerY.equalTo(self.titleBar);
        make.width.height.mas_equalTo(14);
    }];

    NSTextField *titleLabel = [NSTextField labelWithString:@"混音器"];
    titleLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    titleLabel.font = [NSFont systemFontOfSize:12.0];
    [self.titleBar addSubview:titleLabel];
    [titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(iconView.mas_right).offset(5);
        make.centerY.equalTo(self.titleBar);
    }];

    self.toolbarView = [[NSView alloc] init];
    [self.toolbarView backgroundColorWithHex:0x1A1A1A];
    [self addSubview:self.toolbarView];
    [self.toolbarView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.left.right.equalTo(self);
        make.height.mas_equalTo(32);
    }];
    [self setupToolbar];

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

    self.contentView = [[NSView alloc] init];
    [self.contentView backgroundColorWithHex:0x1E1E1E];
    [self addSubview:self.contentView];
    [self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(topSep.mas_bottom);
        make.left.right.equalTo(self);
        make.bottom.equalTo(bottomSep.mas_top);
    }];
}

- (void)setupToolbar {
    self.addButton = [self makeToolbarButtonWithSymbolName:@"plus" action:@selector(showAddPopover)];
    [self.toolbarView addSubview:self.addButton];
    [self.addButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(self.toolbarView);
        make.left.equalTo(self.toolbarView).offset(6);
        make.width.height.mas_equalTo(24);
    }];

    WLToolbarButton *deleteBtn = [self makeToolbarButtonWithSymbolName:@"minus" action:@selector(deleteSource)];
    [self.toolbarView addSubview:deleteBtn];
    [deleteBtn mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(self.toolbarView);
        make.left.equalTo(self.addButton.mas_right).offset(2);
        make.width.height.mas_equalTo(24);
    }];
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

#pragma mark - Toolbar Actions

- (void)showAddPopover {
    WLMenuPanelViewController *menuVC = [[WLMenuPanelViewController alloc] init];
    menuVC.callerType = WLMenuPanelCallerTypeAudioMixer;

    self.addPopover = [[NSPopover alloc] init];
    self.addPopover.contentViewController = menuVC;
    self.addPopover.behavior = NSPopoverBehaviorTransient;

    __weak typeof(self) weakSelf = self;
    menuVC.dismissHandler = ^{
        [weakSelf.addPopover close];
        weakSelf.addPopover = nil;
    };

    [self.addPopover showRelativeToRect:self.addButton.bounds
                                 ofView:self.addButton
                          preferredEdge:NSRectEdgeMaxY];
}

- (void)deleteSource {
    // 预留
}

@end
