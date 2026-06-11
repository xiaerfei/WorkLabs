//
//  WLBasicVideoFilter.m
//  WorkLabs
//
//  镜像 / 颜色校正 / 裁剪 —— 全部用 Metal 离屏渲染（一个 fragment shader 一遍过），
//  替代原 CoreImage（CIColorControls + CIHueAdjust + 仿射变换 + CIContext render）。
//  isIdentity 时透传，零 GPU。
//

#import "WLBasicVideoFilter.h"
#import "WLMetalContext.h"
#import "WLMetalShaderTypes.h"
#import <Metal/Metal.h>

NSString * const WLFilterKeyHMirror    = @"hMirror";
NSString * const WLFilterKeyVMirror    = @"vMirror";
NSString * const WLFilterKeyBrightness = @"brightness";
NSString * const WLFilterKeyContrast   = @"contrast";
NSString * const WLFilterKeySaturation = @"saturation";
NSString * const WLFilterKeyHue        = @"hue";
NSString * const WLFilterKeyCropTop    = @"cropTop";
NSString * const WLFilterKeyCropBottom = @"cropBottom";
NSString * const WLFilterKeyCropLeft   = @"cropLeft";
NSString * const WLFilterKeyCropRight  = @"cropRight";

@interface WLBasicVideoFilter ()
@property (nonatomic, strong) WLMetalContext *metal;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLBuffer> quadBuffer;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (nonatomic, assign) CVPixelBufferPoolRef pool;   // 按输出尺寸缓存，尺寸变则重建
@property (nonatomic, assign) int poolW;
@property (nonatomic, assign) int poolH;
@end

@implementation WLBasicVideoFilter

- (instancetype)init {
    self = [super init];
    if (self) {
        // 颜色校正的中性默认值
        _contrast = 1.0f;
        _saturation = 1.0f;

        _metal = [WLMetalContext shared];
        if (_metal) {
            _pipeline = [_metal pipelineWithFragment:@"filterFragment" blending:NO];
            _textureCache = [_metal newTextureCache];
            // 全屏 quad：pos.xy + tex.uv，texCoord 已含 v-flip（底=1 顶=0），与 vertexShader 约定一致
            static const float quad[] = {
                -1, -1, 0, 1,
                 1, -1, 1, 1,
                -1,  1, 0, 0,
                 1,  1, 1, 0,
            };
            _quadBuffer = [_metal.device newBufferWithBytes:quad
                                                     length:sizeof(quad)
                                                    options:MTLResourceStorageModeShared];
        }
    }
    return self;
}

- (void)dealloc {
    if (_pool) CVPixelBufferPoolRelease(_pool);
    if (_textureCache) CFRelease(_textureCache);
}

#pragma mark - WLStreamFilterProtocol

- (WLNodeType)filterType { return WLNodeTypeVideo; }

- (BOOL)isIdentity {
    return !self.hMirror && !self.vMirror
        && self.brightness == 0.0f && self.contrast == 1.0f
        && self.saturation == 1.0f && self.hue == 0.0f
        && self.cropTop == 0.0f && self.cropBottom == 0.0f
        && self.cropLeft == 0.0f && self.cropRight == 0.0f;
}

#pragma mark - Params

+ (NSDictionary<NSString *, NSNumber *> *)defaultParams {
    return @{
        WLFilterKeyHMirror: @NO,    WLFilterKeyVMirror: @NO,
        WLFilterKeyBrightness: @0.0f, WLFilterKeyContrast: @1.0f,
        WLFilterKeySaturation: @1.0f, WLFilterKeyHue: @0.0f,
        WLFilterKeyCropTop: @0.0f,  WLFilterKeyCropBottom: @0.0f,
        WLFilterKeyCropLeft: @0.0f, WLFilterKeyCropRight: @0.0f,
    };
}

- (NSDictionary<NSString *, NSNumber *> *)params {
    return @{
        WLFilterKeyHMirror: @(self.hMirror),       WLFilterKeyVMirror: @(self.vMirror),
        WLFilterKeyBrightness: @(self.brightness), WLFilterKeyContrast: @(self.contrast),
        WLFilterKeySaturation: @(self.saturation), WLFilterKeyHue: @(self.hue),
        WLFilterKeyCropTop: @(self.cropTop),       WLFilterKeyCropBottom: @(self.cropBottom),
        WLFilterKeyCropLeft: @(self.cropLeft),     WLFilterKeyCropRight: @(self.cropRight),
    };
}

- (void)applyParams:(NSDictionary<NSString *, NSNumber *> *)p {
    NSNumber *n;
    if ((n = p[WLFilterKeyHMirror]))    self.hMirror    = n.boolValue;
    if ((n = p[WLFilterKeyVMirror]))    self.vMirror    = n.boolValue;
    if ((n = p[WLFilterKeyBrightness])) self.brightness = n.floatValue;
    if ((n = p[WLFilterKeyContrast]))   self.contrast   = n.floatValue;
    if ((n = p[WLFilterKeySaturation])) self.saturation = n.floatValue;
    if ((n = p[WLFilterKeyHue]))        self.hue        = n.floatValue;
    if ((n = p[WLFilterKeyCropTop]))    self.cropTop    = n.floatValue;
    if ((n = p[WLFilterKeyCropBottom])) self.cropBottom = n.floatValue;
    if ((n = p[WLFilterKeyCropLeft]))   self.cropLeft   = n.floatValue;
    if ((n = p[WLFilterKeyCropRight]))  self.cropRight  = n.floatValue;
}

