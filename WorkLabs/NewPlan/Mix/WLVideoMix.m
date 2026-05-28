//
//  WLVideoMix.m
//  WorkLabs
//

#import "WLVideoMix.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>

@interface WLVideoMix ()
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) dispatch_queue_t serialQueue;

// streamID -> CVPixelBufferRef（已 retain）
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *latestFrames;
// streamID -> CGRect（NSValue 包装）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *layouts;
// 维持合成顺序（先加入的在底层）
@property (nonatomic, strong) NSMutableArray<NSString *> *streamOrder;

@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;

@end

@implementation WLVideoMix

- (instancetype)initWithCanvasSize:(CGSize)canvasSize {
    self = [super init];
    if (self) {
        _canvasSize = (canvasSize.width > 0 && canvasSize.height > 0)
            ? canvasSize : CGSizeMake(1920, 1080);

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        _ciContext = device ? [CIContext contextWithMTLDevice:device] : [CIContext context];

        _serialQueue = dispatch_queue_create("com.worklabs.videomix", DISPATCH_QUEUE_SERIAL);
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

#pragma mark - Render

- (void)renderWithPts:(Float64)pts {
    if (self.streamOrder.count == 0) return;

    // 从底到顶依次叠加
    CIImage *composed = nil;
    for (NSString *sid in self.streamOrder) {
        CVPixelBufferRef pb = (__bridge CVPixelBufferRef)self.latestFrames[sid];
        if (!pb) continue;

        CIImage *image = [CIImage imageWithCVPixelBuffer:pb];
        if (!image) continue;

        CGRect layout = [self layoutForStreamID:sid imageExtent:image.extent];
        if (layout.size.width <= 0 || layout.size.height <= 0) continue;

        // 缩放到 layout 大小
        CGFloat sx = layout.size.width / image.extent.size.width;
        CGFloat sy = layout.size.height / image.extent.size.height;
        CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];

        // 平移到 layout 位置（画布像素坐标，左下角原点）
        CIImage *placed = [scaled imageByApplyingTransform:
                           CGAffineTransformMakeTranslation(layout.origin.x, layout.origin.y)];

        if (composed == nil) {
            composed = placed;
        } else {
            composed = [placed imageByCompositingOverImage:composed];
        }
    }

    if (composed == nil) return;

    // 裁剪到画布范围
    CGRect canvasRect = CGRectMake(0, 0, self.canvasSize.width, self.canvasSize.height);
    composed = [composed imageByCroppingToRect:canvasRect];

    // 渲染到 pixel buffer
    CVPixelBufferRef out = NULL;
    if (!self.pixelBufferPool) [self ensurePool];
    if (!self.pixelBufferPool) return;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, self.pixelBufferPool, &out) != kCVReturnSuccess || !out) {
        return;
    }

    // 用画布原点对齐渲染
    [self.ciContext render:composed
           toCVPixelBuffer:out
                    bounds:canvasRect
                colorSpace:nil];

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
