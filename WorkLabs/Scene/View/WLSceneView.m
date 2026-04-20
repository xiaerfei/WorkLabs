//
//  WLSceneView.m
//  WorkLabs
//
//  Created by erfeixia on 20/04/2026.
//

#import "WLSceneView.h"
#import "WLScene.h"
#import "WLMetalPreview.h"
#import "WLMediaSourceProvider.h"
#import "WLSourceLayout.h"
#import "WLNodeFrame.h"
#import <Masonry/Masonry.h>

#pragma mark - WLSourcePreviewPair

/// 媒体源与预览视图的配对
@interface WLSourcePreviewPair : NSObject
@property (nonatomic, strong) id<WLMediaSourceProvider> source;
@property (nonatomic, strong) WLMetalPreview *preview;
@property (nonatomic, strong) WLSourceLayout *layout;
@end

@implementation WLSourcePreviewPair
@end

#pragma mark - WLSceneView

@interface WLSceneView ()

@property (nonatomic, strong, readwrite) WLScene *scene;
@property (nonatomic, strong) NSMutableDictionary<NSString *, WLSourcePreviewPair *> *sourcePreviewMap;
@property (nonatomic, strong) NSMutableArray<WLSourcePreviewPair *> *sortedPairs;
@property (nonatomic, assign) BOOL isRendering;

@end

@implementation WLSceneView

#pragma mark - Init

- (instancetype)initWithScene:(WLScene *)scene {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _scene = scene;
        _sourcePreviewMap = [NSMutableDictionary dictionary];
        _sortedPairs = [NSMutableArray array];
        _isRendering = NO;
        
        [self setupSceneView];
        NSLog(@"[WLSceneView] 初始化场景视图: %@", scene.name);
    }
    return self;
}

- (void)setupSceneView {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;
}

#pragma mark - 渲染控制

- (void)startRendering {
    if (self.isRendering) {
        NSLog(@"[WLSceneView] 场景 \"%@\" 已在渲染中", self.scene.name);
        return;
    }
    
    self.isRendering = YES;
    [self rebuildPreviews];
    [self startRenderLoop];
    
    NSLog(@"[WLSceneView] 开始渲染场景: %@", self.scene.name);
}

- (void)stopRendering {
    if (!self.isRendering) {
        return;
    }
    
    self.isRendering = NO;
    
    // 停止所有媒体源
    for (WLSourcePreviewPair *pair in self.sourcePreviewMap.allValues) {
        if ([pair.source isActive]) {
            [pair.source stop];
        }
    }
    
    NSLog(@"[WLSceneView] 停止渲染场景: %@", self.scene.name);
}

- (void)startRenderLoop {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        while (weakSelf.isRendering) {
            [weakSelf renderFrame];
            [NSThread sleepForTimeInterval:1.0 / 60.0]; // 60 FPS
        }
    });
}

- (void)renderFrame {
    for (WLSourcePreviewPair *pair in self.sortedPairs) {
        if (!pair.layout.visible) {
            continue;
        }
        
        WLNodeFrame *frame = [pair.source nextVideoFrame];
        if (frame) {
            CVPixelBufferRef pixelBuffer = frame.pixelBuffer;
            if (pixelBuffer) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [pair.preview displayPixelBuffer:pixelBuffer];
                });
            }
        }
    }
}

#pragma mark - 预览视图管理

- (void)rebuildPreviews {
    // 清除旧预览
    for (WLSourcePreviewPair *pair in self.sourcePreviewMap.allValues) {
        [pair.preview removeFromSuperview];
    }
    [self.sourcePreviewMap removeAllObjects];
    [self.sortedPairs removeAllObjects];
    
    // 为每个媒体源创建预览
    for (id<WLMediaSourceProvider> source in self.scene.sources) {
        WLSourceLayout *layout = [self.scene layoutForIdentifier:source.identifier];
        if (!layout) {
            layout = [WLSourceLayout layoutWithFrame:CGRectZero];
        }
        
        WLMetalPreview *preview = [[WLMetalPreview alloc] initWithFrame:layout.frame];
        [self addSubview:preview];
        
        WLSourcePreviewPair *pair = [[WLSourcePreviewPair alloc] init];
        pair.source = source;
        pair.preview = preview;
        pair.layout = layout;
        
        self.sourcePreviewMap[source.identifier] = pair;
        [self.sortedPairs addObject:pair];
    }
    
    // 按 zIndex 排序
    [self.sortedPairs sortUsingComparator:^NSComparisonResult(WLSourcePreviewPair *p1, WLSourcePreviewPair *p2) {
        return p1.layout.zIndex > p2.layout.zIndex;
    }];
    
    // 重新添加视图（按排序顺序）
    for (WLSourcePreviewPair *pair in self.sortedPairs) {
        [self addSubview:pair.preview];
    }
    
    [self refreshLayout];
}

