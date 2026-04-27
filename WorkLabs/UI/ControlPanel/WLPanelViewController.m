//
//  WLPanelViewController.m
//  WorkLabs
//

#import "WLPanelViewController.h"
#import <Masonry.h>
#import "NSView+BackgroundColor.h"
#import "WLSourcePanel.h"
#import "WLAudioMixerPanel.h"
#import "WLControlsPanel.h"

@interface WLPanelViewController ()

@property (nonatomic, strong) WLSourcePanel *sourcePanel;
@property (nonatomic, strong) WLAudioMixerPanel *audioMixerPanel;
@property (nonatomic, strong) WLControlsPanel *controlsPanel;

@end

@implementation WLPanelViewController

- (void)loadView {
    self.view = [[NSView alloc] init];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.view backgroundColorWithHex:0x3C3C3C];
    self.view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [self setupPanels];
}

- (void)setupPanels {
    self.sourcePanel = [[WLSourcePanel alloc] init];
    self.audioMixerPanel = [[WLAudioMixerPanel alloc] init];
    self.controlsPanel = [[WLControlsPanel alloc] init];

    NSView *sep1 = [[NSView alloc] init];
    [sep1 backgroundColorWithHex:0x3C3C3C];

    NSView *sep2 = [[NSView alloc] init];
    [sep2 backgroundColorWithHex:0x3C3C3C];

    [self.view addSubview:self.sourcePanel];
    [self.view addSubview:sep1];
    [self.view addSubview:self.audioMixerPanel];
    [self.view addSubview:sep2];
    [self.view addSubview:self.controlsPanel];

    [self.sourcePanel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.bottom.left.equalTo(self.view);
        make.right.equalTo(sep1.mas_left);
    }];

    [sep1 mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.bottom.equalTo(self.view);
        make.left.equalTo(self.sourcePanel.mas_right);
        make.width.mas_equalTo(1);
    }];

    [self.audioMixerPanel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.bottom.equalTo(self.view);
        make.left.equalTo(sep1.mas_right);
        make.width.equalTo(self.sourcePanel);
        make.right.equalTo(sep2.mas_left);
    }];

    [sep2 mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.bottom.equalTo(self.view);
        make.left.equalTo(self.audioMixerPanel.mas_right);
        make.width.mas_equalTo(1);
    }];

    [self.controlsPanel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.bottom.right.equalTo(self.view);
        make.left.equalTo(sep2.mas_right);
        make.width.equalTo(self.sourcePanel);
    }];
}

@end
