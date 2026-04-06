//
//  WLAudioResample.h
//  WorkLabs
//
//  Created by erfeixia on 2026/4/6.
//

#import <Foundation/Foundation.h>
#import <libavcodec/avcodec.h>
#import <libswresample/swresample.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLAudioResample : NSObject
/// 初始化重采样器，锁定输出格式（AudioQueue 期望的格式）
/// @param sampleRate 目标采样率 (例如 44100)
/// @param channelLayout 目标声道布局 (例如 AV_CH_LAYOUT_STEREO)
/// @param sampleFormat 目标采样格式 (例如 AV_SAMPLE_FMT_S16)
- (instancetype)initWithOutSampleRate:(int)sampleRate
                     outChannelLayout:(int64_t)channelLayout
                      outSampleFormat:(enum AVSampleFormat)sampleFormat;

/// 将解码后的 AVFrame 重采样为目标格式
/// @param frame FFmpeg 解码输出的原始帧
/// @return 包含目标 PCM 格式数据的 NSData（交错格式连续内存）
- (nullable NSData *)resampleFrame:(AVFrame *)frame;
/// 重置重采样器缓冲区，通常在 Seek 或停止播放时调用
- (void)reset;
@end

NS_ASSUME_NONNULL_END
