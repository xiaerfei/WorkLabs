//
//  WLAudioPlayer.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/24.
//

#import "WLAudioPlayer.h"
#import <QuartzCore/QuartzCore.h>
#import "WLResample.h"
#define kNumberBuffers 3
#define kRequestFrameTimeout 0.1


NSString *const src_sample_fmt_key  = @"src_sample_fmt";
NSString *const dst_sample_fmt_key  = @"dst_sample_fmt";

NSString *const src_sample_rate_key = @"src_sample_rate";
NSString *const dst_sample_rate_key = @"dst_sample_rate";

NSString *const src_nb_channels_key = @"src_nb_channels";
NSString *const dst_nb_channels_key = @"dst_nb_channels";


@interface WLAudioPlayer () {
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioQueueBuffers[kNumberBuffers];
    BOOL _isRunning;
    NSTimeInterval _startTime;
    NSTimeInterval _playedTime;
    dispatch_queue_t _delegateQueue;
}

@property (nonatomic, weak) id<MXAudioPlayerDelegate> delegate;
@property (nonatomic, assign) int sampleRate;
@property (nonatomic, assign) int channelLayout;
@property (nonatomic, assign) enum AVSampleFormat sampleFormat;
@property (nonatomic, strong) WLResample *resample;
@end
@implementation WLAudioPlayer
- (instancetype)initWithParameter:(NSDictionary *)parameter {
    self = [super init];
    if (self) {
        _sampleRate    = [parameter[dst_sample_rate_key] intValue];
        _channelLayout = [parameter[dst_nb_channels_key] intValue];;
        _sampleFormat  = [parameter[dst_sample_fmt_key] intValue];
        _delegateQueue = dispatch_queue_create("com.mx.audioplayer.delegate", DISPATCH_QUEUE_SERIAL);
        [self setupSwrContextWithParameter:parameter];
    }
    return self;
}

- (void)dealloc {
    NSLog(@"MXAudioPlayer release");
    
}

- (void)setupAudioQueue {
    AudioStreamBasicDescription format;
    format.mSampleRate = _sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = 2; // 输出为立体声
    format.mBitsPerChannel = 16;
    format.mBytesPerFrame = format.mChannelsPerFrame * format.mBitsPerChannel / 8;
    format.mBytesPerPacket = format.mBytesPerFrame * format.mFramesPerPacket;
    format.mReserved = 0;
    
    AudioQueueNewOutput(&format,
                      audioQueueOutputCallback,
                      (__bridge void *)self,
                      NULL,
                      kCFRunLoopCommonModes,
                      0,
                      &_audioQueue);
    
    // 计算缓冲区大小
    float desiredBufferDurationSeconds = 0.1; // 100ms 缓冲区
    UInt32 numFramesPerBuffer = desiredBufferDurationSeconds * format.mSampleRate; // 4410 帧
    // UInt32 maxFrameSize = numFramesPerBuffer * format.mBytesPerFrame;          // 4410 * 4 = 176
    UInt32 maxFrameSize = (numFramesPerBuffer * format.mBytesPerFrame + 31) & ~31;
    // desiredBufferDurationSeconds：期望的缓冲区时长（秒），通常选择 0.1~0.5 秒（平衡延迟和稳定性）。
    // 例如：0.1 秒 × 44100 Hz = 4410 帧/缓冲区。
    
    for (int i = 0; i < kNumberBuffers; ++i) {
        AudioQueueAllocateBuffer(_audioQueue, maxFrameSize, &_audioQueueBuffers[i]);
        _audioQueueBuffers[i]->mAudioDataByteSize = 0;
    }
}

- (void)setupSwrContextWithParameter:(NSDictionary *)parameter {
    int src_sample_fmt = [parameter[src_sample_fmt_key] intValue];
    int src_sample_rate = [parameter[src_sample_rate_key]intValue];
    int src_nb_channels = [parameter[src_nb_channels_key]intValue];
    int dst_sample_fmt = [parameter[dst_sample_fmt_key] intValue];
    int dst_sample_rate = [parameter[dst_sample_rate_key]intValue];
    int dst_nb_channels = [parameter[dst_nb_channels_key]intValue];
    self.resample =
    [[WLResample alloc] initWithInputSampleRate:src_sample_rate
                              inputSampleFormat:src_sample_fmt
                              inputChannelCount:src_nb_channels
                               outputSampleRate:dst_sample_rate
                             outputSampleFormat:dst_sample_fmt
                             outputChannelCount:dst_nb_channels];
}

