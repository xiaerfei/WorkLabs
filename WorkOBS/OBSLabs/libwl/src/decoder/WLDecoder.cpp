//
//  WLDecoder.cpp
//  OBSLabs
//
//  原 wl_decoder.c 的 C with Class 迁移：static 辅助函数 → private 成员函数，
//  decoder-> 前缀 → 成员直取；解码/时间戳逻辑逐行保持不变。
//

#include "WLDecoder.hpp"
#include <stdio.h>
#include <stdlib.h>              // free
#include <string.h>              // strdup

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/avutil.h>
#include <libavutil/mathematics.h>
}

// ═════════════════ 无状态辅助（保持文件内 static，不进类）═════════════════

static void print_av_error(const char *prefix, int errnum) {
    char errbuf[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(errnum, errbuf, sizeof(errbuf));
    fprintf(stderr, "%s: %s\n", prefix, errbuf);
}

// ═════════════════ 分步初始化（原 static 辅助函数）═════════════════

int WLDecoder::ffmpeg_init() {
    AVFormatContext *ctx = NULL;
    int ret = avformat_open_input(&ctx, path, NULL, NULL);
    if (ret < 0) {
        print_av_error("avformat_open_input", ret);
        return -1;
    }
    fmt_ctx = ctx;
    return 0;
}

int WLDecoder::find_stream() {
    int ret = avformat_find_stream_info(fmt_ctx, NULL);
    if (ret < 0) {
        print_av_error("avformat_find_stream_info", ret);
        return -1;
    }
    return 0;
}

int WLDecoder::find_video_stream() {
    const AVCodec *codec = NULL;
    int streamIndex = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (streamIndex < 0) {
        print_av_error("avformat_find_video_stream_info", streamIndex);
        return -1;
    }
    video_index = streamIndex;
    return 0;
}

// 配置 video decoder，失败返回 -1，成功返回 0
// 注意：失败时不自行释放，统一由 dtor 收尾
int WLDecoder::cfgd_video() {
    AVStream *stream = fmt_ctx->streams[video_index];
    // 1. 查找对应的基础解码器
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        print_av_error("Video: can not find codec", AVERROR(ENOMEM));
        return -1;
    }

    // 2. 分配解码器上下文
    video_codec_ctx = avcodec_alloc_context3(codec);
    if (!video_codec_ctx) {
        print_av_error("Video: video_codec_ctx is null", AVERROR(ENOMEM));
        return -1;
    }

    // 3. 将流的参数（如分辨率、码率等）复制到解码器上下文中
    int ret = avcodec_parameters_to_context(video_codec_ctx, stream->codecpar);
    if (ret < 0) {
        print_av_error("Video: avcodec_parameters_to_context failed", ret);
        return -1;
    }

    // 4. 配置硬件加速（由外部指定 hw_type，如 "videotoolbox"）
    hw_device_ctx = NULL;

    if (hw_type) {
        // 局部改名 device_type：C 版局部变量与成员同名 hw_type，类里会遮蔽成员
        enum AVHWDeviceType device_type = av_hwdevice_find_type_by_name(hw_type);
        if (device_type == AV_HWDEVICE_TYPE_NONE) {
            fprintf(stderr, "Video: unknown hw device type '%s', falling back to software\n", hw_type);
            video_codec_ctx->thread_count = 0;
            goto open_codec;
        }
        int hw_err = av_hwdevice_ctx_create(&hw_device_ctx, device_type, NULL, NULL, 0);
        if (hw_err >= 0) {
            // 创建成功，将其引用绑定到解码器上下文中
            AVBufferRef *ref = av_buffer_ref(hw_device_ctx);
            if (ref) {
                video_codec_ctx->hw_device_ctx = ref;
            } else {
                // av_buffer_ref OOM，降级为软解
                print_av_error("Video: av_buffer_ref failed, falling back to software", AVERROR(ENOMEM));
                av_buffer_unref(&hw_device_ctx);
                hw_device_ctx = NULL;
                video_codec_ctx->thread_count = 0;
            }
        } else {
            // 失败则置空，FFmpeg 会自动走默认的 CPU 软解，不需要退出
            print_av_error("Video: hw codec error", hw_err);
            hw_device_ctx = NULL;
            /*
             多线程安全（可选优化）：
             在打开视频解码器前，通常建议加上, 这样如果后续触发了软解降级，
             FFmpeg 会自动根据用户的 CPU 核心数开启多线程软解，大大提升软解效率。
             */
            video_codec_ctx->thread_count = 0;
        }
    }

open_codec:
    // 5. 正式打开解码器
    ret = avcodec_open2(video_codec_ctx, codec, NULL);
    if (ret < 0) {
        print_av_error("Video: avcodec_open2 failed", ret);
        return -1;
    }
    return 0;
}

