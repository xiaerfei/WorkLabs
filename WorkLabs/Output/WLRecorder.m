//
//  WLRecorder.m
//  WorkLabs
//

#import "WLRecorder.h"
#import "WLEncodedPacket.h"
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"      // AV_TIME_BASE_Q

static const int kWLAacRate = 44100;

typedef NS_ENUM(NSInteger, WLRecMuxerState) {
    WLRecStateIdle = 0,
    WLRecStateAwaitingKeyframe,   // 已打开文件，等待首个视频关键帧以建流写头
    WLRecStateWriting,            // 已写头，正常写包
    WLRecStateClosed,             // 已写 trailer / 收尾
};

@interface WLRecorder () {
    AVFormatContext *_fmt;
    AVStream        *_vstream;
    AVStream        *_astream;
    int64_t          _baseUs;     // 公共零点（首个视频关键帧的微秒 pts）
    WLRecMuxerState  _state;
}
@property (atomic, assign, readwrite, getter=isRecording) BOOL recording;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy, nullable) NSString *path;
@end

@implementation WLRecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.worklabs.recorder.mux", DISPATCH_QUEUE_SERIAL);
        _state = WLRecStateIdle;
    }
    return self;
}

- (void)dealloc {
    if (self.recording) {
        self.recording = NO;
        dispatch_sync(self.queue, ^{
            if (self->_state == WLRecStateWriting && self->_fmt) av_write_trailer(self->_fmt);
            self->_state = WLRecStateClosed;
            [self teardown];
        });
    }
}

#pragma mark - Public

- (BOOL)startToPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error {
    if (self.recording || path.length == 0) return NO;

    __block BOOL ok = NO;
    __block NSString *errMsg = nil;
    dispatch_sync(self.queue, ^{
        ok = [self openMuxerWithPath:path errMsg:&errMsg];
        if (ok) {
            self->_state  = WLRecStateAwaitingKeyframe;
            self->_baseUs = 0;
            self.path = path;
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

- (void)writePacket:(WLEncodedPacket *)packet {
    if (!packet || !self.recording) return;
    dispatch_async(self.queue, ^{
        [self handlePacket:packet];
    });
}

- (void)stop {
    [self stopWithCompletion:nil];
}

- (void)stopWithCompletion:(void (^)(void))completion {
    if (!self.recording) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    self.recording = NO;   // 立即对外不可见
    dispatch_async(self.queue, ^{
        if (self->_state == WLRecStateWriting && self->_fmt) {
            av_write_trailer(self->_fmt);
            NSLog(@"[WLRecorder] trailer written → %@", self.path.lastPathComponent);
        }
        self->_state = WLRecStateClosed;
        [self teardown];
        NSLog(@"[WLRecorder] stopped");
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

#pragma mark - Muxer 打开 / 收尾（self.queue 内）

- (BOOL)openMuxerWithPath:(NSString *)path errMsg:(NSString * __strong *)errMsg {
    const char *cpath = path.fileSystemRepresentation;
    avformat_alloc_output_context2(&_fmt, NULL, NULL, cpath);
    if (!_fmt) { *errMsg = @"无法创建输出上下文（mp4）"; return NO; }

    if (!(_fmt->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&_fmt->pb, cpath, AVIO_FLAG_WRITE) < 0) {
            *errMsg = @"无法打开输出文件（检查路径/权限）";
            return NO;
        }
    }
    // 建流/写头延迟到首个视频关键帧（届时格式快照含 extradata 随包到达）
    NSLog(@"[WLRecorder] open → %@", path.lastPathComponent);
    return YES;
}

- (void)teardown {
    if (_fmt) {
        if (_fmt->pb && !(_fmt->oformat->flags & AVFMT_NOFILE)) {
            avio_closep(&_fmt->pb);
        }
        avformat_free_context(_fmt);
        _fmt = NULL;
    }
    _vstream = NULL;
    _astream = NULL;
    _baseUs = 0;
    _state = WLRecStateIdle;
}

#pragma mark - 写包（self.queue 内）

- (void)handlePacket:(WLEncodedPacket *)packet {
    // 收尾后到达的残包（stop 与 in-flight 写包的竞态）直接丢弃
    if (_state != WLRecStateAwaitingKeyframe && _state != WLRecStateWriting) return;

    if (_state == WLRecStateAwaitingKeyframe) {
        if (!(packet.isVideo && packet.isKeyframe)) return;   // 丢弃，直到首个视频关键帧
        if (![self openStreamsWithFormat:packet.format]) {
            NSLog(@"[WLRecorder] 建流/写头失败，停止录制");
            _state = WLRecStateClosed;
            return;
        }
        _baseUs = packet.ptsUs;   // 公共零点
        _state  = WLRecStateWriting;
    }

    if (packet.isVideo) [self writeVideoPacket:packet];
    else                [self writeAudioPacket:packet];
}

- (BOOL)openStreamsWithFormat:(WLStreamFormat *)format {
    if (!_fmt || !format) return NO;

    _vstream = avformat_new_stream(_fmt, NULL);
    if (!_vstream) return NO;
    if (![format copyVideoParametersTo:_vstream->codecpar]) return NO;
    _vstream->codecpar->codec_tag = 0;                 // 让 muxer 自定 tag（跨容器安全）
    _vstream->time_base = (AVRational){1, 90000};      // 足够细，避免 us→tb 取整破坏 DTS 单调

    if (format.hasAudio) {
        _astream = avformat_new_stream(_fmt, NULL);
        if (!_astream) return NO;
        if (![format copyAudioParametersTo:_astream->codecpar]) return NO;
        _astream->codecpar->codec_tag = 0;
        _astream->time_base = (AVRational){1, kWLAacRate};
    }

    if (avformat_write_header(_fmt, NULL) < 0) {
        NSLog(@"[WLRecorder] write_header 失败");
        return NO;
    }
    NSLog(@"[WLRecorder] 写头 video%@", _astream ? @"+audio" : @"");
    return YES;
}

- (void)writeVideoPacket:(WLEncodedPacket *)packet {
    if (!_vstream) return;
    AVPacket *pkt = av_packet_clone([packet packet]);   // write 会 unref，必须先 clone
    if (!pkt) return;
    int64_t outPts = packet.ptsUs - _baseUs;
    if (outPts < 0) outPts = 0;
    pkt->pts = outPts;
    pkt->dts = outPts;                                   // max_b_frames=0 ⇒ pts==dts
    pkt->stream_index = _vstream->index;
    pkt->pos = -1;
    av_packet_rescale_ts(pkt, AV_TIME_BASE_Q, _vstream->time_base);
    av_interleaved_write_frame(_fmt, pkt);               // 接管并 unref pkt
    av_packet_free(&pkt);                                // 释放空壳结构
}

- (void)writeAudioPacket:(WLEncodedPacket *)packet {
    if (!_astream) return;                               // 纯视频录制：丢弃音频包
    int64_t outPts = packet.ptsUs - _baseUs;
    if (outPts < 0) return;                              // 首关键帧之前的音频丢弃（保单调；epoch 对齐故不晚开声）
    AVPacket *pkt = av_packet_clone([packet packet]);
    if (!pkt) return;
    pkt->pts = outPts;
    pkt->dts = outPts;
    pkt->stream_index = _astream->index;
    pkt->pos = -1;
    av_packet_rescale_ts(pkt, AV_TIME_BASE_Q, _astream->time_base);
    av_interleaved_write_frame(_fmt, pkt);
    av_packet_free(&pkt);
}

@end
