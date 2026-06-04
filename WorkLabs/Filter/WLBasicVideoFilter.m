//
//  WLBasicVideoFilter.m
//  WorkLabs
//

#import "WLBasicVideoFilter.h"
#import <CoreImage/CoreImage.h>
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
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, assign) CGColorSpaceRef colorSpace; // 输出 sRGB，避免线性 RGB 偏暗
@property (nonatomic, assign) CVPixelBufferPoolRef pool;  // 按输出尺寸缓存，尺寸变则重建
@property (nonatomic, assign) int poolW;
@property (nonatomic, assign) int poolH;
@end

@implementation WLBasicVideoFilter

- (instancetype)init {
    self = [super init];
    if (self) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        _ciContext = device ? [CIContext contextWithMTLDevice:device] : [CIContext context];
        _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        // 颜色校正的中性默认值
        _contrast = 1.0f;
        _saturation = 1.0f;
    }
    return self;
}

- (void)dealloc {
    if (_pool) CVPixelBufferPoolRelease(_pool);
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
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
    if (self.isIdentity) {
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer; // 透传
    }

    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!image) {
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer;
    }

    // 1) 裁剪（CI 坐标系左下原点，cropBottom 对应底边）
    float cl = MAX(0.0f, MIN(self.cropLeft,   0.45f));
    float cr = MAX(0.0f, MIN(self.cropRight,  0.45f));
    float ct = MAX(0.0f, MIN(self.cropTop,    0.45f));
    float cb = MAX(0.0f, MIN(self.cropBottom, 0.45f));
    if (cl > 0 || cr > 0 || ct > 0 || cb > 0) {
        CGRect e = image.extent;
        CGRect crop = CGRectMake(e.origin.x + e.size.width  * cl,
                                 e.origin.y + e.size.height * cb,
                                 e.size.width  * (1.0f - cl - cr),
                                 e.size.height * (1.0f - ct - cb));
        image = [image imageByCroppingToRect:crop];
        image = [image imageByApplyingTransform:
                 CGAffineTransformMakeTranslation(-image.extent.origin.x, -image.extent.origin.y)];
    }

    // 2) 颜色校正
    if (self.brightness != 0.0f || self.contrast != 1.0f || self.saturation != 1.0f) {
        CIFilter *cc = [CIFilter filterWithName:@"CIColorControls"];
        [cc setValue:image forKey:kCIInputImageKey];
        [cc setValue:@(self.brightness) forKey:kCIInputBrightnessKey];
        [cc setValue:@(self.contrast)   forKey:kCIInputContrastKey];
        [cc setValue:@(self.saturation) forKey:kCIInputSaturationKey];
        CIImage *out = cc.outputImage;
        if (out) image = out;
    }
    if (self.hue != 0.0f) {
        CIFilter *hf = [CIFilter filterWithName:@"CIHueAdjust"];
        [hf setValue:image forKey:kCIInputImageKey];
        [hf setValue:@(self.hue * M_PI / 180.0) forKey:kCIInputAngleKey];
        CIImage *out = hf.outputImage;
        if (out) image = out;
    }

    // 3) 镜像（翻转后 extent 原点变负，平移回 (0,0)）
    if (self.hMirror || self.vMirror) {
        CGAffineTransform t = CGAffineTransformMakeScale(self.hMirror ? -1.0 : 1.0,
                                                         self.vMirror ? -1.0 : 1.0);
        image = [image imageByApplyingTransform:t];
        image = [image imageByApplyingTransform:
                 CGAffineTransformMakeTranslation(-image.extent.origin.x, -image.extent.origin.y)];
    }

    CGRect outExtent = image.extent;
    int w = (int)lround(outExtent.size.width);
    int h = (int)lround(outExtent.size.height);
    if (w <= 0 || h <= 0) {
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer;
    }

    CVPixelBufferRef dst = [self acquirePixelBufferWidth:w height:h];
    if (!dst) {
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer;
    }

    [self.ciContext render:image
           toCVPixelBuffer:dst
                    bounds:CGRectMake(0, 0, w, h)
                colorSpace:self.colorSpace];
    return dst; // Create Rule：所有权转移给调用方
}

#pragma mark - Pool

- (nullable CVPixelBufferRef)acquirePixelBufferWidth:(int)w height:(int)h {
    if (_pool == NULL || _poolW != w || _poolH != h) {
        if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey:  @(w),
            (id)kCVPixelBufferHeightKey: @(h),
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
