//
//  WLStreamPreview.m
//  WorkLabs
//

#import "WLStreamPreview.h"
#import <CoreVideo/CoreVideo.h>

static const CGFloat kHandleSize = 10.0;   // 手柄小方块边长
static const CGFloat kHandleHit  = 12.0;   // 手柄命中半径
static const CGFloat kMinSize    = 40.0;   // 最小宽度

typedef NS_ENUM(NSInteger, WLHandle) {
    WLHandleNone = -1,
    WLHandleBottomLeft = 0,
    WLHandleBottom,
    WLHandleBottomRight,
    WLHandleLeft,
    WLHandleRight,
    WLHandleTopLeft,
    WLHandleTop,
    WLHandleTopRight,
    WLHandleCount
};

@interface WLStreamPreview ()
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) BOOL resizing;
@property (nonatomic, assign) CGPoint dragOffset;
@property (nonatomic, assign) WLHandle resizeHandle;
@property (nonatomic, assign) CGRect resizeStartFrame;
@property (nonatomic, assign) BOOL aspectInitialized;
@property (nonatomic, strong) NSMutableArray<CALayer *> *handleLayers;
@property (nonatomic, strong) CALayer *borderLayer;
@end

@implementation WLStreamPreview

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) { [self setupLayer]; }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) { [self setupLayer]; }
    return self;
}

- (void)setupLayer {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;
    _interactive = YES;
    _videoAspect = 16.0 / 9.0;
    _resizeHandle = WLHandleNone;

    // 红框：单独的 layer，置于手柄之下（layer.border 会盖住 sublayer，故不用它）
    _borderLayer = [CALayer layer];
    _borderLayer.borderWidth = 2.0;
    _borderLayer.borderColor = [NSColor systemRedColor].CGColor;
    _borderLayer.backgroundColor = [NSColor clearColor].CGColor;
    _borderLayer.hidden = YES;
    [self.layer addSublayer:_borderLayer];

    // 8 个手柄小方块（红底红边），添加在红框之上
    _handleLayers = [NSMutableArray array];
    for (NSInteger i = 0; i < WLHandleCount; i++) {
        CALayer *h = [CALayer layer];
        h.backgroundColor = [NSColor systemRedColor].CGColor;
        h.borderColor = [NSColor systemRedColor].CGColor;
        h.borderWidth = 1.0;
        h.hidden = YES;
        [self.layer addSublayer:h];
        [_handleLayers addObject:h];
    }
}

- (CALayer *)makeBackingLayer {
    _displayLayer = [AVSampleBufferDisplayLayer layer];
    _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    return _displayLayer;
}

- (NSView *)hitTest:(NSPoint)point {
    if (!self.interactive) return nil; // 不拦截鼠标事件
    return [super hitTest:point];
}

#pragma mark - Selection

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.borderLayer.hidden = !selected;
    for (CALayer *h in self.handleLayers) h.hidden = !selected;
    if (selected) [self layoutHandles];
}

- (void)layout {
    [super layout];
    [self layoutHandles];
}

- (void)handleCenters:(CGPoint *)c {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    c[WLHandleBottomLeft]  = CGPointMake(0,   0);
    c[WLHandleBottom]      = CGPointMake(w/2, 0);
    c[WLHandleBottomRight] = CGPointMake(w,   0);
    c[WLHandleLeft]        = CGPointMake(0,   h/2);
    c[WLHandleRight]       = CGPointMake(w,   h/2);
    c[WLHandleTopLeft]     = CGPointMake(0,   h);
    c[WLHandleTop]         = CGPointMake(w/2, h);
    c[WLHandleTopRight]    = CGPointMake(w,   h);
}

- (void)layoutHandles {
    CGPoint c[WLHandleCount];
    [self handleCenters:c];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.borderLayer.frame = self.bounds;
    for (NSInteger i = 0; i < WLHandleCount; i++) {
        self.handleLayers[i].frame = CGRectMake(c[i].x - kHandleSize/2,
                                                c[i].y - kHandleSize/2,
                                                kHandleSize, kHandleSize);
    }
    [CATransaction commit];
}

- (WLHandle)handleForPoint:(CGPoint)p {
    CGPoint c[WLHandleCount];
    [self handleCenters:c];
    for (NSInteger i = 0; i < WLHandleCount; i++) {
        if (fabs(p.x - c[i].x) <= kHandleHit && fabs(p.y - c[i].y) <= kHandleHit) {
            return (WLHandle)i;
        }
    }
    return WLHandleNone;
}

