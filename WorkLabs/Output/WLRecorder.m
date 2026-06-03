//
//  WLRecorder.m
//  WorkLabs
//

#import "WLRecorder.h"
#include <mach/mach_time.h>       // mach_absolute_time（单调墙钟）
#include <math.h>
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/imgutils.h"
#include "libavutil/opt.h"
#include "libavutil/audio_fifo.h"
#include "libavutil/channel_layout.h"
#include "libavutil/samplefmt.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"

// 单调墙钟（秒）：基于 mach_absolute_time，不受系统时钟调整影响
static Float64 WLNowSeconds(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (Float64)mach_absolute_time() * tb.numer / tb.denom / 1.0e9;
}

// AAC 音频输出参数（固定，输入采样率/声道由 swresample 适配）
static const int kWLAacRate     = 44100;
static const int kWLAacChannels = 2;
static const int kWLAacFrame    = 1024;   // AAC LC 每帧样本数

@interface WLRecorder () {
    AVFormatContext     *_fmt;
    // 视频
    AVStream            *_vstream;
    AVCodecContext      *_vcodec;
    struct SwsContext   *_sws;
    AVFrame             *_frame;
    int                  _width;
    int                  _height;
    int                  _fps;
    BOOL                 _ptsBaseSet;   // 首帧墙钟基准已设
    Float64              _startPts;     // 首个视频帧到达时的墙钟(秒)，作为录制视频时间轴零点
    int64_t              _lastPts;
    BOOL                 _headerWritten; // 延迟到首个视频 packet 再写头（videotoolbox extradata 时序）
    // 音频
    BOOL                 _audioEnabled;
    AVStream            *_astream;
    AVCodecContext      *_acodec;
    SwrContext          *_swr;
    AVAudioFifo         *_afifo;
    int                  _swrSrcRate;     // 当前 swr 输入采样率（变化则重建）
    int                  _swrSrcChannels;
    int64_t              _aNextPts;       // 音频累计 pts（单位 1/kWLAacRate）
}
@property (nonatomic, assign, readwrite, getter=isRecording) BOOL recording;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation WLRecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.worklabs.recorder", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (self.recording) [self stopRecording];
}

#pragma mark - Public

- (BOOL)startRecordingToPath:(NSString *)path
                   videoSize:(CGSize)videoSize
                         fps:(int)fps
                audioEnabled:(BOOL)audioEnabled
                       error:(NSError * _Nullable * _Nullable)error {
    if (self.recording || path.length == 0) return NO;

    __block BOOL ok = NO;
    __block NSString *errMsg = nil;
    dispatch_sync(self.queue, ^{
        self->_audioEnabled = audioEnabled;
        ok = [self setupWithPath:path
                           width:(int)videoSize.width
                          height:(int)videoSize.height
                             fps:fps
                          errMsg:&errMsg];
        if (ok) {
            self->_ptsBaseSet = NO;
            self->_lastPts = -1;
            self->_headerWritten = NO;
            self->_aNextPts = 0;
            self.recording = YES;
        } else {
            [self teardown];
        }
    });

    if (!ok && error) {
        *error = [NSError errorWithDomain:@"WLRecorder" code:-1
                                 userInfo:@{NSLocalizedDescriptionKey: errMsg ?: @"录制启动失败"}];
    }
    return ok;
}

- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    if (!pixelBuffer || !self.recording) return;
    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(self.queue, ^{
        if (self.recording && self->_sws && self->_frame) {
            [self encodePixelBuffer:pixelBuffer pts:pts];
        }
        CVPixelBufferRelease(pixelBuffer);
    });
}

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer || !self.recording || !_audioEnabled) return;
    CFRetain(sampleBuffer);
    dispatch_async(self.queue, ^{
        if (self.recording && self->_audioEnabled && self->_acodec) {
            [self encodeAudioSampleBuffer:sampleBuffer];
        }
        CFRelease(sampleBuffer);
    });
}

- (void)stopRecording {
    if (!self.recording) return;
    dispatch_sync(self.queue, ^{
        self.recording = NO;
        if (self->_headerWritten) {
            if (self->_audioEnabled && self->_acodec) {
                [self drainAudioFifo:YES];     // 编码 FIFO 剩余样本
                [self sendAudioFrame:NULL];    // flush AAC 编码器
            }
            if (self->_vcodec) [self drainEncoder:NULL]; // flush 视频编码器
            if (self->_fmt) av_write_trailer(self->_fmt);
        }
        [self teardown];
        NSLog(@"[WLRecorder] stopped");
    });
}

