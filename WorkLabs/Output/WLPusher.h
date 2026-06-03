//
//  WLPusher.h
//  WorkLabs
//
//  RTMP 推流器 — 把合成画面（BGRA CVPixelBuffer）与混音音频（LPCM）经 ffmpeg
//  编码（h264_videotoolbox + aac_at）封装为 FLV 推送到 rtmp:// 服务器。
//  编码/时序逻辑与 WLRecorder 一致（墙钟视频 pts + 音频 FIFO + header 延迟首视频包），
//  差异在 FLV muxer、rtmp 输出、异步连接与断流检测。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class WLPusher;

@protocol WLPusherDelegate <NSObject>
@optional
- (void)pusherDidStart:(WLPusher *)pusher;                          // 连接成功、开始推流
- (void)pusher:(WLPusher *)pusher didFailWithError:(NSError *)error; // 连接失败或推流中断
- (void)pusherDidStop:(WLPusher *)pusher;                           // 主动停止完成
@end

@interface WLPusher : NSObject

@property (nonatomic, weak) id<WLPusherDelegate> delegate;
@property (atomic, assign, readonly, getter=isPushing) BOOL pushing;

// 异步连接 rtmp 并开始推流（网络连接在后台进行，不阻塞调用线程）；结果经 delegate（主线程）回调。
- (void)startWithURL:(NSString *)url
           videoSize:(CGSize)videoSize
                 fps:(int)fps
        audioEnabled:(BOOL)audioEnabled;

// 追加一帧合成画面（BGRA CVPixelBuffer）；内部异步编码，调用方保留自身所有权。
- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;

// 追加一段 PCM 音频（混音输出，Float32 交错）；内部异步重采样+编码，调用方保留自身所有权。
- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
