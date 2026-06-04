//
//  WLEncodedPacket.m
//  WorkLabs
//

#import "WLEncodedPacket.h"
#include "libavcodec/avcodec.h"

#pragma mark - WLStreamFormat

@implementation WLStreamFormat {
    AVCodecParameters *_videoPar;
    AVCodecParameters *_audioPar;
}

- (instancetype)initWithVideoCodecContext:(const AVCodecContext *)vctx
                        audioCodecContext:(const AVCodecContext *)actx {
    self = [super init];
    if (self) {
        if (!vctx) return nil;
        _videoPar = avcodec_parameters_alloc();
        if (!_videoPar || avcodec_parameters_from_context(_videoPar, vctx) < 0) {
            if (_videoPar) avcodec_parameters_free(&_videoPar);
            return nil;
        }
        // 音频 best-effort：失败则降级为纯视频（_audioPar 保持 NULL）
        if (actx) {
            _audioPar = avcodec_parameters_alloc();
            if (_audioPar && avcodec_parameters_from_context(_audioPar, actx) < 0) {
                avcodec_parameters_free(&_audioPar);
            }
        }
    }
    return self;
}

- (void)dealloc {
    if (_videoPar) avcodec_parameters_free(&_videoPar);
    if (_audioPar) avcodec_parameters_free(&_audioPar);
}

- (BOOL)hasAudio { return _audioPar != NULL; }

- (BOOL)copyVideoParametersTo:(AVCodecParameters *)dst {
    if (!dst || !_videoPar) return NO;
    return avcodec_parameters_copy(dst, _videoPar) >= 0;
}

- (BOOL)copyAudioParametersTo:(AVCodecParameters *)dst {
    if (!dst || !_audioPar) return NO;
    return avcodec_parameters_copy(dst, _audioPar) >= 0;
}

@end

#pragma mark - WLEncodedPacket

@implementation WLEncodedPacket {
    AVPacket *_pkt;
}

- (instancetype)initWithPacket:(AVPacket *)src isVideo:(BOOL)isVideo format:(WLStreamFormat *)format {
    self = [super init];
    if (self) {
        if (!src) return nil;
        _pkt = av_packet_clone(src);   // 引用计数共享底层 buffer
        if (!_pkt) return nil;
        _isVideo    = isVideo;
        _isKeyframe = (_pkt->flags & AV_PKT_FLAG_KEY) != 0;
        _ptsUs      = _pkt->pts;
        _format     = format;
    }
    return self;
}

- (void)dealloc {
    if (_pkt) av_packet_free(&_pkt);
}

- (AVPacket *)packet { return _pkt; }

@end
