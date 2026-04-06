//
//  WLAudioResample.m
//  WorkLabs
//
//  Created by erfeixia on 2026/4/6.
//

#import "WLAudioResample.h"

@interface WLAudioResample () {
    SwrContext *_swrContext;
    
    // 固定的输出参数
    int _outSampleRate;
    int64_t _outChannelLayout;
    int _outChannels;
    enum AVSampleFormat _outSampleFormat;
    
    // 动态记录的输入参数（用于检测是否需要重新初始化）
    int _inSampleRate;
    int64_t _inChannelLayout;
    enum AVSampleFormat _inSampleFormat;
    
    // 内部维护的输出缓冲区，避免频繁 malloc
    uint8_t *_outBuffer;
    int _outBufferSize;
}

@end

@implementation WLAudioResample
- (instancetype)initWithOutSampleRate:(int)sampleRate
                     outChannelLayout:(int64_t)channelLayout
                      outSampleFormat:(enum AVSampleFormat)sampleFormat {
    self = [super init];
    if (self) {
        _outSampleRate = sampleRate;
        _outChannelLayout = channelLayout;
        _outChannels = av_get_channel_layout_nb_channels((uint64_t)channelLayout);
        _outSampleFormat = sampleFormat;
        
        _inSampleRate = 0;
        _inChannelLayout = 0;
        _inSampleFormat = AV_SAMPLE_FMT_NONE;
        
        _swrContext = NULL;
        _outBuffer = NULL;
        _outBufferSize = 0;
    }
    return self;
}

- (void)dealloc {
    if (_swrContext) {
        swr_free(&_swrContext);
    }
    if (_outBuffer) {
        av_freep(&_outBuffer); // FFmpeg 安全释放内存宏
    }
}

- (nullable NSData *)resampleFrame:(AVFrame *)frame {
    // 1. 如果上下文还没初始化，且传入的是空帧，直接返回
    if (!_swrContext && !frame) {
        return nil;
    }
    
    // 2. 如果有 frame，检测并更新输入格式
    if (frame) {
        int64_t currentInLayout = frame->channel_layout;
        if (currentInLayout == 0) {
            currentInLayout = av_get_default_channel_layout(frame->channels);
        }
        int currentInSampleRate = frame->sample_rate;
        enum AVSampleFormat currentInFormat = (enum AVSampleFormat)frame->format;
        
        if (!_swrContext ||
            _inSampleRate != currentInSampleRate ||
            _inChannelLayout != currentInLayout ||
            _inSampleFormat != currentInFormat) {
            
            if (_swrContext) {
                swr_free(&_swrContext);
            }
            
            _swrContext = swr_alloc_set_opts(NULL,
                                             _outChannelLayout, _outSampleFormat, _outSampleRate,
                                             currentInLayout, currentInFormat, currentInSampleRate,
                                             0, NULL);
            
            if (!_swrContext || swr_init(_swrContext) < 0) {
                NSLog(@"[WLResample] SwrContext 初始化失败!");
                return nil;
            }
            
            // 更新记录的输入参数
            _inSampleRate = currentInSampleRate;
            _inChannelLayout = currentInLayout;
            _inSampleFormat = currentInFormat;
        }
    }
    // 3. 计算预估输出空间
    // 如果 frame 为 NULL，则 in_samples 为 0，仅计算内部 delay 长度
    int in_nb_samples = frame ? frame->nb_samples : 0;
    int64_t delay = swr_get_delay(_swrContext, _inSampleRate);
    int64_t outSamples = av_rescale_rnd(delay + in_nb_samples,
                                        _outSampleRate,
                                        _inSampleRate,
                                        AV_ROUND_UP);
    
    // 4. 扩容输出缓冲区 (逻辑不变)
    int requiredBufferSize = av_samples_get_buffer_size(NULL,
                                                        _outChannels,
                                                        (int)outSamples,
                                                        _outSampleFormat,
                                                        1);
    
    if (!_outBuffer || _outBufferSize < requiredBufferSize) {
        _outBufferSize = requiredBufferSize;
        _outBuffer = (uint8_t *)av_realloc(_outBuffer, _outBufferSize);
    }
    
    // 5. 执行转换
    // 如果 frame 为 NULL，传入 NULL 作为输入源，通知 swr 进入 flush 模式
    const uint8_t **in_data = frame ? (const uint8_t **)frame->data : NULL;
    int realOutSamples = swr_convert(_swrContext,
                                     &_outBuffer, (int)outSamples,
                                     in_data, in_nb_samples);
    
    if (realOutSamples < 0) {
        NSLog(@"[WLResample] 重采样转换失败!");
        return nil;
    }
    
    // 6. 计算实际转换出的有效字节数
    int realBufferSize = av_samples_get_buffer_size(NULL,
                                                    _outChannels,
                                                    realOutSamples,
                                                    _outSampleFormat,
                                                    1);
    
    // 7. 包装成 NSData 返回 (此方法会复制内存，外部随意使用，内部 _outBuffer 下次循环复用)
    if (realBufferSize > 0) {
        return [NSData dataWithBytes:_outBuffer length:realBufferSize];
    }
    
    return nil;
}

/// 重置重采样器缓冲区，通常在 Seek 或停止播放时调用
- (void)reset {
    if (_swrContext) {
        // swr_init 会清除内部缓存并保留配置参数
        swr_init(_swrContext);
    }
}
@end
