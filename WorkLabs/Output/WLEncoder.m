//
//  WLEncoder.m
//  WorkLabs
//

#import "WLEncoder.h"
#import "WLEncoderConfig.h"
#import "WLEncodedPacket.h"
#include <mach/mach_time.h>       // mach_absolute_time（单调墙钟）
#include <math.h>
#include <stdatomic.h>            // 视频输入有界反压计数
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"      // AV_TIME_BASE_Q
#include "libavutil/opt.h"
#include "libavutil/audio_fifo.h"
#include "libavutil/channel_layout.h"
#include "libavutil/samplefmt.h"
#include "libavutil/mathematics.h" // av_rescale_rnd
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"

// 单调墙钟（秒）：基于 mach_absolute_time，不受系统时钟调整影响
static Float64 WLEncoderNowSeconds(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (Float64)mach_absolute_time() * tb.numer / tb.denom / 1.0e9;
}

// AAC 输出参数（固定，输入采样率/声道由 swresample 适配）
static const int kWLAacRate     = 44100;
static const int kWLAacChannels = 2;
static const int kWLAacFrame    = 1024;   // AAC LC 每帧样本数
static const int kWLMaxPendingVideo = 4;  // 编码在途视频帧上限：超过则丢帧（合成帧率可能远高于编码吞吐，防 pixelBuffer 堆积致内存爆涨）

@interface WLEncoder () {
    // 视频
    AVCodecContext      *_vcodec;
    struct SwsContext   *_sws;
    AVFrame             *_frame;
    int                  _width;
    int                  _height;
    int                  _fps;
    // 音频
    BOOL                 _audioEnabled;
    AVCodecContext      *_acodec;
    SwrContext          *_swr;
    AVAudioFifo         *_afifo;
    int                  _swrSrcRate;
    int                  _swrSrcChannels;
    // 时间轴（视频/音频共享同一墙钟 epoch）
    BOOL                 _epochSet;
    Float64              _epochSec;          // 首个媒体样本到达的墙钟零点
    int64_t              _lastVideoPts;      // 上一视频 pts（ms），保证单调
    BOOL                 _audioOffsetSet;
    int64_t              _audioOffsetSamples;// 首音频样本相对 epoch 的样本数偏移
    int64_t              _aNextPts;          // 音频累计样本数（不含 offset）
    // 格式快照 / 关键帧
    WLStreamFormat      *_format;            // 首个视频包后生成（含 extradata）
    BOOL                 _formatReady;
    BOOL                 _forceKeyframe;     // 下一帧强制 IDR
    WLEncoderConfig     *_config;
    // 视频输入有界反压（多线程访问）：编码在途帧数 / 累计丢帧数
    atomic_int           _pendingVideo;
    atomic_int           _droppedVideo;
}
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation WLEncoder

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.worklabs.encoder", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (self.running) {
        dispatch_sync(self.queue, ^{
            if (self.running) { self.running = NO; [self teardown]; }
        });
    }
}

#pragma mark - Public

- (BOOL)startWithVideoSize:(CGSize)videoSize
                    config:(WLEncoderConfig *)config
              audioEnabled:(BOOL)audioEnabled {
    if (self.running) return NO;
    int w = (int)videoSize.width, h = (int)videoSize.height;
    if (w <= 0 || h <= 0) return NO;

    __block BOOL ok = NO;
    dispatch_sync(self.queue, ^{
        self->_config = config ?: [WLEncoderConfig defaultConfig];
        self->_audioEnabled = audioEnabled;
        ok = [self setupVideoWithWidth:w height:h];
        if (ok && audioEnabled) ok = [self setupAudio];
        if (ok) {
            self->_epochSet = NO;
            self->_lastVideoPts = -1;
            self->_audioOffsetSet = NO;
            self->_audioOffsetSamples = 0;
            self->_aNextPts = 0;
            self->_formatReady = NO;
            self->_forceKeyframe = NO;
            self->_format = nil;
            self.running = YES;
        } else {
            [self teardown];
        }
    });
    return ok;
}

- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    (void)pts;   // 用墙钟时间轴，源 pts 不参与（多源 pts 基准不可比）
    if (!pixelBuffer || !self.running) return;

    // 有界反压：合成帧率（多源叠加）可能远高于编码吞吐。在途帧达上限即丢弃新帧，
    // 避免未压缩 BGRA 帧在 queue 无限堆积（内存爆涨）。墙钟 pts 保证丢帧后时间轴仍正确（VFR）。
    if (atomic_load(&_pendingVideo) >= kWLMaxPendingVideo) {
        int d = atomic_fetch_add(&_droppedVideo, 1) + 1;
        if (d % 60 == 1) NSLog(@"[WLEncoder] 编码跟不上合成帧率，累计丢帧 %d", d);
        return;
    }
    atomic_fetch_add(&_pendingVideo, 1);

    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(self.queue, ^{
        if (self->_vcodec && self->_sws && self->_frame) {
            [self encodePixelBuffer:pixelBuffer];
        }
        CVPixelBufferRelease(pixelBuffer);
        atomic_fetch_sub(&self->_pendingVideo, 1);
    });
}

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer || !self.running || !_audioEnabled) return;
    CFRetain(sampleBuffer);
    dispatch_async(self.queue, ^{
        if (self->_acodec) [self encodeAudioSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

- (void)requestKeyframe {
    dispatch_async(self.queue, ^{ self->_forceKeyframe = YES; });
}

- (void)stopWithCompletion:(void (^)(void))completion {
    if (!self.running) { if (completion) completion(); return; }
    dispatch_async(self.queue, ^{
        if (!self.running) { if (completion) completion(); return; }
        self.running = NO;
        // flush 视频（残包经 packetOutput 同步派发 → 各 muxer queue，排在收尾 block 之前）
        if (self->_vcodec) [self drainVideoEncoder:NULL];
        // flush 音频（需首视频包已就绪，否则无 format 无法封装）
        if (self->_audioEnabled && self->_acodec && self->_formatReady) {
            [self drainAudioFifo:YES];
            [self sendAudioFrame:NULL];
        }
        [self teardown];
        NSLog(@"[WLEncoder] stopped");
        if (completion) completion();   // 在 encoder queue 上调用
    });
}

#pragma mark - Setup / Teardown（均在 self.queue 内）

- (BOOL)setupVideoWithWidth:(int)w height:(int)h {
    _width = w; _height = h; _fps = (_config.fps > 0 ? _config.fps : 30);

    const AVCodec *encoder = avcodec_find_encoder_by_name("h264_videotoolbox");
    if (!encoder) { NSLog(@"[WLEncoder] 找不到 h264_videotoolbox"); return NO; }

    _vcodec = avcodec_alloc_context3(encoder);
    if (!_vcodec) return NO;

    _vcodec->width      = w;
    _vcodec->height     = h;
    _vcodec->pix_fmt    = AV_PIX_FMT_NV12;
    _vcodec->color_range     = AVCOL_RANGE_MPEG;
    _vcodec->colorspace      = AVCOL_SPC_BT709;
    _vcodec->color_primaries = AVCOL_PRI_BT709;
    _vcodec->color_trc       = AVCOL_TRC_BT709;
    _vcodec->time_base  = (AVRational){1, 1000};   // 毫秒精度
    _vcodec->framerate  = (AVRational){_fps, 1};
    _vcodec->gop_size   = _fps * (_config.keyframeIntervalSeconds > 0 ? _config.keyframeIntervalSeconds : 2);
    _vcodec->bit_rate   = [_config effectiveVideoBitrateForWidth:w height:h];
    _vcodec->max_b_frames = 0;
    // 统一全局头：extradata 以 avcC 形式置于 codecpar，mp4 与 flv 都接受
    _vcodec->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    // 直播低延迟（全局）：videotoolbox realtime
    av_opt_set(_vcodec->priv_data, "realtime", "1", 0);

    if (avcodec_open2(_vcodec, encoder, NULL) < 0) { NSLog(@"[WLEncoder] 打开视频编码器失败"); return NO; }

    _frame = av_frame_alloc();
    if (!_frame) return NO;
    _frame->format = AV_PIX_FMT_NV12;
    _frame->width  = w;
    _frame->height = h;
    _frame->color_range = AVCOL_RANGE_MPEG;
    _frame->colorspace  = AVCOL_SPC_BT709;
    if (av_frame_get_buffer(_frame, 32) < 0) return NO;

    _sws = sws_getContext(w, h, AV_PIX_FMT_BGRA,
                          w, h, AV_PIX_FMT_NV12,
                          SWS_BILINEAR, NULL, NULL, NULL);
    if (!_sws) return NO;
    const int *coeffs = sws_getCoefficients(SWS_CS_ITU709);
    sws_setColorspaceDetails(_sws, coeffs, 1 /*src RGB full*/, coeffs, 0 /*dst YUV limited*/,
                             0, 1 << 16, 1 << 16);

    NSLog(@"[WLEncoder] video %dx%d @%dfps bitrate=%lld gop=%d realtime",
          w, h, _fps, (long long)_vcodec->bit_rate, _vcodec->gop_size);
    return YES;
}

- (BOOL)setupAudio {
    const AVCodec *aenc = avcodec_find_encoder_by_name("aac_at");
    if (!aenc) aenc = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!aenc) { NSLog(@"[WLEncoder] 找不到 AAC 编码器"); return NO; }

    _acodec = avcodec_alloc_context3(aenc);
    if (!_acodec) return NO;

    _acodec->sample_rate = kWLAacRate;
    AVChannelLayout stereo = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
    av_channel_layout_copy(&_acodec->ch_layout, &stereo);
    _acodec->sample_fmt = (aenc->sample_fmts ? aenc->sample_fmts[0] : AV_SAMPLE_FMT_FLTP);
    _acodec->bit_rate   = (_config.audioBitrate > 0 ? _config.audioBitrate : 128000);
    _acodec->time_base  = (AVRational){1, kWLAacRate};
    _acodec->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;   // AudioSpecificConfig 置于 extradata

    if (avcodec_open2(_acodec, aenc, NULL) < 0) { NSLog(@"[WLEncoder] 打开 AAC 编码器失败"); return NO; }

    _afifo = av_audio_fifo_alloc(_acodec->sample_fmt, kWLAacChannels, 1);
    if (!_afifo) return NO;

    _swrSrcRate = 0; _swrSrcChannels = 0;
    return YES;
}

- (void)teardown {
    if (_sws)    { sws_freeContext(_sws); _sws = NULL; }
    if (_frame)  { av_frame_free(&_frame); }
    if (_vcodec) { avcodec_free_context(&_vcodec); }
    if (_swr)    { swr_free(&_swr); }
    if (_afifo)  { av_audio_fifo_free(_afifo); _afifo = NULL; }
    if (_acodec) { avcodec_free_context(&_acodec); }
    _format = nil;
    _audioEnabled = NO;
    _epochSet = NO;
    _audioOffsetSet = NO;
    _audioOffsetSamples = 0;
    _lastVideoPts = -1;
    _aNextPts = 0;
    _formatReady = NO;
    _forceKeyframe = NO;
    _swrSrcRate = 0; _swrSrcChannels = 0;
    _config = nil;
}

#pragma mark - Video Encode（self.queue 内）

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer {
    // 尺寸自卫：画布尺寸在编码会话期间不应变化（settingsCanChangeCanvasSize 已锁定），
    // 万一不符则丢帧，避免 sws 输入/输出尺寸错配崩溃。
    if ((int)CVPixelBufferGetWidth(pixelBuffer) != _width ||
        (int)CVPixelBufferGetHeight(pixelBuffer) != _height) {
        NSLog(@"[WLEncoder] 丢帧：输入尺寸 %zux%zu != 编码器 %dx%d",
              CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), _width, _height);
        return;
    }

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    uint8_t *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    int stride = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
    if (!base) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }
    if (av_frame_make_writable(_frame) < 0) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }
    const uint8_t *srcSlice[1] = { base };
    int srcStride[1] = { stride };
    sws_scale(_sws, srcSlice, srcStride, 0, _height, _frame->data, _frame->linesize);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    // 墙钟时间轴（共 epoch）
    Float64 now = WLEncoderNowSeconds();
    if (!_epochSet) { _epochSec = now; _epochSet = YES; }
    int64_t ms = (int64_t)llround((now - _epochSec) * 1000.0);
    if (ms <= _lastVideoPts) ms = _lastVideoPts + 1;   // 保证单调递增
    _lastVideoPts = ms;
    _frame->pts = ms;

    // 强制关键帧（videotoolbox 尊重 pict_type；设后必须立即复位，否则每帧 IDR 码率爆炸）
    _frame->pict_type = _forceKeyframe ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
    _forceKeyframe = NO;

    [self drainVideoEncoder:_frame];
}

