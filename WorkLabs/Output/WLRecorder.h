//
//  WLRecorder.h
//  WorkLabs
//
//  录制器 — 把合成画面（BGRA CVPixelBuffer）经 ffmpeg 编码（h264_videotoolbox）
//  封装为 mp4 文件；可选混入一路 AAC 音频（aac_at）。视频按真实 pts（VFR），
//  音频按累计样本数推进（44.1kHz / 立体声），两路从录制开始各自从 0 起算。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLRecorder : NSObject

@property (nonatomic, assign, readonly, getter=isRecording) BOOL recording;

// 开始录制到指定 mp4 路径；videoSize 为合成画布尺寸；
// fps 仅用于编码器 GOP/码率估算（实际时间戳按真实 pts，支持可变帧率）。
// audioEnabled=YES 时建立一路 AAC 音频流，由 appendAudioSampleBuffer: 喂入；
// 若整段录制未收到音频，则该路无数据（仍是合法 mp4）。
- (BOOL)startRecordingToPath:(NSString *)path
                   videoSize:(CGSize)videoSize
                         fps:(int)fps
                audioEnabled:(BOOL)audioEnabled
                       error:(NSError * _Nullable * _Nullable)error;

// 追加一帧合成画面（BGRA CVPixelBuffer）；内部异步编码，调用方保留自身所有权。
- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;

// 追加一段 PCM 音频（来自源的 CMSampleBufferRef，Float32 交错）；内部异步重采样+编码，
// 调用方保留自身所有权（内部会 CFRetain）。仅在 audioEnabled 录制时生效。
- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

// 停止录制（flush 编码器 + 写 trailer），同步完成。
- (void)stopRecording;

@end

NS_ASSUME_NONNULL_END
