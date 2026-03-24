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
extern NSString *const src_sample_fmt_key;
extern NSString *const dst_sample_fmt_key;

extern NSString *const src_sample_rate_key;
extern NSString *const dst_sample_rate_key;

extern NSString *const src_nb_channels_key;
extern NSString *const dst_nb_channels_key;


@class WLAudioPlayer;

@protocol MXAudioPlayerDelegate <NSObject>
- (AVFrame *_Nullable)audioPlayer:(WLAudioPlayer *)player requestNextFrame:(NSTimeInterval)timeout;
- (void)stopAudioPlayer:(WLAudioPlayer *)player;
@end

@interface WLAudioPlayer : NSObject
// 初始化播放器
- (instancetype)initWithParameter:(NSDictionary *)parameter;

// 开始播放 (开始索取帧)
- (void)startWithDelegate:(id<MXAudioPlayerDelegate>)delegate;

// 暂停播放
- (void)pause;

// 停止播放 (释放资源)
- (void)stop;

// 是否正在播放
@property (nonatomic, readonly) BOOL isPlaying;

// 音频参数
@property (nonatomic, readonly) int sampleRate;
@property (nonatomic, readonly) int channelLayout;
@property (nonatomic, readonly) enum AVSampleFormat sampleFormat;

// 当前播放时间 (秒)
@property (nonatomic, readonly) NSTimeInterval currentTime;
@end

NS_ASSUME_NONNULL_END
