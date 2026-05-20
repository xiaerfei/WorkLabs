//
//  WLAudioOutput.m
//  WorkLabs
//

#import "WLAudioOutput.h"
#import <AudioToolbox/AudioToolbox.h>

#define kAudioOutputBufferCount  3
#define kAudioOutputBufferSize   8192

static void WLAudioOutputQueueCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);

@interface WLAudioOutput () {
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _buffers[kAudioOutputBufferCount];
    BOOL _isRunning;
}
@end

@implementation WLAudioOutput

- (instancetype)init {
    self = [super init];
    if (self) { _volume = 1.0; }
    return self;
}

- (void)dealloc { [self stop]; }

- (BOOL)start {
    if (_isRunning) return YES;
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = 44100.0;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mChannelsPerFrame = 1;
    asbd.mFramesPerPacket = 1;
    asbd.mBitsPerChannel = 32;
    asbd.mBytesPerFrame = 4;
    asbd.mBytesPerPacket = 4;
    OSStatus status = AudioQueueNewOutput(&asbd, WLAudioOutputQueueCallback, (__bridge void *)self, NULL, NULL, 0, &_audioQueue);
    if (status != noErr) { NSLog(@"[WLAudioOutput] AudioQueueNewOutput failed: %d", (int)status); return NO; }
    for (int i = 0; i < kAudioOutputBufferCount; i++) {
        AudioQueueAllocateBuffer(_audioQueue, kAudioOutputBufferSize, &_buffers[i]);
        memset(_buffers[i]->mAudioData, 0, kAudioOutputBufferSize);
        _buffers[i]->mAudioDataByteSize = kAudioOutputBufferSize;
        AudioQueueEnqueueBuffer(_audioQueue, _buffers[i], 0, NULL);
    }
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, _volume);
    status = AudioQueueStart(_audioQueue, NULL);
    if (status != noErr) { NSLog(@"[WLAudioOutput] AudioQueueStart failed: %d", (int)status); AudioQueueDispose(_audioQueue, YES); _audioQueue = NULL; return NO; }
    _isRunning = YES;
    return YES;
}

- (void)stop {
    if (!_isRunning) return;
    _isRunning = NO;
    if (_audioQueue) { AudioQueueStop(_audioQueue, YES); AudioQueueDispose(_audioQueue, YES); _audioQueue = NULL; }
}

- (void)playSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_isRunning || !sampleBuffer) return;
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) return;
    size_t lengthAtOffset, totalLength;
    char *dataPointer;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, &lengthAtOffset, &totalLength, &dataPointer);
    if (status != kCMBlockBufferNoErr || totalLength == 0) return;
    AudioQueueBufferRef audioBuffer = NULL;
    status = AudioQueueAllocateBuffer(_audioQueue, (UInt32)totalLength, &audioBuffer);
    if (status != noErr) return;
    memcpy(audioBuffer->mAudioData, dataPointer, totalLength);
    audioBuffer->mAudioDataByteSize = (UInt32)totalLength;
    AudioQueueEnqueueBuffer(_audioQueue, audioBuffer, 0, NULL);
}

- (void)setVolume:(float)volume {
    _volume = volume;
    if (_audioQueue) { AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, volume); }
}

static void WLAudioOutputQueueCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    memset(inBuffer->mAudioData, 0, inBuffer->mAudioDataByteSize);
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

@end
