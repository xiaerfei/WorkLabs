//
//  WLImageMediaSource.h
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//
//  静态图片媒体源 —— 实现 WLMediaSourceProvider 协议

#import <Foundation/Foundation.h>
#import "WLMediaSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

/**
 WLImageMediaSource —— 静态图片媒体源
 
 将 NSImage 解码为 CVPixelBuffer，作为持续输出的视频帧。
 适用于图片叠加、背景图层等场景。
 */
@interface WLImageMediaSource : NSObject <WLMediaSourceProvider>

/**
 使用图片文件路径创建图片媒体源
 
 @param filePath 图片文件路径
 @return 实例，如果文件无法加载返回 nil
 */
- (nullable instancetype)initWithFilePath:(NSString *)filePath;

/**
 使用 NSImage 创建图片媒体源
 
 @param image 图片对象
 @return 实例
 */
- (instancetype)initWithImage:(NSImage *)image;

@end

NS_ASSUME_NONNULL_END
