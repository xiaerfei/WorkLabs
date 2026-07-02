//
//  wl_source.h
//  OBSLabs
//
//  源实例（运行时）。持有 vtable 指针 + 私有数据 + 输出缓冲。
//  控制 API 透传到 vtable；output_video/audio 由源内部在自己线程调用，
//  把帧交给 source 层的缓冲（async_frames，下一步实现）。
//

#ifndef wl_source_h
#define wl_source_h

#include <stdbool.h>
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>   // CVPixelBufferRef

#include "wl_source_info.h"        // wl_source_t / wl_source_info_t

// ---- 创建 / 销毁 ----

// 按 type_id 在注册表查找并创建实例。失败返回 NULL。
wl_source_t *wl_source_create(const char *type_id, const char *settings);
// 内部先 stop，再调 vtable.destroy。
void wl_source_destroy(wl_source_t *src);

// ---- 控制（透传 vtable，缺失的回调安全忽略）----
int  wl_source_start(wl_source_t *src);
void wl_source_stop(wl_source_t *src);
void wl_source_pause(wl_source_t *src, bool paused);
void wl_source_seek(wl_source_t *src, int64_t seek_ts_us);

// ---- 信息查询 ----
int64_t wl_source_get_duration(wl_source_t *src);
void    wl_source_get_video_size(wl_source_t *src, int *width, int *height);

// ---- 输出（源内部在自己线程调用）----

// 视频帧。所有源统一走这个入口（解码源提取出 CVPixelBufferRef、采集源天然就是）。
// 当前 stub：临时日志；async_frames（retain + 满丢旧）下一步实现。
void wl_source_output_video(wl_source_t *src, CVPixelBufferRef pixbuf, int64_t pts_ns);

// 音频帧接口待 audio buffer 步定形态（当前音频临时日志在 wl_media_source 里）。

#endif /* wl_source_h */
