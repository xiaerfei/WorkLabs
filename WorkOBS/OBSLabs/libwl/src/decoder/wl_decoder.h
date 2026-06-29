//
//  wl_decoder.h
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//

#ifndef wl_decoder_h
#define wl_decoder_h

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <libavcodec/avcodec.h>
#define MAX_HW_ACCELS 16

// 专门对接 UI 层的硬件加速列表结构体
typedef struct HWAccelList {
    const char *names[MAX_HW_ACCELS]; // 硬件加速名称字符串，如 "cuda", "videotoolbox"
    int count;                        // 当前系统实际支持的个数
} HWAccelList;

// 仅仅告诉外部有这个结构体类型，但不透露里面有什么
typedef struct wl_decoder_t wl_decoder_t;

/**
 * 创建解码器
 * @param path  媒体文件路径
 * @param hw_type  硬件加速类型名称（如 "videotoolbox"），传 NULL 则纯软解
 */
wl_decoder_t *wl_decoder_create(const char *path, const char *hw_type);
void wl_decoder_free(wl_decoder_t *decoder);


/**
 * 获取当前 FFmpeg 构建版本及当前主机系统真正支持的硬件加速列表
 * @return HWAccelList 结构体（值传递，无需外部手动 free）
 */
HWAccelList wl_decoder_get_supported_hwaccels(void);

// ---- wl_media_thread 用的细粒度 API ----

typedef enum {
    WL_READ_VIDEO = 0, ///< 读到视频包，已送入 video_codec_ctx
    WL_READ_AUDIO,     ///< 读到音频包，已送入 audio_codec_ctx
    WL_READ_SKIP,      ///< 字幕 / 数据流等，已跳过
    WL_READ_EOF,       ///< 文件读完（已 flush 两个解码器）
    WL_READ_ERROR,     ///< 致命错误
} wl_read_result_t;

typedef enum {
    WL_FRAME_OK = 0,   ///< 成功解出一帧
    WL_FRAME_NO_DATA,  ///< 解码器无更多输出（需要新 packet 或已 flush 完毕）
    WL_FRAME_ERROR,    ///< 致命错误
} wl_frame_result_t;

/**
 * 从文件读一个 AVPacket，按 stream_index 送入对应解码器。
 * EOF 时自动 flush 两个解码器（send NULL）。
 */
wl_read_result_t wl_decoder_read(wl_decoder_t *decoder);

/**
 * 尝试从 video_codec_ctx 接收一帧（非阻塞）。
 * *out_frame 成功时由调用方 av_frame_free。
 */
wl_frame_result_t wl_decoder_receive_video(wl_decoder_t *decoder,
                                            AVFrame **out_frame,
                                            int64_t  *out_pts_ns);

/**
 * 尝试从 audio_codec_ctx 接收一帧（非阻塞）。
 * *out_frame 成功时由调用方 av_frame_free。
 */
wl_frame_result_t wl_decoder_receive_audio(wl_decoder_t *decoder,
                                            AVFrame **out_frame,
                                            int64_t  *out_pts_ns);

/**
 * 查询解码器是否已经 flush 完毕（两个 codec 都返回 NO_DATA）。
 * 用于主循环判断是否可以结束。
 */
bool wl_decoder_drained(wl_decoder_t *decoder);

/**
 * 向解码器发送 flush 信号（send NULL），用于 seek。
 */
void wl_decoder_flush(wl_decoder_t *decoder);

#endif /* wl_decoder_h */
