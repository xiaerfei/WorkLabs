//
//  WLVideoFilter.m
//  WorkLabs
//

#import "WLVideoFilter.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>

@interface WLVideoFilter ()
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) CGSize poolResolution;
@end

@implementation WLVideoFilter

- (instancetype)initWithOutputResolution:(CGSize)outputResolution {
    self = [super init];
    if (self) {
        _outputResolution = outputResolution;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        _ciContext = device ? [CIContext contextWithMTLDevice:device] : [CIContext context];
    }
    return self;
}

- (void)dealloc {
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
    }
}

#pragma mark - WLVideoFilterProtocol

- (WLNodeType)filterType {
    return WLNodeTypeVideo;
}

- (CVPixelBufferRef)processVideoFrame:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    if (!pixelBuffer) return NULL;
    if (self.outputResolution.width <= 0 || self.outputResolution.height <= 0) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!image) return NULL;

    CGRect extent = image.extent;

    // 1) 裁剪
    if (!CGRectIsEmpty(self.cropRect)) {
        CGRect crop = CGRectIntersection(extent, self.cropRect);
        if (CGRectIsEmpty(crop)) return NULL;
        image = [image imageByCroppingToRect:crop];
        image = [image imageByApplyingTransform:
                 CGAffineTransformMakeTranslation(-crop.origin.x, -crop.origin.y)];
        extent = image.extent;
    }

    // 2) 水平镜像
    if (self.enableMirror) {
        CGAffineTransform t = CGAffineTransformMakeScale(-1.0, 1.0);
        t = CGAffineTransformTranslate(t, -extent.size.width, 0);
        image = [image imageByApplyingTransform:t];
        extent = image.extent;
    }

    // 3) 缩放到 outputResolution
    if (extent.size.width <= 0 || extent.size.height <= 0) return NULL;
    CGFloat sx = self.outputResolution.width / extent.size.width;
    CGFloat sy = self.outputResolution.height / extent.size.height;
    if (sx != 1.0 || sy != 1.0) {
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    }

    // 4) 渲染到输出 pixel buffer
    [self ensurePoolWithSize:self.outputResolution];
    if (!self.pixelBufferPool) return NULL;

    CVPixelBufferRef output = NULL;
    CVReturn ret = CVPixelBufferPoolCreatePixelBuffer(NULL, self.pixelBufferPool, &output);
    if (ret != kCVReturnSuccess || !output) return NULL;

    [self.ciContext render:image toCVPixelBuffer:output];
    return output;
}

#pragma mark - Pool

- (void)ensurePoolWithSize:(CGSize)size {
    if (self.pixelBufferPool && CGSizeEqualToSize(self.poolResolution, size)) {
        return;
    }
    if (self.pixelBufferPool) {
        CVPixelBufferPoolRelease(self.pixelBufferPool);
        self.pixelBufferPool = NULL;
    }
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:  @((int)size.width),
        (id)kCVPixelBufferHeightKey: @((int)size.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool);
    self.pixelBufferPool = pool;
    self.poolResolution = size;
}

@end