#pragma mark - Setup / Teardown（均在 self.queue 内调用）

- (BOOL)setupWithPath:(NSString *)path
                width:(int)w
               height:(int)h
                  fps:(int)fps
               errMsg:(NSString * __strong *)errMsg {
    if (w <= 0 || h <= 0) { *errMsg = @"画布尺寸非法"; return NO; }
    _width = w; _height = h; _fps = (fps > 0 ? fps : 30);

    const char *cpath = path.fileSystemRepresentation;

    avformat_alloc_output_context2(&_fmt, NULL, NULL, cpath);
    if (!_fmt) { *errMsg = @"无法创建输出上下文（mp4）"; return NO; }

    const AVCodec *encoder = avcodec_find_encoder_by_name("h264_videotoolbox");
    if (!encoder) { *errMsg = @"找不到 h264_videotoolbox 编码器"; return NO; }

    _vstream = avformat_new_stream(_fmt, NULL);
    if (!_vstream) { *errMsg = @"无法创建视频流"; return NO; }

    _vcodec = avcodec_alloc_context3(encoder);
    if (!_vcodec) { *errMsg = @"无法分配编码器上下文"; return NO; }

    _vcodec->width      = w;
    _vcodec->height     = h;
    _vcodec->pix_fmt    = AV_PIX_FMT_NV12;          // videotoolbox 原生格式
    _vcodec->color_range     = AVCOL_RANGE_MPEG;    // limited range，与 swscale 输出一致（消除 videotoolbox 警告）
    _vcodec->colorspace      = AVCOL_SPC_BT709;     // HD 标准色彩空间
    _vcodec->color_primaries = AVCOL_PRI_BT709;
    _vcodec->color_trc       = AVCOL_TRC_BT709;
    _vcodec->time_base  = (AVRational){1, 1000};    // 毫秒精度
    _vcodec->framerate  = (AVRational){_fps, 1};
    _vcodec->gop_size   = _fps * 2;
    _vcodec->bit_rate   = (int64_t)w * h * 4;        // 粗略码率（1080p≈8Mbps）
    _vcodec->max_b_frames = 0;

    if (_fmt->oformat->flags & AVFMT_GLOBALHEADER) {
        _vcodec->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    if (avcodec_open2(_vcodec, encoder, NULL) < 0) { *errMsg = @"打开编码器失败"; return NO; }

    // 音频流（可选）：在 write_header 之前建好；AAC extradata 在 open 后即就绪
    if (_audioEnabled && ![self setupAudioWithErrMsg:errMsg]) {
        return NO;
    }

    if (!(_fmt->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&_fmt->pb, cpath, AVIO_FLAG_WRITE) < 0) {
            *errMsg = @"无法打开输出文件（检查路径/权限）";
            return NO;
        }
    }

    // 注意：write_header 延迟到首个视频 packet（此时 videotoolbox 才填好 extradata/SPS/PPS）

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
    // BGRA(full range RGB) → NV12(limited range YUV, BT.709)
    const int *coeffs = sws_getCoefficients(SWS_CS_ITU709);
    sws_setColorspaceDetails(_sws, coeffs, 1 /*src RGB full*/, coeffs, 0 /*dst YUV limited*/,
                             0, 1 << 16, 1 << 16);

    NSLog(@"[WLRecorder] start %dx%d @%dfps audio=%@ → %@",
          w, h, _fps, _audioEnabled ? @"YES" : @"NO", path.lastPathComponent);
    return YES;
}

