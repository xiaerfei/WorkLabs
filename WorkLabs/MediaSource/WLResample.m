//
//  WLResample.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import "WLResample.h"

#import <libswresample/swresample.h>
#import <libavutil/opt.h>
#import <libavutil/error.h>

@interface WLResample () {
    SwrContext *_swrContext;
    int64_t _inputChannelLayout;
    int64_t _outputChannelLayout;
    BOOL _isPlanarInput;
    BOOL _isPlanarOutput;
    AudioStreamBasicDescription _outputFormatDesc;

    // 时间追踪
    int64_t _processedInputSamples;
    int64_t _processedOutputSamples;
    double _baseTimestamp;          // 初始时间戳（秒）
    double _lastReportedTime;       // 上次报告的时间

    // 统计信息
    UInt64 _totalInputSamples;
    UInt64 _totalOutputSamples;
    UInt32 _bufferTooSmallCount;
    UInt32 _truncationCount;

    // 缓冲区管理
    UInt8 *_scratchBuffer;          // 临时缓冲区用于多遍处理
    UInt32 _scratchBufferSize;
}

@end

@implementation WLResample
#pragma mark - 初始化与配置

- (instancetype)initWithInputSampleRate:(int)inputRate
                      inputSampleFormat:(enum AVSampleFormat)inputFormat
                      inputChannelCount:(int)inputChannels
                       outputSampleRate:(int)outputRate
                      outputSampleFormat:(enum AVSampleFormat)outputFormat
                      outputChannelCount:(int)outputChannels {
    self = [super init];
    if (self) {
        _inputSampleRate = inputRate;
        _outputSampleRate = outputRate;
        _inputSampleFormat = inputFormat;
        _outputSampleFormat = outputFormat;
        _inputChannels = inputChannels;
        _outputChannels = outputChannels;
        
        if (av_sample_fmt_is_planar(_outputSampleFormat)) {
            _outputSampleFormat = av_get_packed_sample_fmt(AV_SAMPLE_FMT_S16);
            NSLog(@"Forced output format to packed: %s",
                  av_get_sample_fmt_name(_outputSampleFormat));
        }
        
        _isPlanarInput = av_sample_fmt_is_planar(inputFormat);
        _isPlanarOutput = av_sample_fmt_is_planar(outputFormat);
        
        _inputChannelLayout = av_get_default_channel_layout(inputChannels);
        if (_inputChannelLayout == 0) {
            _inputChannelLayout = AV_CH_LAYOUT_STEREO;
            NSLog(@"Warning: Using default stereo layout for input");
        }
        
        _outputChannelLayout = av_get_default_channel_layout(outputChannels);
        if (_outputChannelLayout == 0) {
            _outputChannelLayout = AV_CH_LAYOUT_STEREO;
            NSLog(@"Warning: Using default stereo layout for output");
        }
        _timeSyncMode = MXTimeSyncHybrid;
        _resizePolicy = WLResampleResizePolicyTruncate; // 默认安全截断策略

        // 初始化统计信息
        _totalInputSamples = 0;
        _totalOutputSamples = 0;
        _bufferTooSmallCount = 0;
        _truncationCount = 0;

        // 初始化临时缓冲区
        _scratchBuffer = NULL;
        _scratchBufferSize = 0;

        // 初始化输出音频格式描述
        [self setupOutputFormatDescription];

        if (![self setupSwrContext]) {
            return nil;
        }

        NSLog(@"Resampler initialized: %s", [self description].UTF8String);
    }
    return self;
}

