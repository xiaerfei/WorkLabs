//
//  WLTransitionEngine.m
//  WorkLabs
//

#import "WLTransitionEngine.h"

@implementation WLTransition
+ (instancetype)transitionWithType:(WLTransitionType)type duration:(NSTimeInterval)duration {
    WLTransition *transition = [[WLTransition alloc] init];
    transition.type = type;
    transition.duration = duration > 0 ? duration : 0.5;
    return transition;
}
+ (instancetype)fadeWithDuration:(NSTimeInterval)duration { return [self transitionWithType:WLTransitionTypeFade duration:duration]; }
+ (instancetype)slideLeftWithDuration:(NSTimeInterval)duration { return [self transitionWithType:WLTransitionSlideLeft duration:duration]; }
+ (instancetype)slideRightWithDuration:(NSTimeInterval)duration { return [self transitionWithType:WLTransitionSlideRight duration:duration]; }
+ (instancetype)cut { return [self transitionWithType:WLTransitionTypeCut duration:0]; }
@end

@interface WLTransitionEngine ()
@property (nonatomic, strong, readwrite, nullable) WLTransition *currentTransition;
@property (nonatomic, assign, readwrite) float progress;
@property (nonatomic, assign, readwrite) BOOL running;
@end

@implementation WLTransitionEngine
- (instancetype)init { self = [super init]; if (self) { _progress = 0.0f; _running = NO; } return self; }

- (void)applyTransitionFromView:(nullable NSView *)fromView toView:(NSView *)toView inContainer:(NSView *)container transition:(WLTransition *)transition completion:(nullable void (^)(void))completion {
    if (!toView || !container) { if (completion) completion(); return; }
    if (!transition || transition.type == WLTransitionTypeNone || transition.type == WLTransitionTypeCut) {
        for (NSView *subview in container.subviews.copy) { [subview removeFromSuperview]; }
        toView.frame = container.bounds;
        toView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [container addSubview:toView];
        if (completion) completion();
        return;
    }
    self.currentTransition = transition; self.progress = 0.0f; self.running = YES;
    switch (transition.type) {
        case WLTransitionTypeFade: [self performFadeTransitionFromView:fromView toView:toView inContainer:container duration:transition.duration completion:completion]; break;
        case WLTransitionSlideLeft: [self performSlideTransitionFromView:fromView toView:toView inContainer:container direction:-1 duration:transition.duration completion:completion]; break;
        case WLTransitionSlideRight: [self performSlideTransitionFromView:fromView toView:toView inContainer:container direction:1 duration:transition.duration completion:completion]; break;
        case WLTransitionTypeZoom: [self performZoomTransitionFromView:fromView toView:toView inContainer:container duration:transition.duration completion:completion]; break;
        default: [self performFadeTransitionFromView:fromView toView:toView inContainer:container duration:transition.duration completion:completion]; break;
    }
}

- (void)cancelCurrentTransition { self.running = NO; self.currentTransition = nil; self.progress = 0.0f; }

- (void)performFadeTransitionFromView:(nullable NSView *)fromView toView:(NSView *)toView inContainer:(NSView *)container duration:(NSTimeInterval)duration completion:(nullable void (^)(void))completion {
    NSRect bounds = container.bounds;
    for (NSView *subview in container.subviews.copy) { [subview removeFromSuperview]; }
    toView.frame = bounds; toView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; toView.alphaValue = 0.0;
    [container addSubview:toView];
    if (fromView && fromView != toView) {
        fromView.frame = bounds; fromView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; fromView.alphaValue = 1.0;
        [container addSubview:fromView positioned:NSWindowBelow relativeTo:toView];
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = duration; context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        toView.animator.alphaValue = 1.0;
        if (fromView && fromView != toView) { fromView.animator.alphaValue = 0.0; }
    } completionHandler:^{
        if (fromView && fromView != toView) { [fromView removeFromSuperview]; }
        self.running = NO; self.progress = 1.0f; self.currentTransition = nil;
        if (completion) completion();
    }];
}

- (void)performSlideTransitionFromView:(nullable NSView *)fromView toView:(NSView *)toView inContainer:(NSView *)container direction:(NSInteger)direction duration:(NSTimeInterval)duration completion:(nullable void (^)(void))completion {
    NSRect bounds = container.bounds; CGFloat offset = bounds.size.width * direction;
    for (NSView *subview in container.subviews.copy) { [subview removeFromSuperview]; }
    toView.frame = CGRectOffset(bounds, offset, 0); toView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:toView];
    if (fromView && fromView != toView) { fromView.frame = bounds; fromView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; [container addSubview:fromView positioned:NSWindowBelow relativeTo:toView]; }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = duration; context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        toView.animator.frame = bounds;
        if (fromView && fromView != toView) { fromView.animator.frame = CGRectOffset(bounds, -offset, 0); }
    } completionHandler:^{
        if (fromView && fromView != toView) { [fromView removeFromSuperview]; }
        self.running = NO; self.progress = 1.0f; self.currentTransition = nil;
        if (completion) completion();
    }];
}

- (void)performZoomTransitionFromView:(nullable NSView *)fromView toView:(NSView *)toView inContainer:(NSView *)container duration:(NSTimeInterval)duration completion:(nullable void (^)(void))completion {
    NSRect bounds = container.bounds; NSRect centerRect = CGRectInset(bounds, bounds.size.width * 0.2, bounds.size.height * 0.2);
    for (NSView *subview in container.subviews.copy) { [subview removeFromSuperview]; }
    toView.frame = centerRect; toView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:toView];
    if (fromView && fromView != toView) { fromView.frame = bounds; fromView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; [container addSubview:fromView positioned:NSWindowBelow relativeTo:toView]; }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = duration; context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        toView.animator.frame = bounds;
        if (fromView && fromView != toView) { fromView.animator.frame = centerRect; }
    } completionHandler:^{
        if (fromView && fromView != toView) { [fromView removeFromSuperview]; }
        self.running = NO; self.progress = 1.0f; self.currentTransition = nil;
        if (completion) completion();
    }];
}
@end
