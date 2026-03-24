//
//  WLResample.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import <Foundation/Foundation.h>
#import <libavutil/samplefmt.h>
#import <libavutil/channel_layout.h>
#import <libavformat/avformat.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN
// 时间同步模式
typedef NS_ENUM(NSUInteger, MXTimeSyncMode) {
    MXTimeSyncOutputStrict,    // 严格按输出样本计算
    MXTimeSyncInputReference,  // 以输入为基准减去延迟
    MXTimeSyncHybrid           // 混合模式（推荐）
};
@interface WLResample : NSObject
// 初始化方法
- (instancetype)initWithInputSampleRate:(int)inputRate
                      inputSampleFormat:(enum AVSampleFormat)inputFormat
                      inputChannelCount:(int)inputChannels
                       outputSampleRate:(int)outputRate
                      outputSampleFormat:(enum AVSampleFormat)outputFormat
                      outputChannelCount:(int)outputChannels;

// 核心重采样方法 (直接填充到 AudioQueueBuffer)
- (int)resampleFrame:(AVFrame *)inputFrame
          intoBuffer:(AudioQueueBufferRef)outBuffer
           outFrames:(UInt32 *)outFrames
              outPts:(int64_t *)outPts;

// 刷新重采样器内部缓冲区到 AudioQueueBuffer
- (int)flushIntoBuffer:(AudioQueueBufferRef)outBuffer
             outFrames:(UInt32 *)outFrames
                outPts:(int64_t *)outPts;

// 获取输出帧数估计
- (UInt32)estimateOutputFramesForInputFrames:(UInt32)inputFrames;

// 属性访问
@property (nonatomic, readonly) int inputSampleRate;
@property (nonatomic, readonly) enum AVSampleFormat inputSampleFormat;
@property (nonatomic, readonly) int inputChannels;
@property (nonatomic, readonly) int outputSampleRate;
@property (nonatomic, readonly) enum AVSampleFormat outputSampleFormat;
@property (nonatomic, readonly) int outputChannels;
@property (nonatomic, readonly) UInt32 bytesPerOutputFrame;

@property (nonatomic) MXTimeSyncMode timeSyncMode;
@property (nonatomic, readonly) double playbackPosition; // 当前播放位置（秒）
@property (nonatomic, readonly) double latency;         // 当前总延迟（秒）
@end

NS_ASSUME_NONNULL_END
