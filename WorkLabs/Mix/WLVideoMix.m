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
#include <time.h>
#include <math.h>

/// 单调时钟纳秒（CLOCK_UPTIME_RAW：单调、不受改系统时间影响、休眠暂停；与 WLMediaSource 一致）
static inline uint64_t wl_mono_now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

/// async 缓冲里的一帧：持有 retain 的 pixelBuffer + 归一化 pts（秒）。
/// dealloc 释放 pixelBuffer → 队列/字典的释放交给 ARC，无需手动管。
@interface WLMixFrame : NSObject
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) Float64 pts;
@end

@implementation WLMixFrame
- (void)dealloc { if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer); }
@end

@interface WLVideoMix ()
@property (nonatomic, strong, nullable) WLMetalContext *metal;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache; // 自有，仅在 serialQueue 触碰
@property (nonatomic, strong, nullable) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) dispatch_queue_t serialQueue;

// ── 每源 async 帧缓冲 + 虚拟时钟选帧（OBS 式：吸收源 fps 差异 / 多源对齐）──
// streamID -> FIFO 队列（元素 WLMixFrame，带 pts）；tick 时按虚拟时钟选当前帧
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<WLMixFrame *> *> *asyncFrames;
// streamID -> 当前显示帧（慢源在两帧之间仍用它合成，实现重复）
@property (nonatomic, strong) NSMutableDictionary<NSString *, WLMixFrame *> *curFrames;
// streamID -> 虚拟时钟（源 pts 轴，秒；缺键 = 冷启动待锚）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastFrameTs;
// 上次 tick 实测系统时刻（纳秒，单调钟）；算 sys_offset 用。0 = 尚未起拍
@property (nonatomic, assign) uint64_t lastSysTs;
// streamID -> CGRect（NSValue 包装）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *layouts;
// 维持合成顺序（先加入的在底层）
@property (nonatomic, strong) NSMutableArray<NSString *> *streamOrder;

// 画布背景（仅在 serialQueue 访问）
@property (nonatomic, assign) BOOL hasBgColor;            // 用户是否设过背景色（区别于默认黑底兜底）
@property (nonatomic, assign) MTLClearColor bgClearColor; // 背景色（sRGB gamma 域，直写 BGRA 非 sRGB 纹理）
@property (nonatomic, strong, nullable) id<MTLTexture> bgTexture; // 背景图（NSImage 转换一次缓存）
// ── 合成 tick（固定节拍主动驱动，替代输入事件驱动）──
@property (nonatomic, strong, nullable) dispatch_source_t tickTimer; // 仅在 serialQueue 创建/销毁
@property (nonatomic, assign) Float64 tickInterval;       // tick 周期（秒）= 1 / 合成帧率
@property (nonatomic, assign) Float64 ptsAccum;           // 累计输出 pts（秒）；每拍 += tickInterval，改帧率不跳变

@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;

@end

@implementation WLVideoMix

@synthesize renderingEnabled = _renderingEnabled;   // 自定义 getter/setter（启停 tick），显式合成 ivar

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
        _tickInterval = 1.0 / 60.0;        // 默认 tick 周期 60fps（可由 setRenderFrameRate: 调整）
        _asyncFrames = [NSMutableDictionary dictionary];
        _curFrames = [NSMutableDictionary dictionary];
        _lastFrameTs = [NSMutableDictionary dictionary];
        _layouts = [NSMutableDictionary dictionary];
        _streamOrder = [NSMutableArray array];

        [self ensurePool];
    }
    return self;
}

- (void)dealloc {
    if (_tickTimer) {
        dispatch_source_cancel(_tickTimer);
        _tickTimer = nil;
    }
    // asyncFrames/curFrames 里的 WLMixFrame 由 ARC 释放，其 dealloc 释放 pixelBuffer，无需手动遍历
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
        // 只更新缓存，下一个 tick 自然采用新背景
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
        // 只更新缓存，下一个 tick 自然采用新背景图
    });
}

#pragma mark - Public