#pragma mark - WLStreamRenderingProtocol

- (WLNodeType)outputType { return WLNodeTypeVideo; }

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

    // 记录视频宽高比；首帧时把浮层调整为视频真实比例
    size_t vw = CVPixelBufferGetWidth(pixelBuffer);
    size_t vh = CVPixelBufferGetHeight(pixelBuffer);
    if (vw > 0 && vh > 0) {
        CGFloat a = (CGFloat)vw / (CGFloat)vh;
        self.videoAspect = a;
        if (!self.aspectInitialized) {
            self.aspectInitialized = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                CGRect f = self.frame;
                f.size.height = f.size.width / a;
                self.frame = f;
                [self layoutHandles];
                [self notifyFrameUpdate];
            });
        }
    }

    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPixelBuffer:pixelBuffer pts:pts];
    if (!sampleBuffer) return;
    [self enqueueSampleBuffer:sampleBuffer];
    CFRelease(sampleBuffer);
}

- (void)flush {
    [self.displayLayer.sampleBufferRenderer flush];
}

#pragma mark - Mouse Interaction

- (void)mouseDown:(NSEvent *)event {
    CGPoint pb = [self convertPoint:event.locationInWindow fromView:nil];

    // 已选中：优先判断是否点在手柄上 → resize
    if (self.selected) {
        WLHandle handle = [self handleForPoint:pb];
        if (handle != WLHandleNone) {
            self.resizing = YES;
            self.resizeHandle = handle;
            self.resizeStartFrame = self.frame;
            return;
        }
    } else {
        // 未选中：通知界面层做单选
        if ([self.delegate respondsToSelector:@selector(renderingDidRequestSelect:)]) {
            [self.delegate renderingDidRequestSelect:self];
        }
    }

    // 否则开始拖动
    self.dragging = YES;
    CGPoint ps = [self.superview convertPoint:event.locationInWindow fromView:nil];
    self.dragOffset = CGPointMake(ps.x - self.frame.origin.x, ps.y - self.frame.origin.y);
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.resizing) {
        CGPoint ps = [self.superview convertPoint:event.locationInWindow fromView:nil];
        [self handleResizeTo:ps];
    } else if (self.dragging) {
        [self handleDrag:event];
    }
}

- (void)mouseUp:(NSEvent *)event {
    self.dragging = NO;
    self.resizing = NO;
    self.resizeHandle = WLHandleNone;
    [self notifyFrameUpdate];
}

#pragma mark - 右键菜单（层级调整）

