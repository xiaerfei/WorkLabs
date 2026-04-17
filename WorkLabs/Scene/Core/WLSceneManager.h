//
//  WLSceneManager.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "WLScene.h"
#import "WLSceneManagerView.h"
#import "WLTransitionEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLSceneManager : NSObject
@property (nonatomic, strong, readonly) WLSceneManagerView *managerView;
@property (nonatomic, strong, nullable) WLScene *currentScene;
@property (nonatomic, strong, readonly) NSMutableArray<WLScene *> *scenes;
@property (nonatomic, assign) CGSize defaultCanvasSize;
- (instancetype)initWithContainerView:(NSView *)containerView canvasSize:(CGSize)size;
- (instancetype)initWithContainerView:(NSView *)containerView;
- (WLScene *)createSceneWithName:(NSString *)name;
- (WLScene *)createSceneWithName:(NSString *)name canvasSize:(CGSize)size;
- (void)removeScene:(WLScene *)scene;
- (void)switchToScene:(WLScene *)scene;
- (void)switchToScene:(WLScene *)scene withTransition:(nullable WLTransition *)transition;
- (NSArray<NSString *> *)sceneNames;
@end

NS_ASSUME_NONNULL_END