- (void)inputVideoFrame:(CVPixelBufferRef)pixelBuffer
                    pts:(Float64)pts
               streamID:(NSString *)streamID {
    if (!pixelBuffer || streamID.length == 0) return;

    CVPixelBufferRetain(pixelBuffer);   // 交给 WLMixFrame 持有
    dispatch_async(self.serialQueue, ^{
        WLMixFrame *f = [WLMixFrame new];
        f.pixelBuffer = pixelBuffer;    // 所有权转移给 f（f.dealloc 会 release）
        f.pts = pts;

        NSMutableArray<WLMixFrame *> *q = self.asyncFrames[streamID];
        if (!q) { q = [NSMutableArray array]; self.asyncFrames[streamID] = q; }

        // 缓冲上限：堆到 30 帧说明 tick 长期跟不上 → 整盘倒掉 + 标记冷启动重锚（OBS MAX_ASYNC_FRAMES）
        if (q.count >= 30) {
            [q removeAllObjects];
            [self.lastFrameTs removeObjectForKey:streamID];
        }
        [q addObject:f];   // 入队尾（FIFO）

        if (![self.streamOrder containsObject:streamID]) {
            [self.streamOrder addObject:streamID];
        }
        // 只投帧进缓冲，不在此触发合成；选哪帧 / 何时合成由 tick + 虚拟时钟决定。
    });
}

- (void)setLayoutFrame:(CGRect)frame forStreamID:(NSString *)streamID {
    if (streamID.length == 0) return;
    dispatch_async(self.serialQueue, ^{
        self.layouts[streamID] = [NSValue valueWithRect:frame];
        // 只更新缓存，下一个 tick 自然采用新 layout（拖动时最多延迟 1 tick）
    });
}

- (void)removeStreamID:(NSString *)streamID {
    if (streamID.length == 0) return;
    dispatch_async(self.serialQueue, ^{
        // WLMixFrame 由 ARC 释放（其 dealloc 释放 pixelBuffer）
        [self.asyncFrames removeObjectForKey:streamID];
        [self.curFrames removeObjectForKey:streamID];
        [self.lastFrameTs removeObjectForKey:streamID];
        [self.layouts removeObjectForKey:streamID];
        [self.streamOrder removeObject:streamID];
    });
}

- (void)setStreamOrder:(NSArray<NSString *> *)streamOrder {
    NSArray *copy = [streamOrder copy];
    dispatch_async(self.serialQueue, ^{
        [self.streamOrder removeAllObjects];
        if (copy.count) [self.streamOrder addObjectsFromArray:copy];
        // 只更新缓存，下一个 tick 自然采用新 z-order
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
        // 只重建 pool，下一个 tick 自然按新尺寸合成
    });
}

- (void)setRenderFrameRate:(int)fps {
    Float64 interval = (fps > 0) ? (1.0 / (Float64)fps) : (1.0 / 60.0);
    dispatch_async(self.serialQueue, ^{
        self.tickInterval = interval;
        if (self.tickTimer) [self rescheduleTick];   // 正在跑则即时改周期
    });
}

#pragma mark - Tick（固定节拍主动合成）

- (BOOL)isRenderingEnabled { return _renderingEnabled; }

// renderingEnabled 自定义 setter：开 → 启动 tick；关 → 停止 tick。
// 立即写 ivar 供 getter 读；timer 启停统一到 serialQueue（timer 也挂在该队列）。
- (void)setRenderingEnabled:(BOOL)renderingEnabled {
    _renderingEnabled = renderingEnabled;
    dispatch_async(self.serialQueue, ^{
        if (self->_renderingEnabled) [self startTick];
        else                         [self stopTick];
    });
}

// 以下三个均在 serialQueue 执行
- (void)startTick {
    if (self.tickTimer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.serialQueue);
    self.tickTimer = t;
    self.ptsAccum = 0;
    self.lastSysTs = 0;                    // 重置墙钟基准：第一拍 sysOffset=0，不被暂停时长暴进虚拟时钟
    [self.asyncFrames removeAllObjects];   // 丢弃（重新）开启前堆积的陈帧；curFrames 保留上次画面作过渡
    [self.lastFrameTs removeAllObjects];   // 各源下次投帧冷启动重锚
    __weak typeof(self) wself = self;
    dispatch_source_set_event_handler(t, ^{
        __strong typeof(wself) self = wself;
        if (!self) return;
        Float64 pts = self.ptsAccum;            // 理论 CFR pts（累加，不受 timer jitter 影响；改帧率仍单调连续）
        self.ptsAccum += self.tickInterval;
        [self renderComposite:pts];
    });
    [self rescheduleTick];          // 设周期（首拍 DISPATCH_TIME_NOW 立即出）
    dispatch_resume(t);
}

