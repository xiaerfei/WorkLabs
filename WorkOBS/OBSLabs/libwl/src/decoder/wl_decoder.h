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
#include "wl_queue.h"
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

// ---- decode 单步 ----

typedef enum {
    WL_DECODE_OK = 0,  // 至少解出一帧，已推入队列
    WL_DECODE_AGAIN,   // pkt 已送入但本次没帧出来（B 帧延迟 / 字幕包等）
    WL_DECODE_EOF,     // 文件读完
    WL_DECODE_ABORTED, // 队列被 abort（外部停止信号）
    WL_DECODE_ERROR,   // 致命错误
} wl_decode_result_t;

/**
 * 读一个 AVPacket，送入对应解码器，把产出的所有 AVFrame 推入队列。
 * 由 decode_thread 在循环中调用；队列满时阻塞（背压），abort 时返回 WL_DECODE_ABORTED。
 */
wl_decode_result_t wl_decoder_next_frames(wl_decoder_t *decoder,
                                           wl_queue_t   *video_q,
                                           wl_queue_t   *audio_q);

#endif /* wl_decoder_h */
