//
//  WLVideoMix.m
//  WorkLabs
//

#import "WLVideoMix.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>

// 单调墙钟（秒），用于合成输出节流
static Float64 WLVideoMixNowSeconds(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (Float64)mach_absolute_time() * tb.numer / tb.denom / 1.0e9;
}

@interface WLVideoMix ()
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) dispatch_queue_t serialQueue;

// streamID -> CVPixelBufferRef（已 retain）
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *latestFrames;
// streamID -> CGRect（NSValue 包装）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *layouts;
// 维持合成顺序（先加入的在底层）
@property (nonatomic, strong) NSMutableArray<NSString *> *streamOrder;

// 画布背景（仅在 serialQueue 访问）
@property (nonatomic, strong, nullable) CIColor *bgColor;
@property (nonatomic, strong, nullable) CIImage *bgImage;
@property (nonatomic, assign) Float64 lastPts;
@property (nonatomic, assign) Float64 lastRenderTime;     // 上次实际合成输出的墙钟（节流用）
@property (nonatomic, assign) Float64 minRenderInterval;  // 合成最小间隔 = 1 / 帧率上限

@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) CGColorSpaceRef colorSpace; // 输出色彩空间(sRGB)，避免输出线性 RGB 致画面偏暗

@end

@implementation WLVideoMix

- (instancetype)initWithCanvasSize:(CGSize)canvasSize {
    self = [super init];
    if (self) {
        _canvasSize = (canvasSize.width > 0 && canvasSize.height > 0)
            ? canvasSize : CGSizeMake(1920, 1080);

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        _ciContext = device ? [CIContext contextWithMTLDevice:device] : [CIContext context];
        _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

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
    if (_colorSpace) {
        CGColorSpaceRelease(_colorSpace);
    }
}

#pragma mark - Background

- (void)setBackgroundColor:(nullable NSColor *)color {
    CIColor *ci = nil;
    if (color) {
        NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (rgb) ci = [[CIColor alloc] initWithColor:rgb];
    }
    dispatch_async(self.serialQueue, ^{
        self.bgColor = ci;
        [self renderWithPts:self.lastPts];
    });
}

- (void)setBackgroundImage:(nullable NSImage *)image {
    CIImage *ci = nil;
    if (image) {
        CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
        if (cg) ci = [CIImage imageWithCGImage:cg];
    }
    dispatch_async(self.serialQueue, ^{
        self.bgImage = ci;
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
    CGRect canvasRect = CGRectMake(0, 0, self.canvasSize.width, self.canvasSize.height);

    // 无任何内容（背景与源都没有）→ 不输出
    if (!self.bgColor && !self.bgImage && self.streamOrder.count == 0) return;

    // 输出节流：合成由输入事件驱动（源帧 + 拖动时高频 setLayoutFrame 等），频率可达数百 Hz、
    //   远超编码吞吐。按帧率上限节流；被跳过的输入已更新 latestFrames/layouts 缓存，
    //   后续帧会用最新状态合成，不丢最终画面。
    Float64 now = WLVideoMixNowSeconds();
    if (self.lastRenderTime > 0 && (now - self.lastRenderTime) < self.minRenderInterval) return;
    self.lastRenderTime = now;

    // 1) 始终以不透明背景起底、铺满画布：确保 CIContext 渲染覆盖整个 pool 复用 buffer，
    //    否则源未覆盖的区域会残留上一帧内容（拖动源时表现为残影）。默认黑底，或用户设的背景色。
    CIImage *composed = [[CIImage imageWithColor:(self.bgColor ?: [CIColor blackColor])]
                         imageByCroppingToRect:canvasRect];

    // 2) 背景图：缩放铺满，叠在背景色之上
    if (self.bgImage) {
        CGRect ext = self.bgImage.extent;
        if (ext.size.width > 0 && ext.size.height > 0) {
            CGFloat sx = self.canvasSize.width / ext.size.width;
            CGFloat sy = self.canvasSize.height / ext.size.height;
            CIImage *scaled = [self.bgImage imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
            // 把缩放后图像原点对齐到 (0,0)
            scaled = [scaled imageByApplyingTransform:
                      CGAffineTransformMakeTranslation(-scaled.extent.origin.x, -scaled.extent.origin.y)];
            composed = composed ? [scaled imageByCompositingOverImage:composed] : scaled;
        }
    }

    // 3) 各路视频流：从底到顶依次叠加
    for (NSString *sid in self.streamOrder) {
        CVPixelBufferRef pb = (__bridge CVPixelBufferRef)self.latestFrames[sid];
        if (!pb) continue;

        CIImage *image = [CIImage imageWithCVPixelBuffer:pb];
        if (!image) continue;

        CGRect layout = [self layoutForStreamID:sid imageExtent:image.extent];
        if (layout.size.width <= 0 || layout.size.height <= 0) continue;

        CGFloat sx = layout.size.width / image.extent.size.width;
        CGFloat sy = layout.size.height / image.extent.size.height;
        CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
        CIImage *placed = [scaled imageByApplyingTransform:
                           CGAffineTransformMakeTranslation(layout.origin.x, layout.origin.y)];

        composed = composed ? [placed imageByCompositingOverImage:composed] : placed;
    }

    composed = [composed imageByCroppingToRect:canvasRect];

    CVPixelBufferRef out = NULL;
    if (!self.pixelBufferPool) [self ensurePool];
    if (!self.pixelBufferPool) return;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, self.pixelBufferPool, &out) != kCVReturnSuccess || !out) {
        return;
    }

    [self.ciContext render:composed
           toCVPixelBuffer:out
                    bounds:canvasRect
                colorSpace:self.colorSpace];

    if (self.output) {
        self.output(out, pts); // 所有权转移给 block
    } else {
        CVPixelBufferRelease(out);
    }
}

- (CGRect)layoutForStreamID:(NSString *)sid imageExtent:(CGRect)extent {
    NSValue *v = self.layouts[sid];
    if (v) return v.rectValue;
    // 缺省：铺满画布
    return CGRectMake(0, 0, self.canvasSize.width, self.canvasSize.height);
}

#pragma mark - Pool

- (void)ensurePool {
    if (_pixelBufferPool) return;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:  @((int)self.canvasSize.width),
        (id)kCVPixelBufferHeightKey: @((int)self.canvasSize.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool);
    _pixelBufferPool = pool;
}

@end
