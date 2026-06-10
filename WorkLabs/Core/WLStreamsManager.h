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

// 合成输出帧率上限（默认 60）：限制合成频率，通常设为编码 fps，避免拖动 / 多源时过度合成致编码丢帧。
@property (nonatomic, assign) int renderFrameRate;

// 是否启用画布合成（WLVideoMix）：默认 NO。纯预览不合成（预览各走自己的 WLStreamPreview 上屏）；
// 仅在录制/推流等真正消费合成帧时由上层置 YES，避免空转 CoreImage 合成浪费 CPU/GPU。
@property (nonatomic, assign, getter=isCompositingEnabled) BOOL compositingEnabled;

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

// 按单路源（streamID）设置/读取基本滤镜参数（镜像/颜色校正/裁剪）；
// 内部维护一个 WLBasicVideoFilter，全默认（identity）时自动透传、零渲染。
- (void)setFilterParams:(NSDictionary *)params forStreamID:(NSString *)streamID;
- (NSDictionary *)filterParamsForStreamID:(NSString *)streamID;

- (NSString *)streamIDForSource:(id<WLStreamSourceProtocol>)source;

#pragma mark - Layout / Background（同步 canvas + mix）

// 设置某路在画布上的 layout（画布像素坐标，左下角原点）
- (void)setLayoutFrame:(CGRect)frame forStreamID:(NSString *)streamID;
- (void)setBackgroundColor:(nullable NSColor *)color;
- (void)setBackgroundImage:(nullable NSImage *)image;

// 更新画布分辨率：按新旧尺寸比例缩放各路 layout，同步 canvas + mix
- (void)setCanvasSize:(CGSize)canvasSize;

#pragma mark - 音频音量（按来源类型）

// 设置某类来源（如 Media / Mic）在混音中的音量（1.0=原始，<1 减小，>1 放大）；
// 对已添加及之后添加的该类源生效。
- (void)setVolume:(float)volume forFromType:(WLFromType)fromType;
- (float)volumeForFromType:(WLFromType)fromType;

// 按单路源（streamID）设置/读取混音音量（1.0=原始）；用于「每源独立调音」
- (void)setVolume:(float)volume forStreamID:(NSString *)streamID;
- (float)volumeForStreamID:(NSString *)streamID;

// z-order 调整（同步 canvas + mix；调用方负责同步预览 subview 顺序）
- (void)bringStreamToFront:(NSString *)streamID;
- (void)sendStreamToBack:(NSString *)streamID;
- (void)moveStreamUp:(NSString *)streamID;
- (void)moveStreamDown:(NSString *)streamID;

#pragma mark - Lifecycle

@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
- (BOOL)start;
- (void)stop;

#pragma mark - 调试

// 调试：模拟音频断流 N 秒（转发给内部混音器），用于验证断流补静音 / A/V 同步
- (void)debugSimulateAudioGapForSeconds:(NSTimeInterval)seconds;

@end

NS_ASSUME_NONNULL_END
