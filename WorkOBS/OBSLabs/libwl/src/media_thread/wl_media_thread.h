//
//  wl_media_thread.h
//  OBSLabs
//
//  对标 OBS mp_media_thread：per-source 的串行主循环线程。
//  职责：read pkt → decode video → decode audio → output 帧到下游缓冲。
//

#ifndef wl_media_thread_h
#define wl_media_thread_h

#include <stdbool.h>
#include <stdint.h>            // int64_t（seek 时间戳）
#include <libavutil/frame.h>  // AVFrame（output 回调签名）

typedef struct wl_media_thread wl_media_thread_t;

// output 回调：解码线程解出一帧后调用，把帧交给上层（wl_source）。
// 视频：硬解 frame->data[3] = CVPixelBufferRef；软解 frame->data[0..] = YUV。
// 音频：frame->data[0] = PCM。pts_ns 已换算为纳秒。
typedef void (*wl_media_video_cb)(AVFrame *frame, int64_t pts_ns, void *opaque);
typedef void (*wl_media_audio_cb)(AVFrame *frame, int64_t pts_ns, void *opaque);

// ---- 生命周期 ----

/**
 * 创建媒体线程（尚未启动）。
 * @param path     媒体文件路径
 * @param hw_type  硬件加速类型（如 "videotoolbox"），NULL = 软解
 */
wl_media_thread_t *wl_media_thread_create(const char *path, const char *hw_type);

/**
 * 设置输出回调（在 start 之前调用；start 后主循环即可能触发回调）。
 */
void wl_media_thread_set_callbacks(wl_media_thread_t *mt,
                                   wl_media_video_cb video_cb,
                                   wl_media_audio_cb audio_cb,
                                   void *opaque);

/**
 * 启动主循环线程。返回 0 成功，-1 失败。
 */
int  wl_media_thread_start(wl_media_thread_t *mt);

/**
 * 停止主循环并 join 等线程退出（幂等）。free 内部会先调它。
 */
void wl_media_thread_stop(wl_media_thread_t *mt);

/**
 * 释放所有资源：通知线程退出 → join 等它真正结束 → 释放。
 * 调用后指针不可再用，不要在 free 之后再访问 mt。
 */
void wl_media_thread_free(wl_media_thread_t *mt);

// ---- 控制 ----

/**
 * 暂停 / 恢复。暂停时主循环在 semaphore 上挂起，不读包不解码。
 */
void wl_media_thread_pause(wl_media_thread_t *mt, bool pause);

/**
 * Seek 到指定时间戳（微秒）。线程安全，可从任意线程调用。
 */
void wl_media_thread_seek(wl_media_thread_t *mt, int64_t seek_ts_us);

#endif /* wl_media_thread_h */
