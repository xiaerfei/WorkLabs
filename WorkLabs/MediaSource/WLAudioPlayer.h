//
//  WLAudioPlayer.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/24.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libswresample/swresample.h>

NS_ASSUME_NONNULL_BEGIN

@class WLAudioPlayer;
@class WLMediaSource;

/// 播放模式
typedef NS_ENUM(NSUInteger, WLAudioPlayerMode) {
    /// 代理模式：通过 WLMediaSourceDelegate 接收 AVFrame
    WLAudioPlayerModeDelegate,
    /// 缓冲模式：外部写入 PCM 数据到缓冲区
    WLAudioPlayerModeBuffer,
    /// 直接模式：AudioUnit 回调时由代理直接提供数据
    WLAudioPlayerModeDirect
};

/// 播放状态
typedef NS_ENUM(NSUInteger, WLAudioPlayerState) {
    WLAudioPlayerStateStopped,
    WLAudioPlayerStatePlaying,
    WLAudioPlayerStatePaused
};

@protocol WLAudioPlayerDelegate <NSObject>
@optional
/// Direct 模式下，AudioUnit 需要数据时回调
/// @param player 播放器实例
/// @param buffer 目标缓冲区，由代理填充 PCM 数据
/// @param length 请求的字节数
/// @param pts 输出时间戳
/// @return 实际提供的字节数
- (UInt32)audioPlayer:(WLAudioPlayer *)player
    requestAudioData:(void *)buffer
              length:(UInt32)length
                 pts:(Float64 *)pts;

/// 播放状态变化通知
- (void)audioPlayer:(WLAudioPlayer *)player didChangeState:(WLAudioPlayerState)state;

/// 缓冲区下溢通知
- (void)audioPlayerDidUnderrun:(WLAudioPlayer *)player;

/// 播放错误通知
- (void)audioPlayer:(WLAudioPlayer *)player didEncounterError:(NSError *)error;
@end

/// 音频播放器，支持三种使用模式
/// - Delegate 模式：与 WLMediaSource 集成，接收解码后的 AVFrame
/// - Buffer 模式：外部直接写入 PCM 数据
/// - Direct 模式：AudioUnit 回调时由代理提供数据
@interface WLAudioPlayer : NSObject

@property (nonatomic, weak, nullable) id<WLAudioPlayerDelegate> delegate;
@property (nonatomic, assign, readonly) WLAudioPlayerMode mode;
@property (nonatomic, assign, readonly) WLAudioPlayerState state;
@property (nonatomic, assign, readonly) BOOL isPlaying;

/// 当前播放位置（秒）
@property (nonatomic, assign, readonly) Float64 currentPTS;

/// 音量控制 (0.0 ~ 1.0)
@property (nonatomic, assign) Float32 volume;

#pragma mark - 初始化

/// 使用指定输出格式和模式初始化
/// @param format 输出音频格式
/// @param mode 播放模式
- (instancetype)initWithOutputFormat:(AudioStreamBasicDescription)format
                                mode:(WLAudioPlayerMode)mode;

/// 使用默认格式初始化（44100Hz, 2ch, Float32, Delegate 模式）
- (instancetype)init;

#pragma mark - 播放控制

/// 开始播放
- (BOOL)start;

/// 停止播放
- (void)stop;

/// 暂停播放
- (void)pause;

/// 恢复播放
- (void)resume;

#pragma mark - Buffer 模式接口

/// 写入 PCM 数据到缓冲区（Buffer 模式专用）
/// @param data PCM 数据指针
/// @param length 数据长度（字节）
/// @param pts 时间戳（秒）
- (void)enqueuePCMData:(const void *)data length:(UInt32)length pts:(Float64)pts;

#pragma mark - Delegate 模式接口（接收 AVFrame）

/// 接收解码后的音频帧（Delegate 模式专用）
/// 内部会进行重采样（如需要）并写入缓冲区
/// @param frame FFmpeg 解码后的音频帧
/// @param pts 时间戳（秒）
- (void)didReceiveAudioFrame:(AVFrame *)frame pts:(Float64)pts;

#pragma mark - 配置

/// 配置输入音频格式（Delegate 模式下，根据解码器输出配置）
/// @param sampleRate 采样率
/// @param sampleFormat FFmpeg 采样格式
/// @param channels 声道数
- (void)configureInputFormat:(int)sampleRate
                sampleFormat:(enum AVSampleFormat)sampleFormat
                    channels:(int)channels;

/// 获取输出音频格式
@property (nonatomic, readonly) AudioStreamBasicDescription outputFormat;

#pragma mark - 缓冲区状态

/// 缓冲区使用率 (0.0 ~ 1.0)
@property (nonatomic, readonly) float bufferUsage;

/// 缓冲区估计时长（秒）
@property (nonatomic, readonly) Float64 bufferDuration;

@end

NS_ASSUME_NONNULL_END
