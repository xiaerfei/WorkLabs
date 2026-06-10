//
//  WLMetalContext.m
//  WorkLabs
//

#import "WLMetalContext.h"

#pragma mark - WLMetalTextureBinding

@interface WLMetalTextureBinding ()
@property (nonatomic, strong, nullable) id<MTLTexture> texture0;
@property (nonatomic, strong, nullable) id<MTLTexture> texture1;
@property (nonatomic, assign) BOOL isYUV;
@property (nonatomic, assign) BOOL isFullRange;
@property (nonatomic, assign) BOOL is10Bit;
@end

@implementation WLMetalTextureBinding {
    CVMetalTextureRef _refs[2];
    int _refCount;
}

- (void)addRef:(CVMetalTextureRef)ref {
    if (ref && _refCount < 2) _refs[_refCount++] = ref;
}

- (void)dealloc {
    for (int i = 0; i < _refCount; i++) {
        if (_refs[i]) CFRelease(_refs[i]);
    }
}

@end

#pragma mark - WLMetalContext

@interface WLMetalContext ()
@property (nonatomic, strong, readwrite) id<MTLDevice> device;
@property (nonatomic, strong, readwrite) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong, readwrite, nullable) id<MTLLibrary> library;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *pipelineCache;
@end

@implementation WLMetalContext

+ (instancetype)shared {
    static WLMetalContext *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WLMetalContext *c = [[WLMetalContext alloc] initPrivate];
        if (c.device && c.commandQueue) inst = c; // 无 Metal 支持则返回 nil
    });
    return inst;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _device = MTLCreateSystemDefaultDevice();
        if (!_device) {
            NSLog(@"[WLMetalContext] Metal is not supported on this device");
            return self;
        }
        _commandQueue = [_device newCommandQueue];
        _library = [_device newDefaultLibrary];
        if (!_library) {
            NSLog(@"[WLMetalContext] newDefaultLibrary failed (no .metal compiled into the bundle?)");
        }
        _pipelineCache = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Texture cache

- (CVMetalTextureCacheRef)newTextureCache {
    if (!self.device) return NULL;
    NSDictionary *attrs = @{
        (id)kCVMetalTextureUsage: @(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead)
    };
    CVMetalTextureCacheRef cache = NULL;
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)attrs,
                                  self.device, NULL, &cache) != kCVReturnSuccess) {
        return NULL;
    }
    return cache; // CF_RETURNS_RETAINED
}

#pragma mark - Pipeline cache

- (id<MTLRenderPipelineState>)pipelineWithFragment:(NSString *)fragmentName blending:(BOOL)blending {
    if (!self.device || !self.library || fragmentName.length == 0) return nil;
    NSString *key = [NSString stringWithFormat:@"%@|%d", fragmentName, blending ? 1 : 0];
    @synchronized (self) {
        id<MTLRenderPipelineState> cached = self.pipelineCache[key];
        if (cached) return cached;

        id<MTLFunction> vfn = [self.library newFunctionWithName:@"vertexShader"];
        id<MTLFunction> ffn = [self.library newFunctionWithName:fragmentName];
        if (!vfn || !ffn) {
            NSLog(@"[WLMetalContext] missing shader function: vertexShader=%@ %@=%@",
                  vfn ? @"ok" : @"nil", fragmentName, ffn ? @"ok" : @"nil");
            return nil;
        }

        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vfn;
        desc.fragmentFunction = ffn;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        if (blending) {
            desc.colorAttachments[0].blendingEnabled = YES;
            desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
            desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        }

        NSError *err = nil;
        id<MTLRenderPipelineState> ps = [self.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!ps) {
            NSLog(@"[WLMetalContext] pipeline '%@' error: %@", fragmentName, err);
            return nil;
        }
        self.pipelineCache[key] = ps;
        return ps;
    }
}

#pragma mark - Bind input (sampling)

