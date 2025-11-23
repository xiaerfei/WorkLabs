//
//  WLMainViewController.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/9.
//

#import "WLMainViewController.h"
#include <libavformat/avformat.h>
#import "NSView+BackgroundColor.h"
#import "WLCameraCaptureManager.h"
#import "WLVideoDeviceManager.h"
#import "WLViedoPreview.h"
#import <Masonry.h>

@interface WLMainViewController () <WLCameraCaptureSubscriber>
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
    
    WLCameraCaptureManager *manager = [WLCameraCaptureManager manager];
    [manager subscriber:self];
    // 启动采集
    [manager startCapture];
    
    NSArray *devices = [WLVideoDeviceManager videoDevices];

    for (AVCaptureDevice *device in devices) {
        NSLog(@"摄像头名称: %@", device.localizedName);
        NSLog(@"     uniqueID : %@", device.uniqueID);
        NSLog(@"      modelID : %@", device.modelID);
        NSLog(@"localizedName : %@", device.localizedName);
        NSLog(@" manufacturer : %@", device.manufacturer);
    }
}

#pragma mark - WLCameraCaptureSubscriber
- (void)cameraCaptureManager:(WLCameraCaptureManager *)manager
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self.videoPreview.displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
}

@end
