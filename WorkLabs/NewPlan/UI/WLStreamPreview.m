//
//  WLStreamPreview.m
//  WorkLabs
//

#import "WLStreamPreview.h"

@implementation WLStreamPreview

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupLayer];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setupLayer];
    }
    return self;
}

- (void)setupLayer {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;
}

- (CALayer *)makeBackingLayer {
    _displayLayer = [AVSampleBufferDisplayLayer layer];
    _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    return _displayLayer;
}

#pragma mark - Public

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;
    CFRetain(sampleBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

- (void)enqueuePixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    if (!pixelBuffer) return;
    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPixelBuffer:pixelBuffer pts:pts];
    if (!sampleBuffer) return;
    [self enqueueSampleBuffer:sampleBuffer];
    CFRelease(sampleBuffer);
}

- (void)flush {
    [self.displayLayer.sampleBufferRenderer flush];
}

#pragma mark - Private

- (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                                   pts:(Float64)pts {
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, pixelBuffer, &formatDesc);
    if (status != noErr) return NULL;

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMakeWithSeconds(pts, 600),
        .decodeTimeStamp = kCMTimeInvalid
    };

    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, pixelBuffer, formatDesc, &timing, &sampleBuffer);
    CFRelease(formatDesc);

    return (status == noErr) ? sampleBuffer : NULL;
}

@end
