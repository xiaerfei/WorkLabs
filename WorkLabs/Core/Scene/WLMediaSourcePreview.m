//
//  WLMediaSourcePreview.m
//  WorkLabs
//

#import "WLMediaSourcePreview.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

static const CGFloat kBorderWidth = 3.0;

@interface WLMediaSourcePreview ()

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLRenderPipelineState> borderPipelineState;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;

@property (nonatomic, strong) id<MTLBuffer> vertexBuffer;
@property (nonatomic, strong) id<MTLBuffer> borderVertexBuffer;

@end

@implementation WLMediaSourcePreview

#pragma mark - Init

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupMetal];
    }
    return self;
}

- (void)dealloc {
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

#pragma mark - Metal Setup

- (void)setupMetal {
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        NSLog(@"[WLMediaSourcePreview] Metal is not supported");
        return;
    }

    self.wantsLayer = YES;
    CAMetalLayer *metalLayer = [CAMetalLayer layer];
    metalLayer.device = self.device;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metalLayer.framebufferOnly = YES;
    metalLayer.opaque = NO;
    metalLayer.drawableSize = self.bounds.size;
    self.layer = metalLayer;

    self.commandQueue = [self.device newCommandQueue];

    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, self.device, nil, &_textureCache);
    if (!_textureCache) {
        NSLog(@"[WLMediaSourcePreview] Failed to create texture cache");
        return;
    }

    [self setupPipeline];
    [self setupVertexBuffers];
}

- (void)layout {
    [super layout];
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    CGFloat scale = self.window.backingScaleFactor ?: 1.0;
    metalLayer.drawableSize = CGSizeMake(self.bounds.size.width * scale,
                                          self.bounds.size.height * scale);
}

- (void)setupPipeline {
    id<MTLLibrary> library = [self.device newDefaultLibrary];

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [library newFunctionWithName:@"vertexShader"];
    desc.fragmentFunction = [library newFunctionWithName:@"fragmentShader"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    NSError *error = nil;
    self.pipelineState = [self.device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (error) {
        NSLog(@"[WLMediaSourcePreview] pipeline error: %@", error);
    }

    MTLRenderPipelineDescriptor *borderDesc = [[MTLRenderPipelineDescriptor alloc] init];
    borderDesc.vertexFunction = [library newFunctionWithName:@"borderVertexShader"];
    borderDesc.fragmentFunction = [library newFunctionWithName:@"borderFragmentShader"];
    borderDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    borderDesc.colorAttachments[0].blendingEnabled = YES;
    borderDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    borderDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    self.borderPipelineState = [self.device newRenderPipelineStateWithDescriptor:borderDesc error:&error];
    if (error) {
        NSLog(@"[WLMediaSourcePreview] border pipeline error: %@", error);
    }
}

- (void)setupVertexBuffers {
    static const float quadVertices[] = {
        -1, -1, 0, 1,
         1, -1, 1, 1,
        -1,  1, 0, 0,
         1,  1, 1, 0,
    };
    self.vertexBuffer = [self.device newBufferWithBytes:quadVertices
                                                 length:sizeof(quadVertices)
                                                options:MTLResourceStorageModeShared];

    static const float borderVertices[] = {
        -1, -1,
         1, -1,
         1,  1,
        -1,  1,
    };
    self.borderVertexBuffer = [self.device newBufferWithBytes:borderVertices
                                                       length:sizeof(borderVertices)
                                                      options:MTLResourceStorageModeShared];
}

#pragma mark - Public

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer || !self.device) return;

    CVPixelBufferRetain(pixelBuffer);

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);

    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

    MTLPixelFormat mtlFormat;
    BOOL isFullRange = NO;

    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        mtlFormat = MTLPixelFormatRG8Unorm;
        isFullRange = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    } else if (pixelFormat == kCVPixelFormatType_32BGRA) {
        mtlFormat = MTLPixelFormatBGRA8Unorm;
        isFullRange = YES;
    } else if (pixelFormat == kCVPixelFormatType_32RGBA) {
        mtlFormat = MTLPixelFormatRGBA8Unorm;
        isFullRange = YES;
    } else {
        mtlFormat = MTLPixelFormatBGRA8Unorm;
        isFullRange = YES;
    }

    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    id<CAMetalDrawable> drawable = (id<CAMetalDrawable>)[metalLayer nextDrawable];
    if (!drawable) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = drawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];

    [encoder setRenderPipelineState:self.pipelineState];
    [encoder setVertexBuffer:self.vertexBuffer offset:0 atIndex:0];

    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {

        CVMetalTextureRef yTextureRef = NULL;
        CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, self.textureCache, pixelBuffer, nil,
            MTLPixelFormatR8Unorm, width, 0, NO, &yTextureRef);
        if (result != kCVReturnSuccess) {
            [encoder endEncoding];
            CVPixelBufferRelease(pixelBuffer);
            return;
        }

        CVMetalTextureRef cbCrTextureRef = NULL;
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, self.textureCache, pixelBuffer, nil,
            mtlFormat, width / 2, 1, NO, &cbCrTextureRef);
        if (result != kCVReturnSuccess) {
            CFRelease(yTextureRef);
            [encoder endEncoding];
            CVPixelBufferRelease(pixelBuffer);
            return;
        }

        id<MTLTexture> yTexture = CVMetalTextureGetTexture(yTextureRef);
        id<MTLTexture> cbCrTexture = CVMetalTextureGetTexture(cbCrTextureRef);

        [encoder setFragmentTexture:yTexture atIndex:0];
        [encoder setFragmentTexture:cbCrTexture atIndex:1];
        [encoder setFragmentBytes:&(BOOL){YES} length:sizeof(BOOL) atIndex:0];
        [encoder setFragmentBytes:&isFullRange length:sizeof(BOOL) atIndex:1];

        CFRelease(yTextureRef);
        CFRelease(cbCrTextureRef);

    } else {
        CVMetalTextureRef textureRef = NULL;
        CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, self.textureCache, pixelBuffer, nil,
            mtlFormat, width, 0, NO, &textureRef);
        if (result != kCVReturnSuccess) {
            [encoder endEncoding];
            CVPixelBufferRelease(pixelBuffer);
            return;
        }

        id<MTLTexture> texture = CVMetalTextureGetTexture(textureRef);
        [encoder setFragmentTexture:texture atIndex:0];
        [encoder setFragmentBytes:&(BOOL){NO} length:sizeof(BOOL) atIndex:0];
        [encoder setFragmentBytes:&(BOOL){NO} length:sizeof(BOOL) atIndex:1];

        CFRelease(textureRef);
    }

    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];

    [self drawBorderWithEncoder:encoder];

    [encoder endEncoding];

    __block CVPixelBufferRef bufferToRelease = pixelBuffer;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        CVPixelBufferRelease(bufferToRelease);
    }];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

#pragma mark - Border

- (void)drawBorderWithEncoder:(id<MTLRenderCommandEncoder>)encoder {
    if (!self.selected) return;

    [encoder setRenderPipelineState:self.borderPipelineState];
    [encoder setVertexBuffer:self.borderVertexBuffer offset:0 atIndex:0];

    static const float borderWidth = kBorderWidth;
    [encoder setVertexBytes:&borderWidth length:sizeof(float) atIndex:1];

    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    float viewWidth = MAX(metalLayer.drawableSize.width, 1.0);
    float viewHeight = MAX(metalLayer.drawableSize.height, 1.0);
    float viewSize[2] = { (float)viewWidth, (float)viewHeight };
    [encoder setVertexBytes:viewSize length:sizeof(viewSize) atIndex:2];

    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

@end
