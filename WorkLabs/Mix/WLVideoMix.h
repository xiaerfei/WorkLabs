//
//  WLVideoMix.h
//  WorkLabs
//
//  视频合成器 — 背景(色/图) + 多路按 layoutFrame 合成到固定画布。
//  合成顺序：填背景色 → 铺背景图(整张) → 按加入顺序(z-order)叠加各路流。
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>
#import "WLDefines.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLVideoMix : NSObject

// 固定画布尺寸；默认 1920x1080
@property (nonatomic, assign, readonly) CGSize canvasSize;

// 合成输出回调（在内部串行队列调用）。
// 所有权遵循 Create Rule：block 收到的 pixelBuffer 所有权转移给 block，需自行 CVPixelBufferRelease。
@property (nonatomic, copy, nullable) void (^output)(CVPixelBufferRef pixelBuffer, Float64 pts);

- (instancetype)initWithCanvasSize:(CGSize)canvasSize;

// 画布背景：纯色 + 整张铺满背景图（传 nil 清除）
- (void)setBackgroundColor:(nullable NSColor *)color;
- (void)setBackgroundImage:(nullable NSImage *)image;

// 输入一帧（按 streamID 区分）。
// 调用方持有 pixelBuffer 所有权，Mix 内部会按需 retain；调用方仍需释放自己的引用。
- (void)inputVideoFrame:(CVPixelBufferRef)pixelBuffer
                    pts:(Float64)pts
               streamID:(NSString *)streamID;

// 设置某路 stream 在画布上的位置/尺寸（画布像素坐标，左下角原点）
- (void)setLayoutFrame:(CGRect)frame forStreamID:(NSString *)streamID;

// 移除某路 stream（同时清掉缓存帧）
- (void)removeStreamID:(NSString *)streamID;

// 设置合成 z-order（数组顺序=从底到顶）；由编排层依据 WLCanvasModel 同步
- (void)setStreamOrder:(NSArray<NSString *> *)streamOrder;

// 更新画布尺寸（重建 pixelBufferPool）
- (void)updateCanvasSize:(CGSize)canvasSize;

// 设置合成输出帧率上限（默认 60）：限制 render 频率，避免输入事件（源帧 / 拖动）驱动的过度合成。
- (void)setRenderFrameRate:(int)fps;

@end

NS_ASSUME_NONNULL_END
