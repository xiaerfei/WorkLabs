//
//  WLSceneViewController.h
//  WorkLabs
//

#import <Cocoa/Cocoa.h>

@class WLSceneManager;

NS_ASSUME_NONNULL_BEGIN

@interface WLSceneViewController : NSViewController

/// 关联的场景管理器
@property (nonatomic, weak, nullable) WLSceneManager *sceneManager;

/// 刷新场景中所有预览视图的布局
- (void)reloadScene;

@end

NS_ASSUME_NONNULL_END
