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

@interface WLMainViewController () <WLCameraCaptureSubscriber, TVUCameraManagerDelegate, WLMediaSourceDelegate, WLVideoDeviceSettingWindowControllerDelegate>
@property (weak) IBOutlet NSView *bottomBarView;
@property (nonatomic, strong) WLViedoPreview *videoPreview;
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
    [self.bottomBarView backgroundColorWithHexString:@"#434343"];
    
    self.videoPreview = [WLRenderingManager manager].videoPreview;
    [self.view addSubview:self.videoPreview];
    [self.videoPreview mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(self.view);
        make.bottom.equalTo(self.bottomBarView.mas_top);
    }];
    NSString *path = @"/Users/erfeixia/Downloads/Test-4K.mp4";
    path = @"/Users/erfeixia/Downloads/[GM-Team][国漫][沧元图 第2季]-29.mp4";
    path = @"/Users/erfeixia/Downloads/盗墓笔记先导集（上）.mkv";
    self.mediaSource = [[WLMediaSource alloc] initWithPath:path];
    self.mediaSource.delegate = self;
    
    [WLStreamsManager manager].videoRenderType = WLVideoRenderTypeCamera;
    [WLStreamsManager manager].audioRenderType = WLAudioRenderTypeMic;
    [[WLStreamsManager manager] start];
}
#pragma mark - Action Methods
- (IBAction)settingButtonAction:(NSButton *)sender {
    if (!self.settingWindowController) {
        self.settingWindowController = [WLVideoDeviceSettingWindowController sharedController];
        self.settingWindowController.delegate = self;
    }
    [self.settingWindowController showWindowWithCurrentDevice:self.currentVideoDeviceID];
}

- (IBAction)startButtonAction:(NSButton *)sender {
    [self.mediaSource start];
}

- (IBAction)startCamera:(id)sender {
    [self startWLCamera];
}
#pragma mark - Private Methods
- (void)startWLCamera {
    WLVideoManager *manager = [WLVideoManager manager];
    [manager subscriber:self];
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    [manager switchWithDevice:device];
    // 启动采集
    [manager startCapture];
}
#pragma mark - WLCameraCaptureSubscriber
- (void)cameraCaptureManager:(WLVideoManager *)manager
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // 获取视频的流信息
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }
    
    // 由于 sampleBuffer 会被系统回收，需要手动 retain pixelBuffer
    CVPixelBufferRetain(pixelBuffer);
    
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    Float64 pts = CMTimeGetSeconds(presentationTime);
    
    // 创建视频节点并添加到流管理器
    WLNode *videoNode = [[WLNode alloc] init];
    videoNode.type = WLNodeTypeVideo;
    videoNode.fromType = WLFromTypeCamera;
    videoNode.data = pixelBuffer;
    videoNode.pts = pts;
    
    WLStreamsManager *streams = [WLStreamsManager manager];
    [streams addVideoNode:videoNode];
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

#pragma mark - WLVideoDeviceSettingWindowControllerDelegate

- (void)videoDeviceSettingController:(WLVideoDeviceSettingWindowController *)controller
              didConfirmWithDevice:(NSString *)deviceID
                           preset:(NSString *)preset
                       useBuffer:(BOOL)useBuffer {
    NSLog(@"确认设置 - 设备：%@, 预设：%@, 使用缓冲：%@", deviceID, preset, @(useBuffer));
    
    self.currentVideoDeviceID = deviceID;
    
    if (deviceID && deviceID.length > 0) {
        NSArray *devices = [[WLDevicesManager manager] currentVideoDevices];
        for (WLDeviceItem *item in devices) {
            if ([item.uniqueID isEqualToString:deviceID]) {
                WLVideoManager *manager = [WLVideoManager manager];
                [manager switchWithDevice:item.device];
                break;
            }
        }
    }
}

@end
