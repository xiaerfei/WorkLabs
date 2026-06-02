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

// 是否响应鼠标拖动/缩放。默认 YES。
@property (nonatomic, assign) BOOL interactive;

// 选中态：显示红框 + 8 个手柄小方块（OBS 风格）。未选中不显示。
@property (nonatomic, assign, getter=isSelected) BOOL selected;

// 视频宽高比 (w/h)。收到首帧后按真实比例更新；resize 时锁定该比例等比缩放。
@property (nonatomic, assign) CGFloat videoAspect;

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)enqueuePixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
- (void)flush;

@end

NS_ASSUME_NONNULL_END
