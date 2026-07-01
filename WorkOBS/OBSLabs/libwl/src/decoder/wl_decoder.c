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

    AVPacket *pkt;         ///< 复用的读包缓冲（避免每次 av_packet_alloc/free）
    AVFrame  *video_frame; ///< 复用的 receive 帧缓冲（video）
    AVFrame  *audio_frame; ///< 复用的 receive 帧缓冲（audio）

    bool eof_reached;   ///< av_read_frame 已返回 EOF
    bool video_drained; ///< video codec 已 flush 且无更多输出
    bool audio_drained; ///< audio codec 已 flush 且无更多输出

    // PTS 外推状态（对标 OBS mp_decode_next：best_effort_timestamp 仍是
    // AV_NOPTS_VALUE 时，用上一帧位置 + 估算时长顶上，不把 NOPTS 传给下游）。
    int64_t video_next_pts_ns;      ///< 下一帧的预测位置
    int64_t video_last_pts_ns;      ///< 上一帧实际采用的 pts（AV_NOPTS_VALUE=尚无）
    int64_t video_last_duration_ns; ///< 上次估算出的时长（duration 缺失时的二级兜底，0=尚无）
    int64_t audio_next_pts_ns;      ///< 下一帧的预测位置（音频时长由 nb_samples 直接算，无需二级兜底）
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

    // calloc 默认清零，但 0 是合法的真实 pts（比如第一帧）；用 AV_NOPTS_VALUE
    // 作初值才能明确区分"真的还没有上一帧"和"上一帧 pts 恰好是 0"。
    decoder->video_next_pts_ns = AV_NOPTS_VALUE;
    decoder->video_last_pts_ns = AV_NOPTS_VALUE;
    decoder->audio_next_pts_ns = AV_NOPTS_VALUE;
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

    decoder->pkt = av_packet_alloc();
    decoder->video_frame = av_frame_alloc();
    decoder->audio_frame = av_frame_alloc();
    if (!decoder->pkt || !decoder->video_frame || !decoder->audio_frame) {
        wl_decoder_free(decoder);
        return NULL;
    }

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

    // 4. 释放复用的读包/帧缓冲（对 NULL 安全，兼容 create 半途失败）
    av_packet_free(&decoder->pkt);
    av_frame_free(&decoder->video_frame);
    av_frame_free(&decoder->audio_frame);

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

    AVPacket *pkt = decoder->pkt;   // 复用同一个 packet，避免每次堆分配

    int ret = av_read_frame(decoder->fmt_ctx, pkt);
    if (ret == AVERROR_EOF) {
        // 文件读完，给两个 codec 送 NULL 触发 drain（EOF 排空，非 seek flush）。
        // 出错/EOF 时 av_read_frame 已把 pkt 置空，无需 unref。
        // drain send 返回值：EOF / EAGAIN 都是预期的软状态（重复 flush / 尚有
        // 输出待取）→ 忽略；只有硬错误才记日志，且不改流程——后续 receive
        // 会自然走到 EOF 结束。
        decoder->eof_reached = true;
        int vret = decoder->video_codec_ctx
                       ? avcodec_send_packet(decoder->video_codec_ctx, NULL) : 0;
        int aret = decoder->audio_codec_ctx
                       ? avcodec_send_packet(decoder->audio_codec_ctx, NULL) : 0;
        if (vret < 0 && vret != AVERROR_EOF && vret != AVERROR(EAGAIN))
            print_av_error("avcodec_send_packet(video drain)", vret);
        if (aret < 0 && aret != AVERROR_EOF && aret != AVERROR(EAGAIN))
            print_av_error("avcodec_send_packet(audio drain)", aret);
        return WL_READ_EOF;
    }
    if (ret < 0) {
        print_av_error("av_read_frame", ret);
        return WL_READ_ERROR;
    }

    int send_ret = 0;
    wl_read_result_t result;
    if (pkt->stream_index == decoder->video_index && decoder->video_codec_ctx) {
        send_ret = avcodec_send_packet(decoder->video_codec_ctx, pkt);
        result = WL_READ_VIDEO;
    } else if (pkt->stream_index == decoder->audio_index && decoder->audio_codec_ctx) {
        send_ret = avcodec_send_packet(decoder->audio_codec_ctx, pkt);
        result = WL_READ_AUDIO;
    } else {
        result = WL_READ_SKIP;   // 字幕 / 数据流，跳过
    }

    av_packet_unref(pkt);   // 释放本次引用，packet 结构留给下次复用

    // 串行 drain-first 设计下 send 不该返回 EAGAIN；真错误（codec 异常等）上报。
    if (send_ret < 0) {
        print_av_error("avcodec_send_packet", send_ret);
        return WL_READ_ERROR;
    }
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
    // best_effort_timestamp：libavcodec 内部已做 pts/dts 兜底 + 启发式估算，
    // 优先于裸 pts 读取。AV_ROUND_PASS_MINMAX 让 AV_NOPTS_VALUE(INT64_MIN)
    // 原样透传，不会被当成普通数字换算出一个看似正常却毫无意义的时间戳。
    *out_pts_ns = av_rescale_q_rnd(ref->best_effort_timestamp, time_base,
                                   (AVRational){1, 1000000000},
                                   AV_ROUND_NEAR_INF | AV_ROUND_PASS_MINMAX);
    return WL_FRAME_OK;
}

