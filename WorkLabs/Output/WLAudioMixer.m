//
//  WLAudioMixer.m
//  WorkLabs
//

#import "WLAudioMixer.h"
#import "TPCircularBuffer.h"
#include "libswresample/swresample.h"
#include "libavutil/channel_layout.h"
#include "libavutil/samplefmt.h"
#include "libavutil/opt.h"

// 统一输出格式
static const int kMixRate     = 44100;
static const int kMixChannels = 2;
static const int kMixFrame    = 1024;                 // 每次输出样本数（≈23.2ms @44.1k）
static const int kRingSeconds = 1;                    // 每路环形缓冲容量（秒）

#pragma mark - 单路输入（私有）

@interface WLMixerInput : NSObject {
@public
    TPCircularBuffer ring;       // 统一格式 PCM（Float32 交错立体声）
    SwrContext      *swr;        // 源格式 → 统一格式
    int              srcRate;
    int              srcChannels;
    int              srcFmt;     // enum AVSampleFormat
    float            gain;       // 混音增益（1.0=原始）
}
@end

@implementation WLMixerInput
@end

#pragma mark - Mixer

@interface WLAudioMixer ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, WLMixerInput *> *inputs;
@property (nonatomic, strong) dispatch_queue_t timerQueue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) BOOL running;
@end

@implementation WLAudioMixer

- (instancetype)init {
    self = [super init];
    if (self) {
        _inputs = [NSMutableDictionary dictionary];
        _timerQueue = dispatch_queue_create("com.worklabs.audiomixer", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc { [self stop]; }

#pragma mark - Inputs

- (void)addInput:(NSString *)inputID {
    if (inputID.length == 0) return;
    @synchronized (self) {
        if (self.inputs[inputID]) return;
        WLMixerInput *in = [WLMixerInput new];
        TPCircularBufferInit(&in->ring, kMixRate * kMixChannels * (int)sizeof(float) * kRingSeconds);
        in->swr = NULL; in->srcRate = 0; in->srcChannels = 0; in->srcFmt = -1;
        in->gain = 1.0f;
        self.inputs[inputID] = in;
    }
}

- (void)removeInput:(NSString *)inputID {
    if (inputID.length == 0) return;
    @synchronized (self) {
        WLMixerInput *in = self.inputs[inputID];
        if (!in) return;
        [self.inputs removeObjectForKey:inputID];
        if (in->swr) swr_free(&in->swr);
        TPCircularBufferCleanup(&in->ring);
    }
}

- (void)setGain:(float)gain forInput:(NSString *)inputID {
    if (inputID.length == 0) return;
    if (gain < 0) gain = 0;
    @synchronized (self) {
        WLMixerInput *in = self.inputs[inputID];
        if (in) in->gain = gain;
    }
}

#pragma mark - Write（在源线程调用）

- (void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer forInput:(NSString *)inputID {
    if (!sampleBuffer || inputID.length == 0) return;

    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!fd) return;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
    if (!asbd) return;
    int srcRate = (int)asbd->mSampleRate;
    int srcCh   = (int)asbd->mChannelsPerFrame;
    if (srcRate <= 0 || srcCh <= 0) return;
    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    enum AVSampleFormat srcFmt = isFloat ? AV_SAMPLE_FMT_FLT : AV_SAMPLE_FMT_S16; // 交错

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!bb) return;
    size_t totalLen = 0; char *data = NULL;
    if (CMBlockBufferGetDataPointer(bb, 0, NULL, &totalLen, &data) != kCMBlockBufferNoErr || !data) return;
    int bytesPerFrame = (asbd->mBytesPerFrame > 0) ? (int)asbd->mBytesPerFrame
                                                   : srcCh * (isFloat ? 4 : 2);
    int nbSamples = (int)(totalLen / bytesPerFrame);
    if (nbSamples <= 0) return;

    @synchronized (self) {
        WLMixerInput *in = self.inputs[inputID];
        if (!in) return;

        if (!in->swr || in->srcRate != srcRate || in->srcChannels != srcCh || in->srcFmt != srcFmt) {
            if (in->swr) swr_free(&in->swr);
            AVChannelLayout inLayout;  av_channel_layout_default(&inLayout, srcCh);
            AVChannelLayout outLayout = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
            swr_alloc_set_opts2(&in->swr, &outLayout, AV_SAMPLE_FMT_FLT, kMixRate,
                                &inLayout, srcFmt, srcRate, 0, NULL);
            if (!in->swr || swr_init(in->swr) < 0) { if (in->swr) swr_free(&in->swr); return; }
            in->srcRate = srcRate; in->srcChannels = srcCh; in->srcFmt = srcFmt;
        }

        int outSamples = (int)av_rescale_rnd(swr_get_out_samples(in->swr, nbSamples),
                                             kMixRate, srcRate, AV_ROUND_UP);
        if (outSamples <= 0) return;
        int outBytes = outSamples * kMixChannels * (int)sizeof(float);
        float *outBuf = (float *)malloc(outBytes);
        if (!outBuf) return;

        uint8_t *outPtr[1] = { (uint8_t *)outBuf };
        const uint8_t *inPtr[1] = { (const uint8_t *)data };
        int converted = swr_convert(in->swr, outPtr, outSamples, inPtr, nbSamples);
        if (converted > 0) {
            TPCircularBufferProduceBytes(&in->ring, outBuf, converted * kMixChannels * (int)sizeof(float));
        }
        free(outBuf);
    }
}

#pragma mark - Timer / Mix

- (void)start {
    if (self.running) return;
    self.running = YES;
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.timerQueue);
    uint64_t intervalNs = (uint64_t)((double)kMixFrame / kMixRate * NSEC_PER_SEC);
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              intervalNs, intervalNs / 10);
    __weak typeof(self) wself = self;
    dispatch_source_set_event_handler(self.timer, ^{ [wself mixOnce]; });
    dispatch_resume(self.timer);
}

