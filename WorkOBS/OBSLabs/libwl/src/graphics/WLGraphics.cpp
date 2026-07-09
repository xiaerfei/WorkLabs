//
//  WLGraphics.cpp
//  OBSLabs
//
//  主循环对标 obs_graphics_thread_loop（obs-video.c:1097）：
//    (1) tick 所有源（逐源按 video_time 挑帧）
//    (2) 合成            ← 阶段二 Metal，当前 stub
//    (3) 输出合成帧      ← 阶段三，当前 stub
//    (4) video_sleep：睡到下一 tick 的绝对时刻，卡顿一次跳 count 帧
//

#include "WLGraphics.hpp"
#include "WLCore.hpp"
#include "WLSource.hpp"
#include "WLTime.hpp"
#include <stdio.h>

// ---------- 生命周期 ----------

WLGraphics::WLGraphics(int fps) {
    // new 不像 calloc 会清零：所有成员逐个初始化（pthread_t 除外，thread_running 守卫）
    thread_running = false;
    atomic_init(&should_stop, false);
    this->fps     = fps;
    interval_ns   = 1000000000LL / fps;
    video_time    = 0;
    total_frames  = 0;
    lagged_frames = 0;
}

WLGraphics::~WLGraphics() {
    stop();   // 幂等；join 节拍线程
}

int WLGraphics::start() {
    if (thread_running) return 0;   // 防重入
    if (pthread_create(&thread, NULL, graphics_thread_func, this) != 0)
        return -1;
    thread_running = true;   // 守卫：只有 start 成功，stop/dtor 才会 join
    return 0;
}

void WLGraphics::stop() {
    if (!thread_running) return;
    atomic_store(&should_stop, true);   // 无 pause 挂起点，置位后最坏等一个 interval
    pthread_join(thread, NULL);
    thread_running = false;
}

// ---------- 节拍核心 ----------

/**
 * 睡到下一 tick 的绝对时刻，并推进 video_time（对标 OBS video_sleep，obs-video.c:805）。
 *
 * - 目标永远是 video_time + interval 这个"绝对时刻"：即使本帧合成耗时不定，
 *   下一目标仍从上一目标推算，误差不累积（与 pace_video 的绝对基准同一原理）。
 * - 卡顿（目标已成过去）：算出实际落后几个 interval，把 video_time 一次性跳到位，
 *   本帧记作"顶 count 帧"。下游接编码后按 count 复帧，时间轴保持规整 CFR。
 */
void WLGraphics::video_sleep() {
    int64_t t = video_time + interval_ns;
    int count;

    if (WLTime::sleep_to_ns(t)) {
        video_time = t;               // 正常：平滑 +interval
        count = 1;
    } else {
        int64_t diff = WLTime::now_ns() - video_time;
        if (diff < interval_ns) diff = interval_ns;
        count = (int)(diff / interval_ns);   // 落后了几个完整 interval
        video_time += interval_ns * count;   // 一次性跳到该到的位置
    }

    total_frames  += count;
    lagged_frames += count - 1;

    if (count > 1) {
        fprintf(stderr, "[gfx] lag: 本 tick 顶 %d 帧 (total=%llu lagged=%llu)\n",
                count, total_frames, lagged_frames);
    }
}

// ---------- 主循环 ----------

// tick 单个源：把本 tick 的 video_time 当"现在几点"传给挑帧
static void tick_one_source(WLSource *src, void *ctx) {
    int64_t video_time = *(int64_t *)ctx;
    int64_t pts = 0;
    // 返回 borrow；阶段一不渲染，挑帧行为由 get_frame 内的 [get] 临时日志观测
    (void)src->get_frame(video_time, &pts);
}

void *WLGraphics::graphics_thread_func(void *arg) {
    ((WLGraphics *)arg)->thread_loop();
    return NULL;
}

void WLGraphics::thread_loop() {
    video_time = WLTime::now_ns();   // 时钟锚定（对标 obs->video.video_time = os_gettime_ns()）

    while (!atomic_load(&should_stop)) {
        // ── (1) tick 所有源（锁内遍历，见 WLCore::foreach_source 并发说明）──
        WLCore::foreach_source(tick_one_source, &video_time);

        // ── (2) 合成 ── TODO(阶段二): Metal 合成取到的各源帧
        // ── (3) 输出 ── TODO(阶段三): 合成帧 + timestamp(=video_time) 送 preview/编码

        // ── (4) 睡到下一 tick ──
        video_sleep();
    }
}
