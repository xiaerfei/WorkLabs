//
//  WLStreamsManager.h
//  WorkLabs
//
//  简化版编排核心：Source → perStreamFilter → fork(Render预览 + WLVideoMix 合成)。
//  背景/布局由 WLCanvasModel 单一数据源描述，同步给 Render 画布与 WLVideoMix。
//  本阶段不接 Encoder/音频。
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import "WLStreamSourceProtocol.h"
#import "WLStreamOutputProtocol.h"
#import "WLStreamFilterProtocol.h"
#import "WLCanvasModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLStreamsManager : NSObject <WLStreamSourceDelegate>

- (instancetype)initWithCanvas:(WLCanvasModel *)canvas;

// 画布数据源（背景/布局）
@property (nonatomic, strong, readonly) WLCanvasModel *canvas;

// 合成帧输出（本阶段用于验证 / 后续接 Encoder）。
// 所有权遵循 Create Rule：block 收到的 pixelBuffer 所有权转移给 block，需自行 CVPixelBufferRelease。
@property (nonatomic, copy, nullable) void (^mixedFrameOutput)(CVPixelBufferRef pixelBuffer, Float64 pts);

// 音频输出（本阶段用于录制）。block 收到的 sampleBuffer 仅在调用期间有效（"借用"语义）；
// 需要持有（如异步编码）请自行 CFRetain / CFRelease。
@property (nonatomic, copy, nullable) void (^audioBufferOutput)(CMSampleBufferRef sampleBuffer);

#pragma mark - Source

// 注册 Source，并指定其预览输出（如 WLStreamPreview，nil 表示不需要预览）。返回该路的 streamID。
// 内部会把 source.delegate 设为 self。预览的拖拽 delegate 由调用方(界面层)管理。
- (NSString *)addSource:(id<WLStreamSourceProtocol>)source
          previewOutput:(nullable id<WLVideoOutputProtocol>)preview;

- (void)removeSource:(id<WLStreamSourceProtocol>)source;

// 为某路 Source 设置 perStreamFilter（缩放/裁剪/镜像）；nil 表示透传
- (void)setFilter:(nullable id<WLVideoFilterProtocol>)filter
        forSource:(id<WLStreamSourceProtocol>)source;

- (NSString *)streamIDForSource:(id<WLStreamSourceProtocol>)source;

#pragma mark - Layout / Background（同步 canvas + mix）

// 设置某路在画布上的 layout（画布像素坐标，左下角原点）
- (void)setLayoutFrame:(CGRect)frame forStreamID:(NSString *)streamID;
- (void)setBackgroundColor:(nullable NSColor *)color;
- (void)setBackgroundImage:(nullable NSImage *)image;

// 更新画布分辨率：按新旧尺寸比例缩放各路 layout，同步 canvas + mix
- (void)setCanvasSize:(CGSize)canvasSize;

// z-order 调整（同步 canvas + mix；调用方负责同步预览 subview 顺序）
- (void)bringStreamToFront:(NSString *)streamID;
- (void)sendStreamToBack:(NSString *)streamID;
- (void)moveStreamUp:(NSString *)streamID;
- (void)moveStreamDown:(NSString *)streamID;

#pragma mark - Lifecycle

@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