- (void)setupOutputFormatDescription {
    memset(&_outputFormatDesc, 0, sizeof(_outputFormatDesc));
    
    _outputFormatDesc.mSampleRate = _outputSampleRate;
    _outputFormatDesc.mFormatID = kAudioFormatLinearPCM;
    _outputFormatDesc.mChannelsPerFrame = _outputChannels;
    _outputFormatDesc.mFramesPerPacket = 1;
    
    switch (_outputSampleFormat) {
        case AV_SAMPLE_FMT_S16:
        case AV_SAMPLE_FMT_S16P:
            _outputFormatDesc.mBitsPerChannel = 16;
            _outputFormatDesc.mFormatFlags = kAudioFormatFlagIsSignedInteger;
            break;
            
        case AV_SAMPLE_FMT_FLT:
        case AV_SAMPLE_FMT_FLTP:
            _outputFormatDesc.mBitsPerChannel = 32;
            _outputFormatDesc.mFormatFlags = kAudioFormatFlagIsFloat;
            break;
            
        default:
            NSLog(@"Unsupported output sample format: %d", _outputSampleFormat);
            _outputFormatDesc.mBitsPerChannel = 16;
            _outputFormatDesc.mFormatFlags = kAudioFormatFlagIsSignedInteger;
            break;
    }
    
    _outputFormatDesc.mBytesPerFrame = (_outputFormatDesc.mBitsPerChannel / 8) * _outputFormatDesc.mChannelsPerFrame;
    _outputFormatDesc.mBytesPerPacket = _outputFormatDesc.mBytesPerFrame * _outputFormatDesc.mFramesPerPacket;
    
    _bytesPerOutputFrame = _outputFormatDesc.mBytesPerFrame;
}

- (BOOL)setupSwrContext {
    if (_swrContext) {
        swr_free(&_swrContext);
        _swrContext = NULL;
    }
    
    _swrContext = swr_alloc();
    if (!_swrContext) {
        NSLog(@"Failed to allocate SwrContext");
        return NO;
    }
    
    // 设置输入参数
    av_opt_set_int(_swrContext, "in_channel_layout", _inputChannelLayout, 0);
    av_opt_set_int(_swrContext, "in_sample_rate", _inputSampleRate, 0);
    av_opt_set_sample_fmt(_swrContext, "in_sample_fmt", _inputSampleFormat, 0);
    
    // 设置输出参数
    av_opt_set_int(_swrContext, "out_channel_layout", _outputChannelLayout, 0);
    av_opt_set_int(_swrContext, "out_sample_rate", _outputSampleRate, 0);
    av_opt_set_sample_fmt(_swrContext, "out_sample_fmt", _outputSampleFormat, 0);
    
    // 高质量重采样配置
    av_opt_set_int(_swrContext, "filter_size", 32, 0);
    av_opt_set_double(_swrContext, "cutoff", 0.97, 0);
    av_opt_set_int(_swrContext, "linear_interp", 1, 0);
    
    // 初始化
    int ret = swr_init(_swrContext);
    if (ret < 0) {
        NSLog(@"Failed to initialize SwrContext: %s", av_err2str(ret));
        swr_free(&_swrContext);
        _swrContext = NULL;
        return NO;
    }
    
    return YES;
}

- (double)playbackPosition {
    switch (_timeSyncMode) {
        case MXTimeSyncOutputStrict:
            return (double)_processedOutputSamples / _outputSampleRate;
            
        case MXTimeSyncInputReference: {
            int64_t delay = swr_get_delay(_swrContext, _inputSampleRate);
            return ((double)_processedInputSamples - delay) / _inputSampleRate;
        }
            
        case MXTimeSyncHybrid:
        default: {
            // 混合模式：取两种方法的加权平均
            double outputTime = (double)_processedOutputSamples / _outputSampleRate;
            int64_t delay = swr_get_delay(_swrContext, _inputSampleRate);
            double inputTime = ((double)_processedInputSamples - delay) / _inputSampleRate;
            
            // 当差异较大时倾向于输出时间
            if (fabs(outputTime - inputTime) > 0.1) {
                return outputTime;
            }
            return (outputTime + inputTime) * 0.5;
        }
    }
}

- (double)latency {
    // 总延迟 = 重采样延迟 + 缓冲延迟
    double resampleLatency = (double)swr_get_delay(_swrContext, _inputSampleRate) / _inputSampleRate;
    double bufferLatency = (double)(_processedInputSamples - _processedOutputSamples * _inputSampleRate / _outputSampleRate) / _inputSampleRate;
    
    return resampleLatency + bufferLatency;
}

- (void)synchronizeWithTimestamp:(double)timestamp {
    _baseTimestamp = timestamp - self.playbackPosition;
}

- (double)synchronizedPlaybackTime {
    return _baseTimestamp + self.playbackPosition;
}
#pragma mark - 核心功能

