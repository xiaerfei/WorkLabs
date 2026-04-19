//
//  WLCameraMediaSource.m
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//

#import "WLCameraMediaSource.h"
#import "WLVideoManager.h"

@interface WLCameraMediaSource ()

@property (nonatomic, strong) WLVideoManager *videoManager;
@property (nonatomic, copy) NSString *deviceID;

/// 缓存的最新视频帧
@property (nonatomic, strong, nullable) WLNodeFrame *latestFrame;

@end

@implementation WLCameraMediaSource
@synthesize sourceType = _sourceType;
@synthesize sourceName = _sourceName;
@synthesize volume = _volume;
@synthesize isActive = _isActive;
@synthesize frameRate = _frameRate;

- (nullable instancetype)initWithDeviceID:(NSString *)deviceID {
    self = [super init];
    if (self) {
        _deviceID = [deviceID copy];
        _sourceType = WLMediaSourceTypeCamera;
        _sourceName = @"Camera";
        _volume = 1.0;
        _isActive = NO;
        _frameRate = 30.0;
        _videoManager = [[WLVideoManager alloc] init];
    }
    return self;
}

#pragma mark - WLMediaSourceProvider

- (void)start {
    _isActive = YES;
}

- (void)stop {
    _isActive = NO;
    self.latestFrame = nil;
}

- (nullable WLNodeFrame *)nextVideoFrame {
    WLNodeFrame *frame = self.latestFrame;
    self.latestFrame = nil;
    return frame;
}

- (nullable WLNodeFrame *)nextAudioFrame {
    // 摄像头源不提供音频数据，音频由独立音频管理器处理
    return nil;
}

- (CGSize)intrinsicSize {
    return CGSizeZero;
}

#pragma mark - WLCameraCaptureSubscriber

- (void)captureOutput:(CMSampleBufferRef)sampleBuffer {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;

    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)imageBuffer;
    CVPixelBufferRetain(pixelBuffer);

    WLNodeFrame *frame = [[WLNodeFrame alloc] init];
    frame.type = WLFrameTypeVideo;
    frame.pixelBuffer = pixelBuffer;
    frame.pts = pts;
    frame.videoSize = CGSizeMake(CVPixelBufferGetWidth(pixelBuffer),
                                  CVPixelBufferGetHeight(pixelBuffer));

    self.latestFrame = frame;
}

@end
