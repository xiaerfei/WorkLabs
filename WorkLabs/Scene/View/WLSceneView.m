//
//  WLSceneView.m
//  WorkLabs
//

#import "WLSceneView.h"
#import "WLSourceView.h"
#import "WLScene.h"

@implementation WLSceneView

- (instancetype)initWithScene:(WLScene *)scene frame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _scene = scene;
        _sourceViews = [NSMutableArray array];
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)addSourceView:(WLSourceView *)sourceView {
    if (sourceView && ![self.sourceViews containsObject:sourceView]) {
        [self.sourceViews addObject:sourceView];
        [self addSubview:sourceView];
    }
}

- (void)removeSourceView:(WLSourceView *)sourceView {
    if (sourceView) {
        [self.sourceViews removeObject:sourceView];
        [sourceView removeFromSuperview];
    }
}

- (void)removeSourceViewForSource:(id<WLMediaSource>)source {
    WLSourceView *viewToRemove = nil;
    for (WLSourceView *view in self.sourceViews) {
        if (view.source == source) { viewToRemove = view; break; }
    }
    if (viewToRemove) { [self removeSourceView:viewToRemove]; }
}

- (nullable WLSourceView *)sourceViewForSource:(id<WLMediaSource>)source {
    for (WLSourceView *view in self.sourceViews) {
        if (view.source == source) { return view; }
    }
    return nil;
}

- (void)updateSourceViewFrame:(NSRect)frame forSource:(id<WLMediaSource>)source {
    WLSourceView *view = [self sourceViewForSource:source];
    if (view) { view.frame = frame; }
}

- (void)updateLayouts {}
- (void)layout { [super layout]; [self updateLayouts]; }

@end