- (int)resampleFrame:(AVFrame *)inputFrame
          intoBuffer:(AudioQueueBufferRef)outBuffer
           outFrames:(UInt32 *)outFrames
              outPts:(int64_t *)outPts {

    // 使用新的实现，保持向后兼容
    NSError *error = nil;
    void *outputData = outBuffer->mAudioData;
    UInt32 outputSamples = 0;
    UInt32 capacity = outBuffer->mAudioDataBytesCapacity;

    UInt32 bytesWritten = [self resampleFrame:inputFrame
                                   outputData:&outputData
                                outputSamples:&outputSamples
                               outputCapacity:capacity
                                        error:&error];

    if (bytesWritten == 0 && error) {
        // 转换错误码
        WLResampleError errCode = (WLResampleError)error.code;
        switch (errCode) {
            case WLResampleErrorInvalidFormat:
                return AVERROR(EINVAL);
            case WLResampleErrorBufferTooSmall:
                return AVERROR(ENOSPC);
            case WLResampleErrorNoMemory:
                return AVERROR(ENOMEM);
            default:
                return AVERROR(EINVAL);
        }
    }

    // 设置输出参数
    outBuffer->mAudioDataByteSize = bytesWritten;
    *outFrames = outputSamples;

    // 计算输出PTS
    if (outPts) {
        *outPts = av_rescale_q(inputFrame->pts,
                              (AVRational){1, _inputSampleRate},
                              (AVRational){1, _outputSampleRate});
    }

    return 0;
}

- (int)flushIntoBuffer:(AudioQueueBufferRef)outBuffer
             outFrames:(UInt32 *)outFrames
                outPts:(int64_t *)outPts {

    // 使用新的实现，保持向后兼容
    NSError *error = nil;
    void *outputData = outBuffer->mAudioData;
    UInt32 outputSamples = 0;
    UInt32 capacity = outBuffer->mAudioDataBytesCapacity;

    UInt32 bytesWritten = [self flushToOutputData:&outputData
                                    outputSamples:&outputSamples
                                   outputCapacity:capacity
                                            error:&error];

    if (bytesWritten == 0 && error) {
        // 转换错误码
        WLResampleError errCode = (WLResampleError)error.code;
        switch (errCode) {
            case WLResampleErrorInvalidFormat:
                return AVERROR(EINVAL);
            case WLResampleErrorBufferTooSmall:
                return AVERROR(ENOSPC);
            case WLResampleErrorNoMemory:
                return AVERROR(ENOMEM);
            default:
                return AVERROR(EINVAL);
        }
    }

    // 设置输出参数
    outBuffer->mAudioDataByteSize = bytesWritten;
    *outFrames = outputSamples;

    // 计算输出PTS
    if (outPts) {
        int64_t delay = swr_get_delay(_swrContext, _inputSampleRate);
        *outPts = av_rescale_q(delay,
                             (AVRational){1, _inputSampleRate},
                             (AVRational){1, _outputSampleRate});
    }

    return 0;
}

- (UInt32)estimateOutputFramesForInputFrames:(UInt32)inputFrames {
    if (!_swrContext) return 0;
    
    // 计算输出样本数（考虑重采样延迟）
    int64_t delay = swr_get_delay(_swrContext, _inputSampleRate);
    int outFrames = (int)av_rescale_rnd(delay + inputFrames,
                                      _outputSampleRate, _inputSampleRate,
                                      AV_ROUND_UP);
    
    // 添加10%的安全余量
    return (UInt32)(outFrames * 1.1);
}

#pragma mark - 维护

- (void)reset {
    if (_swrContext) {
        swr_close(_swrContext);
        swr_init(_swrContext);
    }
}

- (void)dealloc {
    if (_swrContext) {
        swr_free(&_swrContext);
        _swrContext = NULL;
    }

    if (_scratchBuffer) {
        free(_scratchBuffer);
        _scratchBuffer = NULL;
        _scratchBufferSize = 0;
    }

    NSLog(@"WLResample release");
}

#pragma mark - 辅助方法

