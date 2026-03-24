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

@interface WLMainViewController () <WLCameraCaptureSubscriber, TVUCameraManagerDelegate>
@property (weak) IBOutlet NSView *bottomBarView;
@property (nonatomic, strong) WLViedoPreview *videoPreview;
@property (nonatomic, strong) WLEventDisposeBag *bag;
@property (nonatomic, strong) WLMediaSource *mediaSource;
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
    [self.bottomBarView backgroundColorWithHexString:@"#434343"];
    
    self.videoPreview = [[WLViedoPreview alloc] init];
    [self.view addSubview:self.videoPreview];
    [self.videoPreview mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(self.view);
        make.bottom.equalTo(self.bottomBarView.mas_top);
    }];
    NSArray <WLDeviceItem *> *videoDevices = [[WLDevicesManager manager] currentVideoDevices];
    for (WLDeviceItem *item in videoDevices) {
        NSLog(@"%@", item.description);
    }
    
    NSArray <WLDeviceItem *> *audioDevices = [[WLDevicesManager manager] currentAudioDevices];
    for (WLDeviceItem *item in audioDevices) {
        NSLog(@"%@", item.description);
    }
    
    self.bag = [WLEventDisposeBag new];
    
    WLObserve(@[@(WLObserveVideoDeviceChange)])
        .mainQueue()
        .dispose(self.bag)
        .name(@"MainObserve")
        .block(^(WLObserve type, id payload) {
            NSLog(@"Main Receive: %@", payload);
        });
    self.mediaSource = [[WLMediaSource alloc] initWithPath:@"/Users/erfeixia/Downloads/Test-4K.mp4"];
}
#pragma mark - Action Methods
- (IBAction)settingButtonAction:(NSButton *)sender {
    
}

- (IBAction)startButtonAction:(NSButton *)sender {
    [self.mediaSource start];
}
#pragma mark - Private Methods
- (void)startWLCamera {
    WLVideoManager *manager = [WLVideoManager manager];
    [manager subscriber:self];
    // 启动采集
    [manager startCapture];
    
    NSArray *devices = [[WLDevicesManager manager] currentVideoDevices];

    for (AVCaptureDevice *device in devices) {
        NSLog(@"摄像头名称: %@", device.localizedName);
        NSLog(@"     uniqueID : %@", device.uniqueID);
        NSLog(@"      modelID : %@", device.modelID);
        NSLog(@"localizedName : %@", device.localizedName);
        NSLog(@" manufacturer : %@", device.manufacturer);
    }
}
#pragma mark - WLCameraCaptureSubscriber
- (void)cameraCaptureManager:(WLVideoManager *)manager
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self.videoPreview.displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
}

- (void)tvuCaptureOutput:(AVCaptureOutput *)output
   didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
          fromConnection:(AVCaptureConnection *)connection {
    [self.videoPreview.displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
}
@end
