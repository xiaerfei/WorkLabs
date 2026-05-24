//
//  WLStreamPreview.h
//  WorkLabs
//

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import "WLStreamRenderingProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLStreamPreview : NSView <WLStreamRenderingProtocol>

@property (nonatomic, strong, readonly) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, weak, nullable) id<WLStreamRenderingDelegate> delegate;

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)enqueuePixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
- (void)flush;

@end

NS_ASSUME_NONNULL_END
