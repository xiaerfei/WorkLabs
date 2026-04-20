//
//  WLSceneManagerView.h
//  WorkLabs
//
//  Created by erfeixia on 20/04/2026.
//
//  场景管理器视图 —— 容器视图，管理场景切换显示
//  参考: TaskPlan.md

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class WLSceneManager;
@class WLSceneView;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - WLSceneManagerView

/**
 WLSceneManagerView —— 场景管理器视图

 作为场景系统的容器视图：
 1. 持有 WLSceneManager 实例
 2. 显示当前活跃场景的 WLSceneView
 3. 处理场景切换动画

 使用方式：
 1. 通过 initWithSceneManager: 初始化
 2. 视图自动监听场景切换并更新显示
 */
@interface WLSceneManagerView : NSView

/// 关联的场景管理器
@property (nonatomic, strong, readonly) WLSceneManager *sceneManager;

/// 当前显示的场景视图
@property (nonatomic, strong, readonly, nullable) WLSceneView *currentSceneView;

/**
 通过场景管理器初始化

 @param sceneManager 关联的场景管理器
 @return 视图实例
 */
- (instancetype)initWithSceneManager:(WLSceneManager *)sceneManager NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

#pragma mark - 场景切换

/**
 切换到指定场景（带动画）

 @param sceneView 要显示的场景视图
 @param animated 是否有动画效果
 */
- (void)switchToSceneView:(WLSceneView *)sceneView animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END