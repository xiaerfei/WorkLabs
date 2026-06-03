//
//  WLAudioRenderer.h
//  WorkLabs
//
//  音频播放器 — 接收 LPCM CMSampleBufferRef 即时播放（AudioQueue）。
//  首帧到达时按其 formatDescription 配置队列，自动适配采样率/声道/格式。
//  音画同步依赖源端按真实时间节流输出，本播放器只负责即时播放。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLAudioRenderer : NSObject

@property (nonatomic, assign) float volume; // 0.0 ~ 1.0，默认 1.0

// 即时播放一段 PCM 音频；调用方保留 sampleBuffer 所有权（内部仅拷贝数据）
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;

- (void)flush;  // 丢弃排队中的音频
- (void)stop;   // 停止并释放队列

@end

NS_ASSUME_NONNULL_END
