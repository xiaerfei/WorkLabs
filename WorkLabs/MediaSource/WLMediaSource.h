//
//  WLMediaSource.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
typedef struct AVFrame AVFrame;

NS_ASSUME_NONNULL_BEGIN

@class WLMediaSource;

@protocol WLMediaSourceDelegate <NSObject>
@optional
/// 视频帧回调，在渲染线程调用
- (void)mediaSource:(WLMediaSource *)source didOutputVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
/// 音频帧回调，在渲染线程调用，消费者需自行处理 frame 的生命周期
- (void)mediaSource:(WLMediaSource *)source didOutputAudioFrame:(AVFrame *)frame pts:(Float64)pts;
@end

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
@property (nonatomic,   weak) id<WLMediaSourceDelegate> delegate;

- (instancetype)initWithPath:(NSString *)path;

- (void)start;
@end

NS_ASSUME_NONNULL_END
