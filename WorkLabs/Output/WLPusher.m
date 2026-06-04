//
//  WLPusher.m
//  WorkLabs
//

#import "WLPusher.h"
#import "WLEncoderConfig.h"
#include <mach/mach_time.h>
#include <math.h>
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/opt.h"
#include "libavutil/audio_fifo.h"
#include "libavutil/channel_layout.h"
#include "libavutil/samplefmt.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"

static Float64 WLPusherNowSeconds(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (Float64)mach_absolute_time() * tb.numer / tb.denom / 1.0e9;
}

static const int kAacRate     = 44100;
static const int kAacChannels = 2;
static const int kAacFrame    = 1024;

@interface WLPusher () {
    AVFormatContext     *_fmt;
    // 视频
    AVStream            *_vstream;
    AVCodecContext      *_vcodec;
    struct SwsContext   *_sws;
    AVFrame             *_frame;
    int                  _width;
    int                  _height;
    int                  _fps;
    BOOL                 _ptsBaseSet;
    Float64              _startPts;     // 首个视频帧墙钟零点
    int64_t              _lastPts;
    BOOL                 _headerWritten; // 延迟到首个视频 packet 再写头
    BOOL                 _aborted;       // 写失败/断流：下个 append 周期收尾
    // 音频
    BOOL                 _audioEnabled;
    AVStream            *_astream;
    AVCodecContext      *_acodec;
    SwrContext          *_swr;
    AVAudioFifo         *_afifo;
    int                  _swrSrcRate;
    int                  _swrSrcChannels;
    int64_t              _aNextPts;
    WLEncoderConfig     *_config;         // 编码参数（码率/关键帧间隔/帧率/音频码率）
}
@property (atomic, assign, readwrite, getter=isPushing) BOOL pushing;
@property (atomic, assign) BOOL connecting;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation WLPusher

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.worklabs.pusher", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (self.pushing) {
        // 同步收尾，避免 dealloc 后 queue 仍持有裸指针
        dispatch_sync(self.queue, ^{
            if (self.pushing) {
                self.pushing = NO;
                [self teardown];
            }
        });
    }
}

#pragma mark - Public

- (void)startWithURL:(NSString *)url
           videoSize:(CGSize)videoSize
              config:(WLEncoderConfig *)config
        audioEnabled:(BOOL)audioEnabled {
    if (self.pushing || self.connecting || url.length == 0) return;
    self.connecting = YES;
    self.url = url;

    int w = (int)videoSize.width, h = (int)videoSize.height;
    dispatch_async(self.queue, ^{
        self->_audioEnabled = audioEnabled;
        self->_config = config ?: [WLEncoderConfig defaultConfig];
        NSString *errMsg = nil;
        BOOL ok = [self setupWithURL:url width:w height:h errMsg:&errMsg];
        if (ok) {
            self->_ptsBaseSet = NO;
            self->_lastPts = -1;
            self->_headerWritten = NO;
            self->_aborted = NO;
            self->_aNextPts = 0;
            self.pushing = YES;
            self.connecting = NO;
            [self notifyStart];
        } else {
            [self teardown];
            self.connecting = NO;
            [self notifyFailWithMessage:(errMsg ?: @"推流连接失败")];
        }
    });
}

- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    if (!pixelBuffer || !self.pushing) return;
    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(self.queue, ^{
        if (self.pushing) {
            if (self->_aborted) {
                [self finishAbort];
            } else if (self->_sws && self->_frame) {
                [self encodePixelBuffer:pixelBuffer];
            }
        }
        CVPixelBufferRelease(pixelBuffer);
    });
}

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer || !self.pushing || !_audioEnabled) return;
    CFRetain(sampleBuffer);
    dispatch_async(self.queue, ^{
        if (self.pushing && self->_audioEnabled && self->_acodec) {
            if (self->_aborted) {
                [self finishAbort];
            } else {
                [self encodeAudioSampleBuffer:sampleBuffer];
            }
        }
        CFRelease(sampleBuffer);
    });
}

- (void)stop {
    if (!self.pushing && !self.connecting) return;
    dispatch_async(self.queue, ^{
        BOOL was = self.pushing;
        self.pushing = NO;
        self.connecting = NO;
        if (was && !self->_aborted && self->_headerWritten) {
            if (self->_audioEnabled && self->_acodec) {
                [self drainAudioFifo:YES];
                [self sendAudioFrame:NULL];
            }
            if (self->_vcodec) [self drainEncoder:NULL];
            if (self->_fmt) av_write_trailer(self->_fmt);
        }
        [self teardown];
        [self notifyStop];
        NSLog(@"[WLPusher] stopped");
    });
}

