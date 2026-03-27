//
//  WLAudioPlayer.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/24.
//

#import "WLAudioPlayer.h"
#import "WLAudioBuffer.h"
#import "WLResample.h"

// 默认缓冲区容量：0.5秒的 44100Hz 立体声 Float32 音频
static const UInt32 kDefaultBufferCapacity = 44100 * 2 * 4 / 2;

@interface WLAudioPlayer () <WLAudioBufferDelegate> {
    AudioUnit _audioUnit;
    AudioStreamBasicDescription _outputFormat;

    // 重采样输出临时缓冲区（预分配，避免实时线程分配内存）
    UInt8 *_resampleBuffer;
    UInt32 _resampleBufferSize;
}

@property (nonatomic, assign, readwrite) WLAudioPlayerMode mode;
@property (nonatomic, assign, readwrite) WLAudioPlayerState state;
@property (nonatomic, strong) WLAudioBuffer *audioBuffer;
@property (nonatomic, strong, nullable) WLResample *resampler;

/// 输入格式是否已配置
@property (nonatomic, assign) BOOL inputFormatConfigured;

/// 当前播放的 PTS
@property (nonatomic, assign, readwrite) Float64 currentPTS;

@end

@implementation WLAudioPlayer

#pragma mark - 初始化与销毁

- (instancetype)init {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = 44100;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 32;
    format.mBytesPerFrame = 8;
    format.mBytesPerPacket = 8;
    return [self initWithOutputFormat:format mode:WLAudioPlayerModeDelegate];
}

- (instancetype)initWithOutputFormat:(AudioStreamBasicDescription)format
                                mode:(WLAudioPlayerMode)mode {
    self = [super init];
    if (self) {
        _outputFormat = format;
        _mode = mode;
        _state = WLAudioPlayerStateStopped;
        _volume = 1.0f;
        _currentPTS = 0;

        // 创建音频缓冲区（Delegate 和 Buffer 模式需要）
        if (mode != WLAudioPlayerModeDirect) {
            UInt32 bytesPerSecond = (UInt32)(format.mSampleRate * format.mBytesPerFrame);
            UInt32 capacity = MAX(bytesPerSecond, kDefaultBufferCapacity);
            _audioBuffer = [[WLAudioBuffer alloc] initWithCapacity:capacity audioFormat:format];
            _audioBuffer.delegate = self;
            _audioBuffer.overflowPolicy = WLAudioBufferOverflowPolicyDiscardOldest;
            _audioBuffer.underflowPolicy = WLAudioBufferUnderflowPolicyFillSilence;
        }

        // 预分配重采样临时缓冲区
        _resampleBufferSize = 8192 * format.mBytesPerFrame;
        _resampleBuffer = (UInt8 *)malloc(_resampleBufferSize);

        [self setupAudioUnit];
    }
    return self;
}

- (void)dealloc {
    [self destroy];
    if (_resampleBuffer) {
        free(_resampleBuffer);
        _resampleBuffer = NULL;
    }
}

#pragma mark - AudioUnit 配置

- (void)setupAudioUnit {
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;

    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    if (!component) {
        NSLog(@"WLAudioPlayer: Failed to find audio component");
        return;
    }

    OSStatus status = AudioComponentInstanceNew(component, &_audioUnit);
    if (status != noErr) {
        NSLog(@"WLAudioPlayer: Failed to create audio unit: %d", (int)status);
        return;
    }

    // 设置音频格式
    status = AudioUnitSetProperty(_audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &_outputFormat,
                                  sizeof(_outputFormat));
    if (status != noErr) {
        NSLog(@"WLAudioPlayer: Failed to set stream format: %d", (int)status);
    }

    // 设置渲染回调
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = &AudioPlayerRenderCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)self;

    status = AudioUnitSetProperty(_audioUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input,
                                  0,
                                  &callbackStruct,
                                  sizeof(callbackStruct));
    if (status != noErr) {
        NSLog(@"WLAudioPlayer: Failed to set render callback: %d", (int)status);
    }

    status = AudioUnitInitialize(_audioUnit);
    if (status != noErr) {
        NSLog(@"WLAudioPlayer: Failed to initialize audio unit: %d", (int)status);
    }
}

#pragma mark - 播放控制

- (BOOL)start {
    if (_state == WLAudioPlayerStatePlaying) return YES;
    if (!_audioUnit) return NO;

    OSStatus status = AudioOutputUnitStart(_audioUnit);
    if (status != noErr) {
        NSLog(@"WLAudioPlayer: Failed to start: %d", (int)status);
        return NO;
    }

    self.state = WLAudioPlayerStatePlaying;
    NSLog(@"WLAudioPlayer: Started (mode=%lu)", (unsigned long)_mode);
    return YES;
}

- (void)stop {
    if (_state == WLAudioPlayerStateStopped) return;

    if (_audioUnit) {
        AudioOutputUnitStop(_audioUnit);
    }

    // 清空缓冲区
    [_audioBuffer clear];
    _currentPTS = 0;

    self.state = WLAudioPlayerStateStopped;
    NSLog(@"WLAudioPlayer: Stopped");
}

