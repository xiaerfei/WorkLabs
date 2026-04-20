//
//  WLSceneManagerView.m
//  WorkLabs
//
//  Created by erfeixia on 20/04/2026.
//

#import "WLSceneManagerView.h"
#import "WLSceneManager.h"
#import "WLScene.h"
#import "WLSceneView.h"
#import <Masonry/Masonry.h>
#import <Quartz/Quartz.h>

static const NSTimeInterval kTransitionDuration = 0.3;

#pragma mark - WLSceneManagerView

@interface WLSceneManagerView ()

@property (nonatomic, strong, readwrite) WLSceneManager *sceneManager;
@property (nonatomic, strong, readwrite, nullable) WLSceneView *currentSceneView;
@property (nonatomic, strong) NSMutableDictionary<NSString *, WLSceneView *> *sceneViewCache;

@end

@implementation WLSceneManagerView

#pragma mark - Init

- (instancetype)initWithSceneManager:(WLSceneManager *)sceneManager {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _sceneManager = sceneManager;
        _sceneViewCache = [NSMutableDictionary dictionary];
        
        [self setupView];
        [self setupNotifications];
        
        NSLog(@"[WLSceneManagerView] 初始化完成");
    }
    return self;
}

- (void)setupView {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 通知监听

- (void)setupNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSceneChanged:)
                                                 name:@"WLSceneDidChangeNotification"
                                               object:nil];
}

- (void)handleSceneChanged:(NSNotification *)notification {
    WLScene *scene = notification.object;
    if (scene == self.sceneManager.currentScene) {
        [self switchToSceneViewForScene:scene animated:YES];
    }
}

#pragma mark - 场景切换

- (void)switchToSceneViewForScene:(WLScene *)scene animated:(BOOL)animated {
    if (!scene) {
        return;
    }
    
    // 检查缓存
    WLSceneView *sceneView = self.sceneViewCache[scene.name];
    if (!sceneView) {
        sceneView = [[WLSceneView alloc] initWithScene:scene];
        self.sceneViewCache[scene.name] = sceneView;
    }
    
    [self switchToSceneView:sceneView animated:animated];
}

- (void)switchToSceneView:(WLSceneView *)sceneView animated:(BOOL)animated {
    if (sceneView == self.currentSceneView) {
        return;
    }
    
    WLSceneView *previousView = self.currentSceneView;
    
    if (!animated || !previousView) {
        // 直接切换
        [previousView removeFromSuperview];
        [self addSubview:sceneView];
        sceneView.frame = self.bounds;
        [sceneView startRendering];
        self.currentSceneView = sceneView;
        
        NSLog(@"[WLSceneManagerView] 切换到场景: %@", sceneView.scene.name);
    } else {
        // 带动画切换
        sceneView.alphaValue = 0;
        sceneView.frame = self.bounds;
        [self addSubview:sceneView];
        
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = kTransitionDuration;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            sceneView.animator.alphaValue = 1.0;
            previousView.animator.alphaValue = 0.0;
        } completionHandler:^{
            [previousView stopRendering];
            [previousView removeFromSuperview];
            [sceneView startRendering];
        }];
        
        self.currentSceneView = sceneView;
        
        NSLog(@"[WLSceneManagerView] 切换到场景 (动画): %@", sceneView.scene.name);
    }
}

#pragma mark - 场景视图缓存

- (WLSceneView *)sceneViewForScene:(WLScene *)scene {
    return self.sceneViewCache[scene.name];
}

- (void)removeSceneViewForScene:(WLScene *)scene {
    WLSceneView *sceneView = self.sceneViewCache[scene.name];
    if (sceneView) {
        [sceneView stopRendering];
        [sceneView removeFromSuperview];
        [self.sceneViewCache removeObjectForKey:scene.name];
    }
}

#pragma mark - 布局

- (void)layout {
    [super layout];
    self.currentSceneView.frame = self.bounds;
}

- (BOOL)isFlipped {
    return NO;
}

#pragma mark - Description

- (NSString *)description {
    return [NSString stringWithFormat:@"<WLSceneManagerView | current=%@ | cached=%lu>",
            self.currentSceneView ? self.currentSceneView.scene.name : @"(无)",
            (unsigned long)self.sceneViewCache.count];
}

@end
