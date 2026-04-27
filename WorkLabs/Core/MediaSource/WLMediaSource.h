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

@interface WLMediaSource : NSObject
@property (nonatomic,   copy, readonly) NSString *path;
@property (nonatomic, assign, readonly) WLMediaSourceState state;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
@property (nonatomic, assign, readonly) Float64 totalDuration;

/// 视频帧输出回调 (CVPixelBufferRef，调用方负责释放)
@property (nonatomic, copy, nullable) void (^videoFrameOutput)(CVPixelBufferRef pixelBuffer, Float64 pts);

/// 音频帧输出回调 (AVFrame *，由调用方消费)
@property (nonatomic, copy, nullable) void (^audioFrameOutput)(AVFrame *frame, Float64 pts);

- (instancetype)initWithPath:(NSString *)path;

- (void)start;
- (void)stop;

/**
 跳转到指定时间点（单位：秒）
 可在播放过程中任意时刻调用
 */
- (void)seekToTime:(Float64)seconds;

@end

NS_ASSUME_NONNULL_END