- (void)startWithDelegate:(id<MXAudioPlayerDelegate>)delegate {
    if (_isRunning) return;
    
    self.delegate = delegate;
    _playedTime = 0;
    _startTime = CACurrentMediaTime();
    [self setupAudioQueue];
    // 预填充所有缓冲区
    for (int i = 0; i < kNumberBuffers; ++i) {
        [self fillBuffer:_audioQueueBuffers[i]];
    }
    
    AudioQueueStart(_audioQueue, NULL);
    _isRunning = YES;
}

- (void)pause {
    if (!_isRunning) return;
    
    AudioQueuePause(_audioQueue);
    _isRunning = NO;
    _playedTime += CACurrentMediaTime() - _startTime;
}

- (void)stop {
    dispatch_async(_delegateQueue, ^{
        if (!self || !self.delegate) return;
        if (!self->_audioQueue) return;
        
        AudioQueueStop(self->_audioQueue, YES);
        self->_isRunning = NO;
        
        // 重置缓冲区
        for (int i = 0; i < kNumberBuffers; ++i) {
            self->_audioQueueBuffers[i]->mAudioDataByteSize = 0;
        }
        [self.delegate stopAudioPlayer:self];
        
        for (int i = 0; i < kNumberBuffers; ++i) {
            AudioQueueFreeBuffer(self->_audioQueue, self->_audioQueueBuffers[i]);
        }
        OSStatus status = AudioQueueDispose(self->_audioQueue, true);
        if (status != noErr) {
            NSLog(@"Audio Player: Dispose failed: %d",status);
        } else {
            self->_audioQueue = NULL;
            NSLog(@"Audio Player: free AudioQueue successful.");
        }
        
        self->_delegateQueue = nil;
        self->_delegate = nil;
    });
}


- (BOOL)isPlaying {
    return _isRunning;
}

- (NSTimeInterval)currentTime {
    if (_isRunning) {
        return self.resample.playbackPosition;
    }
    return 0;
}

#pragma mark - Buffer Handling
- (void)fillBuffer:(AudioQueueBufferRef)inBuffer {
    __weak typeof(self) weakSelf = self;
    dispatch_async(_delegateQueue, ^{
        [NSThread currentThread].name = @"com.mx.audioplayer.delegate";
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.delegate) return;
        
        // 请求下一帧
        AVFrame *decodedFrame = [self.delegate audioPlayer:self requestNextFrame:kRequestFrameTimeout];
        if (!decodedFrame) {
            // 没有获取到帧，保持缓冲区为空
            inBuffer->mAudioDataByteSize = 0;
            return;
        }
        
        UInt32 outFrames = 0;
        int64_t outPts = 0;
        
        int ret = [self.resample resampleFrame:decodedFrame
                                      intoBuffer:inBuffer
                                       outFrames:&outFrames
                                          outPts:&outPts];
        if (ret == 0 && outFrames > 0) {
            // 将缓冲区提交给 AudioQueue
            AudioQueueEnqueueBuffer(self->_audioQueue, inBuffer, 0, NULL);
        } else {
            // 处理错误或静音
            memset(inBuffer->mAudioData, 0, inBuffer->mAudioDataBytesCapacity);
            inBuffer->mAudioDataByteSize = inBuffer->mAudioDataBytesCapacity;
            AudioQueueEnqueueBuffer(self->_audioQueue, inBuffer, 0, NULL);
        }
        // 释放 AVFrame
        av_frame_free(&decodedFrame);
    });
}

- (double)calculatePCMDurationWithSize:(int)size {
    int bytes_per_sample = 16/8;
    int bytes_per_second = self.sampleRate * bytes_per_sample * self.channelLayout;
    double duration_seconds = size * 1.0f/ bytes_per_second  * 1.0f;
    return duration_seconds;
}


#pragma mark - Audio Queue Callback

static void audioQueueOutputCallback(void *inUserData,
                                    AudioQueueRef inAQ,
                                     AudioQueueBufferRef inBuffer) {
    WLAudioPlayer *player = (__bridge WLAudioPlayer *)inUserData;
    [player fillBuffer:inBuffer];
}
@end