- (void)rightMouseDown:(NSEvent *)event {
    if (!self.interactive) { [super rightMouseDown:event]; return; }

    // 右键先选中本浮层
    if (!self.selected &&
        [self.delegate respondsToSelector:@selector(renderingDidRequestSelect:)]) {
        [self.delegate renderingDidRequestSelect:self];
    }

    NSMenu *menu = [[NSMenu alloc] init];
    [[menu addItemWithTitle:@"置顶"     action:@selector(zOrderFront:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"上移一层" action:@selector(zOrderUp:)    keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"下移一层" action:@selector(zOrderDown:)  keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"置底"     action:@selector(zOrderBack:)  keyEquivalent:@""] setTarget:self];
    [menu addItem:[NSMenuItem separatorItem]];
    [[menu addItemWithTitle:@"取消选中" action:@selector(deselect:)    keyEquivalent:@""] setTarget:self];
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)zOrderFront:(id)sender { [self emitZOrderAction:WLZOrderActionFront]; }
- (void)zOrderBack:(id)sender  { [self emitZOrderAction:WLZOrderActionBack]; }
- (void)zOrderUp:(id)sender    { [self emitZOrderAction:WLZOrderActionUp]; }
- (void)zOrderDown:(id)sender  { [self emitZOrderAction:WLZOrderActionDown]; }

- (void)emitZOrderAction:(WLZOrderAction)action {
    if ([self.delegate respondsToSelector:@selector(rendering:didRequestZOrderAction:)]) {
        [self.delegate rendering:self didRequestZOrderAction:action];
    }
}

- (void)deselect:(id)sender {
    if ([self.delegate respondsToSelector:@selector(renderingDidRequestDeselect:)]) {
        [self.delegate renderingDidRequestDeselect:self];
    }
}

#pragma mark - Drag / Resize

- (void)handleDrag:(NSEvent *)event {
    NSView *sv = self.superview;
    if (!sv) return;
    CGPoint ps = [sv convertPoint:event.locationInWindow fromView:nil];
    CGFloat nx = ps.x - self.dragOffset.x;
    CGFloat ny = ps.y - self.dragOffset.y;
    CGFloat maxX = sv.bounds.size.width  - self.frame.size.width;
    CGFloat maxY = sv.bounds.size.height - self.frame.size.height;
    nx = fmax(0, fmin(nx, maxX));
    ny = fmax(0, fmin(ny, maxY));
    self.frame = NSMakeRect(nx, ny, self.frame.size.width, self.frame.size.height);
    [self layoutHandles];
    [self notifyFrameUpdate];
}

// 按视频宽高比等比缩放，固定被拖手柄的对角/对边
- (void)handleResizeTo:(CGPoint)p {
    CGRect s = self.resizeStartFrame;
    CGFloat aspect = (self.videoAspect > 0) ? self.videoAspect : (s.size.width / fmax(s.size.height, 1));
    CGFloat minW = kMinSize, minH = kMinSize;
    CGFloat newW = s.size.width, newH = s.size.height, ox = s.origin.x, oy = s.origin.y;

    switch (self.resizeHandle) {
        case WLHandleBottomLeft: {                 // 锚 TopRight
            CGFloat ax = CGRectGetMaxX(s), ay = CGRectGetMaxY(s);
            newW = fmax(ax - p.x, minW); newH = newW / aspect;
            if (newH < minH) { newH = minH; newW = newH * aspect; }
            ox = ax - newW; oy = ay - newH;
            break;
        }
        case WLHandleBottomRight: {                // 锚 TopLeft
            CGFloat ax = CGRectGetMinX(s), ay = CGRectGetMaxY(s);
            newW = fmax(p.x - ax, minW); newH = newW / aspect;
            if (newH < minH) { newH = minH; newW = newH * aspect; }
            ox = ax; oy = ay - newH;
            break;
        }
        case WLHandleTopLeft: {                    // 锚 BottomRight
            CGFloat ax = CGRectGetMaxX(s), ay = CGRectGetMinY(s);
            newW = fmax(ax - p.x, minW); newH = newW / aspect;
            if (newH < minH) { newH = minH; newW = newH * aspect; }
            ox = ax - newW; oy = ay;
            break;
        }
        case WLHandleTopRight: {                   // 锚 BottomLeft
            CGFloat ax = CGRectGetMinX(s), ay = CGRectGetMinY(s);
            newW = fmax(p.x - ax, minW); newH = newW / aspect;
            if (newH < minH) { newH = minH; newW = newH * aspect; }
            ox = ax; oy = ay;
            break;
        }
        case WLHandleLeft: {                        // 锚 右边，垂直居中
            CGFloat ax = CGRectGetMaxX(s), cy = CGRectGetMidY(s);
            newW = fmax(ax - p.x, minW); newH = newW / aspect;
            ox = ax - newW; oy = cy - newH / 2;
            break;
        }
        case WLHandleRight: {                       // 锚 左边，垂直居中
            CGFloat ax = CGRectGetMinX(s), cy = CGRectGetMidY(s);
            newW = fmax(p.x - ax, minW); newH = newW / aspect;
            ox = ax; oy = cy - newH / 2;
            break;
        }
        case WLHandleBottom: {                      // 锚 顶边，水平居中
            CGFloat ay = CGRectGetMaxY(s), cx = CGRectGetMidX(s);
            newH = fmax(ay - p.y, minH); newW = newH * aspect;
            oy = ay - newH; ox = cx - newW / 2;
            break;
        }
        case WLHandleTop: {                         // 锚 底边，水平居中
            CGFloat ay = CGRectGetMinY(s), cx = CGRectGetMidX(s);
            newH = fmax(p.y - ay, minH); newW = newH * aspect;
            oy = ay; ox = cx - newW / 2;
            break;
        }
        default: return;
    }

    self.frame = NSMakeRect(ox, oy, newW, newH);
    [self layoutHandles];
    [self notifyFrameUpdate];
}

- (void)notifyFrameUpdate {
    if ([self.delegate respondsToSelector:@selector(rendering:didUpdateFrame:)]) {
        // 返回 superview 坐标系的 frame
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
