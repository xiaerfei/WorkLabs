//
//  WLFFmpegMediaSource.h
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//
//  FFmpeg 媒体源 —— 实现自 WLMediaSourceProvider 协议
//  负责打开媒体文件、解码音视频帧、通过协议对外提供帧数据

#import "WLMediaSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLFFmpegMediaSource : NSObject <WLMediaSourceProvider>

/// 媒体文件路径
@property (nonatomic, copy, readonly) NSString *path;

/// 是否正在运行
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

/**
 通过文件路径初始化 FFmpeg 媒体源
 
 @param path 媒体文件路径（本地文件或网络流地址）
 @return 实例对象
 */
- (instancetype)initWithPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
