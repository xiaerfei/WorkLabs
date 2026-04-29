//
//  WLMainViewController.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/9.
//

#import "WLMainViewController.h"
#include <libavformat/avformat.h>
#import "NSView+BackgroundColor.h"
#import "WLVideoManager.h"
#import "WLDevicesManager.h"
#import "WLViedoPreview.h"
#import <Masonry.h>
#import "TVUVideoManager.h"
#import <TVURSignal.h>

#import "WLEvent.h"

#import "WLMediaSource.h"
#import "WLRenderingManager.h"
#import "WLStreamsManager.h"
#import "WLNode.h"

#import "WLVideoDeviceSettingWindowController.h"
#import "WLVideoDeviceSettingView.h"
#import "WLPanelViewController.h"

#import "WLSceneViewController.h"
#import "WLSceneManager.h"

@interface WLMainViewController ()
@property (nonatomic, strong) WLPanelViewController *panelVC;
@property (nonatomic, strong) WLEventDisposeBag *bag;
@property (nonatomic, strong) WLMediaSource *mediaSource;
@property (nonatomic, strong) WLVideoDeviceSettingWindowController *settingWindowController;
@property (nonatomic, strong) NSString *currentVideoDeviceID;

@property (nonatomic, strong) NSView *seekContainer;
@property (nonatomic, strong) NSSlider *seekSlider;
@property (nonatomic, strong) NSTextField *currentTimeLabel;
@property (nonatomic, strong) NSTextField *totalTimeLabel;
@property (nonatomic, strong) NSTimer *seekUpdateTimer;
@property (nonatomic, strong) WLSceneViewController *sceneViewController;
@end

@implementation WLMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    unsigned int ver = avformat_version();
    int major = (ver >> 16) & 0xFF;
    int minor = (ver >> 8) & 0xFF;
    int micro = ver & 0xFF;

    printf("libavformat version: %d.%d.%d\n", major, minor, micro);
    
    self.view.backgroundColor = [NSColor blackColor];
    
    // 场景视图 — 填充主区域（控制面板 + seekContainer 上方）
    self.sceneViewController = [[WLSceneViewController alloc] init];
    self.sceneViewController.sceneManager = [WLSceneManager manager];
    [self addChildViewController:self.sceneViewController];
    [self.view addSubview:self.sceneViewController.view];
    [self.sceneViewController.view mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.top.right.equalTo(self.view);
    }];
    
    // 控制面板容器，固定在窗口底部
    self.panelVC = [[WLPanelViewController alloc] init];
    [self addChildViewController:self.panelVC];
    [self.view addSubview:self.panelVC.view];
    [self.panelVC.view mas_makeConstraints:^(MASConstraintMaker *make) {
        make.leading.trailing.bottom.equalTo(self.view);
        make.height.mas_equalTo(220);
    }];
    
    [WLStreamsManager manager].videoRenderType = WLVideoRenderTypeCamera;
    [WLStreamsManager manager].audioRenderType = WLAudioRenderTypeMic;
    [[WLStreamsManager manager] start];
    
    [self setupSeekControls];
    
    // sceneViewController.view 的 bottom 约束连接到 seekContainer.top
    [self.sceneViewController.view mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.equalTo(self.seekContainer.mas_top);
    }];
    
    __weak typeof(self) weakSelf = self;
    self.seekUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateSeekUI];
    }];
}

- (void)dealloc {
    [_seekUpdateTimer invalidate];
}

- (void)setupSeekControls {
    self.seekContainer = [[NSView alloc] init];
    [self.seekContainer backgroundColorWithHex:0x2A2A2A];
    [self.view addSubview:self.seekContainer];
    [self.seekContainer mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.right.equalTo(self.view);
        make.bottom.equalTo(self.panelVC.view.mas_top);
        make.height.mas_equalTo(36);
    }];
    
    self.currentTimeLabel = [NSTextField labelWithString:@"00:00"];
    self.currentTimeLabel.textColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    self.currentTimeLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.currentTimeLabel.alignment = NSTextAlignmentRight;
    [self.seekContainer addSubview:self.currentTimeLabel];
    [self.currentTimeLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.seekContainer).offset(10);
        make.centerY.equalTo(self.seekContainer);
    }];
    
    self.totalTimeLabel = [NSTextField labelWithString:@"00:00"];
    self.totalTimeLabel.textColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    self.totalTimeLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.seekContainer addSubview:self.totalTimeLabel];
    [self.totalTimeLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.right.equalTo(self.seekContainer).offset(-10);
        make.centerY.equalTo(self.seekContainer);
    }];
    
    self.seekSlider = [[NSSlider alloc] init];
    self.seekSlider.minValue = 0;
    self.seekSlider.maxValue = 100;
    self.seekSlider.continuous = YES;
    [self.seekContainer addSubview:self.seekSlider];
    [self.seekSlider mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.currentTimeLabel.mas_right).offset(8);
        make.right.equalTo(self.totalTimeLabel.mas_left).offset(-8);
        make.centerY.equalTo(self.seekContainer);
    }];
}

- (NSString *)formatTime:(Float64)seconds {
    int totalSec = (int)round(seconds);
    int h = totalSec / 3600;
    int m = (totalSec % 3600) / 60;
    int s = totalSec % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@"%02d:%02d:%02d", h, m, s];
    }
    return [NSString stringWithFormat:@"%02d:%02d", m, s];
}

- (void)updateSeekUI {
    Float64 duration = self.mediaSource.totalDuration;
    if (duration > 0 && self.seekSlider.maxValue != duration) {
        self.seekSlider.maxValue = duration;
        self.totalTimeLabel.stringValue = [self formatTime:duration];
    }
}

@end