wl_frame_result_t wl_decoder_receive_video(wl_decoder_t *decoder,
                                            AVFrame **out_frame,
                                            int64_t  *out_pts_ns) {
    if (!decoder->video_codec_ctx) {
        decoder->video_drained = true;   // 无视频流 → 视为永久排空
        return WL_FRAME_EOF;
    }

    AVRational tb = (decoder->video_index >= 0)
        ? decoder->fmt_ctx->streams[decoder->video_index]->time_base
        : (AVRational){1, 1};

    // decoder->video_frame 复用：avcodec_receive_frame 内部会先对它做
    // av_frame_unref，成功时内容被 move 进新分配的 out_frame（见
    // receive_frame），frame 结构体本身留给下次调用复用。
    wl_frame_result_t r = receive_frame(decoder->video_codec_ctx,
                                         decoder->video_frame, tb,
                                         out_frame, out_pts_ns);
    if (r == WL_FRAME_EOF) {   // 仅真 EOF 才算排空；EAGAIN 不是
        decoder->video_drained = true;
        return r;
    }
    if (r != WL_FRAME_OK)
        return r;

    // ── PTS 外推（对标 OBS mp_decode_next + get_estimated_duration）──
    // best_effort_timestamp 仍是 AV_NOPTS_VALUE 时（libavcodec 也没辙），
    // 用上一帧的推算位置顶上，不把 NOPTS 传给下游。
    int64_t last_pts_ns = decoder->video_last_pts_ns;
    int64_t pts_ns = *out_pts_ns;
    if (pts_ns == AV_NOPTS_VALUE)
        pts_ns = decoder->video_next_pts_ns;

    // 帧时长三级兜底：① codec 给的 pkt_duration ② 上一帧位置差值
    // ③ 上次估算出的时长 ④ 该流 time_base 的一个 tick（最后一道防线）
    int64_t duration_ns;
    if ((*out_frame)->pkt_duration > 0) {
        duration_ns = av_rescale_q((*out_frame)->pkt_duration, tb,
                                    (AVRational){1, 1000000000});
    } else if (last_pts_ns != AV_NOPTS_VALUE) {
        duration_ns = pts_ns - last_pts_ns;
    } else if (decoder->video_last_duration_ns > 0) {
        duration_ns = decoder->video_last_duration_ns;
    } else {
        duration_ns = av_rescale_q(1, tb, (AVRational){1, 1000000000});
    }

    decoder->video_last_duration_ns = duration_ns;
    decoder->video_last_pts_ns = pts_ns;
    decoder->video_next_pts_ns = pts_ns + duration_ns;
    *out_pts_ns = pts_ns;

    return WL_FRAME_OK;
}

wl_frame_result_t wl_decoder_receive_audio(wl_decoder_t *decoder,
                                            AVFrame **out_frame,
                                            int64_t  *out_pts_ns) {
    if (!decoder->audio_codec_ctx) {
        decoder->audio_drained = true;   // 无音频流 → 视为永久排空
        return WL_FRAME_EOF;
    }

    AVRational tb = (decoder->audio_index >= 0)
        ? decoder->fmt_ctx->streams[decoder->audio_index]->time_base
        : (AVRational){1, 1};

    // decoder->audio_frame 复用，语义同 wl_decoder_receive_video。
    wl_frame_result_t r = receive_frame(decoder->audio_codec_ctx,
                                         decoder->audio_frame, tb,
                                         out_frame, out_pts_ns);
    if (r == WL_FRAME_EOF) {   // 仅真 EOF 才算排空；EAGAIN 不是
        decoder->audio_drained = true;
        return r;
    }
    if (r != WL_FRAME_OK)
        return r;

    // ── PTS 外推 ──
    // 音频时长可以直接由 nb_samples/sample_rate 精确算出，不需要像视频那样
    // 三级兜底；best_effort_timestamp 仍是 NOPTS 时用上一帧推算位置顶上。
    int64_t pts_ns = *out_pts_ns;
    if (pts_ns == AV_NOPTS_VALUE)
        pts_ns = decoder->audio_next_pts_ns;

    int64_t duration_ns = av_rescale_q((*out_frame)->nb_samples,
                                        (AVRational){1, (*out_frame)->sample_rate},
                                        (AVRational){1, 1000000000});

    decoder->audio_next_pts_ns = pts_ns + duration_ns;
    *out_pts_ns = pts_ns;

    return WL_FRAME_OK;
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