- (NSString *)description {
    return [NSString stringWithFormat:
            @"<WLResample: %p\n"
            "  Input:  %dHz, %dch, %s (%s)\n"
            "  Output: %dHz, %dch, %s (%s)\n"
            "  Output Format: %@\n"
            "  TimeSync: %@, ResizePolicy: %@\n"
            "  Stats: in=%llu, out=%llu, bufferTooSmall=%u, truncation=%u\n"
            "  Context: %s>",
            self,
            _inputSampleRate, _inputChannels,
            av_get_sample_fmt_name(_inputSampleFormat),
            _isPlanarInput ? "planar" : "packed",
            _outputSampleRate, _outputChannels,
            av_get_sample_fmt_name(_outputSampleFormat),
            _isPlanarOutput ? "planar" : "packed",
            [self outputFormatDescriptionString],
            [self timeSyncModeString],
            [self resizePolicyString],
            _totalInputSamples, _totalOutputSamples,
            _bufferTooSmallCount, _truncationCount,
            _swrContext ? "valid" : "NULL"];
}

- (NSString *)outputFormatDescriptionString {
    return [NSString stringWithFormat:
            @"ASBD: rate=%.0f, ch=%u, bits=%u, flags=0x%X, bytes/frame=%u",
            _outputFormatDesc.mSampleRate,
            _outputFormatDesc.mChannelsPerFrame,
            _outputFormatDesc.mBitsPerChannel,
            _outputFormatDesc.mFormatFlags,
            _outputFormatDesc.mBytesPerFrame];
}

#pragma mark - 属性访问

- (UInt64)totalInputSamples {
    return _totalInputSamples;
}

- (UInt64)totalOutputSamples {
    return _totalOutputSamples;
}

- (UInt32)bufferTooSmallCount {
    return _bufferTooSmallCount;
}

- (UInt32)truncationCount {
    return _truncationCount;
}

#pragma mark - 新的重采样方法实现

- (UInt32)resampleFrame:(AVFrame *)inputFrame
             outputData:(void **)outputData
          outputSamples:(UInt32 *)outputSamples
         outputCapacity:(UInt32)capacity
                  error:(NSError **)error {

    if (!_swrContext || !inputFrame || !outputData || !outputSamples) {
        if (error) *error = [self errorWithCode:WLResampleErrorInvalidFormat
                                         message:@"Invalid parameters"];
        return 0;
    }

    // 验证输入帧参数
    if (inputFrame->sample_rate != _inputSampleRate ||
        inputFrame->format != _inputSampleFormat ||
        inputFrame->channels != _inputChannels) {
        if (error) *error = [self errorWithCode:WLResampleErrorInvalidFormat
                                         message:@"Input frame doesn't match resampler configuration"];
        return 0;
    }

    // 估计所需输出大小
    int64_t delay = swr_get_delay(_swrContext, _inputSampleRate);
    int64_t estimated = av_rescale_rnd(delay + inputFrame->nb_samples,
                                      _outputSampleRate, _inputSampleRate,
                                      AV_ROUND_UP);
    UInt32 requiredBytes = (UInt32)estimated * _bytesPerOutputFrame;

    // 检查缓冲区是否足够
    if (requiredBytes > capacity) {
        _bufferTooSmallCount++;

        switch (_resizePolicy) {
            case WLResampleResizePolicyError:
                if (error) *error = [self errorWithCode:WLResampleErrorBufferTooSmall
                                                 message:@"Output buffer too small"];
                return 0;

            case WLResampleResizePolicyTruncate:
                return [self safeResampleFrame:inputFrame
                                    outputData:outputData
                                 outputSamples:outputSamples
                                outputCapacity:capacity
                                         error:error];

            case WLResampleResizePolicyMultiplePass:
                return [self multiPassResampleFrame:inputFrame
                                         outputData:outputData
                                      outputSamples:outputSamples
                                     outputCapacity:capacity
                                              error:error];

            case WLResampleResizePolicyAutoExpand:
                // 注意：此策略需要调用者支持缓冲区扩展
                // 这里我们回退到安全截断
                return [self safeResampleFrame:inputFrame
                                    outputData:outputData
                                 outputSamples:outputSamples
                                outputCapacity:capacity
                                         error:error];

            default:
                if (error) *error = [self errorWithCode:WLResampleErrorInternal
                                                 message:@"Unknown resize policy"];
                return 0;
        }
    }

    // 执行正常重采样
    return [self internalResampleFrame:inputFrame
                            outputData:outputData
                         outputSamples:outputSamples
                        outputCapacity:capacity
                                 error:error];
}

