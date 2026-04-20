//
//  WLSceneManager.h
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//
//  场景管理器 —— 管理所有场景的生命周期（创建、删除、切换）
//  参考: OBS架构设计.md §1

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "WLScene.h"

@class WLTransition;
@class WLSceneManagerView;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - WLSceneManager

/**
 WLSceneManager —— 场景管理器

 负责管理应用中所有场景的创建、删除、切换操作。
 是场景系统的顶层入口，外部通过此对象与场景系统交互。

 使用方式：
 1. 初始化（可传入容器视图）
 2. createSceneWithName: 创建新场景
 3. switchToScene: 切换当前活跃场景
 4. removeScene: 删除不需要的场景

 当前阶段实现：
 - ✅ 场景 CRUD 管理
 - ✅ 当前场景跟踪
 - ✅ WLSceneManagerView 容器视图
 - ⏳ 场景切换转场动画（稍后实现）
 */
@interface WLSceneManager : NSObject

/// 所有已创建的场景
@property (nonatomic, strong, readonly) NSArray<WLScene *> *scenes;

/// 当前活跃场景
@property (nonatomic, strong, readonly, nullable) WLScene *currentScene;

/// 默认画布尺寸（新建场景时使用）
@property (nonatomic, assign) CGSize defaultCanvasSize;

/// 场景管理器视图（容器视图，由 managerView 提供）
@property (nonatomic, strong, readonly, nullable) WLSceneManagerView *managerView;

/**
 通过容器视图初始化场景管理器

 @param containerView 用于承载场景视图的容器（稍后绑定 WLSceneManagerView）
 @return 实例对象
 */
- (instancetype)initWithContainerView:(nullable NSView *)containerView NS_DESIGNATED_INITIALIZER;

/**
 获取或创建绑定到容器视图的 WLSceneManagerView

 如果已有绑定的视图且容器相同，直接返回；否则创建新视图并绑定。

 @param containerView 容器视图
 @return WLSceneManagerView 实例
 */
- (WLSceneManagerView *)getManagerViewWithContainerView:(NSView *)containerView;

- (instancetype)init NS_UNAVAILABLE;

#pragma mark - 标识符生成

/**
 生成一个全局唯一的媒体源标识符

 @return 精确到毫秒的时间戳字符串，格式如 "1745086200000"
 */
- (NSString *)generateIdentifier;

#pragma mark - 单例

/**
 获取共享实例（用于生成全局唯一 identifier）
 
 @warning 仅用于 identifier 生成，不要用于场景管理
 */
+ (instancetype)shared;

#pragma mark - 场景管理

/**
 创建新场景并自动添加到场景列表
 
 @param name 场景名称
 @return 新创建的场景实例
 */
- (WLScene *)createSceneWithName:(NSString *)name;

/**
 创建新场景并指定画布尺寸
 
 @param name 场景名称
 @param size 画布尺寸
 @return 新创建的场景实例
 */
- (WLScene *)createSceneWithName:(NSString *)name canvasSize:(CGSize)size;

/**
 移除并销毁一个场景
 
 如果被移除的是当前场景，会自动切换到第一个可用场景（如有）。
 
 @param scene 要移除的场景
 */
- (void)removeScene:(WLScene *)scene;

/**
 切换到目标场景
 
 @param scene 要切换到的目标场景
 */
- (void)switchToScene:(WLScene *)scene;

/**
 带转场效果切换到目标场景
 
 @param scene      要切换到的目标场景
 @param transition 转场效果配置（nil 表示无动画直接切换）
 */
- (void)switchToScene:(WLScene *)scene withTransition:(nullable WLTransition *)transition;

@end

NS_ASSUME_NONNULL_END
