//
//  WLSceneManager.m
//  WorkLabs
//

#import "WLSceneManager.h"

@interface WLSceneManager ()
@property (nonatomic, strong, readwrite) WLSceneManagerView *managerView;
@property (nonatomic, strong, nullable, readwrite) WLScene *currentScene;
@property (nonatomic, strong, readwrite) NSMutableArray<WLScene *> *scenes;
@end

@implementation WLSceneManager

- (instancetype)initWithContainerView:(NSView *)containerView canvasSize:(CGSize)size {
    self = [super init];
    if (self) {
        _scenes = [NSMutableArray array];
        _defaultCanvasSize = size;
        _managerView = [[WLSceneManagerView alloc] initWithFrame:containerView.bounds];
        _managerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [containerView addSubview:_managerView];
    }
    return self;
}

- (instancetype)initWithContainerView:(NSView *)containerView { return [self initWithContainerView:containerView canvasSize:CGSizeMake(1920, 1080)]; }

- (WLScene *)createSceneWithName:(NSString *)name { return [self createSceneWithName:name canvasSize:self.defaultCanvasSize]; }

- (WLScene *)createSceneWithName:(NSString *)name canvasSize:(CGSize)size {
    static NSInteger sceneCount = 0;
    NSString *sceneName = name ?: [NSString stringWithFormat:@"Scene %ld", ++sceneCount];
    NSMutableSet *existingNames = [NSMutableSet setWithArray:[self sceneNames]];
    if ([existingNames containsObject:sceneName]) {
        NSInteger suffix = 1;
        while ([existingNames containsObject:[NSString stringWithFormat:@"%@ %ld", sceneName, suffix]]) { suffix++; }
        sceneName = [NSString stringWithFormat:@"%@ %ld", sceneName, suffix];
    }
    WLScene *scene = [[WLScene alloc] initWithName:sceneName canvasSize:size];
    [self.scenes addObject:scene];
    if (!self.currentScene) { [self switchToScene:scene]; }
    return scene;
}

- (void)removeScene:(WLScene *)scene {
    if (!scene || ![self.scenes containsObject:scene]) return;
    [scene stop];
    [self.scenes removeObject:scene];
    if (self.currentScene == scene) {
        self.currentScene = self.scenes.firstObject;
        if (self.currentScene) { [self.managerView setContentView:self.currentScene.sceneView]; }
        else { [self.managerView clearContentView]; }
    }
}

- (void)switchToScene:(WLScene *)scene { [self switchToScene:scene withTransition:nil]; }

- (void)switchToScene:(WLScene *)scene withTransition:(nullable WLTransition *)transition {
    if (!scene || ![self.scenes containsObject:scene]) return;
    WLScene *previousScene = self.currentScene;
    if (previousScene && previousScene != scene) { [previousScene stop]; }
    self.currentScene = scene;
    [scene start];
    if (transition && previousScene && previousScene != scene) {
        [self.managerView transitionFromView:previousScene.sceneView toView:scene.sceneView transition:transition];
    } else { [self.managerView setContentView:scene.sceneView]; }
}

- (NSArray<NSString *> *)sceneNames {
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:self.scenes.count];
    for (WLScene *scene in self.scenes) { [names addObject:scene.name]; }
    return [names copy];
}

@end