- (UInt32)safeResampleFrame:(AVFrame *)inputFrame
                 outputData:(void **)outputData
              outputSamples:(UInt32 *)outputSamples
             outputCapacity:(UInt32)capacity
                      error:(NSError **)error {

    // 计算最大可输出的样本数
    UInt32 maxOutputSamples = capacity / _bytesPerOutputFrame;
    if (maxOutputSamples == 0) {
        if (error) *error = [self errorWithCode:WLResampleErrorBufferTooSmall
                                         message:@"Output buffer has no capacity"];
        return 0;
    }

    // 执行重采样，但限制输出大小
    uint8_t *outData[AV_NUM_DATA_POINTERS] = {0};
    outData[0] = (uint8_t *)*outputData;

    uint8_t **inData = inputFrame->extended_data ? inputFrame->extended_data : inputFrame->data;

    int samplesConverted = swr_convert(_swrContext,
                                      outData,
                                      maxOutputSamples,
                                      (const uint8_t **)inData,
                                      inputFrame->nb_samples);

    if (samplesConverted < 0) {
        if (error) *error = [self errorWithCode:WLResampleErrorInternal
                                         message:[NSString stringWithFormat:@"Resampling failed: %s", av_err2str(samplesConverted)]];
        return 0;
    }

    // 如果转换的样本数小于请求数，说明有数据被丢弃
    if (samplesConverted < maxOutputSamples) {
        _truncationCount++;
    }

    *outputSamples = (UInt32)samplesConverted;
    UInt32 bytesWritten = samplesConverted * _bytesPerOutputFrame;

    // 更新统计
    _totalInputSamples += inputFrame->nb_samples;
    _totalOutputSamples += samplesConverted;
    _processedInputSamples += inputFrame->nb_samples;
    _processedOutputSamples += samplesConverted;

    return bytesWritten;
}

- (UInt32)multiPassResampleFrame:(AVFrame *)inputFrame
                      outputData:(void **)outputData
                   outputSamples:(UInt32 *)outputSamples
                  outputCapacity:(UInt32)capacity
                           error:(NSError **)error {

    // 此方法需要临时缓冲区，这里简化为单次处理
    // 实际实现应该分多次处理大帧，但需要更复杂的逻辑
    // 目前先使用安全截断策略
    NSLog(@"WLResample: Multi-pass resampling not fully implemented, using safe truncation");
    return [self safeResampleFrame:inputFrame
                        outputData:outputData
                     outputSamples:outputSamples
                    outputCapacity:capacity
                             error:error];
}

- (UInt32)internalResampleFrame:(AVFrame *)inputFrame
                     outputData:(void **)outputData
                  outputSamples:(UInt32 *)outputSamples
                 outputCapacity:(UInt32)capacity
                          error:(NSError **)error {

    uint8_t *outData[AV_NUM_DATA_POINTERS] = {0};
    outData[0] = (uint8_t *)*outputData;

    uint8_t **inData = inputFrame->extended_data ? inputFrame->extended_data : inputFrame->data;

    // 计算可用的输出样本数
    UInt32 availableOutputSamples = capacity / _bytesPerOutputFrame;

    int samplesConverted = swr_convert(_swrContext,
                                      outData,
                                      availableOutputSamples,
                                      (const uint8_t **)inData,
                                      inputFrame->nb_samples);

    if (samplesConverted < 0) {
        if (error) *error = [self errorWithCode:WLResampleErrorInternal
                                         message:[NSString stringWithFormat:@"Resampling failed: %s", av_err2str(samplesConverted)]];
        return 0;
    }

    *outputSamples = (UInt32)samplesConverted;
    UInt32 bytesWritten = samplesConverted * _bytesPerOutputFrame;

    // 更新统计
    _totalInputSamples += inputFrame->nb_samples;
    _totalOutputSamples += samplesConverted;
    _processedInputSamples += inputFrame->nb_samples;
    _processedOutputSamples += samplesConverted;

    return bytesWritten;
}

