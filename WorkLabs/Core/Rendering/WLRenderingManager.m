//
//  WLRenderingManager.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/29.
//

#import "WLRenderingManager.h"
#import "WLAudioQueuePlayer.h"

@interface WLRenderingManager ()
@property (nonatomic, strong, readwrite) WLViedoPreview *videoPreview;
@property (nonatomic, strong, readwrite) WLAudioQueuePlayer *audioQueuePlayer;
@end

@implementation WLRenderingManager

- (instancetype)init {
    self = [super init];
    if (self) {
    }
    return self;
}

#pragma mark -
+ (instancetype)manager {
    static WLRenderingManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[WLRenderingManager alloc] init];
    });
    return manager;
}

- (void)pixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    CMSampleBufferRef sampleBuffer = [self sampleBufferFromPixelBuffer:pixelBuffer pts:pts];
    if (sampleBuffer) {
        [self.videoPreview.displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }
}
#pragma mark - Private Methods

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
