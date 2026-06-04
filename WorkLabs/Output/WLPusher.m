//
//  WLPusher.m
//  WorkLabs
//

#import "WLPusher.h"
#import "WLEncodedPacket.h"
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"      // AV_TIME_BASE_Q

static const int kWLAacRate = 44100;

typedef NS_ENUM(NSInteger, WLPushMuxerState) {
    WLPushStateIdle = 0,
    WLPushStateAwaitingKeyframe,
    WLPushStateWriting,
    WLPushStateClosed,
};

@interface WLPusher () {
    AVFormatContext *_fmt;
    AVStream        *_vstream;
    AVStream        *_astream;
    int64_t          _baseUs;
    WLPushMuxerState _state;
    BOOL             _aborted;     // 写失败/断流：收尾并通知
}
@property (atomic, assign, readwrite, getter=isPushing) BOOL pushing;
@property (atomic, assign) BOOL connecting;
@property (nonatomic, copy, nullable) NSString *url;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation WLPusher

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.worklabs.pusher.mux", DISPATCH_QUEUE_SERIAL);
        _state = WLPushStateIdle;
    }
    return self;
}

- (void)dealloc {
    if (self.pushing) {
        dispatch_sync(self.queue, ^{
            if (self.pushing) { self.pushing = NO; [self teardown]; }
        });
    }
}

#pragma mark - Public

- (void)startWithURL:(NSString *)url {
    if (self.pushing || self.connecting || url.length == 0) return;
    self.connecting = YES;
    self.url = url;
    dispatch_async(self.queue, ^{
        NSString *errMsg = nil;
        BOOL ok = [self openMuxerWithURL:url errMsg:&errMsg];
        if (ok) {
            self->_state   = WLPushStateAwaitingKeyframe;
            self->_baseUs  = 0;
            self->_aborted = NO;
            self.pushing    = YES;
            self.connecting = NO;
            [self notifyStart];
        } else {
            [self teardown];
            self.connecting = NO;
            [self notifyFailWithMessage:(errMsg ?: @"推流连接失败")];
        }
    });
}

- (void)writePacket:(WLEncodedPacket *)packet {
    if (!packet || !self.pushing) return;
    dispatch_async(self.queue, ^{
        [self handlePacket:packet];
    });
}

- (void)stop {
    if (!self.pushing && !self.connecting) return;
    dispatch_async(self.queue, ^{
        BOOL was = self.pushing;
        self.pushing = NO;
        self.connecting = NO;
        if (was && !self->_aborted && self->_state == WLPushStateWriting && self->_fmt) {
            av_write_trailer(self->_fmt);
        }
        self->_state = WLPushStateClosed;
        [self teardown];
        [self notifyStop];
        NSLog(@"[WLPusher] stopped");
    });
}

#pragma mark - 断流收尾（queue 内）

- (void)finishAbort {
    if (_state == WLPushStateClosed) return;
    _state = WLPushStateClosed;
    self.pushing = NO;
    [self teardown];
    [self notifyFailWithMessage:@"推流中断（连接可能已断开）"];
    NSLog(@"[WLPusher] aborted");
}

#pragma mark - Muxer 打开 / 收尾（queue 内）

- (BOOL)openMuxerWithURL:(NSString *)url errMsg:(NSString * __strong *)errMsg {
    const char *curl = url.UTF8String;

    // FLV muxer（rtmp 无扩展名，需显式指定）
    avformat_alloc_output_context2(&_fmt, NULL, "flv", curl);
    if (!_fmt) { *errMsg = @"无法创建 FLV 输出上下文"; return NO; }

    // 连接 rtmp（阻塞握手/connect/publish；在后台 queue 执行）
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
    // 建流/写头延迟到首个视频关键帧（届时格式快照含 extradata 随包到达）
    NSLog(@"[WLPusher] connected → %@", url);
    return YES;
}

- (void)teardown {
    if (_fmt) {
        if (_fmt->pb) avio_closep(&_fmt->pb);
        avformat_free_context(_fmt);
        _fmt = NULL;
    }
    _vstream = NULL;
    _astream = NULL;
    _baseUs = 0;
    _aborted = NO;
    _state = WLPushStateIdle;
}

#pragma mark - 写包（queue 内）

- (void)handlePacket:(WLEncodedPacket *)packet {
    if (_state != WLPushStateAwaitingKeyframe && _state != WLPushStateWriting) return;
    if (_aborted) { [self finishAbort]; return; }

    if (_state == WLPushStateAwaitingKeyframe) {
        if (!(packet.isVideo && packet.isKeyframe)) return;   // 丢弃，直到首个视频关键帧
        if (![self openStreamsWithFormat:packet.format]) {
            [self finishAbort];
            return;
        }
        _baseUs = packet.ptsUs;
        _state  = WLPushStateWriting;
    }

    if (packet.isVideo) [self writeVideoPacket:packet];
    else                [self writeAudioPacket:packet];

    if (_aborted) [self finishAbort];   // 写失败 → 立即收尾通知
}

- (BOOL)openStreamsWithFormat:(WLStreamFormat *)format {
    if (!_fmt || !format) return NO;

    _vstream = avformat_new_stream(_fmt, NULL);
    if (!_vstream) return NO;
    if (![format copyVideoParametersTo:_vstream->codecpar]) return NO;
    _vstream->codecpar->codec_tag = 0;
    _vstream->time_base = (AVRational){1, 90000};

    if (format.hasAudio) {
        _astream = avformat_new_stream(_fmt, NULL);
        if (!_astream) return NO;
        if (![format copyAudioParametersTo:_astream->codecpar]) return NO;
        _astream->codecpar->codec_tag = 0;
        _astream->time_base = (AVRational){1, kWLAacRate};
    }

    if (avformat_write_header(_fmt, NULL) < 0) {
        NSLog(@"[WLPusher] write_header 失败");
        return NO;
    }
    NSLog(@"[WLPusher] 写头 video%@", _astream ? @"+audio" : @"");
    return YES;
}

- (void)writeVideoPacket:(WLEncodedPacket *)packet {
    if (!_vstream) return;
    AVPacket *pkt = av_packet_clone([packet packet]);
    if (!pkt) return;
    int64_t outPts = packet.ptsUs - _baseUs;
    if (outPts < 0) outPts = 0;
    pkt->pts = outPts;
    pkt->dts = outPts;
    pkt->stream_index = _vstream->index;
    pkt->pos = -1;
    av_packet_rescale_ts(pkt, AV_TIME_BASE_Q, _vstream->time_base);
    if (av_interleaved_write_frame(_fmt, pkt) < 0) _aborted = YES;   // 断流检测
    av_packet_free(&pkt);
}

- (void)writeAudioPacket:(WLEncodedPacket *)packet {
    if (!_astream) return;
    int64_t outPts = packet.ptsUs - _baseUs;
    if (outPts < 0) return;
    AVPacket *pkt = av_packet_clone([packet packet]);
    if (!pkt) return;
    pkt->pts = outPts;
    pkt->dts = outPts;
    pkt->stream_index = _astream->index;
    pkt->pos = -1;
    av_packet_rescale_ts(pkt, AV_TIME_BASE_Q, _astream->time_base);
    if (av_interleaved_write_frame(_fmt, pkt) < 0) _aborted = YES;
    av_packet_free(&pkt);
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

@end