- (UInt32)flushToOutputData:(void **)outputData
              outputSamples:(UInt32 *)outputSamples
             outputCapacity:(UInt32)capacity
                      error:(NSError **)error {

    if (!_swrContext || !outputData || !outputSamples) {
        if (error) *error = [self errorWithCode:WLResampleErrorInvalidFormat
                                         message:@"Invalid parameters"];
        return 0;
    }

    // 计算剩余样本
    int64_t delay = swr_get_delay(_swrContext, _inputSampleRate);
    if (delay <= 0) {
        *outputSamples = 0;
        return 0;
    }

    // 计算可用的输出样本数
    UInt32 availableOutputSamples = capacity / _bytesPerOutputFrame;
    if (availableOutputSamples == 0) {
        if (error) *error = [self errorWithCode:WLResampleErrorBufferTooSmall
                                         message:@"Output buffer has no capacity"];
        return 0;
    }

    uint8_t *outData[AV_NUM_DATA_POINTERS] = {0};
    outData[0] = (uint8_t *)*outputData;

    // 用NULL输入触发刷新
    int samplesConverted = swr_convert(_swrContext,
                                     outData, availableOutputSamples,
                                     NULL, 0);

    if (samplesConverted < 0) {
        if (error) *error = [self errorWithCode:WLResampleErrorInternal
                                         message:[NSString stringWithFormat:@"Flush failed: %s", av_err2str(samplesConverted)]];
        return 0;
    }

    *outputSamples = (UInt32)samplesConverted;
    UInt32 bytesWritten = samplesConverted * _bytesPerOutputFrame;

    // 更新输出样本统计
    _totalOutputSamples += samplesConverted;
    _processedOutputSamples += samplesConverted;

    return bytesWritten;
}

#pragma mark - 估计与配置

- (UInt32)estimateBufferSizeForInputFrames:(UInt32)inputFrames {
    if (!_swrContext) return 0;

    int64_t delay = swr_get_delay(_swrContext, _inputSampleRate);
    int outFrames = (int)av_rescale_rnd(delay + inputFrames,
                                      _outputSampleRate, _inputSampleRate,
                                      AV_ROUND_UP);

    // 添加20%的安全余量
    UInt32 estimatedFrames = (UInt32)(outFrames * 1.2);
    return estimatedFrames * _bytesPerOutputFrame;
}

- (BOOL)isFormatCompatibleWithInputFrame:(AVFrame *)frame {
    if (!frame) return NO;

    return (frame->sample_rate == _inputSampleRate &&
            frame->format == _inputSampleFormat &&
            frame->channels == _inputChannels);
}

- (BOOL)reconfigureWithInputSampleRate:(int)inputRate
                     inputSampleFormat:(enum AVSampleFormat)inputFormat
                     inputChannelCount:(int)inputChannels
                      outputSampleRate:(int)outputRate
                     outputSampleFormat:(enum AVSampleFormat)outputFormat
                     outputChannelCount:(int)outputChannels {

    // 如果参数相同，不需要重新配置
    if (inputRate == _inputSampleRate &&
        inputFormat == _inputSampleFormat &&
        inputChannels == _inputChannels &&
        outputRate == _outputSampleRate &&
        outputFormat == _outputSampleFormat &&
        outputChannels == _outputChannels) {
        return YES;
    }

    // 更新属性
    _inputSampleRate = inputRate;
    _inputSampleFormat = inputFormat;
    _inputChannels = inputChannels;
    _outputSampleRate = outputRate;
    _outputSampleFormat = outputFormat;
    _outputChannels = outputChannels;

    // 重新设置输出格式描述
    [self setupOutputFormatDescription];

    // 重新配置重采样上下文
    return [self setupSwrContext];
}

#pragma mark - 辅助方法

- (NSError *)errorWithCode:(WLResampleError)code message:(NSString *)message {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: message ?: @""};
    return [NSError errorWithDomain:@"WLResample" code:code userInfo:userInfo];
}

@end