#pragma mark - 断流收尾（queue 内）

- (void)finishAbort {
    if (!self.pushing) return;
    self.pushing = NO;
    [self teardown];
    [self notifyFailWithMessage:@"推流中断（连接可能已断开）"];
    NSLog(@"[WLPusher] aborted");
}

#pragma mark - delegate 回调（主线程）

- (void)notifyStart {
    __weak typeof(self) wself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        if ([self.delegate respondsToSelector:@selector(pusherDidStart:)]) [self.delegate pusherDidStart:self];
    });
}

- (void)notifyStop {
    __weak typeof(self) wself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        if ([self.delegate respondsToSelector:@selector(pusherDidStop:)]) [self.delegate pusherDidStop:self];
    });
}

- (void)notifyFailWithMessage:(NSString *)msg {
    __weak typeof(self) wself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        NSError *err = [NSError errorWithDomain:@"WLPusher" code:-1
                                       userInfo:@{NSLocalizedDescriptionKey: msg ?: @"推流错误"}];
        if ([self.delegate respondsToSelector:@selector(pusher:didFailWithError:)]) [self.delegate pusher:self didFailWithError:err];
    });
}

#pragma mark - Setup / Teardown（queue 内）

- (BOOL)setupWithURL:(NSString *)url
               width:(int)w
              height:(int)h
              errMsg:(NSString * __strong *)errMsg {
    if (w <= 0 || h <= 0) { *errMsg = @"画布尺寸非法"; return NO; }
    _width = w; _height = h; _fps = (_config.fps > 0 ? _config.fps : 30);

    const char *curl = url.UTF8String;

    // FLV muxer（rtmp 无扩展名，需显式指定）
    avformat_alloc_output_context2(&_fmt, NULL, "flv", curl);
    if (!_fmt) { *errMsg = @"无法创建 FLV 输出上下文"; return NO; }

    const AVCodec *encoder = avcodec_find_encoder_by_name("h264_videotoolbox");
    if (!encoder) { *errMsg = @"找不到 h264_videotoolbox 编码器"; return NO; }

    _vstream = avformat_new_stream(_fmt, NULL);
    if (!_vstream) { *errMsg = @"无法创建视频流"; return NO; }

    _vcodec = avcodec_alloc_context3(encoder);
    if (!_vcodec) { *errMsg = @"无法分配编码器上下文"; return NO; }

    _vcodec->width      = w;
    _vcodec->height     = h;
    _vcodec->pix_fmt    = AV_PIX_FMT_NV12;
    _vcodec->color_range     = AVCOL_RANGE_MPEG;
    _vcodec->colorspace      = AVCOL_SPC_BT709;
    _vcodec->color_primaries = AVCOL_PRI_BT709;
    _vcodec->color_trc       = AVCOL_TRC_BT709;
    _vcodec->time_base  = (AVRational){1, 1000};
    _vcodec->framerate  = (AVRational){_fps, 1};
    _vcodec->gop_size   = _fps * (_config.keyframeIntervalSeconds > 0 ? _config.keyframeIntervalSeconds : 2);
    _vcodec->bit_rate   = [_config effectiveVideoBitrateForWidth:w height:h];
    _vcodec->max_b_frames = 0;
    // 直播低延迟：videotoolbox realtime 模式
    av_opt_set(_vcodec->priv_data, "realtime", "1", 0);

    if (_fmt->oformat->flags & AVFMT_GLOBALHEADER) {
        _vcodec->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    if (avcodec_open2(_vcodec, encoder, NULL) < 0) { *errMsg = @"打开视频编码器失败"; return NO; }

    if (_audioEnabled && ![self setupAudioWithErrMsg:errMsg]) {
        return NO;
    }

    // 连接 rtmp 服务器（阻塞握手/connect/publish；在后台 queue 执行）
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rw_timeout", "5000000", 0);   // 5s I/O 超时，避免无限阻塞
    int ret = avio_open2(&_fmt->pb, curl, AVIO_FLAG_WRITE, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        char buf[256] = {0};
        av_strerror(ret, buf, sizeof(buf));
        *errMsg = [NSString stringWithFormat:@"无法连接推流地址：%s", buf];
        return NO;
    }

    // write_header 延迟到首个视频 packet（videotoolbox extradata 时序）

    _frame = av_frame_alloc();
    if (!_frame) { *errMsg = @"无法分配帧"; return NO; }
    _frame->format = AV_PIX_FMT_NV12;
    _frame->width  = w;
    _frame->height = h;
    _frame->color_range = AVCOL_RANGE_MPEG;
    _frame->colorspace  = AVCOL_SPC_BT709;
    if (av_frame_get_buffer(_frame, 32) < 0) { *errMsg = @"分配帧缓冲失败"; return NO; }

    _sws = sws_getContext(w, h, AV_PIX_FMT_BGRA,
                          w, h, AV_PIX_FMT_NV12,
                          SWS_BILINEAR, NULL, NULL, NULL);
    if (!_sws) { *errMsg = @"创建像素格式转换失败"; return NO; }
    const int *coeffs = sws_getCoefficients(SWS_CS_ITU709);
    sws_setColorspaceDetails(_sws, coeffs, 1, coeffs, 0, 0, 1 << 16, 1 << 16);

    NSLog(@"[WLPusher] connected %dx%d @%dfps audio=%@ → %@",
          w, h, _fps, _audioEnabled ? @"YES" : @"NO", url);
    return YES;
}

- (BOOL)setupAudioWithErrMsg:(NSString * __strong *)errMsg {
    const AVCodec *aenc = avcodec_find_encoder_by_name("aac_at");
    if (!aenc) aenc = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!aenc) { *errMsg = @"找不到 AAC 编码器"; return NO; }

    _astream = avformat_new_stream(_fmt, NULL);
    if (!_astream) { *errMsg = @"无法创建音频流"; return NO; }

    _acodec = avcodec_alloc_context3(aenc);
    if (!_acodec) { *errMsg = @"无法分配音频编码器上下文"; return NO; }

    _acodec->sample_rate = kAacRate;
    AVChannelLayout stereo = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
    av_channel_layout_copy(&_acodec->ch_layout, &stereo);
    _acodec->sample_fmt = (aenc->sample_fmts ? aenc->sample_fmts[0] : AV_SAMPLE_FMT_FLTP);
    _acodec->bit_rate   = (_config.audioBitrate > 0 ? _config.audioBitrate : 128000);
    _acodec->time_base  = (AVRational){1, kAacRate};

    if (_fmt->oformat->flags & AVFMT_GLOBALHEADER) {
        _acodec->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    if (avcodec_open2(_acodec, aenc, NULL) < 0) { *errMsg = @"打开 AAC 编码器失败"; return NO; }

    avcodec_parameters_from_context(_astream->codecpar, _acodec);
    _astream->time_base = _acodec->time_base;

    _afifo = av_audio_fifo_alloc(_acodec->sample_fmt, kAacChannels, 1);
    if (!_afifo) { *errMsg = @"分配音频 FIFO 失败"; return NO; }

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
    if (_fmt) {
        if (_fmt->pb) avio_closep(&_fmt->pb);
        avformat_free_context(_fmt);
        _fmt = NULL;
    }
    _vstream = NULL;
    _astream = NULL;
    _audioEnabled = NO;
    _ptsBaseSet = NO;
    _headerWritten = NO;
    _aborted = NO;
    _lastPts = -1;
    _aNextPts = 0;
    _swrSrcRate = 0; _swrSrcChannels = 0;
    _config = nil;
}

#pragma mark - Video Encode（queue 内）

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer {
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

    // 墙钟时间轴（与录制一致，多源 pts 不可比）
    Float64 nowSec = WLPusherNowSeconds();
    if (!_ptsBaseSet) { _startPts = nowSec; _ptsBaseSet = YES; }
    int64_t framePts = (int64_t)llround((nowSec - _startPts) * 1000.0);
    if (framePts <= _lastPts) framePts = _lastPts + 1;
    _lastPts = framePts;
    _frame->pts = framePts;

    [self drainEncoder:_frame];
}

- (void)drainEncoder:(AVFrame *)frame {
    if (avcodec_send_frame(_vcodec, frame) < 0) return;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return;
    while (avcodec_receive_packet(_vcodec, pkt) == 0) {
        if (!_headerWritten) {
            avcodec_parameters_from_context(_vstream->codecpar, _vcodec);
            _vstream->time_base = _vcodec->time_base;
            if (avformat_write_header(_fmt, NULL) < 0) {
                NSLog(@"[WLPusher] write_header failed");
                _aborted = YES;
                av_packet_unref(pkt);
                break;
            }
            _headerWritten = YES;
            if (_audioEnabled && _acodec) [self drainAudioFifo:NO];
        }
        av_packet_rescale_ts(pkt, _vcodec->time_base, _vstream->time_base);
        pkt->stream_index = _vstream->index;
        if (av_interleaved_write_frame(_fmt, pkt) < 0) {   // 断流检测
            _aborted = YES;
            av_packet_unref(pkt);
            break;
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
}

#pragma mark - Audio Encode（queue 内）

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
    int nbSamples = (int)(totalLen / (srcCh * sizeof(float)));
    if (nbSamples <= 0) return;

    if (!_swr || _swrSrcRate != srcRate || _swrSrcChannels != srcCh) {
        if (_swr) swr_free(&_swr);
        AVChannelLayout inLayout;  av_channel_layout_default(&inLayout, srcCh);
        AVChannelLayout outLayout = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
        swr_alloc_set_opts2(&_swr, &outLayout, _acodec->sample_fmt, kAacRate,
                            &inLayout, AV_SAMPLE_FMT_FLT, srcRate, 0, NULL);
        if (!_swr || swr_init(_swr) < 0) { if (_swr) swr_free(&_swr); return; }
        _swrSrcRate = srcRate; _swrSrcChannels = srcCh;
    }

    int outSamples = (int)av_rescale_rnd(swr_get_out_samples(_swr, nbSamples), kAacRate, srcRate, AV_ROUND_UP);
    if (outSamples <= 0) return;
    uint8_t **outData = NULL; int outLinesize = 0;
    if (av_samples_alloc_array_and_samples(&outData, &outLinesize, kAacChannels, outSamples, _acodec->sample_fmt, 0) < 0) return;
    const uint8_t *inData[1] = { (const uint8_t *)data };
    int converted = swr_convert(_swr, outData, outSamples, inData, nbSamples);
    if (converted > 0) av_audio_fifo_write(_afifo, (void **)outData, converted);
    if (outData) { av_freep(&outData[0]); av_freep(&outData); }

    if (_headerWritten) [self drainAudioFifo:NO];
}

- (void)drainAudioFifo:(BOOL)flushAll {
    if (!_afifo || !_acodec) return;
    int frameSize = (_acodec->frame_size > 0) ? _acodec->frame_size : kAacFrame;
    int threshold = flushAll ? 1 : frameSize;
    while (av_audio_fifo_size(_afifo) >= threshold) {
        int avail = av_audio_fifo_size(_afifo);
        int take = FFMIN(frameSize, avail);
        AVFrame *f = av_frame_alloc();
        if (!f) break;
        f->nb_samples  = frameSize;
        f->format      = _acodec->sample_fmt;
        f->sample_rate = kAacRate;
        av_channel_layout_copy(&f->ch_layout, &_acodec->ch_layout);
        if (av_frame_get_buffer(f, 0) < 0) { av_frame_free(&f); break; }
        if (take < frameSize) {
            av_samples_set_silence(f->data, 0, frameSize, kAacChannels, _acodec->sample_fmt);
        }
        av_audio_fifo_read(_afifo, (void **)f->data, take);
        f->pts = _aNextPts;
        _aNextPts += frameSize;
        [self sendAudioFrame:f];
        av_frame_free(&f);
        if (!flushAll && av_audio_fifo_size(_afifo) < frameSize) break;
        if (flushAll && take < frameSize) break;
    }
}

- (void)sendAudioFrame:(AVFrame *)frame {
    if (!_acodec) return;
    if (avcodec_send_frame(_acodec, frame) < 0) return;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return;
    while (avcodec_receive_packet(_acodec, pkt) == 0) {
        av_packet_rescale_ts(pkt, _acodec->time_base, _astream->time_base);
        pkt->stream_index = _astream->index;
        if (av_interleaved_write_frame(_fmt, pkt) < 0) {   // 断流检测
            _aborted = YES;
            av_packet_unref(pkt);
            break;
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
}

@end
