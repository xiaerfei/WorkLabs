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
    output_cb     = NULL;
    output_ctx    = NULL;
    pthread_mutex_init(&output_mutex, NULL);
}

WLGraphics::~WLGraphics() {
    stop();   // 幂等；join 节拍线程——之后没人再读 output_cb，销毁锁才安全
    pthread_mutex_destroy(&output_mutex);
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

void WLGraphics::set_output(wl_frame_output_cb cb, void *ctx) {
    pthread_mutex_lock(&output_mutex);
    output_cb  = cb;
    output_ctx = ctx;
    pthread_mutex_unlock(&output_mutex);
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

// tick 的收集上下文：传入本 tick 的"现在几点"，传出挑出的合成帧
struct tick_ctx {
    int64_t          video_time;   // in：本 tick 的虚拟时刻
    CVPixelBufferRef frame;        // out：挑出的帧（已 retain，thread_loop 负责 release）
    int64_t          pts_ns;       // out：该帧 pts
};

// tick 单个源：把本 tick 的 video_time 当"现在几点"传给挑帧
static void tick_one_source(WLSource *src, void *ctx) {
    tick_ctx *tc = (tick_ctx *)ctx;
    // 分流唯一依据 = ASYNC 位（对齐 obs_source_video_tick，obs-source.c:1367）：
    // 异步源本 tick 挑帧；同步源没有帧队列，render 阶段直接 video_render() 现画（M3）
    if ((src->info.output_flags & WL_SOURCE_ASYNC) == 0) return;

    int64_t pts = 0;
    CVPixelBufferRef f = src->get_frame(tc->video_time, &pts);   // 返回 borrow
    if (!f) return;

    // Step1 没有真合成：多源时保留"最后一个有帧的源"（退化为单源直显）。
    // 在锁内（foreach_source 持 WLCore 锁）retain，出锁后即便该源被 remove 也安全。
    // Step2(M3) 这里换成：收集所有源帧 → Metal 合成到一张纹理 → 输出那张纹理。
    if (tc->frame) CVPixelBufferRelease(tc->frame);
    tc->frame  = CVPixelBufferRetain(f);
    tc->pts_ns = pts;
}

void *WLGraphics::graphics_thread_func(void *arg) {
    ((WLGraphics *)arg)->thread_loop();
    return NULL;
}

void WLGraphics::thread_loop() {
    video_time = WLTime::now_ns();   // 时钟锚定（对标 obs->video.video_time = os_gettime_ns()）

    while (!atomic_load(&should_stop)) {
        // ── (1) tick 所有源 + 挑帧（锁内遍历，见 WLCore::foreach_source 并发说明）──
        tick_ctx tc;
        tc.video_time = video_time;
        tc.frame      = NULL;
        tc.pts_ns     = 0;
        WLCore::foreach_source(tick_one_source, &tc);

        // ── (2) 合成 ── Step1 = 直显：tc.frame 即"合成"产物（Step2/M3 换 Metal 合成）
        // ── (3) 输出 ── 把合成帧 push 给预览/编码。回调在锁外调（只做轻量转发），
        //     先把 output_cb/ctx 拷到局部再出锁调用，避免持 output_mutex 期间跑用户代码。
        if (tc.frame) {
            pthread_mutex_lock(&output_mutex);
            wl_frame_output_cb cb = output_cb;
            void *cb_ctx = output_ctx;
            pthread_mutex_unlock(&output_mutex);

            if (cb) cb(tc.frame, tc.pts_ns, cb_ctx);
            CVPixelBufferRelease(tc.frame);   // 释放 tick 里 retain 的那份
        }

        // ── (4) 睡到下一 tick ──
        video_sleep();
    }
}
