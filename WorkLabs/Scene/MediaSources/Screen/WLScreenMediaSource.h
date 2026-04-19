//
//  WLScreenMediaSource.h
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//
//  屏幕捕获媒体源 —— 实现 WLMediaSourceProvider 协议

#import <Foundation/Foundation.h>
#import "WLMediaSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

/**
 WLScreenMediaSource —— 屏幕录制媒体源
 
 使用 CGWindowListCreateImage / SCStreamCaptureOutput 捕获屏幕内容。
 使用方式:
 1. initWithDisplayID: 创建实例
 2. start / stop 控制采集
 3. nextVideoFrame 获取视频帧
 */
@interface WLScreenMediaSource : NSObject <WLMediaSourceProvider>

/** 显示器 ID (CGDirectDisplayID) */
@property (nonatomic, assign, readonly) uint32_t displayID;

/** 是否捕获鼠标光标 */
@property (nonatomic, assign) BOOL showCursor;

/**
 使用指定显示器创建屏幕捕获媒体源
 
 @param displayID CGDirectDisplayID
 @return 实例
 */
- (instancetype)initWithDisplayID:(uint32_t)displayID;

@end

NS_ASSUME_NONNULL_END
