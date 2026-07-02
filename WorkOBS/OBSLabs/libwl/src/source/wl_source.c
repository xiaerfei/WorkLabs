//
//  wl_source.c
//  OBSLabs
//

#include "wl_source.h"
#include "wl_source_registry.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

// async_frames 默认容量。create 时定、运行期固定（要换大小改这里 / 将来给 create 加参数，重启生效）。
#define WL_DEFAULT_ASYNC_CAPACITY 30

// 环形缓冲的一个 slot
typedef struct {
    CVPixelBufferRef pixbuf;   // retain 持有
    int64_t          pts_ns;
} wl_async_frame;

struct wl_source {
    const wl_source_info_t *info;   // vtable（不拥有，指向注册表中的静态实例）
    void                   *data;   // 私有数据（vtable.create 分配）

    // async_frames：堆分配环形缓冲（容量运行期固定），生产者(解码线程)/消费者(tick) 共享
    wl_async_frame  *frames;
    int              capacity;
    int              head;          // 最旧帧下标
    int              count;         // 当前帧数
    pthread_mutex_t  async_mutex;

    // 消费端挑帧的时钟基准（首次 get_frame 锚定）+ 当前显示帧（source 持有）
    bool             consume_anchored;
    int64_t          consume_first_pts;   // 媒体零点
    int64_t          consume_first_sys;   // 墙钟零点
    CVPixelBufferRef cur_frame;
    int64_t          cur_frame_pts;
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
    src->info     = info;
    src->capacity = WL_DEFAULT_ASYNC_CAPACITY;
    src->frames   = calloc(src->capacity, sizeof(wl_async_frame));
    if (!src->frames) {
        free(src);
        return NULL;
    }
    pthread_mutex_init(&src->async_mutex, NULL);

    // 传 src 给 create：源存下反向引用，output 时回调 wl_source_output_video
    src->data = info->create(settings, src);
    if (!src->data) {
        fprintf(stderr, "[source] create failed for type '%s'\n", info->id);
        pthread_mutex_destroy(&src->async_mutex);
        free(src->frames);
        free(src);
        return NULL;
    }
    return src;
}

void wl_source_destroy(wl_source_t *src) {
    if (!src) return;

    wl_source_stop(src);   // 先停生产者（解码线程 join），之后清缓冲无并发
    if (src->info->destroy) src->info->destroy(src->data);

    // 释放缓冲里剩余帧 + 当前显示帧
    for (int i = 0; i < src->count; i++) {
        int idx = (src->head + i) % src->capacity;
        CVPixelBufferRelease(src->frames[idx].pixbuf);
    }
    if (src->cur_frame) CVPixelBufferRelease(src->cur_frame);

    free(src->frames);
    pthread_mutex_destroy(&src->async_mutex);
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

// ---- 生产端 ----

void wl_source_output_video(wl_source_t *src, CVPixelBufferRef pixbuf, int64_t pts_ns) {
    if (!src || !pixbuf) return;

    CVPixelBufferRetain(pixbuf);   // 队列持有一份
    pthread_mutex_lock(&src->async_mutex);

    if (src->count == src->capacity) {
        // 满 → 丢最旧（非阻塞，绝不停生产者）
        CVPixelBufferRelease(src->frames[src->head].pixbuf);
        src->head = (src->head + 1) % src->capacity;
        src->count--;
    }
    int tail = (src->head + src->count) % src->capacity;
    src->frames[tail].pixbuf = pixbuf;
    src->frames[tail].pts_ns = pts_ns;
    src->count++;

    pthread_mutex_unlock(&src->async_mutex);
}

// ---- 消费端 ----

CVPixelBufferRef wl_source_get_frame(wl_source_t *src, int64_t sys_time_ns, int64_t *out_pts_ns) {
    if (!src) return NULL;

    pthread_mutex_lock(&src->async_mutex);

    // 首次锚定（需缓冲里有帧，才能拿最旧帧 pts 当媒体零点）
    if (!src->consume_anchored && src->count > 0) {
        src->consume_first_pts = src->frames[src->head].pts_ns;
        src->consume_first_sys = sys_time_ns;
        src->consume_anchored  = true;
    }

    int advanced = 0;   // 本 tick 从缓冲取走几帧（显示 1 + 跳过 advanced-1）
    if (src->consume_anchored) {
        // 此刻按墙钟推算，媒体本该播到的位置（与生产端 pace 对偶）
        int64_t target = src->consume_first_pts + (sys_time_ns - src->consume_first_sys);

        // 追赶：把 pts <= target 的帧逐个提升为 cur_frame（跳过的旧帧 release），
        // 停在"pts ≤ target 的最新一帧"。
        while (src->count > 0 && src->frames[src->head].pts_ns <= target) {
            if (src->cur_frame) CVPixelBufferRelease(src->cur_frame);
            src->cur_frame     = src->frames[src->head].pixbuf;   // 转移所有权给 cur_frame
            src->cur_frame_pts = src->frames[src->head].pts_ns;
            src->head = (src->head + 1) % src->capacity;
            src->count--;
            advanced++;
        }
    }

    CVPixelBufferRef ret = src->cur_frame;   // borrow（缓冲空时保持上一帧，不黑屏）
    if (out_pts_ns) *out_pts_ns = src->cur_frame_pts;

    // ── 临时验证日志（验证完删除）：advanced=每 tick 取走帧数（60→30 应稳定 2）──
    int     depth    = src->count;
    int64_t show_rel = ret ? (src->cur_frame_pts - src->consume_first_pts) : -1;
    pthread_mutex_unlock(&src->async_mutex);
    fprintf(stderr, "[get] show=%6lldms  depth=%2d  advanced=%d\n", show_rel / 1000000, depth, advanced);

    return ret;
}
