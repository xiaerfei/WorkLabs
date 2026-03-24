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

@interface WLMainViewController () <WLCameraCaptureSubscriber, TVUCameraManagerDelegate, WLMediaSourceDelegate>
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
    NSString *path = @"/Users/erfeixia/Downloads/Test-4K.mp4";
    path = @"/Users/erfeixia/Downloads/hdr_video.MOV";
    self.mediaSource = [[WLMediaSource alloc] initWithPath:path];
    self.mediaSource.delegate = self;
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
#pragma mark - WLMediaSourceDelegate
- (void)mediaSource:(WLMediaSource *)source didOutputVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    CMSampleBufferRef sampleBuffer = [self sampleBufferFromPixelBuffer:pixelBuffer pts:pts];
    if (sampleBuffer) {
        [self.videoPreview.displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }
}

- (void)mediaSource:(WLMediaSource *)source didOutputAudioFrame:(AVFrame *)frame pts:(Float64)pts {
    // TODO: 音频播放实现
}
#pragma mark - Private Methods (MediaSource)
- (CMSampleBufferRef)sampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    if (status != noErr) return NULL;

    CMSampleTimingInfo timingInfo;
    timingInfo.duration = kCMTimeInvalid;
    timingInfo.presentationTimeStamp = CMTimeMakeWithSeconds(pts, 600);
    timingInfo.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                      pixelBuffer,
                                                      formatDescription,
                                                      &timingInfo,
                                                      &sampleBuffer);
    CFRelease(formatDescription);
    return (status == noErr) ? sampleBuffer : NULL;
}
@end