- (void)pause {
    if (_state != WLAudioPlayerStatePlaying) return;

    if (_audioUnit) {
        AudioOutputUnitStop(_audioUnit);
    }

    self.state = WLAudioPlayerStatePaused;
}

- (void)resume {
    if (_state != WLAudioPlayerStatePaused) return;

    if (_audioUnit) {
        AudioOutputUnitStart(_audioUnit);
    }

    self.state = WLAudioPlayerStatePlaying;
}

- (void)destroy {
    [self stop];
    if (_audioUnit) {
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = nil;
    }
}

- (BOOL)isPlaying {
    return _state == WLAudioPlayerStatePlaying;
}

- (void)setState:(WLAudioPlayerState)state {
    if (_state != state) {
        _state = state;
        if ([_delegate respondsToSelector:@selector(audioPlayer:didChangeState:)]) {
            [_delegate audioPlayer:self didChangeState:state];
        }
    }
}

#pragma mark - Buffer 模式接口

- (void)enqueuePCMData:(const void *)data length:(UInt32)length pts:(Float64)pts {
    if (_mode != WLAudioPlayerModeBuffer) {
        NSLog(@"WLAudioPlayer: enqueuePCMData only available in Buffer mode");
        return;
    }

    NSError *error = nil;
    [_audioBuffer writeData:data length:length pts:pts error:&error];
    if (error) {
        NSLog(@"WLAudioPlayer: Buffer write error: %@", error.localizedDescription);
    }
}

#pragma mark - Delegate 模式接口

- (void)didReceiveAudioFrame:(AVFrame *)frame pts:(Float64)pts {
    if (_mode != WLAudioPlayerModeDelegate) {
        return;
    }

    if (!frame || frame->nb_samples == 0) {
        return;
    }

    // 检查是否需要重采样
    BOOL needsResample = (frame->sample_rate != (int)_outputFormat.mSampleRate ||
                          frame->channels != (int)_outputFormat.mChannelsPerFrame ||
                          [self needsFormatConversion:frame]);

    if (needsResample) {
        [self resampleAndEnqueue:frame pts:pts];
    } else {
        // 直接写入缓冲区（packed 格式）
        UInt32 dataSize = frame->nb_samples * _outputFormat.mBytesPerFrame;
        NSError *error = nil;
        [_audioBuffer writeData:frame->data[0] length:dataSize pts:pts error:&error];
    }
}

- (void)configureInputFormat:(int)sampleRate
                sampleFormat:(enum AVSampleFormat)sampleFormat
                    channels:(int)channels {
    // 判断输出采样格式
    enum AVSampleFormat outFmt;
    if (_outputFormat.mFormatFlags & kAudioFormatFlagIsFloat) {
        outFmt = AV_SAMPLE_FMT_FLT;
    } else {
        outFmt = AV_SAMPLE_FMT_S16;
    }

    // 如果输入和输出格式一致，不需要重采样器
    BOOL needsResampler = (sampleRate != (int)_outputFormat.mSampleRate ||
                           channels != (int)_outputFormat.mChannelsPerFrame ||
                           sampleFormat != outFmt);

    if (needsResampler) {
        self.resampler = [[WLResample alloc] initWithInputSampleRate:sampleRate
                                                    inputSampleFormat:sampleFormat
                                                    inputChannelCount:channels
                                                     outputSampleRate:(int)_outputFormat.mSampleRate
                                                    outputSampleFormat:outFmt
                                                    outputChannelCount:(int)_outputFormat.mChannelsPerFrame];
        if (!_resampler) {
            NSLog(@"WLAudioPlayer: Failed to create resampler");
        }
    } else {
        self.resampler = nil;
    }

    _inputFormatConfigured = YES;
    NSLog(@"WLAudioPlayer: Input format configured: %dHz/%dch/%s, resampler=%@",
          sampleRate, channels, av_get_sample_fmt_name(sampleFormat),
          _resampler ? @"YES" : @"NO");
}

#pragma mark - 缓冲区状态

- (AudioStreamBasicDescription)outputFormat {
    return _outputFormat;
}

- (float)bufferUsage {
    return _audioBuffer.usage;
}

- (Float64)bufferDuration {
    return _audioBuffer.estimatedDuration;
}

#pragma mark - AudioUnit 渲染回调

