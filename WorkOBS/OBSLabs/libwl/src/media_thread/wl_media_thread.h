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
#include <stdint.h>   // int64_t（seek 时间戳）

typedef struct wl_media_thread wl_media_thread_t;

// ---- 生命周期 ----

/**
 * 创建媒体线程（尚未启动）。
 * @param path     媒体文件路径
 * @param hw_type  硬件加速类型（如 "videotoolbox"），NULL = 软解
 */
wl_media_thread_t *wl_media_thread_create(const char *path, const char *hw_type);

/**
 * 启动主循环线程。返回 0 成功，-1 失败。
 */
int  wl_media_thread_start(wl_media_thread_t *mt);

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