- (void)stop {
    if (!self.running && !self.timer) {
        [self releaseAllInputs];
        return;
    }
    self.running = NO;
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    [self releaseAllInputs];
}

- (void)releaseAllInputs {
    @synchronized (self) {
        for (WLMixerInput *in in self.inputs.allValues) {
            if (in->swr) swr_free(&in->swr);
            TPCircularBufferCleanup(&in->ring);
        }
        [self.inputs removeAllObjects];
    }
}

- (void)mixOnce {
    const int frameFloats = kMixFrame * kMixChannels;
    float mix[frameFloats];
    memset(mix, 0, sizeof(mix));
    BOOL any = NO;

    @synchronized (self) {
        if (!self.running) return;
        for (WLMixerInput *in in self.inputs.allValues) {
            int32_t availBytes = 0;
            void *tail = TPCircularBufferTail(&in->ring, &availBytes);
            if (!tail || availBytes <= 0) continue;
            int wantBytes = frameFloats * (int)sizeof(float);
            int useBytes = MIN(availBytes, wantBytes);
            int useFloats = useBytes / (int)sizeof(float);
            const float *src = (const float *)tail;
            float g = in->gain;
            for (int i = 0; i < useFloats; i++) mix[i] += src[i] * g;   // 增益后叠加
            TPCircularBufferConsume(&in->ring, useBytes);
            any = YES;
        }
    }

    if (!any) return;   // 无任何输入数据，不产静音帧

    // 限幅 [-1, 1]
    for (int i = 0; i < frameFloats; i++) {
        if (mix[i] > 1.0f) mix[i] = 1.0f;
        else if (mix[i] < -1.0f) mix[i] = -1.0f;
    }

    CMSampleBufferRef sb = [self makeSampleBufferFromFloats:mix samples:kMixFrame];
    if (sb) {
        if (self.mixedOutput) self.mixedOutput(sb);   // 所有权转移
        else CFRelease(sb);
    }
}

#pragma mark - 构造混音输出 CMSampleBuffer（44.1k / 立体声 / Float32 交错）

- (CMSampleBufferRef)makeSampleBufferFromFloats:(const float *)samples samples:(int)nbSamples {
    int dataSize = nbSamples * kMixChannels * (int)sizeof(float);
    void *copy = malloc(dataSize);
    if (!copy) return NULL;
    memcpy(copy, samples, dataSize);

    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate       = kMixRate;
    asbd.mFormatID         = kAudioFormatLinearPCM;
    asbd.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mChannelsPerFrame = kMixChannels;
    asbd.mBitsPerChannel   = 32;
    asbd.mFramesPerPacket  = 1;
    asbd.mBytesPerFrame    = kMixChannels * (int)sizeof(float);
    asbd.mBytesPerPacket   = asbd.mBytesPerFrame;

    CMFormatDescriptionRef fmtDesc = NULL;
    if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &fmtDesc) != noErr) {
        free(copy); return NULL;
    }

    CMBlockBufferRef blockBuffer = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, copy, dataSize,
                                           kCFAllocatorMalloc, NULL, 0, dataSize, 0, &blockBuffer) != kCMBlockBufferNoErr) {
        CFRelease(fmtDesc); free(copy); return NULL;
    }

    CMSampleBufferRef sampleBuffer = NULL;
    CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid };
    OSStatus st = CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, YES, NULL, NULL,
                                       fmtDesc, nbSamples, 1, &timing, 0, NULL, &sampleBuffer);
    CFRelease(fmtDesc);
    CFRelease(blockBuffer);
    return (st == noErr) ? sampleBuffer : NULL;
}

@end
