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

// 是否响应鼠标拖动/缩放。默认 YES。MainPreview 应设为 NO，使其不拦截事件。
@property (nonatomic, assign) BOOL interactive;

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)enqueuePixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
- (void)flush;

@end

NS_ASSUME_NONNULL_END