// frame 为 NULL 表示 flush
- (void)drainVideoEncoder:(AVFrame *)frame {
    BOOL wasReady = _formatReady;
    if (avcodec_send_frame(_vcodec, frame) < 0) return;

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return;

    while (avcodec_receive_packet(_vcodec, pkt) == 0) {
        if (!_formatReady) {
            // 首个视频包：此时 videotoolbox extradata(SPS/PPS) 已就绪 → 生成格式快照
            _format = [[WLStreamFormat alloc] initWithVideoCodecContext:_vcodec
                                                      audioCodecContext:(_audioEnabled ? _acodec : NULL)];
            _formatReady = (_format != nil);
        }
        if (_formatReady) {
            av_packet_rescale_ts(pkt, _vcodec->time_base, AV_TIME_BASE_Q);   // → 微秒
            WLEncodedPacket *ep = [[WLEncodedPacket alloc] initWithPacket:pkt isVideo:YES format:_format];
            if (ep && self.packetOutput) self.packetOutput(ep);
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);

    // 首次就绪后，把首视频包之前积压的音频补发出去
    if (!wasReady && _formatReady && _audioEnabled && _acodec) {
        [self drainAudioFifo:NO];
    }
}

#pragma mark - Audio Encode（self.queue 内）

- (void)encodeAudioSampleBuffer:(CMSampleBufferRef)sb {
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (!fd) return;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
    if (!asbd) return;
    int srcRate = (int)asbd->mSampleRate;
    int srcCh   = (int)asbd->mChannelsPerFrame;
    if (srcRate <= 0 || srcCh <= 0) return;

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (!bb) return;
    size_t totalLen = 0; char *data = NULL;
    if (CMBlockBufferGetDataPointer(bb, 0, NULL, &totalLen, &data) != kCMBlockBufferNoErr || !data) return;
    int nbSamples = (int)(totalLen / (srcCh * sizeof(float)));   // 源为 Float32 交错
    if (nbSamples <= 0) return;

    // 墙钟 epoch + 首音频偏移（与视频共零点，消除 A/V 固定偏移）
    Float64 now = WLEncoderNowSeconds();
    if (!_epochSet) { _epochSec = now; _epochSet = YES; }
    if (!_audioOffsetSet) {
        int64_t off = (int64_t)llround((now - _epochSec) * (Float64)kWLAacRate);
        _audioOffsetSamples = (off > 0 ? off : 0);
        _audioOffsetSet = YES;
    }

    // 配置 / 复用 SwrContext（输入 FLT 交错 → encoder 的 sample_fmt，44.1kHz 立体声）
    if (!_swr || _swrSrcRate != srcRate || _swrSrcChannels != srcCh) {
        if (_swr) swr_free(&_swr);
        AVChannelLayout inLayout;
        av_channel_layout_default(&inLayout, srcCh);
        AVChannelLayout outLayout = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
        swr_alloc_set_opts2(&_swr,
                            &outLayout, _acodec->sample_fmt, kWLAacRate,
                            &inLayout, AV_SAMPLE_FMT_FLT, srcRate,
                            0, NULL);
        if (!_swr || swr_init(_swr) < 0) { if (_swr) swr_free(&_swr); return; }
        _swrSrcRate = srcRate; _swrSrcChannels = srcCh;
    }

    int outSamples = (int)av_rescale_rnd(swr_get_out_samples(_swr, nbSamples),
                                         kWLAacRate, srcRate, AV_ROUND_UP);
    if (outSamples <= 0) return;

    uint8_t **outData = NULL;
    int outLinesize = 0;
    if (av_samples_alloc_array_and_samples(&outData, &outLinesize, kWLAacChannels,
                                           outSamples, _acodec->sample_fmt, 0) < 0) {
        return;
    }
    const uint8_t *inData[1] = { (const uint8_t *)data };
    int converted = swr_convert(_swr, outData, outSamples, inData, nbSamples);
    if (converted > 0) {
        av_audio_fifo_write(_afifo, (void **)outData, converted);
    }
    if (outData) { av_freep(&outData[0]); av_freep(&outData); }

    // 首视频包未出时先积压在 FIFO，等格式就绪后再消费（drainVideoEncoder 会补 drain）
    if (_formatReady) [self drainAudioFifo:NO];
}

// flushAll=YES 时连不足一帧的尾部也编码（末帧补静音到 frame_size）
- (void)drainAudioFifo:(BOOL)flushAll {
    if (!_afifo || !_acodec) return;
    int frameSize = (_acodec->frame_size > 0) ? _acodec->frame_size : kWLAacFrame;
    int threshold = flushAll ? 1 : frameSize;

    while (av_audio_fifo_size(_afifo) >= threshold) {
        int avail = av_audio_fifo_size(_afifo);
        int take = FFMIN(frameSize, avail);

        AVFrame *f = av_frame_alloc();
        if (!f) break;
        f->nb_samples  = frameSize;
        f->format      = _acodec->sample_fmt;
        f->sample_rate = kWLAacRate;
        av_channel_layout_copy(&f->ch_layout, &_acodec->ch_layout);
        if (av_frame_get_buffer(f, 0) < 0) { av_frame_free(&f); break; }

        if (take < frameSize) {
            av_samples_set_silence(f->data, 0, frameSize, kWLAacChannels, _acodec->sample_fmt);
        }
        av_audio_fifo_read(_afifo, (void **)f->data, take);

        f->pts = _audioOffsetSamples + _aNextPts;   // 含相对 epoch 的偏移 → 与视频共零点
        _aNextPts += frameSize;                     // 含补零部分，保持连续
        [self sendAudioFrame:f];
        av_frame_free(&f);

        if (!flushAll && av_audio_fifo_size(_afifo) < frameSize) break;
        if (flushAll && take < frameSize) break;   // 尾部已取尽
    }
}

// frame 为 NULL 表示 flush；仅在 _formatReady 后调用（需 _format 封包）
- (void)sendAudioFrame:(AVFrame *)frame {
    if (!_acodec) return;
    if (avcodec_send_frame(_acodec, frame) < 0) return;

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return;
    while (avcodec_receive_packet(_acodec, pkt) == 0) {
        av_packet_rescale_ts(pkt, _acodec->time_base, AV_TIME_BASE_Q);   // → 微秒
        WLEncodedPacket *ep = [[WLEncodedPacket alloc] initWithPacket:pkt isVideo:NO format:_format];
        if (ep && self.packetOutput) self.packetOutput(ep);
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
}

@end
