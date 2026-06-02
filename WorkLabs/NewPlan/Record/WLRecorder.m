//
//  WLRecorder.m
//  WorkLabs
//

#import "WLRecorder.h"
#include <math.h>
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/imgutils.h"
#include "libavutil/opt.h"
#include "libswscale/swscale.h"

@interface WLRecorder () {
    AVFormatContext     *_fmt;
    AVStream            *_vstream;
    AVCodecContext      *_vcodec;
    struct SwsContext   *_sws;
    AVFrame             *_frame;
    int                  _width;
    int                  _height;
    int                  _fps;
    BOOL                 _ptsBaseSet;   // 首帧 pts 基准已设
    Float64              _startPts;
    int64_t              _lastPts;
    BOOL                 _headerWritten; // 延迟到首个 packet 再写头（videotoolbox extradata 时序）
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
                       error:(NSError * _Nullable * _Nullable)error {
    if (self.recording || path.length == 0) return NO;

    __block BOOL ok = NO;
    __block NSString *errMsg = nil;
    dispatch_sync(self.queue, ^{
        ok = [self setupWithPath:path
                           width:(int)videoSize.width
                          height:(int)videoSize.height
                             fps:fps
                          errMsg:&errMsg];
        if (ok) {
            self->_ptsBaseSet = NO;
            self->_lastPts = -1;
            self->_headerWritten = NO;
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

- (void)stopRecording {
    if (!self.recording) return;
    dispatch_sync(self.queue, ^{
        self.recording = NO;
        if (self->_vcodec) {
            [self drainEncoder:NULL]; // flush
        }
        if (self->_headerWritten && self->_fmt) {
            av_write_trailer(self->_fmt);
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

    if (!(_fmt->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&_fmt->pb, cpath, AVIO_FLAG_WRITE) < 0) {
            *errMsg = @"无法打开输出文件（检查路径/权限）";
            return NO;
        }
    }

    // 注意：write_header 延迟到首个 packet（此时 videotoolbox 才填好 extradata/SPS/PPS）

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

    NSLog(@"[WLRecorder] start %dx%d @%dfps → %@", w, h, _fps, path.lastPathComponent);
    return YES;
}

- (void)teardown {
    if (_sws)    { sws_freeContext(_sws); _sws = NULL; }
    if (_frame)  { av_frame_free(&_frame); }
    if (_vcodec) { avcodec_free_context(&_vcodec); }
    if (_fmt) {
        if (_fmt->pb && !(_fmt->oformat->flags & AVFMT_NOFILE)) {
            avio_closep(&_fmt->pb);
        }
        avformat_free_context(_fmt);
        _fmt = NULL;
    }
    _vstream = NULL;
    _ptsBaseSet = NO;
    _headerWritten = NO;
    _lastPts = -1;
}

#pragma mark - Encode（在 self.queue 内调用）

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

    if (!_ptsBaseSet) { _startPts = pts; _ptsBaseSet = YES; }
    int64_t framePts = (int64_t)llround((pts - _startPts) * 1000.0); // ms
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
        // 首个 packet：此时 encoder 已生成 extradata(SPS/PPS)，先写头
        if (!_headerWritten) {
            avcodec_parameters_from_context(_vstream->codecpar, _vcodec);
            _vstream->time_base = _vcodec->time_base;
            if (avformat_write_header(_fmt, NULL) < 0) {
                NSLog(@"[WLRecorder] write_header failed");
                av_packet_unref(pkt);
                break;
            }
            _headerWritten = YES;
        }
        av_packet_rescale_ts(pkt, _vcodec->time_base, _vstream->time_base);
        pkt->stream_index = _vstream->index;
        av_interleaved_write_frame(_fmt, pkt);
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
}

@end