static OSStatus AudioPlayerRenderCallback(void *inRefCon,
                                           AudioUnitRenderActionFlags *ioActionFlags,
                                           const AudioTimeStamp *inTimeStamp,
                                           UInt32 inBusNumber,
                                           UInt32 inNumberFrames,
                                           AudioBufferList *ioData) {
    WLAudioPlayer *player = (__bridge WLAudioPlayer *)inRefCon;
    if (!player || player->_state != WLAudioPlayerStatePlaying) {
        // 静音
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
        return noErr;
    }

    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        UInt32 requestedBytes = ioData->mBuffers[i].mDataByteSize;
        void *outputBuffer = ioData->mBuffers[i].mData;

        switch (player->_mode) {
            case WLAudioPlayerModeDelegate:
            case WLAudioPlayerModeBuffer: {
                // 从环形缓冲区读取
                Float64 pts = 0;
                NSError *error = nil;
                UInt32 bytesRead = [player->_audioBuffer readDataNonBlocking:outputBuffer
                                                                      length:requestedBytes
                                                                         pts:&pts
                                                                       error:&error];

                if (bytesRead > 0) {
                    player->_currentPTS = pts;
                }

                // 如果读取不足，剩余部分填充静音
                if (bytesRead < requestedBytes) {
                    memset((UInt8 *)outputBuffer + bytesRead, 0, requestedBytes - bytesRead);
                }

                // 应用音量
                if (player->_volume < 1.0f && bytesRead > 0) {
                    [player applyVolume:outputBuffer length:bytesRead];
                }
                break;
            }

            case WLAudioPlayerModeDirect: {
                // 直接模式：由代理提供数据
                Float64 pts = 0;
                UInt32 provided = 0;

                if ([player->_delegate respondsToSelector:@selector(audioPlayer:requestAudioData:length:pts:)]) {
                    provided = [player->_delegate audioPlayer:player
                                            requestAudioData:outputBuffer
                                                      length:requestedBytes
                                                         pts:&pts];
                }

                if (provided > 0) {
                    player->_currentPTS = pts;
                }

                // 不足部分填充静音
                if (provided < requestedBytes) {
                    memset((UInt8 *)outputBuffer + provided, 0, requestedBytes - provided);
                }

                // 应用音量
                if (player->_volume < 1.0f && provided > 0) {
                    [player applyVolume:outputBuffer length:provided];
                }
                break;
            }
        }
    }

    return noErr;
}

#pragma mark - WLAudioBufferDelegate

- (void)audioBuffer:(WLAudioBuffer *)buffer usageChanged:(float)usage {
    // 可用于监控
}

- (void)audioBufferOverflow:(WLAudioBuffer *)buffer discardedBytes:(UInt32)bytes {
    NSLog(@"WLAudioPlayer: Buffer overflow, discarded %u bytes", bytes);
}

- (void)audioBufferUnderflow:(WLAudioBuffer *)buffer {
    if ([_delegate respondsToSelector:@selector(audioPlayerDidUnderrun:)]) {
        [_delegate audioPlayerDidUnderrun:self];
    }
}

#pragma mark - 私有方法

- (BOOL)needsFormatConversion:(AVFrame *)frame {
    // 检查是否需要 planar -> packed 转换或采样格式转换
    if (av_sample_fmt_is_planar(frame->format)) {
        return YES;
    }

    if (_outputFormat.mFormatFlags & kAudioFormatFlagIsFloat) {
        return (frame->format != AV_SAMPLE_FMT_FLT);
    } else {
        return (frame->format != AV_SAMPLE_FMT_S16);
    }
}

- (void)resampleAndEnqueue:(AVFrame *)frame pts:(Float64)pts {
    // 懒初始化重采样器
    if (!_resampler) {
        [self configureInputFormat:frame->sample_rate
                      sampleFormat:(enum AVSampleFormat)frame->format
                          channels:frame->channels];
    }

    if (!_resampler) {
        NSLog(@"WLAudioPlayer: No resampler available, skipping frame");
        return;
    }

    // 检查格式兼容性，如果不兼容则重新配置
    if (![_resampler isFormatCompatibleWithInputFrame:frame]) {
        [self configureInputFormat:frame->sample_rate
                      sampleFormat:(enum AVSampleFormat)frame->format
                          channels:frame->channels];
    }

    // 确保重采样缓冲区够大
    UInt32 estimatedSize = [_resampler estimateBufferSizeForInputFrames:frame->nb_samples];
    if (estimatedSize > _resampleBufferSize) {
        _resampleBufferSize = estimatedSize;
        _resampleBuffer = (UInt8 *)realloc(_resampleBuffer, _resampleBufferSize);
    }

    // 执行重采样
    void *outputData = _resampleBuffer;
    UInt32 outputSamples = 0;
    NSError *error = nil;

    UInt32 bytesWritten = [_resampler resampleFrame:frame
                                          outputData:&outputData
                                       outputSamples:&outputSamples
                                      outputCapacity:_resampleBufferSize
                                               error:&error];

    if (bytesWritten > 0) {
        [_audioBuffer writeData:outputData length:bytesWritten pts:pts error:nil];
    } else if (error) {
        NSLog(@"WLAudioPlayer: Resample error: %@", error.localizedDescription);
    }
}

- (void)applyVolume:(void *)buffer length:(UInt32)length {
    if (_outputFormat.mFormatFlags & kAudioFormatFlagIsFloat) {
        Float32 *samples = (Float32 *)buffer;
        UInt32 sampleCount = length / sizeof(Float32);
        for (UInt32 i = 0; i < sampleCount; i++) {
            samples[i] *= _volume;
        }
    } else {
        // SInt16 格式
        SInt16 *samples = (SInt16 *)buffer;
        UInt32 sampleCount = length / sizeof(SInt16);
        for (UInt32 i = 0; i < sampleCount; i++) {
            samples[i] = (SInt16)(samples[i] * _volume);
        }
    }
}

@end