#pragma mark - Process

- (nullable CVPixelBufferRef)processVideoFrame:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    if (!pixelBuffer) return NULL;

    // 透传：无调整，或 Metal 不可用（降级不致崩）
    if (self.isIdentity || !self.metal || !self.pipeline || !self.textureCache || !self.quadBuffer) {
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer;
    }

    size_t inW = CVPixelBufferGetWidth(pixelBuffer);
    size_t inH = CVPixelBufferGetHeight(pixelBuffer);

    // 裁剪改变输出尺寸（与原 CoreImage 语义一致）
    float cl = MAX(0.0f, MIN(self.cropLeft,   0.45f));
    float cr = MAX(0.0f, MIN(self.cropRight,  0.45f));
    float ct = MAX(0.0f, MIN(self.cropTop,    0.45f));
    float cb = MAX(0.0f, MIN(self.cropBottom, 0.45f));
    int outW = (int)lround((double)inW * (1.0 - cl - cr));
    int outH = (int)lround((double)inH * (1.0 - ct - cb));
    if (outW <= 0 || outH <= 0) {
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer;
    }
    // 量化输出尺寸到 16 的倍数：拖动裁剪时尺寸逐帧连续变化，会令 acquirePixelBuffer 每帧重建 pool，
    // 旧 pool 的 in-flight buffer（仍在预览 AVSampleBufferDisplayLayer 队列里）来不及回收即堆积 →
    // 内存尖峰（实测 200MB→700MB 后回落）。量化后相邻帧多落同一尺寸桶，pool 命中复用、极少重建，削平尖峰。
    // 无裁剪时 outW==inW（下方 MIN 兜底），尺寸不变、pool 不重建，与纯颜色/镜像路径一致。
    outW = MAX(16, MIN((int)inW, ((outW + 8) / 16) * 16));
    outH = MAX(16, MIN((int)inH, ((outH + 8) / 16) * 16));

    CVPixelBufferRef dst = [self acquirePixelBufferWidth:outW height:outH];
    if (!dst) {
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer;
    }

    // @autoreleasepool 关键：本方法在源渲染线程 / 摄像头采集队列上每帧被调用，MTLCommandBuffer 等
    // autoreleased 对象会持有输入/输出纹理（及其 IOSurface 像素内存）直到自身释放；循环无 pool 排空则
    // 每帧累积 —— 开滤镜时内存从十几 % 飙到 1GB+。pool 在 waitUntilCompleted 后排空，GPU 已完成，安全。
    BOOL ok = NO;
    @autoreleasepool {
        WLMetalTextureBinding *input  = [self.metal bindSamplingPixelBuffer:pixelBuffer cache:self.textureCache];
        WLMetalTextureBinding *output = [self.metal bindRenderTargetPixelBuffer:dst cache:self.textureCache];
        if (input && output) {
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = output.texture0;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;

            id<MTLCommandBuffer> cmdBuf = [self.metal.commandQueue commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:pass];
            [enc setRenderPipelineState:self.pipeline];
            [enc setVertexBuffer:self.quadBuffer offset:0 atIndex:0];
            [enc setFragmentTexture:input.texture0 atIndex:0];
            [enc setFragmentTexture:(input.texture1 ?: input.texture0) atIndex:1]; // 非 YUV 占位，shader 不访问

            WLFilterParams p = {0};
            p.hMirror     = self.hMirror ? 1 : 0;
            p.vMirror     = self.vMirror ? 1 : 0;
            p.cropL       = cl;
            p.cropR       = cr;
            p.cropT       = ct;
            p.cropB       = cb;
            p.brightness  = self.brightness;
            p.contrast    = self.contrast;
            p.saturation  = self.saturation;
            p.hueRadians  = self.hue * (float)M_PI / 180.0f;
            p.isYUV       = input.isYUV ? 1 : 0;
            p.isFullRange = input.isFullRange ? 1 : 0;
            [enc setFragmentBytes:&p length:sizeof(p) atIndex:0];

            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted]; // 下游（编码器 CPU swscale / 预览）需读完成后的像素，必须等
            CVMetalTextureCacheFlush(self.textureCache, 0);
            ok = YES;
        }
    } // pool 排空：command buffer / encoder / 输入输出 binding 全部释放（GPU 已完成）

    if (!ok) { // 绑定失败：降级透传原帧
        CVPixelBufferRelease(dst);
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer;
    }
    return dst; // Create Rule：所有权转移给调用方
}

#pragma mark - Pool

- (nullable CVPixelBufferRef)acquirePixelBufferWidth:(int)w height:(int)h {
    if (_pool == NULL || _poolW != w || _poolH != h) {
        if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey:     @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey:               @(w),
            (id)kCVPixelBufferHeightKey:              @(h),
            (id)kCVPixelBufferMetalCompatibilityKey:  @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVPixelBufferPoolRef pool = NULL;
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool);
        _pool = pool;
        _poolW = w;
        _poolH = h;
    }
    if (!_pool) return NULL;
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &pb) != kCVReturnSuccess) return NULL;
    return pb;
}

@end
