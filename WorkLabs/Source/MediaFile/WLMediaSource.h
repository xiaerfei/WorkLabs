//
//  WLMediaSource.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include "libavutil/frame.h"
#import "WLStreamSourceProtocol.h"

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSUInteger, WLMediaSourceState) {
    /// 初始化 FFmpeg
    WLMediaSourceStateCfgFFmpeg,
    /// 初始化 FFmpeg 失败
    WLMediaSourceStateCfgFFmpegFailed,
    /// 开始读取视频文件
    WLMediaSourceStateReadVideo,
    /// 退出
    WLMediaSourceStateExit
};

@interface WLMediaSource : NSObject <WLStreamSourceProtocol>
@property (nonatomic,   copy, readonly) NSString *path;
@property (nonatomic, assign, readonly) WLMediaSourceState state;
@property (nonatomic, assign, readonly) Float64 totalDuration;

// 循环播放：YES 时播放到结尾自动 seek 回开头继续（默认 YES）
@property (nonatomic, assign) BOOL loopEnabled;

// 当前播放位置（秒，文件内归一化时间；循环时回绕到 0）。供进度条回显，原子读。
@property (atomic, readonly) Float64 currentTime;

// 跳转到指定位置（秒，文件内时间）。线程安全：仅置请求标志，由 parse 线程异步执行。
- (void)seekTo:(Float64)seconds;

- (instancetype)initWithPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
