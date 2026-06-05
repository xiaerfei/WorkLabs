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

- (instancetype)initWithPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
