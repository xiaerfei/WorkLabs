//
//  WLScene.h
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//
//  场景 —— 包含多个媒体源，代表一个可切换的"画布"
//  参考: OBS架构设计.md §2

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import "WLMediaSourceProvider.h"
#import "WLSourceLayout.h"

@class WLMediaMixer;
@class WLSceneView;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - WLScene

/**
 WLScene —— 场景类
 
 代表一个独立的"画布"，可以包含多个媒体源（视频/音频）。
 
 使用方式：
 1. 通过 WLSceneManager 创建场景
 2. 使用 addSource:atRect: 添加媒体源并指定位置
 3. 场景切换时由 WLSceneManager 统一管理
 
 当前阶段实现：
 - ✅ 添加/移除媒体源
 - ✅ 布局信息管理
 - ⏳ WLSceneView（稍后实现）
 - ⏳ renderFrame 视频合成（稍后实现）
 */
@interface WLScene : NSObject

/// 场景名称（用于 UI 展示和标识）
@property (nonatomic, copy) NSString *name;

/// 画布尺寸（像素）
@property (nonatomic, assign) CGSize canvasSize;

/// 所有媒体源（只读外部访问，内部通过 addSource/removeSource 管理）
@property (nonatomic, strong, readonly) NSArray<id<WLMediaSourceProvider>> *sources;

/// 各媒体源的布局信息映射（key = source.identifier）
@property (nonatomic, strong, readonly) NSDictionary<NSString *, WLSourceLayout *> *sourceLayouts;

/// 场景视图（稍后实现）
@property (nonatomic, strong, readonly, nullable) WLSceneView *sceneView;

/// 音频混音器（稍后实现）
@property (nonatomic, strong, nullable) WLMediaMixer *audioMixer;

/**
 通过名称和画布尺寸初始化场景
 
 @param name 场景名称
 @param size 画布尺寸（像素），如 CGSizeMake(1920, 1080)
 @return 实例对象
 */
- (instancetype)initWithName:(NSString *)name canvasSize:(CGSize)size NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

#pragma mark - 媒体源管理

/**
 向场景添加媒体源
 
 @param source 实现 WLMediaSourceProvider 协议的媒体源
 @param rect   媒体源在画布中的初始位置和大小
 */
- (void)addSource:(id<WLMediaSourceProvider>)source atRect:(CGRect)rect;

/**
 从场景移除媒体源（会自动调用 source.stop）
 
 @param source 要移除的媒体源
 */
- (void)removeSource:(id<WLMediaSourceProvider>)source;

#pragma mark - 查询

/**
 根据媒体源标识符获取其布局信息

 @param identifier 媒体源的 identifier
 @return 对应的布局信息；未找到返回 nil
 */
- (nullable WLSourceLayout *)layoutForIdentifier:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
