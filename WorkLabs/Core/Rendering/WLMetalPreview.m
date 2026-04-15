
#import "WLMetalPreview.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

static const CGFloat kBorderWidth = 3.0;
static const CGFloat kEdgeHitSize = 6.0;
static const CGFloat kMinSize = 80.0;

typedef NS_ENUM(NSUInteger, WLEdgeMode) {
    WLEdgeModeNone,
    WLEdgeModeTop,
    WLEdgeModeBottom,
    WLEdgeModeLeft,
    WLEdgeModeRight,
    WLEdgeModeTopLeft,
    WLEdgeModeTopRight,
    WLEdgeModeBottomLeft,
    WLEdgeModeBottomRight,
};

@interface WLMetalPreview () <MTKViewDelegate>

@property (nonatomic, strong) MTKView *metalView;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLRenderPipelineState> borderPipelineState;

@property (nonatomic, assign) WLEdgeMode edgeMode;
@property (nonatomic, assign) NSPoint dragStartPoint;
@property (nonatomic, assign) NSRect dragStartFrame;

@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;

@property (nonatomic, assign) CGSize currentPixelBufferSize;
@property (nonatomic, strong) id<MTLBuffer> vertexBuffer;
@property (nonatomic, strong) id<MTLBuffer> borderVertexBuffer;

@end

@implementation WLMetalPreview

#pragma mark - Init

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupMetal];
        [self setupGestures];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setupMetal];
        [self setupGestures];
    }
    return self;
}

- (void)dealloc {
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

#pragma mark - Setup

- (void)setupMetal {
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        NSLog(@"[WLMetalPreview] Metal is not supported");
        return;
    }

    self.metalView = [[MTKView alloc] initWithFrame:self.bounds device:self.device];
    self.metalView.delegate = self;
    self.metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.metalView.enableSetNeedsDisplay = NO;
    self.metalView.preferredFramesPerSecond = 60;
    self.metalView.paused = YES;
    self.metalView.layer.opaque = NO;

    [self addSubview:self.metalView];

    self.commandQueue = [self.device newCommandQueue];

    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, self.device, nil, &_textureCache);

    if (!_textureCache) {
        NSLog(@"[WLMetalPreview] Failed to create texture cache");
        return;
    }

    if (!_textureCache) {
        NSLog(@"[WLMetalPreview] Failed to create texture cache");
        return;
    }

    [self setupPipeline];

    [self setupVertexBuffers];
}

- (void)setupPipeline {
    id<MTLLibrary> library = [self.device newDefaultLibrary];

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [library newFunctionWithName:@"vertexShader"];
    desc.fragmentFunction = [library newFunctionWithName:@"fragmentShader"];
    desc.colorAttachments[0].pixelFormat = self.metalView.colorPixelFormat;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    NSError *error = nil;
    self.pipelineState = [self.device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (error) {
        NSLog(@"[WLMetalPreview] pipeline error: %@", error);
    }

    MTLRenderPipelineDescriptor *borderDesc = [[MTLRenderPipelineDescriptor alloc] init];
    borderDesc.vertexFunction = [library newFunctionWithName:@"borderVertexShader"];
    borderDesc.fragmentFunction = [library newFunctionWithName:@"borderFragmentShader"];
    borderDesc.colorAttachments[0].pixelFormat = self.metalView.colorPixelFormat;
    borderDesc.colorAttachments[0].blendingEnabled = YES;
    borderDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    borderDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    self.borderPipelineState = [self.device newRenderPipelineStateWithDescriptor:borderDesc error:&error];
    if (error) {
        NSLog(@"[WLMetalPreview] border pipeline error: %@", error);
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

- (void)setupGestures {
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:(NSTrackingMouseEnteredAndExited |
                                                                NSTrackingMouseMoved |
                                                                NSTrackingActiveInActiveApp |
                                                                NSTrackingInVisibleRect)
                                                         owner:self
                                                      userInfo:nil]];

    NSPanGestureRecognizer *pan = [[NSPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];
}

#pragma mark - Public

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer || !self.device) return;

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    self.currentPixelBufferSize = CGSizeMake(width, height);

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

    id<MTLTexture> texture = nil;

    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {

        CVMetalTextureRef yTextureRef = NULL;
        CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, self.textureCache, pixelBuffer, nil,
            MTLPixelFormatR8Unorm, width, 0, NO, &yTextureRef);
        if (result != kCVReturnSuccess) return;

        CVMetalTextureRef cbCrTextureRef = NULL;
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, self.textureCache, pixelBuffer, nil,
            mtlFormat, width / 2, 1, NO, &cbCrTextureRef);
        if (result != kCVReturnSuccess) {
            CFRelease(yTextureRef);
            return;
        }

        id<MTLTexture> yTexture = CVMetalTextureGetTexture(yTextureRef);
        id<MTLTexture> cbCrTexture = CVMetalTextureGetTexture(cbCrTextureRef);

        [self renderYUVWithYTexture:yTexture cbCrTexture:cbCrTexture fullRange:isFullRange];

        CFRelease(yTextureRef);
        CFRelease(cbCrTextureRef);

    } else {
        CVMetalTextureRef textureRef = NULL;
        CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, self.textureCache, pixelBuffer, nil,
            mtlFormat, width, 0, NO, &textureRef);
        if (result != kCVReturnSuccess) return;

        texture = CVMetalTextureGetTexture(textureRef);
        [self renderRGBWithTexture:texture];
        CFRelease(textureRef);
    }
}