- (void)refreshLayout {
    for (WLSourcePreviewPair *pair in self.sourcePreviewMap.allValues) {
        WLSourceLayout *layout = [self.scene layoutForIdentifier:pair.source.identifier];
        if (layout) {
            pair.layout = layout;
            pair.preview.frame = [self convertRectFromCanvas:layout.frame];
            pair.preview.hidden = !layout.visible;
        }
    }
}

- (NSRect)convertRectFromCanvas:(CGRect)rect {
    // 将画布坐标系转换为视图坐标系
    // 假设视图大小等于画布大小
    CGFloat viewWidth = self.bounds.size.width;
    CGFloat viewHeight = self.bounds.size.height;
    CGFloat canvasWidth = self.scene.canvasSize.width;
    CGFloat canvasHeight = self.scene.canvasSize.height;
    
    if (canvasWidth == 0 || canvasHeight == 0) {
        return rect;
    }
    
    CGFloat scaleX = viewWidth / canvasWidth;
    CGFloat scaleY = viewHeight / canvasHeight;
    
    return CGRectMake(rect.origin.x * scaleX,
                      rect.origin.y * scaleY,
                      rect.size.width * scaleX,
                      rect.size.height * scaleY);
}

#pragma mark - 媒体源管理

- (void)addSourcePreviewForSource:(id<WLMediaSourceProvider>)source {
    if (self.sourcePreviewMap[source.identifier]) {
        NSLog(@"[WLSceneView] 源 \"%@\" 已有预览，跳过", source.sourceName);
        return;
    }
    
    WLSourceLayout *layout = [self.scene layoutForIdentifier:source.identifier];
    if (!layout) {
        layout = [WLSourceLayout layoutWithFrame:CGRectMake(0, 0, 320, 180)];
    }
    
    WLMetalPreview *preview = [[WLMetalPreview alloc] initWithFrame:layout.frame];
    [self addSubview:preview];
    
    WLSourcePreviewPair *pair = [[WLSourcePreviewPair alloc] init];
    pair.source = source;
    pair.preview = preview;
    pair.layout = layout;
    
    self.sourcePreviewMap[source.identifier] = pair;
    [self.sortedPairs addObject:pair];
    
    [self refreshLayout];
    
    if (self.isRendering) {
        [source start];
    }
    
    NSLog(@"[WLSceneView] 添加源预览: %@", source.sourceName);
}

- (void)removeSourcePreviewForSource:(id<WLMediaSourceProvider>)source {
    WLSourcePreviewPair *pair = self.sourcePreviewMap[source.identifier];
    if (!pair) {
        return;
    }
    
    if ([pair.source isActive]) {
        [pair.source stop];
    }
    
    [pair.preview removeFromSuperview];
    [self.sourcePreviewMap removeObjectForKey:source.identifier];
    [self.sortedPairs removeObject:pair];
    
    NSLog(@"[WLSceneView] 移除源预览: %@", source.sourceName);
}

#pragma mark - NSView

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self refreshLayout];
}

- (BOOL)isFlipped {
    return NO;
}

#pragma mark - Description

- (NSString *)description {
    return [NSString stringWithFormat:@"<WLSceneView | scene=%@ | sources=%lu | rendering=%@>",
            self.scene.name, (unsigned long)self.sourcePreviewMap.count,
            self.isRendering ? @"YES" : @"NO"];
}

@end