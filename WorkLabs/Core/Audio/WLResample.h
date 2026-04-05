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

// 重采样错误码
typedef NS_ENUM(NSInteger, WLResampleError) {
    WLResampleErrorNoMemory = -1,
    WLResampleErrorInvalidFormat = -2,
    WLResampleErrorBufferTooSmall = -3,  // 缓冲区不足（第256行问题）
    WLResampleErrorInternal = -4
};

// 缓冲区不足处理策略
typedef NS_ENUM(NSUInteger, WLResampleResizePolicy) {
    WLResampleResizePolicyError,        // 返回错误
    WLResampleResizePolicyTruncate,     // 安全截断，只填充可用空间
    WLResampleResizePolicyMultiplePass, // 多遍处理，分多次处理大帧
    WLResampleResizePolicyAutoExpand    // 自动扩展缓冲区（不适用于固定缓冲区）
};

@interface WLResample : NSObject

#pragma mark - 初始化方法
- (instancetype)initWithInputSampleRate:(int)inputRate
                      inputSampleFormat:(enum AVSampleFormat)inputFormat
                      inputChannelCount:(int)inputChannels
                       outputSampleRate:(int)outputRate
                      outputSampleFormat:(enum AVSampleFormat)outputFormat
                      outputChannelCount:(int)outputChannels;

#pragma mark - 核心重采样方法

/// 重采样帧到 AudioQueueBuffer (兼容现有接口)
- (int)resampleFrame:(AVFrame *)inputFrame
          intoBuffer:(AudioQueueBufferRef)outBuffer
           outFrames:(UInt32 *)outFrames
              outPts:(int64_t *)outPts;

/// 新的重采样方法，支持灵活的输出缓冲区
/// @param inputFrame 输入帧
/// @param outputData 输出数据指针
/// @param outputSamples 输出样本数
/// @param capacity 输出缓冲区容量（字节）
/// @param error 错误输出
/// @return 实际输出的字节数，0表示错误
- (UInt32)resampleFrame:(AVFrame *)inputFrame
             outputData:(void **)outputData
          outputSamples:(UInt32 *)outputSamples
         outputCapacity:(UInt32)capacity
                  error:(NSError **)error;

/// 安全重采样方法：自动处理缓冲区不足
- (UInt32)safeResampleFrame:(AVFrame *)inputFrame
                 outputData:(void **)outputData
              outputSamples:(UInt32 *)outputSamples
             outputCapacity:(UInt32)capacity
                      error:(NSError **)error;

/// 多遍重采样方法：分多次处理大帧
- (UInt32)multiPassResampleFrame:(AVFrame *)inputFrame
                      outputData:(void **)outputData
                   outputSamples:(UInt32 *)outputSamples
                  outputCapacity:(UInt32)capacity
                           error:(NSError **)error;

#pragma mark - 刷新操作

/// 刷新重采样器内部缓冲区到 AudioQueueBuffer
- (int)flushIntoBuffer:(AudioQueueBufferRef)outBuffer
             outFrames:(UInt32 *)outFrames
                outPts:(int64_t *)outPts;

/// 新的刷新方法，支持灵活的输出缓冲区
- (UInt32)flushToOutputData:(void **)outputData
              outputSamples:(UInt32 *)outputSamples
             outputCapacity:(UInt32)capacity
                      error:(NSError **)error;

#pragma mark - 估计与配置

/// 获取输出帧数估计
- (UInt32)estimateOutputFramesForInputFrames:(UInt32)inputFrames;

/// 估计重采样后所需缓冲区大小（字节）
- (UInt32)estimateBufferSizeForInputFrames:(UInt32)inputFrames;

/// 检查格式兼容性
- (BOOL)isFormatCompatibleWithInputFrame:(AVFrame *)frame;

#pragma mark - 属性访问

@property (nonatomic, readonly) int inputSampleRate;
@property (nonatomic, readonly) enum AVSampleFormat inputSampleFormat;
@property (nonatomic, readonly) int inputChannels;
@property (nonatomic, readonly) int outputSampleRate;
@property (nonatomic, readonly) enum AVSampleFormat outputSampleFormat;
@property (nonatomic, readonly) int outputChannels;
@property (nonatomic, readonly) UInt32 bytesPerOutputFrame;

@property (nonatomic) MXTimeSyncMode timeSyncMode;
@property (nonatomic, assign) WLResampleResizePolicy resizePolicy;
@property (nonatomic, readonly) double playbackPosition; // 当前播放位置（秒）
@property (nonatomic, readonly) double latency;         // 当前总延迟（秒）

#pragma mark - 统计信息

@property (nonatomic, readonly) UInt64 totalInputSamples;
@property (nonatomic, readonly) UInt64 totalOutputSamples;
@property (nonatomic, readonly) UInt32 bufferTooSmallCount;
@property (nonatomic, readonly) UInt32 truncationCount;

#pragma mark - 维护

/// 重置重采样器状态（不清除配置）
- (void)reset;

/// 重新配置重采样器参数
- (BOOL)reconfigureWithInputSampleRate:(int)inputRate
                     inputSampleFormat:(enum AVSampleFormat)inputFormat
                     inputChannelCount:(int)inputChannels
                      outputSampleRate:(int)outputRate
                     outputSampleFormat:(enum AVSampleFormat)outputFormat
                     outputChannelCount:(int)outputChannels;

@end

NS_ASSUME_NONNULL_END