- (BOOL)setupAudioWithErrMsg:(NSString * __strong *)errMsg {
    const AVCodec *aenc = avcodec_find_encoder_by_name("aac_at");
    if (!aenc) aenc = avcodec_find_encoder(AV_CODEC_ID_AAC);   // 兜底（理论上 LGPL 构建含 aac_at）
    if (!aenc) { *errMsg = @"找不到 AAC 编码器"; return NO; }

    _astream = avformat_new_stream(_fmt, NULL);
    if (!_astream) { *errMsg = @"无法创建音频流"; return NO; }

    _acodec = avcodec_alloc_context3(aenc);
    if (!_acodec) { *errMsg = @"无法分配音频编码器上下文"; return NO; }

    _acodec->sample_rate = kWLAacRate;
    AVChannelLayout stereo = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
    av_channel_layout_copy(&_acodec->ch_layout, &stereo);
    _acodec->sample_fmt = (aenc->sample_fmts ? aenc->sample_fmts[0] : AV_SAMPLE_FMT_FLTP);
    _acodec->bit_rate   = 128000;
    _acodec->time_base  = (AVRational){1, kWLAacRate};

    if (_fmt->oformat->flags & AVFMT_GLOBALHEADER) {
        _acodec->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    if (avcodec_open2(_acodec, aenc, NULL) < 0) { *errMsg = @"打开 AAC 编码器失败"; return NO; }

    // AAC extradata（AudioSpecificConfig）在 open 后已就绪 → 现在即可写 codecpar
    avcodec_parameters_from_context(_astream->codecpar, _acodec);
    _astream->time_base = _acodec->time_base;

    _afifo = av_audio_fifo_alloc(_acodec->sample_fmt, kWLAacChannels, 1);
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
        if (_fmt->pb && !(_fmt->oformat->flags & AVFMT_NOFILE)) {
            avio_closep(&_fmt->pb);
        }
        avformat_free_context(_fmt);
        _fmt = NULL;
    }
    _vstream = NULL;
    _astream = NULL;
    _audioEnabled = NO;
    _ptsBaseSet = NO;
    _headerWritten = NO;
    _lastPts = -1;
    _aNextPts = 0;
    _swrSrcRate = 0; _swrSrcChannels = 0;
}

#pragma mark - Video Encode（在 self.queue 内调用）

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return;
    }
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

    // 用单调墙钟作为时间轴：多源(摄像头=系统 mach 时间 / 媒体=文件 pts)的源 pts 基准不可比，
    // 直接相减会因跳变把时长撑爆（曾出现 21h 时长 + 画面静止）。合成录制以"实际录制经过时间"为准。
    (void)pts;
    Float64 nowSec = WLNowSeconds();
    if (!_ptsBaseSet) { _startPts = nowSec; _ptsBaseSet = YES; }
    int64_t framePts = (int64_t)llround((nowSec - _startPts) * 1000.0); // ms
    if (framePts <= _lastPts) framePts = _lastPts + 1;               // 保证单调递增
    _lastPts = framePts;
    _frame->pts = framePts;

    [self drainEncoder:_frame];
}

// frame 为 NULL 表示 flush
- (void)drainEncoder:(AVFrame *)frame {
    if (avcodec_send_frame(_vcodec, frame) < 0) return;

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return;

    while (avcodec_receive_packet(_vcodec, pkt) == 0) {
        // 首个视频 packet：此时 encoder 已生成 extradata(SPS/PPS)，写头（音频流 codecpar 已在 setup 就绪）
        if (!_headerWritten) {
            avcodec_parameters_from_context(_vstream->codecpar, _vcodec);
            _vstream->time_base = _vcodec->time_base;
            if (avformat_write_header(_fmt, NULL) < 0) {
                NSLog(@"[WLRecorder] write_header failed");
                av_packet_unref(pkt);
                break;
            }
            _headerWritten = YES;
            // 写头前积压在 FIFO 的音频，现在可以编码写出
            if (_audioEnabled && _acodec) [self drainAudioFifo:NO];
        }
        av_packet_rescale_ts(pkt, _vcodec->time_base, _vstream->time_base);
        pkt->stream_index = _vstream->index;
        av_interleaved_write_frame(_fmt, pkt);
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
}

#pragma mark - Audio Encode（在 self.queue 内调用）

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

    // 配置 / 复用 SwrContext（输入 FLT 交错 → 输出 encoder 的 sample_fmt，44.1kHz 立体声）
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

    // header 未写时先积压在 FIFO，等首个视频 packet 写头后再消费
    if (_headerWritten) [self drainAudioFifo:NO];
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

        f->pts = _aNextPts;
        _aNextPts += frameSize;     // 含补零部分，保持连续
        [self sendAudioFrame:f];
        av_frame_free(&f);

        if (!flushAll && av_audio_fifo_size(_afifo) < frameSize) break;
        if (flushAll && take < frameSize) break;   // 尾部已取尽
    }
}

// frame 为 NULL 表示 flush；仅在 header 写入后调用
- (void)sendAudioFrame:(AVFrame *)frame {
    if (!_acodec) return;
    if (avcodec_send_frame(_acodec, frame) < 0) return;

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return;
    while (avcodec_receive_packet(_acodec, pkt) == 0) {
        av_packet_rescale_ts(pkt, _acodec->time_base, _astream->time_base);
        pkt->stream_index = _astream->index;
        av_interleaved_write_frame(_fmt, pkt);
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
}

@end
