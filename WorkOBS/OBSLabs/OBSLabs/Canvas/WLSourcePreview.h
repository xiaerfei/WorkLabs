//
//  WLSourcePreview.h
//  OBSLabs
//
//  交互式源预览浮层：AVSampleBufferDisplayLayer 渲染 + 拖拽/缩放/选中/右键。
//  从 WorkLabs WLStreamPreview 搬入，适配 WorkOBS。
//

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// 层级(z-order)调整动作
typedef NS_ENUM(NSInteger, WLZOrderAction) {
    WLZOrderActionFront,
    WLZOrderActionBack,
    WLZOrderActionUp,
    WLZOrderActionDown,
};

@class WLSourcePreview;

@protocol WLSourcePreviewDelegate <NSObject>
- (void)sourcePreview:(WLSourcePreview *)preview didUpdateFrame:(CGRect)frame;
@optional
- (void)sourcePreviewDidRequestSelect:(WLSourcePreview *)preview;
- (void)sourcePreviewDidRequestDeselect:(WLSourcePreview *)preview;
- (void)sourcePreviewDidRequestRemove:(WLSourcePreview *)preview;
- (void)sourcePreview:(WLSourcePreview *)preview didRequestZOrderAction:(WLZOrderAction)action;
@end

@interface WLSourcePreview : NSView

@property (nonatomic, strong, readonly) AVSampleBufferDisplayLayer *videoLayer;
@property (nonatomic, weak, nullable) id<WLSourcePreviewDelegate> delegate;
@property (nonatomic, assign) BOOL interactive;       // 默认 YES
@property (nonatomic, assign, getter=isSelected) BOOL selected;
@property (nonatomic, assign) CGFloat videoAspect;    // 首帧后更新，resize 锁比例

- (void)enqueuePixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
- (void)flush;

@end

NS_ASSUME_NONNULL_END