- (void)rescheduleTick {
    if (!self.tickTimer) return;
    uint64_t intervalNs = (uint64_t)(self.tickInterval * 1.0e9);
    dispatch_source_set_timer(self.tickTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              intervalNs,
                              intervalNs / 10);   // leeway 10%：允许内核合并省电；pts 用理论值，jitter 不进时间戳
}

- (void)stopTick {
    if (!self.tickTimer) return;
    dispatch_source_cancel(self.tickTimer);
    self.tickTimer = nil;
}

#pragma mark - 选帧（虚拟时钟：吸收源 fps 差异 / 多源对齐）

// 每 tick 一次（serialQueue）：用实测墙钟推进各源虚拟时钟，从各源 async 队列选出当前显示帧。
// sys_offset 用实测流逝（掉帧时多推进 → 自动追帧）；而输出 pts 仍由 tick 理论累加给（CFR）。
- (void)selectFramesForTick {
    uint64_t now = wl_mono_now_ns();
    Float64 sysOffset = (self.lastSysTs != 0) ? (Float64)(now - self.lastSysTs) / 1.0e9 : 0.0;
    self.lastSysTs = now;

    for (NSString *sid in self.streamOrder) {
        [self selectFrameForStream:sid sysOffset:sysOffset];
    }
}

// 单源选帧（参照 OBS ready_async_frame 简化）：推进虚拟时钟、丢过期帧、定 curFrames[sid]。
// 队空 → curFrames 保持（慢源重复）；冷启动 → 首帧立即显示并锚定；>2s 跳变 → 重锚；2ms 平滑。
- (void)selectFrameForStream:(NSString *)sid sysOffset:(Float64)sysOffset {
    NSMutableArray<WLMixFrame *> *q = self.asyncFrames[sid];
    if (q.count == 0) return;   // 无新帧 → 沿用 curFrames[sid]（慢源重复）

    NSNumber *vtBox = self.lastFrameTs[sid];
    if (vtBox == nil) {
        // 冷启动：第一帧立即作为当前帧，用其 pts 锚定虚拟时钟
        WLMixFrame *first = q.firstObject;
        self.curFrames[sid] = first;
        [q removeObjectAtIndex:0];
        self.lastFrameTs[sid] = @(first.pts);
        return;
    }

    Float64 vt = vtBox.doubleValue + sysOffset;   // 虚拟时钟以实测墙钟速度在源 pts 轴前进

    // 跳变重锚：队头 pts 与虚拟时钟差 > 2s（多半 seek / 不连续）→ 直接对齐到该帧
    if (fabs(q.firstObject.pts - vt) > 2.0) {
        vt = q.firstObject.pts;
    }

    // vt 已越过队头 → 该帧到点/过期，取为当前帧；继续丢更早的，直到队头落在未来
    BOOL selected = NO;
    while (q.count > 0) {
        WLMixFrame *head = q.firstObject;
        if (vt < head.pts) break;                        // 队头在未来 → 停
        if (selected && (vt - head.pts) < 0.002) break;  // 已取过 且 仅超前 <2ms → 平滑停（不为精确多丢）
        self.curFrames[sid] = head;
        [q removeObjectAtIndex:0];
        selected = YES;
    }
    self.lastFrameTs[sid] = @(vt);
}

#pragma mark - Render

- (void)renderComposite:(Float64)pts {
    // 由合成 tick 在 serialQueue 调用。renderingEnabled 与节拍都由 tick 把关——
    // tick 仅在 renderingEnabled=YES 时存在，故此处不再查 renderingEnabled、不再做最小间隔节流。

    // 推进各源虚拟时钟、选出每源当前显示帧（吸收源 fps 差异 / 多源对齐）
    [self selectFramesForTick];

    // 无任何内容（背景与源都没有）→ 不输出（不录纯空画布）
    if (!self.hasBgColor && !self.bgTexture && self.streamOrder.count == 0) return;

    // Metal 不可用则无法合成（构造时已尝试，pipeline/cache 缺失即放弃）
    if (!self.pipeline || !self.textureCache) return;

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
                CVPixelBufferRef pb = self.curFrames[sid].pixelBuffer;   // 虚拟时钟选出的当前帧
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
