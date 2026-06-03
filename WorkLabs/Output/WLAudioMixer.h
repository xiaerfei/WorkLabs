//
//  WLAudioMixer.h
//  WorkLabs
//
//  多路音频混音器 — 各路 PCM 经 swresample 统一为 44.1kHz/立体声/Float32，
//  写入各自 lock-free 环形缓冲；一个定时器按固定帧长(1024 样本)从各路取样相加、
//  限幅后输出一路混音 LPCM CMSampleBufferRef（供播放 + 录制）。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLAudioMixer : NSObject

// 混音输出（44.1kHz / 立体声 / Float32 交错 LPCM）。所有权转移给 block（需 CFRelease）。
@property (nonatomic, copy, nullable) void (^mixedOutput)(CMSampleBufferRef sampleBuffer);

// 注册 / 注销一路输入（inputID 唯一标识，如 source 的 streamID）
- (void)addInput:(NSString *)inputID;
- (void)removeInput:(NSString *)inputID;

// 写入某路 PCM（任意采样率/声道，Float32 或 S16 交错）；内部重采样进该路环形缓冲。
- (void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer forInput:(NSString *)inputID;

- (void)start;  // 启动混音输出定时器
- (void)stop;   // 停止定时器并释放所有输入

@end

NS_ASSUME_NONNULL_END
