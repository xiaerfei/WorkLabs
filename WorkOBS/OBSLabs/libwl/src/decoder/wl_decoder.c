//
//  wl_decoder.c
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//

#include "wl_decoder.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/avutil.h>

typedef struct wl_decoder_t {
    const char *path;
    AVFormatContext *fmt_ctx;
    int video_index; ///< 视频索引
    int audio_index; ///< 音频索引
    
    AVCodecContext *video_codec_ctx; ///< Video 解码器
    AVBufferRef *hw_device_ctx; ///< 硬解码
} wl_decoder_t;

#pragma mark - Private Methods
static void print_av_error(const char *prefix, int errnum) {
    char errbuf[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(errnum, errbuf, sizeof(errbuf));
    fprintf(stderr, "%s: %s\n", prefix, errbuf);
}

static int wl_decoder_ffmpeg_init(wl_decoder_t *decoder) {
    AVFormatContext *fmt_ctx = NULL;
    int ret = avformat_open_input(&fmt_ctx, decoder->path, NULL, NULL);
    if (ret < 0) {
        print_av_error("avformat_open_input", ret);
        return -1;
    }
    decoder->fmt_ctx = fmt_ctx;
    return 0;
}

static int wl_decoder_find_stream(wl_decoder_t *decoder) {
    AVFormatContext *fmt_ctx = decoder->fmt_ctx;
    int ret = avformat_find_stream_info(fmt_ctx, NULL);
    if (ret < 0) {
        print_av_error("avformat_find_stream_info", ret);
        return -1;
    }
    
    return 0;
}

static int wl_decoder_find_video_stream(wl_decoder_t *decoder) {
    AVFormatContext *fmt_ctx = decoder->fmt_ctx;
    const AVCodec *codec = NULL;
    int streamIndex = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (streamIndex < 0) {
        print_av_error("avformat_find_video_stream_info", streamIndex);
        return -1;
    }
    decoder->video_index = streamIndex;
    return 0;
}
// 配置 video decoder，失败返回 -1，成功返回 0
static int wl_decoder_cfgd_video(wl_decoder_t *decoder) {
    AVFormatContext *fmt_ctx = decoder->fmt_ctx;
    AVStream *stream = fmt_ctx->streams[decoder->video_index];
    // 1. 查找对应的基础解码器
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        // 错误日志：找不到对应的解码器
        print_av_error("Video: can not find codec", AVERROR(ENOMEM));
        return -1;
    }
    
    // 2. 分配解码器上下文
    decoder->video_codec_ctx = avcodec_alloc_context3(codec);
    if (!decoder->video_codec_ctx) {
        print_av_error("Video: video_codec_ctx is null", AVERROR(ENOMEM));
        return -1;
    }
    
    // 3. 将流的参数（如分辨率、码率等）复制到解码器上下文中
    int ret = avcodec_parameters_to_context(decoder->video_codec_ctx, stream->codecpar);
    if (ret < 0) {
        avcodec_free_context(&decoder->video_codec_ctx);
        print_av_error("Video: video_codec_ctx is null", ret);
        return -1;
    }
    
    // 4. [MacOS 独有] 配置 VideoToolbox 硬件加速
    decoder->hw_device_ctx = NULL;
    
    if (av_hwdevice_find_type_by_name("videotoolbox") != AV_HWDEVICE_TYPE_NONE) {
        int hw_err = av_hwdevice_ctx_create(&decoder->hw_device_ctx,
                                            AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                            NULL, NULL, 0);
        if (hw_err >= 0) {
            // 创建成功，将其引用绑定到解码器上下文中
            decoder->video_codec_ctx->hw_device_ctx = av_buffer_ref(decoder->hw_device_ctx);
            // 可选：打印日志提示硬件加速已启用
        } else {
            // 失败则置空，FFmpeg 会自动走默认的 CPU 软解，不需要退出
            print_av_error("Video: hw codec error", hw_err);
            decoder->hw_device_ctx = NULL;
            /*
             多线程安全（可选优化）：
             在打开视频解码器前，通常建议加上, 这样如果后续触发了软解降级，
             FFmpeg 会自动根据用户的 CPU 核心数开启多线程软解，大大提升软解效率。
             */
            decoder->video_codec_ctx->thread_count = 0;
        }
    }
    
    // 5. 正式打开解码器
    ret = avcodec_open2(decoder->video_codec_ctx, codec, NULL);
    if (ret < 0) {
        // 如果打开失败，清理所有已分配的资源
        if (decoder->hw_device_ctx) {
            av_buffer_unref(&decoder->hw_device_ctx);
        }
        avcodec_free_context(&decoder->video_codec_ctx);
        print_av_error("Video: hw codec avcodec_open2 error", ret);
        return -1;
    }
    
    return 0;
}

void wl_decoder_video_codec_free(wl_decoder_t *decoder) {
    if (decoder->video_codec_ctx) {
        avcodec_free_context(&decoder->video_codec_ctx);
    }
    if (decoder->hw_device_ctx) {
        // 必须用 unref 减少引用计数，才能真正释放 GPU 硬件上下文
        av_buffer_unref(&decoder->hw_device_ctx);
    }
}


static int wl_decoder_find_audio_stream(wl_decoder_t *decoder) {
    AVFormatContext *fmt_ctx = decoder->fmt_ctx;
    const AVCodec *codec = NULL;
    int streamIndex = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (streamIndex < 0) {
        print_av_error("avformat_find_audio_stream_info", streamIndex);
        return -1;
    }
    decoder->audio_index = streamIndex;
    return 0;
}

// 配置 audio decoder
static int wl_decoder_cfgd_audio(wl_decoder_t *decoder) {
    
    return 0;
}

#pragma mark - Public Methods
wl_decoder_t *wl_decoder_create(const char *path) {
    wl_decoder_t *decoder = malloc(sizeof(wl_decoder_t));
    decoder->path = path;
    int ret = wl_decoder_ffmpeg_init(decoder);
    if (ret != 0) {
        free(decoder);
        decoder = NULL;
    }
    return decoder;
}

void wl_decoder_free(wl_decoder_t *decoder) {
    if (decoder == NULL) return;
    wl_decoder_video_codec_free(decoder);
    
    
    free(decoder);
}



