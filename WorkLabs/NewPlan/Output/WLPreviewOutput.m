//
//  WLPreviewOutput.m
//  WorkLabs
//

#import "WLPreviewOutput.h"
#import "WLViedoPreview.h"

@interface WLPreviewOutput ()
@property (nonatomic, strong, readwrite) WLViedoPreview *preview;
@end

@implementation WLPreviewOutput

- (instancetype)init {
    self = [super init];
    if (self) { _preview = [[WLViedoPreview alloc] init]; }
    return self;
}

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    if (!pixelBuffer) return;
    CMSampleBufferRef sampleBuffer = [self sampleBufferFromPixelBuffer:pixelBuffer pts:pts];
    if (!sampleBuffer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.preview.displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

- (CMSampleBufferRef)sampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    if (status != noErr) return NULL;
    CMSampleTimingInfo timingInfo;
    timingInfo.duration = kCMTimeInvalid;
    timingInfo.presentationTimeStamp = CMTimeMakeWithSeconds(pts, 600);
    timingInfo.decodeTimeStamp = kCMTimeInvalid;
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, formatDescription, &timingInfo, &sampleBuffer);
    CFRelease(formatDescription);
    return (status == noErr) ? sampleBuffer : NULL;
}

@end