- (WLMetalTextureBinding *)bindSamplingPixelBuffer:(CVPixelBufferRef)pb cache:(CVMetalTextureCacheRef)cache {
    if (!pb || !cache) return nil;
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    WLMetalTextureBinding *b = [[WLMetalTextureBinding alloc] init];

    if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        b.isYUV = YES;
        b.is10Bit = NO;
        b.isFullRange = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

        size_t w0 = CVPixelBufferGetWidthOfPlane(pb, 0);
        size_t h0 = CVPixelBufferGetHeightOfPlane(pb, 0);
        size_t w1 = CVPixelBufferGetWidthOfPlane(pb, 1);
        size_t h1 = CVPixelBufferGetHeightOfPlane(pb, 1);

        CVMetalTextureRef yRef = NULL, cRef = NULL;
        if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, NULL,
                MTLPixelFormatR8Unorm, w0, h0, 0, &yRef) != kCVReturnSuccess || !yRef) {
            return nil;
        }
        if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, NULL,
                MTLPixelFormatRG8Unorm, w1, h1, 1, &cRef) != kCVReturnSuccess || !cRef) {
            CFRelease(yRef);
            return nil;
        }
        [b addRef:yRef];
        [b addRef:cRef];
        b.texture0 = CVMetalTextureGetTexture(yRef);
        b.texture1 = CVMetalTextureGetTexture(cRef);
    } else if (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
               fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
        // 10-bit YUV（HEVC Main 10 硬解输出）：Y 平面 R16Unorm，CbCr 平面 RG16Unorm
        b.isYUV = YES;
        b.is10Bit = YES;
        b.isFullRange = (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);

        size_t w0 = CVPixelBufferGetWidthOfPlane(pb, 0);
        size_t h0 = CVPixelBufferGetHeightOfPlane(pb, 0);
        size_t w1 = CVPixelBufferGetWidthOfPlane(pb, 1);
        size_t h1 = CVPixelBufferGetHeightOfPlane(pb, 1);

        CVMetalTextureRef yRef = NULL, cRef = NULL;
        if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, NULL,
                MTLPixelFormatR16Unorm, w0, h0, 0, &yRef) != kCVReturnSuccess || !yRef) {
            return nil;
        }
        if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, NULL,
                MTLPixelFormatRG16Unorm, w1, h1, 1, &cRef) != kCVReturnSuccess || !cRef) {
            CFRelease(yRef);
            return nil;
        }
        [b addRef:yRef];
        [b addRef:cRef];
        b.texture0 = CVMetalTextureGetTexture(yRef);
        b.texture1 = CVMetalTextureGetTexture(cRef);
    } else {
        b.isYUV = NO;
        b.isFullRange = YES;
        MTLPixelFormat mf = (fmt == kCVPixelFormatType_32RGBA)
            ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatBGRA8Unorm;
        size_t w = CVPixelBufferGetWidth(pb);
        size_t h = CVPixelBufferGetHeight(pb);
        CVMetalTextureRef ref = NULL;
        if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, NULL,
                mf, w, h, 0, &ref) != kCVReturnSuccess || !ref) {
            return nil;
        }
        [b addRef:ref];
        b.texture0 = CVMetalTextureGetTexture(ref);
    }

    return b.texture0 ? b : nil;
}

#pragma mark - Bind output (render target)

- (WLMetalTextureBinding *)bindRenderTargetPixelBuffer:(CVPixelBufferRef)pb cache:(CVMetalTextureCacheRef)cache {
    if (!pb || !cache) return nil;
    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    CVMetalTextureRef ref = NULL;
    if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, NULL,
            MTLPixelFormatBGRA8Unorm, w, h, 0, &ref) != kCVReturnSuccess || !ref) {
        return nil;
    }
    WLMetalTextureBinding *b = [[WLMetalTextureBinding alloc] init];
    [b addRef:ref];
    b.texture0 = CVMetalTextureGetTexture(ref);
    return b.texture0 ? b : nil;
}

@end
