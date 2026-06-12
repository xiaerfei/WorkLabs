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

// 设置某路增益（1.0=原始；<1 减小，>1 放大）。混音时该路样本乘以此增益。
- (void)setGain:(float)gain forInput:(NSString *)inputID;

// 读取某路当前电平（最近一拍混音中该路增益后的样本峰值，线性 0~1+）；
// 无数据 / 断流 / 输入不存在时为 0。供 UI 电平表轮询，转 dBFS = 20·log10(level)。
- (float)peakLevelForInput:(NSString *)inputID;

// 写入某路 PCM（任意采样率/声道，Float32 或 S16 交错）；内部重采样进该路环形缓冲。
- (void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer forInput:(NSString *)inputID;

- (void)start;  // 启动混音输出定时器
- (void)stop;   // 停止定时器并释放所有输入

// 调试：模拟「所有音频源断流」N 秒（期间丢弃所有 writeSampleBuffer 输入），
// 使 mixOnce 走补静音路径，用于验证断流补静音 / A/V 同步。N<=0 取消。
- (void)debugSimulateGapForSeconds:(NSTimeInterval)seconds;

@end

NS_ASSUME_NONNULL_END
