//
//  wl_decoder.c
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//

#include "wl_decoder.h"
#include <stdbool.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/avutil.h>
#include <libavutil/mathematics.h>

typedef struct wl_decoder_t {
    const char *path;
    const char *hw_type; ///< 硬件加速类型名称（如 "videotoolbox"），NULL 表示纯软解
    AVFormatContext *fmt_ctx;
    int video_index; ///< 视频索引
    int audio_index; ///< 音频索引

    AVCodecContext *video_codec_ctx; ///< Video 解码器
    AVCodecContext *audio_codec_ctx; ///< Audio 解码器
    AVBufferRef *hw_device_ctx; ///< 硬解码

    bool eof_reached;   ///< av_read_frame 已返回 EOF
    bool video_drained; ///< video codec 已 flush 且无更多输出
    bool audio_drained; ///< audio codec 已 flush 且无更多输出
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
// 注意：失败时不自行释放，统一由 wl_decoder_free 收尾
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
        print_av_error("Video: avcodec_parameters_to_context failed", ret);
        return -1;
    }

    // 4. 配置硬件加速（由外部指定 hw_type，如 "videotoolbox"）
    decoder->hw_device_ctx = NULL;

    if (decoder->hw_type) {
        enum AVHWDeviceType hw_type = av_hwdevice_find_type_by_name(decoder->hw_type);
        if (hw_type == AV_HWDEVICE_TYPE_NONE) {
            fprintf(stderr, "Video: unknown hw device type '%s', falling back to software\n", decoder->hw_type);
            decoder->video_codec_ctx->thread_count = 0;
            goto open_codec;
        }
        int hw_err = av_hwdevice_ctx_create(&decoder->hw_device_ctx,
                                            hw_type,
                                            NULL, NULL, 0);
        if (hw_err >= 0) {
            // 创建成功，将其引用绑定到解码器上下文中
            AVBufferRef *ref = av_buffer_ref(decoder->hw_device_ctx);
            if (ref) {
                decoder->video_codec_ctx->hw_device_ctx = ref;
            } else {
                // av_buffer_ref OOM，降级为软解
                print_av_error("Video: av_buffer_ref failed, falling back to software", AVERROR(ENOMEM));
                av_buffer_unref(&decoder->hw_device_ctx);
                decoder->hw_device_ctx = NULL;
                decoder->video_codec_ctx->thread_count = 0;
            }
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

open_codec:
    // 5. 正式打开解码器
    ret = avcodec_open2(decoder->video_codec_ctx, codec, NULL);
    if (ret < 0) {
        print_av_error("Video: avcodec_open2 failed", ret);
        return -1;
    }
    return 0;
}

void wl_decoder_video_codec_free(wl_decoder_t *decoder) {
    if (decoder->video_codec_ctx) {
        avcodec_free_context(&decoder->video_codec_ctx);
        decoder->video_codec_ctx = NULL;
    }
    if (decoder->hw_device_ctx) {
        // 必须用 unref 减少引用计数，才能真正释放 GPU 硬件上下文
        av_buffer_unref(&decoder->hw_device_ctx);
        decoder->hw_device_ctx = NULL;
    }
}

void wl_decoder_audio_codec_free(wl_decoder_t *decoder) {
    if (decoder->audio_codec_ctx) {
        avcodec_free_context(&decoder->audio_codec_ctx);
        decoder->audio_codec_ctx = NULL;
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

// 配置 audio decoder，失败返回 -1，成功返回 0
// 注意：失败时不自行释放，统一由 wl_decoder_free 收尾
static int wl_decoder_cfgd_audio(wl_decoder_t *decoder) {
    AVFormatContext *fmt_ctx = decoder->fmt_ctx;
    AVStream *stream = fmt_ctx->streams[decoder->audio_index];

    // 1. 查找对应的音频解码器
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        print_av_error("Audio: can not find codec", AVERROR(ENOMEM));
        return -1;
    }

    // 2. 分配解码器上下文
    decoder->audio_codec_ctx = avcodec_alloc_context3(codec);
    if (!decoder->audio_codec_ctx) {
        print_av_error("Audio: audio_codec_ctx is null", AVERROR(ENOMEM));
        return -1;
    }

    // 3. 将流的参数（采样率、声道数、采样格式等）复制到解码器上下文中
    int ret = avcodec_parameters_to_context(decoder->audio_codec_ctx, stream->codecpar);
    if (ret < 0) {
        print_av_error("Audio: avcodec_parameters_to_context failed", ret);
        return -1;
    }

    // 4. 打开解码器
    ret = avcodec_open2(decoder->audio_codec_ctx, codec, NULL);
    if (ret < 0) {
        print_av_error("Audio: avcodec_open2 failed", ret);
        return -1;
    }

    return 0;
}

#pragma mark - Public Methods
wl_decoder_t *wl_decoder_create(const char *path, const char *hw_type) {
    wl_decoder_t *decoder = calloc(1, sizeof(wl_decoder_t));
    decoder->path = path;
    decoder->hw_type = hw_type;
    int ret = wl_decoder_ffmpeg_init(decoder);
    if (ret != 0) {
        wl_decoder_free(decoder);
        return NULL;
    }
    ret = wl_decoder_find_stream(decoder);
    if (ret != 0) { wl_decoder_free(decoder); return NULL; }
    ret = wl_decoder_find_video_stream(decoder);
    if (ret != 0) { wl_decoder_free(decoder); return NULL; }
    ret = wl_decoder_cfgd_video(decoder);
    if (ret != 0) { wl_decoder_free(decoder); return NULL; }
    ret = wl_decoder_find_audio_stream(decoder);
    if (ret != 0) { wl_decoder_free(decoder); return NULL; }
    ret = wl_decoder_cfgd_audio(decoder);
    if (ret != 0) { wl_decoder_free(decoder); return NULL; }
    return decoder;
}

void wl_decoder_free(wl_decoder_t *decoder) {
    if (decoder == NULL) return;

    // 1. 释放 video codec + hw device ctx
    wl_decoder_video_codec_free(decoder);

    // 2. 释放 audio codec
    wl_decoder_audio_codec_free(decoder);

    // 3. 关闭 AVFormatContext（内部会 avformat_free_context + 置 NULL）
    if (decoder->fmt_ctx) {
        avformat_close_input(&decoder->fmt_ctx);
        decoder->fmt_ctx = NULL;
    }

    free(decoder);
}

/**
 * 获取当前 FFmpeg 构建版本及当前主机系统真正支持的硬件加速列表
 * @return HWAccelList 结构体（值传递，无需外部手动 free）
 */
HWAccelList wl_decoder_get_supported_hwaccels(void) {
    HWAccelList list;
    list.count = 0;
    
    enum AVHWDeviceType type = AV_HWDEVICE_TYPE_NONE;
    
    // 迭代遍历当前环境编译进去的所有硬件设备类型
    while ((type = av_hwdevice_iterate_types(type)) != AV_HWDEVICE_TYPE_NONE) {
        const char *name = av_hwdevice_get_type_name(type);
        
        if (name) {
            // 工业级防御性编程：防止未来 FFmpeg 支持的硬解类型超出我们数组的上限
            if (list.count < MAX_HW_ACCELS) {
                list.names[list.count] = name;
                list.count++;
            } else {
                fprintf(stderr, "[HW] Warning: Supported hardware accelerators exceeded MAX_HW_ACCELS\n");
                break;
            }
        }
    }

    return list;
}

// ---- wl_media_thread 用的细粒度 API ----

wl_read_result_t wl_decoder_read(wl_decoder_t *decoder) {
    if (decoder->eof_reached) return WL_READ_EOF;

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return WL_READ_ERROR;

    int ret = av_read_frame(decoder->fmt_ctx, pkt);
    if (ret == AVERROR_EOF) {
        // 文件读完，flush 两个解码器（send NULL 触发 drain）
        av_packet_free(&pkt);
        decoder->eof_reached = true;
        if (decoder->video_codec_ctx && decoder->video_index >= 0)
            avcodec_send_packet(decoder->video_codec_ctx, NULL);
        if (decoder->audio_codec_ctx && decoder->audio_index >= 0)
            avcodec_send_packet(decoder->audio_codec_ctx, NULL);
        return WL_READ_EOF;
    }
    if (ret < 0) {
        av_packet_free(&pkt);
        return WL_READ_ERROR;
    }

    wl_read_result_t result;
    if (pkt->stream_index == decoder->video_index && decoder->video_codec_ctx) {
        avcodec_send_packet(decoder->video_codec_ctx, pkt);
        result = WL_READ_VIDEO;
    } else if (pkt->stream_index == decoder->audio_index && decoder->audio_codec_ctx) {
        avcodec_send_packet(decoder->audio_codec_ctx, pkt);
        result = WL_READ_AUDIO;
    } else {
        result = WL_READ_SKIP;
    }

    av_packet_free(&pkt);
    return result;
}

static wl_frame_result_t receive_frame(AVCodecContext *ctx,
                                        AVFrame *frame,
                                        AVRational time_base,
                                        AVFrame **out_frame,
                                        int64_t  *out_pts_ns) {
    int ret = avcodec_receive_frame(ctx, frame);
    // 严格区分两种"没帧"：
    //   EAGAIN → 只是还需要喂 packet，codec 没结束（不能据此判定 drained）
    //   EOF    → codec 已排空，不会再有输出（真正结束）
    if (ret == AVERROR(EAGAIN))
        return WL_FRAME_AGAIN;
    if (ret == AVERROR_EOF)
        return WL_FRAME_EOF;
    if (ret < 0)
        return WL_FRAME_ERROR;

    // 复制一份给调用方（frame 本身留给下一次 receive 复用）
    AVFrame *ref = av_frame_alloc();
    if (!ref) {
        av_frame_unref(frame);
        return WL_FRAME_ERROR;
    }
    av_frame_move_ref(ref, frame);

    *out_frame = ref;
    *out_pts_ns = av_rescale_q(ref->pts, time_base,
                                (AVRational){1, 1000000000});
    return WL_FRAME_OK;
}

wl_frame_result_t wl_decoder_receive_video(wl_decoder_t *decoder,
                                            AVFrame **out_frame,
                                            int64_t  *out_pts_ns) {
    if (!decoder->video_codec_ctx) {
        decoder->video_drained = true;   // 无视频流 → 视为永久排空
        return WL_FRAME_EOF;
    }
    AVFrame *frame = av_frame_alloc();
    if (!frame) return WL_FRAME_ERROR;

    AVRational tb = (decoder->video_index >= 0)
        ? decoder->fmt_ctx->streams[decoder->video_index]->time_base
        : (AVRational){1, 1};

    wl_frame_result_t r = receive_frame(decoder->video_codec_ctx,
                                         frame, tb, out_frame, out_pts_ns);
    if (r == WL_FRAME_EOF)   // 仅真 EOF 才算排空；EAGAIN 不是
        decoder->video_drained = true;

    av_frame_free(&frame);
    return r;
}

wl_frame_result_t wl_decoder_receive_audio(wl_decoder_t *decoder,
                                            AVFrame **out_frame,
                                            int64_t  *out_pts_ns) {
    if (!decoder->audio_codec_ctx) {
        decoder->audio_drained = true;   // 无音频流 → 视为永久排空
        return WL_FRAME_EOF;
    }
    AVFrame *frame = av_frame_alloc();
    if (!frame) return WL_FRAME_ERROR;

    AVRational tb = (decoder->audio_index >= 0)
        ? decoder->fmt_ctx->streams[decoder->audio_index]->time_base
        : (AVRational){1, 1};

    wl_frame_result_t r = receive_frame(decoder->audio_codec_ctx,
                                         frame, tb, out_frame, out_pts_ns);
    if (r == WL_FRAME_EOF)   // 仅真 EOF 才算排空；EAGAIN 不是
        decoder->audio_drained = true;

    av_frame_free(&frame);
    return r;
}

bool wl_decoder_drained(wl_decoder_t *decoder) {
    return decoder->video_drained && decoder->audio_drained;
}

void wl_decoder_flush(wl_decoder_t *decoder) {
    // ⚠️ 坑：seek 必须用 avcodec_flush_buffers()，绝不能用 avcodec_send_packet(NULL)！
    //   send(NULL) 是 EOF 排空信号 —— 之后 codec 进入 draining 模式、拒收新 packet
    //   （send 真实包返回 AVERROR_EOF），必须再 flush_buffers 才能复用。
    //   而 seek 之后还要继续喂包，所以这里用 flush_buffers：丢弃内部缓存帧 + 重置
    //   解码器状态，使其重新接收新 packet。
    //   （EOF drain 的 send(NULL) 在 wl_decoder_read 的 AVERROR_EOF 分支里单独处理，
    //    两者语义相反，切勿混用。）
    if (decoder->video_codec_ctx)
        avcodec_flush_buffers(decoder->video_codec_ctx);
    if (decoder->audio_codec_ctx)
        avcodec_flush_buffers(decoder->audio_codec_ctx);

    // seek 可能从 EOF 之后往回跳，重置文件级 + 解码器级的结束标志
    decoder->eof_reached   = false;
    decoder->video_drained = false;
    decoder->audio_drained = false;
}
