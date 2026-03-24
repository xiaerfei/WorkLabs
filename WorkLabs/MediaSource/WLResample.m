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
    if (!_swrContext || !inputFrame || !outBuffer || !outFrames) {
        NSLog(@"Invalid parameters");
        return AVERROR(EINVAL);
    }
    
    // 验证输入帧参数
    if (inputFrame->sample_rate != _inputSampleRate ||
        inputFrame->format != _inputSampleFormat ||
        inputFrame->channels != _inputChannels) {
        NSLog(@"Input frame doesn't match resampler configuration");
        return AVERROR(EINVAL);
    }
    
    // 计算可用输出帧数
    UInt32 availableOutFrames = outBuffer->mAudioDataBytesCapacity / _bytesPerOutputFrame;
    if (availableOutFrames == 0) {
        NSLog(@"Output buffer has no capacity");
        return AVERROR(ENOSPC);
    }
    
    // 准备数据指针
    /*
        这样写的原因是, 兼容性考虑:
        当 extended_data 存在时，它总是正确的数据指针
        当 extended_data 为 NULL 时，回退到传统的 data 成员
        
        FFmpeg 内部约定:
        根据 FFmpeg 文档，当 extended_data 分配时，它应该包含与 data 相同的内容
        但 extended_data 可能有额外的指针用于额外声道
        
        data数组的限制：
        data数组仍只包含前8个声道
        必须使用extended_data访问第9+声道
        extended_data
        │
        ├──→ [0] 声道1数据 (1024个float)
        ├──→ [1] 声道2数据
        │     ...
        └──→ [15] 声道16数据
        这意味着 extended_data 包含了全部的音频数据
     
        planar:
        extended_data
        │
        ├──→ [0] 声道1数据 (1024个float)
        ├──→ [1] 声道2数据
        │     ...
        └──→ [15] 声道16数据
        interleaved:
        extended_data[0]: LRLRLRLRLRLR...
     */
    uint8_t **inData = inputFrame->extended_data ? inputFrame->extended_data : inputFrame->data;
    uint8_t *outData[AV_NUM_DATA_POINTERS] = {0};
    outData[0] = (uint8_t *)outBuffer->mAudioData;
    ///TODO: 处理当 outData 不足以容纳重采样出来的数据时，会丢失数据或者crash
    // 执行重采样
    int samplesConverted = swr_convert(_swrContext,
                                       outData,
                                       availableOutFrames,
                                       (const uint8_t **)inData,
                                       inputFrame->nb_samples);
    
    if (samplesConverted < 0) {
        NSLog(@"Resampling failed: %s", av_err2str(samplesConverted));
        *outFrames = 0;
        return samplesConverted;
    }
    
    // 设置实际填充的数据量
    outBuffer->mAudioDataByteSize = samplesConverted * _bytesPerOutputFrame;
    *outFrames = samplesConverted;
    
    // 更新时间统计
    _processedInputSamples  += inputFrame->nb_samples;
    _processedOutputSamples += samplesConverted;
    
    // 计算输出PTS
    if (outPts) {
        // 进行不同时间基（AVRational）之间的转换
        *outPts = av_rescale_q(inputFrame->pts,
                              (AVRational){1, _inputSampleRate},
                              (AVRational){1, _outputSampleRate});
    }
    
    return 0;
}

- (int)flushIntoBuffer:(AudioQueueBufferRef)outBuffer
             outFrames:(UInt32 *)outFrames
                outPts:(int64_t *)outPts {
    if (!_swrContext || !outBuffer || !outFrames) {
        return AVERROR(EINVAL);
    }
    
    // 计算剩余样本
    int64_t delay = swr_get_delay(_swrContext, _inputSampleRate);
    if (delay <= 0) {
        *outFrames = 0;
        return 0;
    }
    
    // 计算可用输出帧数
    UInt32 availableOutFrames = outBuffer->mAudioDataBytesCapacity / _bytesPerOutputFrame;
    if (availableOutFrames == 0) {
        NSLog(@"Output buffer has no capacity for flush");
        *outFrames = 0;
        return AVERROR(ENOSPC);
    }
    
    uint8_t *outData[AV_NUM_DATA_POINTERS] = {0};
    outData[0] = (uint8_t *)outBuffer->mAudioData;
    
    // 用NULL输入触发刷新
    int samplesConverted = swr_convert(_swrContext,
                                     outData, availableOutFrames,
                                     NULL, 0);
    
    if (samplesConverted < 0) {
        *outFrames = 0;
        return samplesConverted;
    }
    
    outBuffer->mAudioDataByteSize = samplesConverted * _bytesPerOutputFrame;
    *outFrames = samplesConverted;
    
    // 计算输出PTS
    if (outPts) {
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
    NSLog(@"MXResample release");
}

#pragma mark - 辅助方法

- (NSString *)description {
    return [NSString stringWithFormat:
            @"<MXResample: %p\n"
            "  Input:  %dHz, %dch, %s (%s)\n"
            "  Output: %dHz, %dch, %s (%s)\n"
            "  Output Format: %@\n"
            "  Context: %s>",
            self,
            _inputSampleRate, _inputChannels,
            av_get_sample_fmt_name(_inputSampleFormat),
            _isPlanarInput ? "planar" : "packed",
            _outputSampleRate, _outputChannels,
            av_get_sample_fmt_name(_outputSampleFormat),
            _isPlanarOutput ? "planar" : "packed",
            [self outputFormatDescriptionString],
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
@end
