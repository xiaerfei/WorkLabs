//
//  WLAudioRenderer.m
//  WorkLabs
//

#import "WLAudioRenderer.h"
#import <AudioToolbox/AudioToolbox.h>

// 推模式：每帧 allocate 一个 buffer，播完在回调里 free，避免累积。
static void WLAudioRendererCallback(void *userData, AudioQueueRef aq, AudioQueueBufferRef buffer) {
    AudioQueueFreeBuffer(aq, buffer);
}

@interface WLAudioRenderer () {
    AudioQueueRef _audioQueue;
    AudioStreamBasicDescription _asbd;
    BOOL _configured;
}
@end

@implementation WLAudioRenderer

- (instancetype)init {
    self = [super init];
    if (self) { _volume = 1.0; }
    return self;
}

- (void)dealloc { [self stop]; }

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;

    @synchronized (self) {
        if (!_configured && ![self configureWithSampleBuffer:sampleBuffer]) return;
        if (!_audioQueue) return;

        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
        if (!blockBuffer) return;

        size_t lengthAtOffset = 0, totalLength = 0;
        char *dataPointer = NULL;
        if (CMBlockBufferGetDataPointer(blockBuffer, 0, &lengthAtOffset, &totalLength, &dataPointer) != kCMBlockBufferNoErr
            || totalLength == 0 || !dataPointer) {
            return;
        }

        AudioQueueBufferRef buf = NULL;
        if (AudioQueueAllocateBuffer(_audioQueue, (UInt32)totalLength, &buf) != noErr || !buf) return;
        memcpy(buf->mAudioData, dataPointer, totalLength);
        buf->mAudioDataByteSize = (UInt32)totalLength;
        AudioQueueEnqueueBuffer(_audioQueue, buf, 0, NULL);
    }
}

// 必须在 @synchronized(self) 内调用
- (BOOL)configureWithSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!fmt) return NO;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    if (!asbd) return NO;
    _asbd = *asbd;

    OSStatus status = AudioQueueNewOutput(&_asbd, WLAudioRendererCallback,
                                          (__bridge void *)self, NULL, NULL, 0, &_audioQueue);
    if (status != noErr) {
        NSLog(@"[WLAudioRenderer] AudioQueueNewOutput failed: %d", (int)status);
        _audioQueue = NULL;
        return NO;
    }
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, _volume);
    status = AudioQueueStart(_audioQueue, NULL);
    if (status != noErr) {
        NSLog(@"[WLAudioRenderer] AudioQueueStart failed: %d", (int)status);
        AudioQueueDispose(_audioQueue, YES);
        _audioQueue = NULL;
        return NO;
    }
    _configured = YES;
    NSLog(@"[WLAudioRenderer] started %.0fHz %uch float=%d",
          _asbd.mSampleRate, (unsigned)_asbd.mChannelsPerFrame,
          (_asbd.mFormatFlags & kAudioFormatFlagIsFloat) ? 1 : 0);
    return YES;
}

- (void)setVolume:(float)volume {
    _volume = volume;
    @synchronized (self) {
        if (_audioQueue) AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, volume);
    }
}

- (void)flush {
    @synchronized (self) {
        if (_audioQueue) AudioQueueFlush(_audioQueue);
    }
}

- (void)stop {
    @synchronized (self) {
        if (_audioQueue) {
            AudioQueueStop(_audioQueue, YES);
            AudioQueueDispose(_audioQueue, YES);
            _audioQueue = NULL;
        }
        _configured = NO;
    }
}

@end
