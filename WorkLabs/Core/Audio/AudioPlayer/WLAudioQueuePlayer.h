//
//  WLAudioQueuePlayer.h
//  WorkLabs
//
//  Created by erfeixia on 2026/4/6.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <libavutil/frame.h>
#import "WLAudioResample.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLAudioQueuePlayer : NSObject

@property (nonatomic, assign) float volume; // 0.0 ~ 1.0

/// 初始化播放器
/// @param rate 采样率 (如 44100)
/// @param channels 声道数 (如 2)
- (instancetype)initWithSampleRate:(int)rate channels:(int)channels;

/// 喂入解码后的数据
- (void)putAVFrame:(AVFrame *)frame;

/// 播放控制
- (void)play;
- (void)pause;
- (void)stop;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
