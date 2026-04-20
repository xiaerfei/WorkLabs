//
//  WLSceneView.h
//  WorkLabs
//
//  Created by erfeixia on 20/04/2026.
//
//  场景视图 —— 渲染单个场景中的所有媒体源
//  参考: TaskPlan.md

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class WLScene;
@class WLMetalPreview;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - WLSceneView

/**
 WLSceneView —— 场景视图

 负责渲染单个场景中的所有媒体源：
 1. 为每个媒体源创建 WLMetalPreview
 2. 根据布局信息设置预览视图的位置和大小
 3. 启动媒体源并持续渲染视频帧

 使用方式：
 1. 通过 initWithScene: 初始化
 2. 调用 startRendering 开始渲染
 3. 调用 stopRendering 停止渲染
 */
@interface WLSceneView : NSView

/// 关联的场景
@property (nonatomic, strong, readonly) WLScene *scene;

/// 初始化

/**
 通过场景初始化视图

 @param scene 关联的场景实例
 @return 视图实例
 */
- (instancetype)initWithScene:(WLScene *)scene NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

#pragma mark - 渲染控制

/**
 开始渲染场景中的所有媒体源

 会启动所有媒体源并开始渲染视频帧。
 */
- (void)startRendering;

/**
 停止渲染场景中的所有媒体源

 会停止所有媒体源并清空预览视图。
 */
- (void)stopRendering;

/**
 刷新视图布局

 当场景的 sourceLayouts 发生变化时调用，重新计算所有预览视图的位置和大小。
 */
- (void)refreshLayout;

@end

NS_ASSUME_NONNULL_END