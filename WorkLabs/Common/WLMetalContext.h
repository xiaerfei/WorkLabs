//
//  WLMetalContext.h
//  WorkLabs
//
//  全工程共享的 Metal 基础设施：device / commandQueue / 默认 library / pipeline-state 缓存。
//  这些对象线程安全、可全局共享，替换各处独立的 MTLCreateSystemDefaultDevice()。
//
//  注意：CVMetalTextureCache 不是线程安全的 —— 每个渲染对象（每个滤镜实例、合成器）
//  各自 newTextureCache 持有一份，只在自己的串行队列上使用。
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

// 一次绑定的产物。持有底层 CVMetalTextureRef 的生命周期（ARC dealloc 时 CFRelease）。
// 调用方需持有本对象，直到对应 command buffer 完成（waitUntilCompleted 之后）方可释放。
@interface WLMetalTextureBinding : NSObject
@property (nonatomic, readonly, nullable) id<MTLTexture> texture0; // 采样: Y 或 RGB；render target: 输出
@property (nonatomic, readonly, nullable) id<MTLTexture> texture1; // 采样 YUV 时: CbCr，否则 nil
@property (nonatomic, readonly) BOOL isYUV;
@property (nonatomic, readonly) BOOL isFullRange;
@end

@interface WLMetalContext : NSObject

+ (nullable instancetype)shared;

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;
@property (nonatomic, readonly, nullable) id<MTLLibrary> library;

// 为单个渲染对象创建独占的 texture cache（带 RenderTarget|ShaderRead usage）。
- (nullable CVMetalTextureCacheRef)newTextureCache CF_RETURNS_RETAINED;

// 取/建 render pipeline（顶点固定为默认库的 vertexShader，颜色目标 BGRA8Unorm）。
// 按 (fragment 函数名, blending) 缓存复用。blending=YES 时启用 sourceAlpha/oneMinusSourceAlpha。
- (nullable id<MTLRenderPipelineState>)pipelineWithFragment:(NSString *)fragmentName
                                                  blending:(BOOL)blending;

// 将输入 CVPixelBuffer 绑成可采样纹理（NV12 双平面 / BGRA / RGBA，自动检测 full/video range）。
- (nullable WLMetalTextureBinding *)bindSamplingPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                                     cache:(CVMetalTextureCacheRef)cache;

// 将输出 CVPixelBuffer（须 Metal 兼容、BGRA）绑成 render target 纹理（texture0）。
- (nullable WLMetalTextureBinding *)bindRenderTargetPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                                         cache:(CVMetalTextureCacheRef)cache;

@end

NS_ASSUME_NONNULL_END