#pragma mark - Render

- (void)renderRGBWithTexture:(id<MTLTexture>)texture {
    if (!texture) return;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];

    MTLRenderPassDescriptor *passDesc = self.metalView.currentRenderPassDescriptor;
    if (!passDesc) return;

    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];

    [encoder setRenderPipelineState:self.pipelineState];
    [encoder setVertexBuffer:self.vertexBuffer offset:0 atIndex:0];
    [encoder setFragmentTexture:texture atIndex:0];
    [encoder setFragmentBytes:&(BOOL){NO} length:sizeof(BOOL) atIndex:0];
    [encoder setFragmentBytes:&(BOOL){NO} length:sizeof(BOOL) atIndex:1];

    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];

    [self drawBorderWithEncoder:encoder];

    [encoder endEncoding];

    [commandBuffer presentDrawable:self.metalView.currentDrawable];
    [commandBuffer commit];
}

- (void)renderYUVWithYTexture:(id<MTLTexture>)yTexture
                  cbCrTexture:(id<MTLTexture>)cbCrTexture
                    fullRange:(BOOL)fullRange {
    if (!yTexture || !cbCrTexture) return;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];

    MTLRenderPassDescriptor *passDesc = self.metalView.currentRenderPassDescriptor;
    if (!passDesc) return;

    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];

    [encoder setRenderPipelineState:self.pipelineState];
    [encoder setVertexBuffer:self.vertexBuffer offset:0 atIndex:0];
    [encoder setFragmentTexture:yTexture atIndex:0];
    [encoder setFragmentTexture:cbCrTexture atIndex:1];
    [encoder setFragmentBytes:&(BOOL){YES} length:sizeof(BOOL) atIndex:0];
    [encoder setFragmentBytes:&fullRange length:sizeof(BOOL) atIndex:1];

    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];

    [self drawBorderWithEncoder:encoder];

    [encoder endEncoding];

    [commandBuffer presentDrawable:self.metalView.currentDrawable];
    [commandBuffer commit];
}

- (void)drawBorderWithEncoder:(id<MTLRenderCommandEncoder>)encoder {
    [encoder setRenderPipelineState:self.borderPipelineState];
    [encoder setVertexBuffer:self.borderVertexBuffer offset:0 atIndex:0];

    static const float borderWidth = kBorderWidth;
    [encoder setVertexBytes:&borderWidth length:sizeof(float) atIndex:1];

    float viewWidth = MAX(self.metalView.bounds.size.width, 1.0);
    float viewHeight = MAX(self.metalView.bounds.size.height, 1.0);
    float viewSize[2] = { (float)viewWidth, (float)viewHeight };
    [encoder setVertexBytes:viewSize length:sizeof(viewSize) atIndex:2];

    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)drawInMTKView:(MTKView *)view {
}

#pragma mark - Edge Detection & Cursor

- (WLEdgeMode)edgeModeForPoint:(NSPoint)point {
    CGFloat edgeSize = kEdgeHitSize;
    NSRect bounds = self.bounds;

    BOOL nearLeft = point.x < edgeSize;
    BOOL nearRight = point.x > bounds.size.width - edgeSize;
    BOOL nearTop = point.y > bounds.size.height - edgeSize;
    BOOL nearBottom = point.y < edgeSize;

    if (nearTop && nearLeft) return WLEdgeModeTopLeft;
    if (nearTop && nearRight) return WLEdgeModeTopRight;
    if (nearBottom && nearLeft) return WLEdgeModeBottomLeft;
    if (nearBottom && nearRight) return WLEdgeModeBottomRight;
    if (nearTop) return WLEdgeModeTop;
    if (nearBottom) return WLEdgeModeBottom;
    if (nearLeft) return WLEdgeModeLeft;
    if (nearRight) return WLEdgeModeRight;

    return WLEdgeModeNone;
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self updateCursorForEdgeMode:[self edgeModeForPoint:point]];
}

