//
//  WLVideoMix.m
//  WorkLabs
//
//  Metal 离屏合成器（替代原 CoreImage）：背景色(clear 铺底) + 背景图(全屏 quad) +
//  按 streamOrder 各路源 quad（layout→NDC，alpha blend，painter's algorithm），
//  单 render pass 渲到 IOSurface-backed BGRA 画布，零中间纹理。
//

#import "WLVideoMix.h"
#import "WLMetalContext.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include <mach/mach_time.h>

// 单调墙钟（秒），用于合成输出节流
static Float64 WLVideoMixNowSeconds(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (Float64)mach_absolute_time() * tb.numer / tb.denom / 1.0e9;
}

@interface WLVideoMix ()
@property (nonatomic, strong, nullable) WLMetalContext *metal;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache; // 自有，仅在 serialQueue 触碰
@property (nonatomic, strong, nullable) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) dispatch_queue_t serialQueue;

// streamID -> CVPixelBufferRef（已 retain）
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *latestFrames;
// streamID -> CGRect（NSValue 包装）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *layouts;
// 维持合成顺序（先加入的在底层）
@property (nonatomic, strong) NSMutableArray<NSString *> *streamOrder;

// 画布背景（仅在 serialQueue 访问）
@property (nonatomic, assign) BOOL hasBgColor;            // 用户是否设过背景色（区别于默认黑底兜底）
@property (nonatomic, assign) MTLClearColor bgClearColor; // 背景色（sRGB gamma 域，直写 BGRA 非 sRGB 纹理）
@property (nonatomic, strong, nullable) id<MTLTexture> bgTexture; // 背景图（NSImage 转换一次缓存）
@property (nonatomic, assign) Float64 lastPts;
@property (nonatomic, assign) Float64 lastRenderTime;     // 上次实际合成输出的墙钟（节流用）
@property (nonatomic, assign) Float64 minRenderInterval;  // 合成最小间隔 = 1 / 帧率上限

@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;

@end

@implementation WLVideoMix

- (instancetype)initWithCanvasSize:(CGSize)canvasSize {
    self = [super init];
    if (self) {
        _canvasSize = (canvasSize.width > 0 && canvasSize.height > 0)
            ? canvasSize : CGSizeMake(1920, 1080);

        _metal = [WLMetalContext shared];
        if (_metal) {
            // 合成复用基础 fragmentShader（YUV/BGRA + range）；各源位置/缩放全在顶点 NDC+texCoord 完成。
            // blending:YES → 源 alpha 叠加（不透明视频时即覆盖，painter's algorithm）。
            _pipeline = [_metal pipelineWithFragment:@"fragmentShader" blending:YES];
            _textureCache = [_metal newTextureCache];
        }
        _bgClearColor = MTLClearColorMake(0, 0, 0, 1); // 默认黑底铺底，防 pool 复用 buffer 残影

        _serialQueue = dispatch_queue_create("com.worklabs.videomix", DISPATCH_QUEUE_SERIAL);
        _minRenderInterval = 1.0 / 60.0;   // 默认合成帧率上限 60fps（可由 setRenderFrameRate: 调整）
        _latestFrames = [NSMutableDictionary dictionary];
        _layouts = [NSMutableDictionary dictionary];
        _streamOrder = [NSMutableArray array];

        [self ensurePool];
    }
    return self;
}

- (void)dealloc {
    for (NSString *sid in _latestFrames) {
        CVPixelBufferRef pb = (__bridge CVPixelBufferRef)_latestFrames[sid];
        if (pb) CVPixelBufferRelease(pb);
    }
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
    }
    if (_textureCache) {
        CFRelease(_textureCache);
    }
}

#pragma mark - Background

- (void)setBackgroundColor:(nullable NSColor *)color {
    BOOL has = (color != nil);
    MTLClearColor cc = MTLClearColorMake(0, 0, 0, 1);
    if (color) {
        NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (rgb) {
            CGFloat r = 0, g = 0, b = 0, a = 1;
            [rgb getRed:&r green:&g blue:&b alpha:&a];
            cc = MTLClearColorMake(r, g, b, a); // sRGB gamma 域分量直作 clearColor，与源 YUV→RGB 的 gamma 域一致
        }
    }
    dispatch_async(self.serialQueue, ^{
        self.hasBgColor = has;
        self.bgClearColor = cc;
        [self renderWithPts:self.lastPts];
    });
}

- (void)setBackgroundImage:(nullable NSImage *)image {
    // NSImage → MTLTexture：在调用线程转换好（纹理只读、可跨线程持有），再入队存储。
    // SRGB:@NO → 纹理按非 sRGB（BGRA8Unorm）存，采样即 gamma passthrough，与合成输出域一致、不偏暗。
    id<MTLTexture> tex = nil;
    if (image && self.metal.device) {
        CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
        if (cg) {
            MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:self.metal.device];
            NSDictionary *opts = @{
                MTKTextureLoaderOptionSRGB: @NO,
                MTKTextureLoaderOptionTextureUsage: @(MTLTextureUsageShaderRead),
            };
            NSError *err = nil;
            tex = [loader newTextureWithCGImage:cg options:opts error:&err];
            if (!tex) NSLog(@"[WLVideoMix] background texture load failed: %@", err);
        }
    }
    dispatch_async(self.serialQueue, ^{
        self.bgTexture = tex;
        [self renderWithPts:self.lastPts];
    });
}

