//
//  WLSceneManagerView.m
//  WorkLabs
//

#import "WLSceneManagerView.h"

@interface WLSceneManagerView ()
@property (nonatomic, strong, readwrite) NSView *backgroundView;
@property (nonatomic, strong, readwrite) NSView *contentView;
@property (nonatomic, strong, readwrite) NSView *transitionView;
@end

@implementation WLSceneManagerView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) { [self setupSubviews]; }
    return self;
}

- (void)setupSubviews {
    self.wantsLayer = YES; self.layer.masksToBounds = YES;
    _backgroundView = [[NSView alloc] initWithFrame:self.bounds];
    _backgroundView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _backgroundView.wantsLayer = YES; _backgroundView.layer.backgroundColor = [NSColor blackColor].CGColor;
    [self addSubview:_backgroundView];
    _contentView = [[NSView alloc] initWithFrame:self.bounds];
    _contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _contentView.wantsLayer = YES;
    [self addSubview:_contentView];
    _transitionView = [[NSView alloc] initWithFrame:self.bounds];
    _transitionView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _transitionView.wantsLayer = YES; _transitionView.hidden = YES;
    [self addSubview:_transitionView];
}

- (void)setContentView:(nullable NSView *)view {
    for (NSView *subview in self.contentView.subviews.copy) { [subview removeFromSuperview]; }
    if (view) {
        view.frame = self.contentView.bounds;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.contentView addSubview:view];
    }
}

- (void)clearContentView { [self setContentView:nil]; }

- (void)transitionFromView:(nullable NSView *)fromView toView:(nullable NSView *)toView transition:(WLTransition *)transition {
    if (!toView) return;
    if (!transition || !fromView) { [self setContentView:toView]; return; }
    [self setContentView:toView];
}

- (void)setBackgroundColor:(NSColor *)color { self.backgroundView.layer.backgroundColor = color.CGColor ?: [NSColor blackColor].CGColor; }

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    self.backgroundView.frame = bounds;
    self.contentView.frame = bounds;
    self.transitionView.frame = bounds;
}

@end
