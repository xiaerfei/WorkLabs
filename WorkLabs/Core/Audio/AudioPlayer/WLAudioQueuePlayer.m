//
//  WLAudioQueuePlayer.m
//  WorkLabs
//
//  Created by erfeixia on 2026/4/6.
//

#import "WLAudioQueuePlayer.h"
#import "TPCircularBuffer.h"

#define kQueueBufferCount 3      // 队列缓冲区数量
#define kQueueBufferSize 8192    // 单个缓冲区大小 (8KB)
#define kCircleBufferSize 512*1024 // 环形缓冲区总大小 (512KB)

@interface WLAudioQueuePlayer () {
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _buffers[kQueueBufferCount];
    TPCircularBuffer _circleBuffer;
    
    AudioStreamBasicDescription _asbd;
    BOOL _isPlaying;
}
@property (nonatomic, strong) WLAudioResample *resampler;
@end

@implementation WLAudioQueuePlayer

- (instancetype)initWithSampleRate:(int)rate channels:(int)channels {
    self = [super init];
    if (self) {
        // 1. 初始化重采样器 (固定输出为 S16, Stereo)
        _resampler = [[WLAudioResample alloc] initWithOutSampleRate:rate
                                                   outChannelLayout:av_get_default_channel_layout(channels)
                                                    outSampleFormat:AV_SAMPLE_FMT_S16];
        
        // 2. 初始化环形缓冲区
        TPCircularBufferInit(&_circleBuffer, kCircleBufferSize);
        
        // 3. 配置 ASBD (macOS 硬件友好的 PCM 格式)
        _asbd.mSampleRate = rate;
        _asbd.mFormatID = kAudioFormatLinearPCM;
        _asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        _asbd.mChannelsPerFrame = channels;
        _asbd.mFramesPerPacket = 1;
        _asbd.mBitsPerChannel = 16;
        _asbd.mBytesPerFrame = channels * (16 / 8);
        _asbd.mBytesPerPacket = _asbd.mBytesPerFrame;
        
        [self setupAudioQueue];
    }
    return self;
}

- (void)setupAudioQueue {
    // 创建播放队列
    AudioQueueNewOutput(&_asbd, WLPlayerAudioQueueCallback, (__bridge void *)self, NULL, NULL, 0, &_audioQueue);
    
    // 分配缓冲区并预设静音
    for (int i = 0; i < kQueueBufferCount; i++) {
        AudioQueueAllocateBuffer(_audioQueue, kQueueBufferSize, &_buffers[i]);
        memset(_buffers[i]->mAudioData, 0, kQueueBufferSize);
        _buffers[i]->mAudioDataByteSize = kQueueBufferSize;
        AudioQueueEnqueueBuffer(_audioQueue, _buffers[i], 0, NULL);
    }
}

// C 回调函数：由系统音频线程触发
static void WLPlayerAudioQueueCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    WLAudioQueuePlayer *player = (__bridge WLAudioQueuePlayer *)inUserData;
    
    int32_t availableBytes;
    void *tail = TPCircularBufferTail(&player->_circleBuffer, &availableBytes);
    
    uint32_t bytesToRead = MIN(availableBytes, kQueueBufferSize);
    
    if (bytesToRead > 0) {
        memcpy(inBuffer->mAudioData, tail, bytesToRead);
        inBuffer->mAudioDataByteSize = bytesToRead;
        TPCircularBufferConsume(&player->_circleBuffer, bytesToRead);
    } else {
        // 数据不足时填静音，防止爆音
        memset(inBuffer->mAudioData, 0, kQueueBufferSize);
        inBuffer->mAudioDataByteSize = kQueueBufferSize;
    }
    
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

- (void)putAVFrame:(AVFrame *)frame {
    NSData *pcmData = [self.resampler resampleFrame:frame];
    if (!pcmData) return;
    
    int32_t availableSpace;
    void *head = TPCircularBufferHead(&_circleBuffer, &availableSpace);
    
    if (availableSpace >= pcmData.length) {
        memcpy(head, pcmData.bytes, pcmData.length);
        TPCircularBufferProduce(&_circleBuffer, (int32_t)pcmData.length);
    }
    // 注意：如果空间不足，这里直接丢弃。实际开发中可加入信号量等待。
}

#pragma mark - 控制方法

- (void)play {
    AudioQueueStart(_audioQueue, NULL);
    _isPlaying = YES;
}

- (void)pause {
    AudioQueuePause(_audioQueue);
    _isPlaying = NO;
}

- (void)stop {
    AudioQueueStop(_audioQueue, YES);
    TPCircularBufferClear(&_circleBuffer);
    _isPlaying = NO;
}

- (void)reset {
    [self stop];
    [self.resampler reset];
}

- (void)setVolume:(float)volume {
    _volume = volume;
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, volume);
}

- (void)dealloc {
    AudioQueueDispose(_audioQueue, YES);
    TPCircularBufferCleanup(&_circleBuffer);
}

@end