#pragma mark - Public

- (void)inputVideoFrame:(CVPixelBufferRef)pixelBuffer
                    pts:(Float64)pts
               streamID:(NSString *)streamID {
    if (!pixelBuffer || streamID.length == 0) return;

    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(self.serialQueue, ^{
        // 替换缓存帧
        CVPixelBufferRef old = (__bridge CVPixelBufferRef)self.latestFrames[streamID];
        if (old) CVPixelBufferRelease(old);
        self.latestFrames[streamID] = (__bridge id)pixelBuffer;

        if (![self.streamOrder containsObject:streamID]) {
            [self.streamOrder addObject:streamID];
        }

        [self renderWithPts:pts];
    });
}

- (void)setLayoutFrame:(CGRect)frame forStreamID:(NSString *)streamID {
    if (streamID.length == 0) return;
    dispatch_async(self.serialQueue, ^{
        self.layouts[streamID] = [NSValue valueWithRect:frame];
        [self renderWithPts:self.lastPts];
    });
}

- (void)removeStreamID:(NSString *)streamID {
    if (streamID.length == 0) return;
    dispatch_async(self.serialQueue, ^{
        CVPixelBufferRef old = (__bridge CVPixelBufferRef)self.latestFrames[streamID];
        if (old) CVPixelBufferRelease(old);
        [self.latestFrames removeObjectForKey:streamID];
        [self.layouts removeObjectForKey:streamID];
        [self.streamOrder removeObject:streamID];
    });
}

- (void)setStreamOrder:(NSArray<NSString *> *)streamOrder {
    NSArray *copy = [streamOrder copy];
    dispatch_async(self.serialQueue, ^{
        [self.streamOrder removeAllObjects];
        if (copy.count) [self.streamOrder addObjectsFromArray:copy];
        [self renderWithPts:self.lastPts];
    });
}

- (void)updateCanvasSize:(CGSize)canvasSize {
    if (canvasSize.width <= 0 || canvasSize.height <= 0) return;
    dispatch_async(self.serialQueue, ^{
        self->_canvasSize = canvasSize;
        if (self->_pixelBufferPool) {
            CVPixelBufferPoolRelease(self->_pixelBufferPool);
            self->_pixelBufferPool = NULL;
        }
        [self ensurePool];
        [self renderWithPts:self.lastPts];
    });
}

- (void)setRenderFrameRate:(int)fps {
    Float64 interval = (fps > 0) ? (1.0 / (Float64)fps) : (1.0 / 60.0);
    dispatch_async(self.serialQueue, ^{
        self.minRenderInterval = interval;
    });
}

#pragma mark - Render

