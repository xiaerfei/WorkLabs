//
//  WLEncoder.h
//  WorkLabs
//
//  共享编码器 —— 把合成画面（BGRA CVPixelBuffer）与混音（Float32 PCM CMSampleBuffer）
//  各编码一次（h264_videotoolbox + aac_at），输出统一为微秒时间基的 WLEncodedPacket，
//  经 packetOutput 分发给多个 muxer（录制 mp4 / 推流 flv）。编一次、分发多路。
//
//  · 单调墙钟时间轴：视频与音频共享同一 epoch（首个媒体样本到达时锚定），消除 A/V 固定偏移。
//  · realtime=1 始终开（推流低延迟优先；max_b_frames=0 本无 B 帧前瞻，对录制影响可忽略）。
//  · 统一 AV_CODEC_FLAG_GLOBAL_HEADER：产 avcC + global extradata，mp4 与 flv 都直接接受。
//  · 一次性对象：start 全新分配 / stop 全 teardown，不跨会话复用；调用方每次会话新建。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@class WLEncoderConfig;
@class WLEncodedPacket;

NS_ASSUME_NONNULL_BEGIN

@interface WLEncoder : NSObject

@property (atomic, assign, readonly, getter=isRunning) BOOL running;

// 编码后包的分发回调（在编码器自己的串行 queue 上同步调用）。
// 调用方应在此把包投递到各 muxer 的 queue（包是不可变 OC 对象，跨 queue 共享安全）。
@property (nonatomic, copy, nullable) void (^packetOutput)(WLEncodedPacket *packet);

// 启动编码器；videoSize 为画布尺寸，config 提供码率/关键帧间隔/帧率/音频码率。
// audioEnabled=YES 时建立 AAC 路（由 appendAudioSampleBuffer: 喂入）。
- (BOOL)startWithVideoSize:(CGSize)videoSize
                    config:(WLEncoderConfig *)config
              audioEnabled:(BOOL)audioEnabled;

// 追加一帧合成画面 / 一段混音；内部异步编码，调用方保留自身所有权（内部各自 retain）。
- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

// 请求下一帧强制为关键帧（IDR）—— 供 muxer 中途加入时快速对齐 GOP 起点。
- (void)requestKeyframe;

// 停止：flush 编码器（残包仍经 packetOutput 派发）→ teardown → 在编码器 queue 上回调 completion。
// completion 内通常依次投递各 muxer 的收尾（async 到 muxer queue，FIFO 自动排在残包之后）。
- (void)stopWithCompletion:(nullable void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