- (void)mouseEntered:(NSEvent *)event {
    [[NSCursor arrowCursor] set];
}

- (void)mouseExited:(NSEvent *)event {
    [[NSCursor arrowCursor] set];
}

- (void)updateCursorForEdgeMode:(WLEdgeMode)mode {
    switch (mode) {
        case WLEdgeModeTop:
        case WLEdgeModeBottom:
            [[NSCursor resizeUpDownCursor] set];
            break;
        case WLEdgeModeLeft:
        case WLEdgeModeRight:
            [[NSCursor resizeLeftRightCursor] set];
            break;
        case WLEdgeModeTopLeft:
        case WLEdgeModeBottomRight:
            [[NSCursor arrowCursor] set];
            break;
        case WLEdgeModeTopRight:
        case WLEdgeModeBottomLeft:
            [[NSCursor arrowCursor] set];
            break;
        default:
            [[NSCursor arrowCursor] set];
            break;
    }
}

#pragma mark - Pan Gesture (Drag + Resize)

- (void)handlePan:(NSPanGestureRecognizer *)recognizer {
    NSPoint location = [recognizer locationInView:self];
    NSPoint translation = [recognizer translationInView:self.superview];

    if (recognizer.state == NSGestureRecognizerStateBegan) {
        self.edgeMode = [self edgeModeForPoint:location];
        self.dragStartPoint = [recognizer locationInView:self.superview];
        self.dragStartFrame = self.frame;
    }

    if (recognizer.state == NSGestureRecognizerStateChanged) {
        if (self.edgeMode == WLEdgeModeNone) {
            NSPoint origin = self.frame.origin;
            origin.x = self.dragStartFrame.origin.x + translation.x;
            origin.y = self.dragStartFrame.origin.y + translation.y;
            [self setFrameOrigin:origin];
        } else {
            [self resizeWithTranslation:translation];
        }
    }

    if (recognizer.state == NSGestureRecognizerStateEnded) {
        self.edgeMode = WLEdgeModeNone;
    }
}

- (void)resizeWithTranslation:(NSPoint)translation {
    NSRect frame = self.dragStartFrame;
    CGFloat deltaX = translation.x;
    CGFloat deltaY = translation.y;

    switch (self.edgeMode) {
        case WLEdgeModeLeft:
            frame.origin.x += deltaX;
            frame.size.width -= deltaX;
            break;
        case WLEdgeModeRight:
            frame.size.width += deltaX;
            break;
        case WLEdgeModeBottom:
            frame.origin.y += deltaY;
            frame.size.height -= deltaY;
            break;
        case WLEdgeModeTop:
            frame.size.height += deltaY;
            break;
        case WLEdgeModeTopLeft:
            frame.origin.x += deltaX;
            frame.size.width -= deltaX;
            frame.size.height += deltaY;
            break;
        case WLEdgeModeTopRight:
            frame.size.width += deltaX;
            frame.size.height += deltaY;
            break;
        case WLEdgeModeBottomLeft:
            frame.origin.x += deltaX;
            frame.origin.y += deltaY;
            frame.size.width -= deltaX;
            frame.size.height -= deltaY;
            break;
        case WLEdgeModeBottomRight:
            frame.origin.y += deltaY;
            frame.size.width += deltaX;
            frame.size.height -= deltaY;
            break;
        default:
            break;
    }

    if (frame.size.width < kMinSize) {
        if (self.edgeMode == WLEdgeModeLeft ||
            self.edgeMode == WLEdgeModeTopLeft ||
            self.edgeMode == WLEdgeModeBottomLeft) {
            frame.origin.x = self.dragStartFrame.origin.x + self.dragStartFrame.size.width - kMinSize;
        }
        frame.size.width = kMinSize;
    }

    if (frame.size.height < kMinSize) {
        if (self.edgeMode == WLEdgeModeBottom ||
            self.edgeMode == WLEdgeModeBottomLeft ||
            self.edgeMode == WLEdgeModeBottomRight) {
            frame.origin.y = self.dragStartFrame.origin.y + self.dragStartFrame.size.height - kMinSize;
        }
        frame.size.height = kMinSize;
    }

    [self setFrame:frame];
}

#pragma mark - NSView Override

- (BOOL)isFlipped {
    return NO;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    self.metalView.frame = self.bounds;
}

@end