- (void)renderWithPts:(Float64)pts {
    self.lastPts = pts;

    // 未启用合成（纯预览）时直接返回：不空转整套 Metal 合成。
    // lastPts 已更新、latestFrames 由 inputVideoFrame 持续刷新，启用瞬间即用最新状态合成首帧，无延迟无丢状态。
    if (!self.renderingEnabled) return;

    // 无任何内容（背景与源都没有）→ 不输出
    if (!self.hasBgColor && !self.bgTexture && self.streamOrder.count == 0) return;

    // Metal 不可用则无法合成（构造时已尝试，pipeline/cache 缺失即放弃）
    if (!self.pipeline || !self.textureCache) return;

    // 输出节流：合成由输入事件驱动（源帧 + 拖动时高频 setLayoutFrame 等），频率可达数百 Hz、
    //   远超编码吞吐。按帧率上限节流；被跳过的输入已更新 latestFrames/layouts 缓存，
    //   后续帧会用最新状态合成，不丢最终画面。
    Float64 now = WLVideoMixNowSeconds();
    if (self.lastRenderTime > 0 && (now - self.lastRenderTime) < self.minRenderInterval) return;
    self.lastRenderTime = now;

    if (!self.pixelBufferPool) [self ensurePool];
    if (!self.pixelBufferPool) return;

    CVPixelBufferRef out = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, self.pixelBufferPool, &out) != kCVReturnSuccess || !out) {
        return;
    }

    // @autoreleasepool：本方法在 videomix 串行队列高频执行（录制/推流），MTLCommandBuffer 等 autoreleased
    // 对象会持有输入/输出纹理及其 IOSurface 像素内存，无 pool 排空将每帧累积致内存暴涨。pool 在
    // waitUntilCompleted 后排空（GPU 已完成）；out 为 CF 对象不受 pool 影响，安全交付下游。
    BOOL rendered = NO;
    @autoreleasepool {
        WLMetalTextureBinding *target = [self.metal bindRenderTargetPixelBuffer:out cache:self.textureCache];
        if (target) {
            // loadAction=Clear 背景色：既是背景，也是「始终铺满整张画布」防 pool 复用 buffer 残影（替代旧 CoreImage 全屏铺底）
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = target.texture0;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = self.bgClearColor;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;

            id<MTLCommandBuffer> cmdBuf = [self.metal.commandQueue commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:pass];
            [enc setRenderPipelineState:self.pipeline];

            // 输入纹理 binding 需活到 GPU 完成；持有到 pool 排空（waitUntilCompleted 之后）
            NSMutableArray<WLMetalTextureBinding *> *inputs = [NSMutableArray array];

            const float W = (float)self.canvasSize.width;
            const float H = (float)self.canvasSize.height;
            BOOL no = NO;

            // 1) 背景图：缩放铺满画布（全屏 quad，texCoord 含 v-flip：底=1 顶=0）
            if (self.bgTexture) {
                const float quad[] = {
                    -1, -1, 0, 1,
                     1, -1, 1, 1,
                    -1,  1, 0, 0,
                     1,  1, 1, 0,
                };
                [enc setVertexBytes:quad length:sizeof(quad) atIndex:0];
                [enc setFragmentTexture:self.bgTexture atIndex:0];
                [enc setFragmentTexture:self.bgTexture atIndex:1]; // 占位（isYUV=NO 时 shader 不采样它）
                [enc setFragmentBytes:&no length:sizeof(BOOL) atIndex:0];  // isYUV = NO（BGRA passthrough）
                [enc setFragmentBytes:&no length:sizeof(BOOL) atIndex:1];  // isFullRange（BGRA 无关）
                [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            }

            // 2) 各路视频流：从底到顶依次叠加（layout=画布像素、左下原点 → NDC y 不翻；翻转在 texCoord v）
            for (NSString *sid in self.streamOrder) {
                CVPixelBufferRef pb = (__bridge CVPixelBufferRef)self.latestFrames[sid];
                if (!pb) continue;

                CGRect layout = [self layoutForStreamID:sid];
                if (layout.size.width <= 0 || layout.size.height <= 0) continue;

                WLMetalTextureBinding *in = [self.metal bindSamplingPixelBuffer:pb cache:self.textureCache];
                if (!in) continue;
                [inputs addObject:in];

                const float ndcL = layout.origin.x / W * 2.0f - 1.0f;
                const float ndcR = (layout.origin.x + layout.size.width) / W * 2.0f - 1.0f;
                const float ndcB = layout.origin.y / H * 2.0f - 1.0f;
                const float ndcT = (layout.origin.y + layout.size.height) / H * 2.0f - 1.0f;
                const float quad[] = {
                    ndcL, ndcB, 0, 1,   // bottom-left  → tex(0,1)
                    ndcR, ndcB, 1, 1,   // bottom-right → tex(1,1)
                    ndcL, ndcT, 0, 0,   // top-left     → tex(0,0)
                    ndcR, ndcT, 1, 0,   // top-right    → tex(1,0)
                };
                [enc setVertexBytes:quad length:sizeof(quad) atIndex:0];
                [enc setFragmentTexture:in.texture0 atIndex:0];
                [enc setFragmentTexture:(in.texture1 ?: in.texture0) atIndex:1]; // 非 YUV 占位
                BOOL isYUV = in.isYUV, isFull = in.isFullRange;
                [enc setFragmentBytes:&isYUV length:sizeof(BOOL) atIndex:0];
                [enc setFragmentBytes:&isFull length:sizeof(BOOL) atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            }

            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted]; // 下游编码器 CPU swscale 读同一 buffer，必须等 GPU 完成再交付
            CVMetalTextureCacheFlush(self.textureCache, 0);
            rendered = YES;
        }
    } // pool 排空：command buffer / encoder / 输入输出 binding 全部释放（GPU 已完成）

    if (!rendered) { // 绑定 render target 失败
        CVPixelBufferRelease(out);
        return;
    }

    if (self.output) {
        self.output(out, pts); // 所有权转移给 block（out 是 CF 对象，不受上方 pool 影响）
    } else {
        CVPixelBufferRelease(out);
    }
}

- (CGRect)layoutForStreamID:(NSString *)sid {
    NSValue *v = self.layouts[sid];
    if (v) return v.rectValue;
    // 缺省：铺满画布
    return CGRectMake(0, 0, self.canvasSize.width, self.canvasSize.height);
}

#pragma mark - Pool

- (void)ensurePool {
    if (_pixelBufferPool) return;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:     @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:               @((int)self.canvasSize.width),
        (id)kCVPixelBufferHeightKey:              @((int)self.canvasSize.height),
        (id)kCVPixelBufferMetalCompatibilityKey:  @YES, // 绑 render target 需要（旧 CoreImage 路径无此项）
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool);
    _pixelBufferPool = pool;
}

@end