int WLDecoder::find_audio_stream() {
    const AVCodec *codec = NULL;
    int streamIndex = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (streamIndex < 0) {
        print_av_error("avformat_find_audio_stream_info", streamIndex);
        return -1;
    }
    audio_index = streamIndex;
    return 0;
}

// 配置 audio decoder，失败返回 -1，成功返回 0
// 注意：失败时不自行释放，统一由 dtor 收尾
int WLDecoder::cfgd_audio() {
    AVStream *stream = fmt_ctx->streams[audio_index];

    // 1. 查找对应的音频解码器
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        print_av_error("Audio: can not find codec", AVERROR(ENOMEM));
        return -1;
    }

    // 2. 分配解码器上下文
    audio_codec_ctx = avcodec_alloc_context3(codec);
    if (!audio_codec_ctx) {
        print_av_error("Audio: audio_codec_ctx is null", AVERROR(ENOMEM));
        return -1;
    }

    // 3. 将流的参数（采样率、声道数、采样格式等）复制到解码器上下文中
    int ret = avcodec_parameters_to_context(audio_codec_ctx, stream->codecpar);
    if (ret < 0) {
        print_av_error("Audio: avcodec_parameters_to_context failed", ret);
        return -1;
    }

    // 4. 打开解码器
    ret = avcodec_open2(audio_codec_ctx, codec, NULL);
    if (ret < 0) {
        print_av_error("Audio: avcodec_open2 failed", ret);
        return -1;
    }

    return 0;
}

// ═════════════════ 释放 ═════════════════

void WLDecoder::video_codec_free() {
    if (video_codec_ctx) {
        avcodec_free_context(&video_codec_ctx);
        video_codec_ctx = NULL;
    }
    if (hw_device_ctx) {
        // 必须用 unref 减少引用计数，才能真正释放 GPU 硬件上下文
        av_buffer_unref(&hw_device_ctx);
        hw_device_ctx = NULL;
    }
}

void WLDecoder::audio_codec_free() {
    if (audio_codec_ctx) {
        avcodec_free_context(&audio_codec_ctx);
        audio_codec_ctx = NULL;
    }
}

// ═════════════════ 生命周期 ═════════════════

WLDecoder::WLDecoder(const char *path, const char *hw_type) {
    // new 不像 calloc 会清零：所有成员先逐个初始化。指针必须先全置 NULL——
    // 下面分步初始化任何一步失败都提前 return，dtor 靠 NULL 跳过未分配的资源。
    this->path    = strdup(path ? path : "");
    this->hw_type = hw_type ? strdup(hw_type) : NULL;   // NULL = 纯软解，原样保留
    fmt_ctx         = NULL;
    video_index     = -1;   // C 版 calloc 给 0；-1 更诚实（0 是合法流号），receive 侧本就按 >=0 判断
    audio_index     = -1;
    video_codec_ctx = NULL;
    audio_codec_ctx = NULL;
    hw_device_ctx   = NULL;
    pkt             = NULL;
    video_frame     = NULL;
    audio_frame     = NULL;
    eof_reached     = false;
    video_drained   = false;
    audio_drained   = false;
    ok              = false;

    // calloc 清零对这几个字段本来也不对：0 是合法的真实 pts（比如第一帧）；用
    // AV_NOPTS_VALUE 作初值才能明确区分"真的还没有上一帧"和"上一帧 pts 恰好是 0"。
    video_next_pts_ns      = AV_NOPTS_VALUE;
    video_last_pts_ns      = AV_NOPTS_VALUE;
    video_last_duration_ns = 0;
    audio_next_pts_ns      = AV_NOPTS_VALUE;

    // 分步初始化：C 版每步失败 free+return NULL；这里失败直接 return（ok 留 false），
    // 调用方查 valid() 后 delete，清理统一走 dtor
    if (ffmpeg_init()       != 0) return;
    if (find_stream()       != 0) return;
    if (find_video_stream() != 0) return;
    if (cfgd_video()        != 0) return;
    if (find_audio_stream() != 0) return;
    if (cfgd_audio()        != 0) return;

    pkt         = av_packet_alloc();
    video_frame = av_frame_alloc();
    audio_frame = av_frame_alloc();
    if (!pkt || !video_frame || !audio_frame) return;

    ok = true;
}

