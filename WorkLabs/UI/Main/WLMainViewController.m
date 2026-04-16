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
#import "WLControlPanelContainerView.h"

@interface WLMainViewController ()
@property (nonatomic, strong) WLControlPanelContainerView *controlPanelContainer;
@property (nonatomic, strong) WLEventDisposeBag *bag;
@property (nonatomic, strong) WLMediaSource *mediaSource;
@property (nonatomic, strong) WLVideoDeviceSettingWindowController *settingWindowController;
@property (nonatomic, strong) NSString *currentVideoDeviceID;
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

    // 控制面板容器，固定在窗口底部
    self.controlPanelContainer = [[WLControlPanelContainerView alloc] init];
    [self.view addSubview:self.controlPanelContainer];
    [self.controlPanelContainer mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.right.bottom.equalTo(self.view);
        make.height.mas_equalTo(220);
    }];

    // 初始化媒体源
    NSString *path = @"/Users/erfeixia/Downloads/Test-4K.mp4";
    self.mediaSource = [[WLMediaSource alloc] initWithPath:path];
    
    [WLStreamsManager manager].videoRenderType = WLVideoRenderTypeCamera;
    [WLStreamsManager manager].audioRenderType = WLAudioRenderTypeMic;
    [[WLStreamsManager manager] start];
}
@end
