//
//  WLStreamPreview.m
//  WorkLabs
//

#import "WLStreamPreview.h"

static const CGFloat kResizeHitArea = 8.0;
static const CGFloat kMinSize = 40.0;

typedef NS_OPTIONS(NSUInteger, WLResizeEdge) {
    WLResizeEdgeNone   = 0,
    WLResizeEdgeLeft   = 1 << 0,
    WLResizeEdgeRight  = 1 << 1,
    WLResizeEdgeTop    = 1 << 2,
    WLResizeEdgeBottom = 1 << 3,
};

@interface WLStreamPreview ()
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) BOOL resizing;
@property (nonatomic, assign) CGPoint dragOffset;
@property (nonatomic, assign) WLResizeEdge resizeEdge;
@property (nonatomic, assign) CGRect resizeStartFrame;
@end

@implementation WLStreamPreview

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupLayer];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setupLayer];
    }
    return self;
}

- (void)setupLayer {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.2].CGColor;
}

- (CALayer *)makeBackingLayer {
    _displayLayer = [AVSampleBufferDisplayLayer layer];
    _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    return _displayLayer;
}

#pragma mark - WLStreamRenderingProtocol

- (WLNodeType)outputType {
    return WLNodeTypeVideo;
}

- (void)receiveVideoFrame:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    [self enqueuePixelBuffer:pixelBuffer pts:pts];
}

#pragma mark - Public

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;
    CFRetain(sampleBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

- (void)enqueuePixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    if (!pixelBuffer) return;
    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPixelBuffer:pixelBuffer pts:pts];
    if (!sampleBuffer) return;
    [self enqueueSampleBuffer:sampleBuffer];
    CFRelease(sampleBuffer);
}

- (void)flush {
    [self.displayLayer.sampleBufferRenderer flush];
}

#pragma mark - Mouse Interaction

- (WLResizeEdge)resizeEdgeForPoint:(CGPoint)point {
    WLResizeEdge edge = WLResizeEdgeNone;
    CGRect bounds = self.bounds;
    if (point.x < kResizeHitArea)                        edge |= WLResizeEdgeLeft;
    if (point.x > bounds.size.width - kResizeHitArea)    edge |= WLResizeEdgeRight;
    if (point.y < kResizeHitArea)                        edge |= WLResizeEdgeTop;
    if (point.y > bounds.size.height - kResizeHitArea)   edge |= WLResizeEdgeBottom;
    return edge;
}

- (NSCursor *)cursorForEdge:(WLResizeEdge)edge {
    switch (edge) {
        case WLResizeEdgeLeft | WLResizeEdgeTop:
        case WLResizeEdgeRight | WLResizeEdgeBottom:
            return [NSCursor crosshairCursor]; // ↘↖
        case WLResizeEdgeRight | WLResizeEdgeTop:
        case WLResizeEdgeLeft | WLResizeEdgeBottom:
            return [NSCursor crosshairCursor]; // ↗↙
        case WLResizeEdgeLeft:
        case WLResizeEdgeRight:
            return [NSCursor resizeLeftRightCursor];
        case WLResizeEdgeTop:
        case WLResizeEdgeBottom:
            return [NSCursor resizeUpDownCursor];
        default:
            return [NSCursor openHandCursor];
    }
}

- (void)mouseDown:(NSEvent *)event {
    CGPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    self.resizeEdge = [self resizeEdgeForPoint:point];

    if (self.resizeEdge != WLResizeEdgeNone) {
        self.resizing = YES;
        self.resizeStartFrame = self.frame;
    } else {
        self.dragging = YES;
        self.dragOffset = CGPointMake(point.x, point.y);
        [NSCursor.closedHandCursor push];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.resizing) {
        [self handleResize:event];
    } else if (self.dragging) {
        [self handleDrag:event];
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (self.dragging) {
        [NSCursor pop];
    }
    self.dragging = NO;
    self.resizing = NO;
    [self notifyFrameUpdate];
}

- (void)mouseEntered:(NSEvent *)event {
    CGPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    WLResizeEdge edge = [self resizeEdgeForPoint:point];
    [[self cursorForEdge:edge] set];
}

- (void)mouseMoved:(NSEvent *)event {
    CGPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    WLResizeEdge edge = [self resizeEdgeForPoint:point];
    [[self cursorForEdge:edge] set];
}

- (void)mouseExited:(NSEvent *)event {
    [NSCursor.arrowCursor set];
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor openHandCursor]];
}

#pragma mark - Drag / Resize

- (void)handleDrag:(NSEvent *)event {
    NSView *superview = self.superview;
    if (!superview) return;

    CGPoint superPoint = [superview convertPoint:event.locationInWindow fromView:nil];
    CGFloat newX = superPoint.x - self.dragOffset.x;
    CGFloat newY = superPoint.y - self.dragOffset.y;

    // 约束在 superview bounds 内
    CGFloat maxX = superview.bounds.size.width - self.frame.size.width;
    CGFloat maxY = superview.bounds.size.height - self.frame.size.height;
    newX = fmax(0, fmin(newX, maxX));
    newY = fmax(0, fmin(newY, maxY));

    self.frame = NSMakeRect(newX, newY, self.frame.size.width, self.frame.size.height);
}

- (void)handleResize:(NSEvent *)event {
    CGPoint superPoint = [self.superview convertPoint:event.locationInWindow fromView:nil];
    CGRect f = self.resizeStartFrame;
    CGFloat minW = kMinSize;
    CGFloat minH = kMinSize;

    if (self.resizeEdge & WLResizeEdgeLeft) {
        CGFloat right = NSMaxX(f);
        CGFloat newW = right - superPoint.x;
        if (newW >= minW) {
            f.origin.x = superPoint.x;
            f.size.width = newW;
        }
    }
    if (self.resizeEdge & WLResizeEdgeRight) {
        CGFloat newW = superPoint.x - f.origin.x;
        if (newW >= minW) {
            f.size.width = newW;
        }
    }
    if (self.resizeEdge & WLResizeEdgeTop) {
        CGFloat top = NSMaxY(f);
        CGFloat newH = top - superPoint.y;
        if (newH >= minH) {
            f.origin.y = superPoint.y;
            f.size.height = newH;
        }
    }
    if (self.resizeEdge & WLResizeEdgeBottom) {
        CGFloat newH = superPoint.y - f.origin.y;
        if (newH >= minH) {
            f.size.height = newH;
        }
    }

    self.frame = f;
}

- (void)notifyFrameUpdate {
    if (self.delegate) {
        // 返回基于 superview 坐标系的 frame（像素值，与 output 画布一致）
        [self.delegate rendering:self didUpdateFrame:self.frame];
    }
}

#pragma mark - Private

- (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                                   pts:(Float64)pts {
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, pixelBuffer, &formatDesc);
    if (status != noErr) return NULL;

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMakeWithSeconds(pts, 600),
        .decodeTimeStamp = kCMTimeInvalid
    };

    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, pixelBuffer, formatDesc, &timing, &sampleBuffer);
    CFRelease(formatDesc);

    return (status == noErr) ? sampleBuffer : NULL;
}

@end