WLDecoder::~WLDecoder() {
    // 1. 释放 video codec + hw device ctx
    video_codec_free();

    // 2. 释放 audio codec
    audio_codec_free();

    // 3. 关闭 AVFormatContext（内部会 avformat_free_context + 置 NULL）
    if (fmt_ctx) {
        avformat_close_input(&fmt_ctx);
        fmt_ctx = NULL;
    }

    // 4. 释放复用的读包/帧缓冲（对 NULL 安全，兼容 ctor 半途失败）
    av_packet_free(&pkt);
    av_frame_free(&video_frame);
    av_frame_free(&audio_frame);

    // 5. 释放拥有的字符串拷贝（free 对 NULL 安全）
    free(path);
    free(hw_type);
}

HWAccelList WLDecoder::get_supported_hwaccels() {
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

// ═════════════════ 细粒度 API ═════════════════

wl_read_result_t WLDecoder::read() {
    if (eof_reached) return WL_READ_EOF;

    int ret = av_read_frame(fmt_ctx, pkt);   // pkt 复用同一个 packet，避免每次堆分配
    if (ret == AVERROR_EOF) {
        // 文件读完，给两个 codec 送 NULL 触发 drain（EOF 排空，非 seek flush）。
        // 出错/EOF 时 av_read_frame 已把 pkt 置空，无需 unref。
        // drain send 返回值：EOF / EAGAIN 都是预期的软状态（重复 flush / 尚有
        // 输出待取）→ 忽略；只有硬错误才记日志，且不改流程——后续 receive
        // 会自然走到 EOF 结束。
        eof_reached = true;
        int vret = video_codec_ctx ? avcodec_send_packet(video_codec_ctx, NULL) : 0;
        int aret = audio_codec_ctx ? avcodec_send_packet(audio_codec_ctx, NULL) : 0;
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
    if (pkt->stream_index == video_index && video_codec_ctx) {
        send_ret = avcodec_send_packet(video_codec_ctx, pkt);
        result = WL_READ_VIDEO;
    } else if (pkt->stream_index == audio_index && audio_codec_ctx) {
        send_ret = avcodec_send_packet(audio_codec_ctx, pkt);
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

// 无状态辅助：从 ctx 收一帧到复用缓冲 frame，move 到新分配的 *out_frame
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
                                   (enum AVRounding)(AV_ROUND_NEAR_INF | AV_ROUND_PASS_MINMAX));
    return WL_FRAME_OK;
}

wl_frame_result_t WLDecoder::receive_video(AVFrame **out_frame, int64_t *out_pts_ns) {
    if (!video_codec_ctx) {
        video_drained = true;   // 无视频流 → 视为永久排空
        return WL_FRAME_EOF;
    }

    AVRational tb = (video_index >= 0)
        ? fmt_ctx->streams[video_index]->time_base
        : (AVRational){1, 1};

    // video_frame 复用：avcodec_receive_frame 内部会先对它做 av_frame_unref，
    // 成功时内容被 move 进新分配的 out_frame（见 receive_frame），
    // frame 结构体本身留给下次调用复用。
    wl_frame_result_t r = receive_frame(video_codec_ctx, video_frame, tb,
                                        out_frame, out_pts_ns);
    if (r == WL_FRAME_EOF) {   // 仅真 EOF 才算排空；EAGAIN 不是
        video_drained = true;
        return r;
    }
    if (r != WL_FRAME_OK)
        return r;

    // 帧时长的“四级防御机制”
    // ── PTS 外推（对标 OBS mp_decode_next + get_estimated_duration）──
    // best_effort_timestamp 仍是 AV_NOPTS_VALUE 时（libavcodec 也没辙），
    // 用上一帧的推算位置顶上，不把 NOPTS 传给下游。
    int64_t last_pts_ns = video_last_pts_ns;
    int64_t pts_ns = *out_pts_ns;
    if (pts_ns == AV_NOPTS_VALUE)
        pts_ns = video_next_pts_ns;

    // 帧时长三级兜底：① codec 给的 pkt_duration ② 上一帧位置差值
    // ③ 上次估算出的时长 ④ 该流 time_base 的一个 tick（最后一道防线）
    int64_t duration_ns;
    if ((*out_frame)->duration > 0) {
        /// 第一道防线：用官方原生的帧时长
        /// 如果视频容器（如 MP4、MKV）或者解码器本身在帧里明确记录了 pkt_duration（
        /// 当前帧持续了多少个刻度），那就最完美。直接把它从流的时间基准 tb 转换成纳秒（
        /// 1000000000），作为这一帧的真实时长。
        duration_ns = av_rescale_q((*out_frame)->duration, tb,
                                   (AVRational){1, 1000000000});
    } else if (last_pts_ns != AV_NOPTS_VALUE) {
        /// 第二道防线：用前后帧的 PTS 差值
        /// 如果 pkt_duration 没给（很常见，很多封装格式这里是 0），但上一帧的 PTS 是已知的，那就用当前帧的 PTS 减去上一帧的 PTS。
        /// 场景：比如上一帧在第 40 毫秒显示，当前帧在第 80 毫秒显示，那上一帧显然持续了 $80 - 40 = 40$ 毫秒。
        duration_ns = pts_ns - last_pts_ns;
    } else if (video_last_duration_ns > 0) {
        /// 第三道防线：用前一帧的“历史经验”
        /// 如果这是前几帧，连 last_pts_ns 都还没有呢？那就看看更早之前成功估算出的历史时长
        /// video_last_duration_ns。既然上一次是这么久，在没有新数据的情况下，假设视频是
        /// 恒定帧率（CFR），继续沿用这个经验值。
        duration_ns = video_last_duration_ns;
    } else {
        /// 第四道防线：终极无脑兜底（最后一道防线）
        /// 也就是我们上一轮讨论的那行代码。如果上面三个条件全部抓瞎（比如刚开播、既没时长、又没上一帧
        ///  PTS、也没历史经验），那就只能认为这一帧只持续了时间基准的 1 个最小刻度。虽然可能不准，但
        ///  保证了 duration_ns 大于 0，程序能继续跑下去。
        duration_ns = av_rescale_q(1, tb, (AVRational){1, 1000000000});
    }

    video_last_duration_ns = duration_ns;
    video_last_pts_ns = pts_ns;
    video_next_pts_ns = pts_ns + duration_ns;
    *out_pts_ns = pts_ns;

    return WL_FRAME_OK;
}

wl_frame_result_t WLDecoder::receive_audio(AVFrame **out_frame, int64_t *out_pts_ns) {
    if (!audio_codec_ctx) {
        audio_drained = true;   // 无音频流 → 视为永久排空
        return WL_FRAME_EOF;
    }

    AVRational tb = (audio_index >= 0)
        ? fmt_ctx->streams[audio_index]->time_base
        : (AVRational){1, 1};

    // audio_frame 复用，语义同 receive_video。
    wl_frame_result_t r = receive_frame(audio_codec_ctx, audio_frame, tb,
                                        out_frame, out_pts_ns);
    if (r == WL_FRAME_EOF) {   // 仅真 EOF 才算排空；EAGAIN 不是
        audio_drained = true;
        return r;
    }
    if (r != WL_FRAME_OK)
        return r;

    // ── PTS 外推 ──
    // 音频时长可以直接由 nb_samples/sample_rate 精确算出，不需要像视频那样
    // 三级兜底；best_effort_timestamp 仍是 NOPTS 时用上一帧推算位置顶上。
    int64_t pts_ns = *out_pts_ns;
    if (pts_ns == AV_NOPTS_VALUE)
        pts_ns = audio_next_pts_ns;

    int64_t duration_ns = av_rescale_q((*out_frame)->nb_samples,
                                       (AVRational){1, (*out_frame)->sample_rate},
                                       (AVRational){1, 1000000000});

    audio_next_pts_ns = pts_ns + duration_ns;
    *out_pts_ns = pts_ns;

    return WL_FRAME_OK;
}

bool WLDecoder::drained() const {
    return video_drained && audio_drained;
}

void WLDecoder::flush() {
    // ⚠️ 坑：seek 必须用 avcodec_flush_buffers()，绝不能用 avcodec_send_packet(NULL)！
    //   send(NULL) 是 EOF 排空信号 —— 之后 codec 进入 draining 模式、拒收新 packet
    //   （send 真实包返回 AVERROR_EOF），必须再 flush_buffers 才能复用。
    //   而 seek 之后还要继续喂包，所以这里用 flush_buffers：丢弃内部缓存帧 + 重置
    //   解码器状态，使其重新接收新 packet。
    //   （EOF drain 的 send(NULL) 在 read() 的 AVERROR_EOF 分支里单独处理，
    //    两者语义相反，切勿混用。）
    if (video_codec_ctx)
        avcodec_flush_buffers(video_codec_ctx);
    if (audio_codec_ctx)
        avcodec_flush_buffers(audio_codec_ctx);

    // seek 可能从 EOF 之后往回跳，重置文件级 + 解码器级的结束标志
    eof_reached   = false;
    video_drained = false;
    audio_drained = false;
}
