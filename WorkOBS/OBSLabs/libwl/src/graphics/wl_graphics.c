//
//  wl_graphics.c
//  OBSLabs
//
//  主循环对标 obs_graphics_thread_loop（obs-video.c:1097）：
//    (1) tick 所有源（逐源按 video_time 挑帧）
//    (2) 合成            ← 阶段二 Metal，当前 stub
//    (3) 输出合成帧      ← 阶段三，当前 stub
//    (4) video_sleep：睡到下一 tick 的绝对时刻，卡顿一次跳 count 帧
//

#include "wl_graphics.h"
#include "wl_core.h"
#include "wl_source.h"
#include "wl_time.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

struct wl_graphics {
    pthread_t       thread;
    bool            thread_running;   // start 成功后置 true：守卫 stop 里的 join
    atomic_bool     should_stop;

    int             fps;
    int64_t         interval_ns;      // 一个 tick 的标称时长 = 1e9 / fps
    int64_t         video_time;       // 虚拟当前时刻（起点 = 启动时的单调钟，每 tick +interval）

    // 健康度统计（对标 OBS total_frames / lagged_frames）
    uint64_t        total_frames;
    uint64_t        lagged_frames;
};

// ---------- 节拍核心 ----------

/**
 * 睡到下一 tick 的绝对时刻，并推进 video_time（对标 OBS video_sleep，obs-video.c:805）。
 *
 * - 目标永远是 video_time + interval 这个"绝对时刻"：即使本帧合成耗时不定，
 *   下一目标仍从上一目标推算，误差不累积（与 pace_video 的绝对基准同一原理）。
 * - 卡顿（目标已成过去）：算出实际落后几个 interval，把 video_time 一次性跳到位，
 *   本帧记作"顶 count 帧"。下游接编码后按 count 复帧，时间轴保持规整 CFR。
 */
static void video_sleep(wl_graphics_t *g) {
    int64_t t = g->video_time + g->interval_ns;
    int count;

    if (wl_sleep_to_ns(t)) {
        g->video_time = t;            // 正常：平滑 +interval
        count = 1;
    } else {
        int64_t diff = wl_now_ns() - g->video_time;
        if (diff < g->interval_ns) diff = g->interval_ns;
        count = (int)(diff / g->interval_ns);   // 落后了几个完整 interval
        g->video_time += g->interval_ns * count; // 一次性跳到该到的位置
    }

    g->total_frames  += count;
    g->lagged_frames += count - 1;

    if (count > 1) {
        fprintf(stderr, "[gfx] lag: 本 tick 顶 %d 帧 (total=%llu lagged=%llu)\n",
                count, g->total_frames, g->lagged_frames);
    }
}

// ---------- 主循环 ----------

// tick 单个源：把本 tick 的 video_time 当"现在几点"传给挑帧
static void tick_one_source(wl_source_t *src, void *ctx) {
    int64_t video_time = *(int64_t *)ctx;
    int64_t pts = 0;
    // 返回 borrow；阶段一不渲染，挑帧行为由 get_frame 内的 [get] 临时日志观测
    (void)wl_source_get_frame(src, video_time, &pts);
}

static void *graphics_thread_func(void *arg) {
    wl_graphics_t *g = arg;

    g->video_time = wl_now_ns();   // 时钟锚定（对标 obs->video.video_time = os_gettime_ns()）

    while (!atomic_load(&g->should_stop)) {
        // ── (1) tick 所有源（锁内遍历，见 wl_core_foreach_source 并发说明）──
        wl_core_foreach_source(tick_one_source, &g->video_time);

        // ── (2) 合成 ── TODO(阶段二): Metal 合成取到的各源帧
        // ── (3) 输出 ── TODO(阶段三): 合成帧 + timestamp(=video_time) 送 preview/编码

        // ── (4) 睡到下一 tick ──
        video_sleep(g);
    }
    return NULL;
}

// ---------- 公开 API ----------

wl_graphics_t *wl_graphics_create(int fps) {
    if (fps <= 0) return NULL;
    wl_graphics_t *g = calloc(1, sizeof(*g));
    if (!g) return NULL;

    g->fps         = fps;
    g->interval_ns = 1000000000LL / fps;
    atomic_init(&g->should_stop, false);
    return g;
}

int wl_graphics_start(wl_graphics_t *g) {
    if (pthread_create(&g->thread, NULL, graphics_thread_func, g) != 0)
        return -1;
    g->thread_running = true;
    return 0;
}

void wl_graphics_stop(wl_graphics_t *g) {
    if (!g || !g->thread_running) return;
    atomic_store(&g->should_stop, true);   // 无 pause 挂起点，置位后最坏等一个 interval
    pthread_join(g->thread, NULL);
    g->thread_running = false;
}

void wl_graphics_free(wl_graphics_t *g) {
    if (!g) return;
    wl_graphics_stop(g);
    free(g);
}
