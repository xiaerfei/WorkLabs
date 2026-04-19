//
//  WLSceneManager.m
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//

#import "WLSceneManager.h"

@interface WLSceneManager ()

@property (nonatomic, strong, readwrite) NSArray<WLScene *> *scenes;
@property (nonatomic, strong, readwrite, nullable) WLScene *currentScene;

@property (nonatomic, strong) NSMutableArray<WLScene *> *mutableScenes;
@property (nonatomic, weak, nullable) NSView *containerView;

@end

@implementation WLSceneManager

static WLSceneManager *_sharedInstance = nil;

#pragma mark - 单例

+ (instancetype)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[self alloc] init];
    });
    return _sharedInstance;
}

#pragma mark - 初始化

- (instancetype)initWithContainerView:(NSView *)containerView {
    self = [super init];
    if (self) {
        _containerView = containerView;
        _mutableScenes = [NSMutableArray array];
        _scenes = @[];
        _defaultCanvasSize = CGSizeMake(1920, 1080);
        
        NSLog(@"[WLSceneManager] 初始化完成，默认画布: %.0fx%.0f",
              _defaultCanvasSize.width, _defaultCanvasSize.height);
    }
    return self;
}

#pragma mark - 标识符生成

- (NSString *)generateIdentifier {
    @synchronized (self) {
        int64_t timestamp = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000);
        return [NSString stringWithFormat:@"%lld", timestamp];
    }
}

#pragma mark - 场景管理

- (WLScene *)createSceneWithName:(NSString *)name {
    return [self createSceneWithName:name canvasSize:self.defaultCanvasSize];
}

- (WLScene *)createSceneWithName:(NSString *)name canvasSize:(CGSize)size {
    NSParameterAssert(name.length > 0);
    
    // 检查重名
    for (WLScene *scene in self.mutableScenes) {
        if ([scene.name isEqualToString:name]) {
            NSLog(@"[WLSceneManager] 已存在同名场景 \"%@\"，跳过创建", name);
            return scene;
        }
    }
    
    WLScene *scene = [[WLScene alloc] initWithName:name canvasSize:size];
    [self.mutableScenes addObject:scene];
    self.scenes = [self.mutableScenes copy];
    
    // 第一个场景自动设为当前场景
    if (!self.currentScene) {
        [self switchToScene:scene];
    }
    
    NSLog(@"[WLSceneManager] 创建场景: \"%@\" (%.0fx%.0f)，当前共 %lu 个场景",
          name, size.width, size.height, (unsigned long)self.scenes.count);
    
    return scene;
}

- (void)removeScene:(WLScene *)scene {
    NSParameterAssert(scene);
    
    if (![self.mutableScenes containsObject:scene]) {
        NSLog(@"[WLSceneManager] 场景 \"%@\" 不在管理列表中，跳过移除", scene.name);
        return;
    }
    
    NSString *removedName = scene.name;
    
    // 如果是当前场景，需要先切换
    BOOL wasCurrent = (scene == self.currentScene);
    
    [self.mutableScenes removeObject:scene];
    self.scenes = [self.mutableScenes copy];
    
    if (wasCurrent) {
        // 自动切换到第一个可用场景
        self.currentScene = self.scenes.firstObject;
        NSLog(@"[WLSceneManager] 当前场景已移除，切换到: %@",
              self.currentScene ? self.currentScene.name : @"(无)");
    }
    
    NSLog(@"[WLSceneManager] 已移除场景: \"%@\"，剩余 %lu 个场景",
          removedName, (unsigned long)self.scenes.count);
}

- (void)switchToScene:(WLScene *)scene {
    [self switchToScene:scene withTransition:nil];
}

- (void)switchToScene:(WLScene *)scene withTransition:(nullable WLTransition *)transition {
    NSParameterAssert(scene);
    
    if (![self.mutableScenes containsObject:scene]) {
        NSLog(@"[WLSceneManager] 场景 \"%@\" 不在管理列表中，无法切换", scene.name);
        return;
    }
    
    if (scene == self.currentScene) {
        NSLog(@"[WLSceneManager] 场景 \"%@\" 已经是当前活跃场景，跳过切换", scene.name);
        return;
    }
    
    WLScene *previousScene = self.currentScene;
    self.currentScene = scene;
    
    // TODO: 稍后实现转场动画
    if (transition) {
        NSLog(@"[WLSceneManager] 切转场动画将在后续实现");
    }
    
    NSLog(@"[WLSceneManager] 场景切换: \"%@\" → \"%@\"",
          previousScene ? previousScene.name : @"(无)", scene.name);
}

#pragma mark - Description

- (NSString *)description {
    return [NSString stringWithFormat:@"<WLSceneManager | current=%@ | scenes=%lu>",
            self.currentScene ? self.currentScene.name : @"(无)",
            (unsigned long)self.scenes.count];
}

@end
