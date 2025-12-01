//
//  WLMainViewController.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/9.
//

#import "WLMainViewController.h"
#include <libavformat/avformat.h>
#import "NSView+BackgroundColor.h"
#import "WLCameraManager.h"
#import "WLDevicesManager.h"
#import "WLViedoPreview.h"
#import <Masonry.h>
#import "TVUCameraManager.h"

#import <TVURSignal.h>

@interface WLMainViewController () <WLCameraCaptureSubscriber, TVUCameraManagerDelegate>
@property (weak) IBOutlet NSView *bottomBarView;
@property (nonatomic, strong) WLViedoPreview *videoPreview;
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
}

- (void)startWLCamera {
    WLCameraManager *manager = [WLCameraManager manager];
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

- (void)startTVUCamera {
    TVUCameraManager *manager = [TVUCameraManager manager];
    manager.delegate = self;
    
    NSArray <WLDeviceItem *> *devices = [[WLDevicesManager manager] currentVideoDevices];
    if (devices.count == 0) {
        return;
    }
    
    [manager startCaptureSessionWithDevice:devices.firstObject.device];
    
}
#pragma mark - WLCameraCaptureSubscriber
- (void)cameraCaptureManager:(WLCameraManager *)manager
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self.videoPreview.displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
}

- (void)tvuCaptureOutput:(AVCaptureOutput *)output
   didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
          fromConnection:(AVCaptureConnection *)connection {
    [self.videoPreview.displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
}
@end
