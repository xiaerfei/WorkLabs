//
//  WLRecorder.h
//  WorkLabs
//
//  录制器 — 把合成画面（BGRA CVPixelBuffer）经 ffmpeg 编码（h264_videotoolbox）
//  封装为 mp4 文件。本阶段仅视频；时间戳按真实 pts（VFR）。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLRecorder : NSObject

@property (nonatomic, assign, readonly, getter=isRecording) BOOL recording;

// 开始录制到指定 mp4 路径；videoSize 为合成画布尺寸；
// fps 仅用于编码器 GOP/码率估算（实际时间戳按真实 pts，支持可变帧率）。
- (BOOL)startRecordingToPath:(NSString *)path
                   videoSize:(CGSize)videoSize
                         fps:(int)fps
                       error:(NSError * _Nullable * _Nullable)error;

// 追加一帧合成画面（BGRA CVPixelBuffer）；内部异步编码，调用方保留自身所有权。
- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;

// 停止录制（flush 编码器 + 写 trailer），同步完成。
- (void)stopRecording;

@end

NS_ASSUME_NONNULL_END
