//
//  WLControlPanelContainerView.m
//  WorkLabs
//

#import "WLControlPanelContainerView.h"
#import "WLScenePanel.h"
#import "WLSourcePanel.h"
#import "WLAudioMixerPanel.h"
#import "WLTransitionPanel.h"
#import "WLControlsPanel.h"
#import <Masonry.h>
#import "NSView+BackgroundColor.h"

@interface WLControlPanelContainerView ()

@property (nonatomic, strong) WLScenePanel      *scenePanel;
@property (nonatomic, strong) WLSourcePanel     *sourcePanel;
@property (nonatomic, strong) WLAudioMixerPanel *audioMixerPanel;
@property (nonatomic, strong) WLTransitionPanel *transitionPanel;
@property (nonatomic, strong) WLControlsPanel   *controlsPanel;

@end

@implementation WLControlPanelContainerView

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    [self backgroundColorWithHex:0x3C3C3C]; // 分隔线底色（1pt 间隙露出来即为分隔线）

    self.scenePanel      = [[WLScenePanel alloc] init];
    self.sourcePanel     = [[WLSourcePanel alloc] init];
    self.audioMixerPanel = [[WLAudioMixerPanel alloc] init];
    self.transitionPanel = [[WLTransitionPanel alloc] init];
    self.controlsPanel   = [[WLControlsPanel alloc] init];

    
    NSPopover.class;
    
    // 所有面板使用深色主题
    NSAppearance *darkAppearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (NSView *panel in @[self.scenePanel, self.sourcePanel, self.audioMixerPanel,
                             self.transitionPanel, self.controlsPanel]) {
        panel.appearance = darkAppearance;
        [self addSubview:panel];
    }

    NSArray<NSView *> *panels = @[
        self.scenePanel,
        self.sourcePanel,
        self.audioMixerPanel,
        self.transitionPanel,
        self.controlsPanel,
    ];

    // 水平等宽排列，面板间 1pt 间隙（由容器底色形成分隔线效果）
    for (NSUInteger i = 0; i < panels.count; i++) {
        NSView *panel = panels[i];
        NSView *firstPanel = panels[0];
        BOOL isFirst = (i == 0);
        BOOL isLast  = (i == panels.count - 1);

        [panel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.top.bottom.equalTo(self);

            if (isFirst) {
                make.left.equalTo(self);
            } else {
                NSView *prev = panels[i - 1];
                make.left.equalTo(prev.mas_right).offset(1);
                make.width.equalTo(firstPanel);
            }

            if (isLast) {
                make.right.equalTo(self);
            }
        }];
    }
}

@end
