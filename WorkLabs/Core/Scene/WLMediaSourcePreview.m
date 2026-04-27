//
//  WLMediaSourcePreview.m
//  WorkLabs
//

#import "WLMediaSourcePreview.h"
#import "WLMediaSourceItem.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

static const CGFloat kBorderWidth = 3.0;

@interface WLMediaSourcePreview () <MTKViewDelegate>

// Metal 基础
@property (nonatomic, strong) MTKView *metalView;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLRenderPipelineState> borderPipelineState;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;

@property (nonatomic, assign) CGSize currentPixelBufferSize;
@property (nonatomic, strong) id<MTLBuffer> vertexBuffer;
@property (nonatomic, strong) id<MTLBuffer> borderVertexBuffer;

// UI 覆盖层
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSImageView *typeIconView;
@property (nonatomic, strong) NSView *audioPlaceholderView;

// 拖拽状态
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) NSPoint dragOffset;

@end

@implementation WLMediaSourcePreview

#pragma mark - Init

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupMetal];
        [self setupOverlayViews];
    }
    return self;
}

- (void)dealloc {
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

#pragma mark - Metal Setup (拷贝自 WLMetalPreview)

- (void)setupMetal {
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        NSLog(@"[WLMediaSourcePreview] Metal is not supported");
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
        NSLog(@"[WLMediaSourcePreview] Failed to create texture cache");
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
        NSLog(@"[WLMediaSourcePreview] pipeline error: %@", error);
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

#pragma mark - Overlay Views

- (void)setupOverlayViews {
    // 名称标签 (左上角)
    self.nameLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.nameLabel.editable = NO;
    self.nameLabel.bordered = NO;
    self.nameLabel.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.6];
    self.nameLabel.textColor = [NSColor whiteColor];
    self.nameLabel.font = [NSFont systemFontOfSize:11.0];
    self.nameLabel.drawsBackground = YES;
    [self addSubview:self.nameLabel];

    // 类型图标 (左下角)
    self.typeIconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.typeIconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:self.typeIconView];

    // 音频占位视图
    self.audioPlaceholderView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.audioPlaceholderView.wantsLayer = YES;
    self.audioPlaceholderView.layer.backgroundColor = [[NSColor colorWithWhite:0.15 alpha:1.0] CGColor];
    self.audioPlaceholderView.hidden = YES;
    [self addSubview:self.audioPlaceholderView];
}

- (void)layout {
    [super layout];

    // 名称标签布局
    [self.nameLabel sizeToFit];
    NSSize labelSize = self.nameLabel.frame.size;
    self.nameLabel.frame = NSMakeRect(4, self.bounds.size.height - labelSize.height - 4,
                                       labelSize.width + 8, labelSize.height + 2);

    // 类型图标布局
    CGFloat iconSize = 16;
    self.typeIconView.frame = NSMakeRect(4, 4, iconSize, iconSize);

    // 音频占位布局
    self.audioPlaceholderView.frame = self.bounds;
}

#pragma mark - Public

- (void)setItem:(WLMediaSourceItem *)item {
    _item = item;
    [self updateOverlayContent];
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
}

- (void)updateOverlayContent {
    if (!self.item) return;

    self.nameLabel.stringValue = self.item.name ?: @"";

    NSString *iconName = nil;
    switch (self.item.type) {
        case WLMediaSourceTypeCamera: iconName = @"camera.fill";    break;
        case WLMediaSourceTypeVideo:  iconName = @"film";           break;
        case WLMediaSourceTypeAudio:  iconName = @"music.note";     break;
    }
    if (iconName) {
        self.typeIconView.image = [NSImage imageWithSystemSymbolName:iconName
                                         accessibilityDescription:nil];
        self.typeIconView.contentTintColor = [NSColor colorWithWhite:0.9 alpha:0.8];
    }
}

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer || !self.device) return;

    self.audioPlaceholderView.hidden = YES;

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

        id<MTLTexture> texture = CVMetalTextureGetTexture(textureRef);
        [self renderRGBWithTexture:texture];
        CFRelease(textureRef);
    }
}

- (void)showAudioPlaceholder {
    self.audioPlaceholderView.hidden = NO;

    // 音频图标居中
    NSImageView *audioIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
    audioIcon.image = [NSImage imageWithSystemSymbolName:@"music.note"
                                    accessibilityDescription:nil];
    audioIcon.contentTintColor = [NSColor colorWithWhite:0.5 alpha:0.6];
    audioIcon.imageScaling = NSImageScaleProportionallyUpOrDown;

    // 移除旧图标
    for (NSView *sv in self.audioPlaceholderView.subviews) {
        [sv removeFromSuperview];
    }

    [self.audioPlaceholderView addSubview:audioIcon];
    audioIcon.frame = NSMakeRect((self.bounds.size.width - 32) / 2,
                                  (self.bounds.size.height - 32) / 2,
                                  32, 32);
}

- (void)updateTransform {
    if (!self.item) return;
    NSRect newFrame = NSMakeRect(self.item.position.x - self.item.size.width / 2,
                                  self.item.position.y - self.item.size.height / 2,
                                  self.item.size.width,
                                  self.item.size.height);
    self.frame = newFrame;
}

#pragma mark - Render (拷贝自 WLMetalPreview)

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
    if (!self.selected) return;

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

#pragma mark - Mouse Events (拖拽)

- (void)mouseDown:(NSEvent *)event {
    self.isDragging = YES;
    NSPoint locationInView = [self convertPoint:event.locationInWindow fromView:nil];
    self.dragOffset = NSMakePoint(locationInView.x - self.bounds.size.width / 2,
                                   locationInView.y - self.bounds.size.height / 2);
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.isDragging || !self.item) return;

    NSView *superview = self.superview;
    if (!superview) return;

    NSPoint locationInSuperview = [superview convertPoint:event.locationInWindow fromView:nil];
    CGFloat newX = locationInSuperview.x - self.dragOffset.x;
    CGFloat newY = locationInSuperview.y - self.dragOffset.y;

    // 边界限制
    newX = MAX(0, MIN(newX, superview.bounds.size.width));
    newY = MAX(0, MIN(newY, superview.bounds.size.height));

    self.item.position = NSMakePoint(newX, newY);
    [self updateTransform];
}

- (void)mouseUp:(NSEvent *)event {
    self.isDragging = NO;
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)drawInMTKView:(MTKView *)view {
}

@end
