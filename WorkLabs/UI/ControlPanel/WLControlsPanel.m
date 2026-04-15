//
//  WLControlsPanel.m
//  WorkLabs
//

#import "WLControlsPanel.h"
#import <Masonry.h>
#import "NSView+BackgroundColor.h"
#import "WLEvent.h"

@interface WLControlsPanel ()

@property (nonatomic, strong) NSView *titleBar;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSButton *streamButton;
@property (nonatomic, strong) NSButton *recordButton;

@end

@implementation WLControlsPanel

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
    iconView.image = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3"
                                  accessibilityDescription:nil];
    iconView.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.titleBar addSubview:iconView];
    [iconView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.titleBar).offset(8);
        make.centerY.equalTo(self.titleBar);
        make.width.height.mas_equalTo(14);
    }];

    NSTextField *titleLabel = [NSTextField labelWithString:@"控制按钮"];
    titleLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    titleLabel.font = [NSFont systemFontOfSize:12.0];
    [self.titleBar addSubview:titleLabel];
    [titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(iconView.mas_right).offset(5);
        make.centerY.equalTo(self.titleBar);
    }];

    // 标题栏分隔线
    NSView *topSep = [[NSView alloc] init];
    [topSep backgroundColorWithHex:0x3C3C3C];
    [self addSubview:topSep];
    [topSep mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.titleBar.mas_bottom);
        make.left.right.equalTo(self);
        make.height.mas_equalTo(1);
    }];

    // 内容区
    self.contentView = [[NSView alloc] init];
    [self.contentView backgroundColorWithHex:0x1E1E1E];
    [self addSubview:self.contentView];
    [self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(topSep.mas_bottom);
        make.left.right.bottom.equalTo(self);
    }];

    [self setupButtons];
}

- (void)setupButtons {
    CGFloat hPad = 10.0;
    CGFloat btnH = 26.0;
    CGFloat spacing = 6.0;

    // 开始直播
    self.streamButton = [self makeActionButtonWithTitle:@"开始直播"
                                                action:@selector(toggleStreaming)];
    [self.contentView addSubview:self.streamButton];
    [self.streamButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.contentView).offset(10);
        make.left.equalTo(self.contentView).offset(hPad);
        make.right.equalTo(self.contentView).offset(-hPad);
        make.height.mas_equalTo(btnH);
    }];

    // 开始录制
    self.recordButton = [self makeActionButtonWithTitle:@"开始录制"
                                                action:@selector(toggleRecording)];
    [self.contentView addSubview:self.recordButton];
    [self.recordButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.streamButton.mas_bottom).offset(spacing);
        make.left.equalTo(self.contentView).offset(hPad);
        make.right.equalTo(self.contentView).offset(-hPad);
        make.height.mas_equalTo(btnH);
    }];

    // 启动虚拟摄像机（主按钮 + 右侧齿轮）
    NSButton *virtualCamButton = [self makeActionButtonWithTitle:@"启动虚拟摄像机"
                                                         action:@selector(toggleVirtualCamera)];
    NSButton *virtualCamGear = [[NSButton alloc] init];
    virtualCamGear.image = [NSImage imageWithSystemSymbolName:@"gear"
                                         accessibilityDescription:nil];
    virtualCamGear.bezelStyle = NSBezelStyleRounded;
    virtualCamGear.target = self;
    virtualCamGear.action = @selector(virtualCameraSettings);
    [self.contentView addSubview:virtualCamButton];
    [self.contentView addSubview:virtualCamGear];
    [virtualCamGear mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.recordButton.mas_bottom).offset(spacing);
        make.right.equalTo(self.contentView).offset(-hPad);
        make.width.height.mas_equalTo(btnH);
    }];
    [virtualCamButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.recordButton.mas_bottom).offset(spacing);
        make.left.equalTo(self.contentView).offset(hPad);
        make.right.equalTo(virtualCamGear.mas_left).offset(-4);
        make.height.mas_equalTo(btnH);
    }];

    // 工作室模式
    NSButton *studioButton = [self makeActionButtonWithTitle:@"工作室模式"
                                                     action:@selector(toggleStudioMode)];
    [self.contentView addSubview:studioButton];
    [studioButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(virtualCamButton.mas_bottom).offset(spacing);
        make.left.equalTo(self.contentView).offset(hPad);
        make.right.equalTo(self.contentView).offset(-hPad);
        make.height.mas_equalTo(btnH);
    }];

    // 设置
    NSButton *settingsButton = [self makeActionButtonWithTitle:@"设置"
                                                       action:@selector(openSettings)];
    [self.contentView addSubview:settingsButton];
    [settingsButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(studioButton.mas_bottom).offset(spacing);
        make.left.equalTo(self.contentView).offset(hPad);
        make.right.equalTo(self.contentView).offset(-hPad);
        make.height.mas_equalTo(btnH);
    }];
}

- (NSButton *)makeActionButtonWithTitle:(NSString *)title action:(SEL)action {
    NSButton *btn = [[NSButton alloc] init];
    btn.title = title;
    btn.bezelStyle = NSBezelStyleRounded;
    btn.font = [NSFont systemFontOfSize:12.0];
    btn.target = self;
    btn.action = action;
    return btn;
}

#pragma mark - Actions

- (void)toggleStreaming {
    WLSend().type(WLObserveStartStreaming).payload(nil).send();
}

- (void)toggleRecording {
    WLSend().type(WLObserveStartRecording).payload(nil).send();
}

- (void)toggleVirtualCamera {}
- (void)virtualCameraSettings {}
- (void)toggleStudioMode {}
- (void)openSettings {}

@end
