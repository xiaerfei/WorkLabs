//
//  wl_source.c
//  OBSLabs
//

#include "wl_source.h"
#include "wl_source_registry.h"
#include <stdio.h>
#include <stdlib.h>

struct wl_source {
    const wl_source_info_t *info;   // vtable（不拥有，指向注册表中的静态实例）
    void                   *data;   // 私有数据（vtable.create 分配）

    // TODO(async_frames): 视频帧 FIFO 缓冲（CVPixelBufferRef + pts，max 30，满丢旧）
    // TODO(audio buffer): 音频缓冲
};

// ---- 创建 / 销毁 ----

wl_source_t *wl_source_create(const char *type_id, const char *settings) {
    const wl_source_info_t *info = wl_source_find(type_id);
    if (!info) {
        fprintf(stderr, "[source] unknown type '%s'\n", type_id ? type_id : "(null)");
        return NULL;
    }

    wl_source_t *src = calloc(1, sizeof(*src));
    if (!src) return NULL;
    src->info = info;

    // 传 src 给 create：源存下这个反向引用，output 时回调 wl_source_output_video
    src->data = info->create(settings, src);
    if (!src->data) {
        fprintf(stderr, "[source] create failed for type '%s'\n", info->id);
        free(src);
        return NULL;
    }
    return src;
}

void wl_source_destroy(wl_source_t *src) {
    if (!src) return;
    wl_source_stop(src);   // 保证已停（幂等）
    if (src->info->destroy) src->info->destroy(src->data);
    free(src);
}

// ---- 控制（透传 vtable）----

int wl_source_start(wl_source_t *src) {
    if (!src || !src->info->start) return -1;
    return src->info->start(src->data);
}

void wl_source_stop(wl_source_t *src) {
    if (src && src->info->stop) src->info->stop(src->data);
}

void wl_source_pause(wl_source_t *src, bool paused) {
    if (src && src->info->pause) src->info->pause(src->data, paused);
}

void wl_source_seek(wl_source_t *src, int64_t seek_ts_us) {
    if (src && src->info->seek) src->info->seek(src->data, seek_ts_us);
}

// ---- 信息查询 ----

int64_t wl_source_get_duration(wl_source_t *src) {
    if (!src || !src->info->get_duration) return -1;
    return src->info->get_duration(src->data);
}

void wl_source_get_video_size(wl_source_t *src, int *width, int *height) {
    if (width)  *width  = 0;
    if (height) *height = 0;
    if (src && src->info->get_video_size) src->info->get_video_size(src->data, width, height);
}

// ---- 输出 ----

void wl_source_output_video(wl_source_t *src, CVPixelBufferRef pixbuf, int64_t pts_ns) {
    (void)src;
    if (!pixbuf) return;

    // TODO(async_frames): CVPixelBufferRetain(pixbuf) + push 到 src->async_frames（满丢旧）
    // ── 临时验证日志（验证完删除）：证明帧经 source 层输出、CVPixelBuffer 提取正确 ──
    static int cnt = 0;
    fprintf(stderr, "[src V] #%-4d pts=%6lldms  %zux%zu\n",
            cnt++, pts_ns / 1000000,
            CVPixelBufferGetWidth(pixbuf), CVPixelBufferGetHeight(pixbuf));
}
