//
//  WLStreamPreview.h
//  WorkLabs
//

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLStreamPreview : NSView

@property (nonatomic, strong, readonly) AVSampleBufferDisplayLayer *displayLayer;

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)enqueuePixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
- (void)flush;

@end

NS_ASSUME_NONNULL_END
