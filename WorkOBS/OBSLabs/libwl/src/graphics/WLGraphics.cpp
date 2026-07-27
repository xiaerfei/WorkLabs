//
//  WLGraphics.cpp
//  OBSLabs
//
//  主循环对标 obs_graphics_thread_loop（obs-video.c:1097）：
//    (1) tick 所有源（逐源按 video_time 挑帧，owned +1 收集）
//    (2) 合成            ← M3 Metal，当前 stub
//    (3) per-source 输出（预览浮层用；合成后单帧出口随 M2 编码再加）
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

// tick 一拍最多收集的源数。栈上定长（Orthodox C++ 不用 STL）；超出不静默，告警丢弃。
#define WL_TICK_MAX_SOURCES 64

// tick 的收集上下文：传入本 tick 的"现在几点"，传出各源挑出的帧
struct tick_ctx {
    int64_t video_time;             // in：本 tick 的虚拟时刻
    int     count;                  // out：收集到几个源的帧
    struct {
        WLSource        *src;       // 路由 key（出锁后只可比较不可解引用）
        CVPixelBufferRef frame;     // owned（get_frame 已 +1，thread_loop 负责 release）
        int64_t          pts_ns;
    } out[WL_TICK_MAX_SOURCES];
};

// tick 单个源：把本 tick 的 video_time 当"现在几点"传给挑帧，有帧就收集
static void tick_one_source(WLSource *src, void *ctx) {
    tick_ctx *tc = (tick_ctx *)ctx;
    // 分流唯一依据 = ASYNC 位（对齐 obs_source_video_tick，obs-source.c:1367）：
    // 异步源本 tick 挑帧；同步源没有帧队列，render 阶段直接 video_render() 现画（M3）
    if ((src->info.output_flags & WL_SOURCE_ASYNC) == 0) return;
    if (tc->count >= WL_TICK_MAX_SOURCES) {
        fprintf(stderr, "[gfx] tick 源数超 %d，多余的本拍丢弃\n", WL_TICK_MAX_SOURCES);
        return;
    }

    int64_t pts = 0;
    CVPixelBufferRef f = src->get_frame(tc->video_time, &pts);   // owned：+1 到手
    if (!f) return;

    tc->out[tc->count].src    = src;
    tc->out[tc->count].frame  = f;      // 接管 get_frame 给的那份引用
    tc->out[tc->count].pts_ns = pts;
    tc->count++;
}

void *WLGraphics::graphics_thread_func(void *arg) {
    ((WLGraphics *)arg)->thread_loop();
    return NULL;
}

void WLGraphics::thread_loop() {
    video_time = WLTime::now_ns();   // 时钟锚定（对标 obs->video.video_time = os_gettime_ns()）

    while (!atomic_load(&should_stop)) {
        // 先看有没有人接帧：锁内只拷指针（避免持 output_mutex 期间跑用户代码），
        // 没人接就整拍跳过挑帧——不白做 retain/release，缓冲靠 drop-oldest 自净。
        pthread_mutex_lock(&output_mutex);
        wl_frame_output_cb cb = output_cb;
        void *cb_ctx = output_ctx;
        pthread_mutex_unlock(&output_mutex);

        if (cb) {
            // ── (1) tick 所有源 + 逐源挑帧（锁内遍历，见 WLCore::foreach_source 并发说明）──
            tick_ctx tc;
            tc.video_time = video_time;
            tc.count      = 0;
            WLCore::foreach_source(tick_one_source, &tc);

            // ── (2) 合成 ── M3 换 Metal：把 tc.out 各源帧按画布模型合成一张纹理再输出
            // ── (3) 输出 ── 出了源列表锁逐源 push（对标 render_displays：渲染线程推，UI 不拉）。
            //     帧攥着 owned 引用，回调返回后才 release——回调内 borrow 绝对有效；
            //     源此刻即便被删也不影响这份帧引用，src 只当路由 key。
            for (int i = 0; i < tc.count; i++) {
                cb(tc.out[i].src, tc.out[i].frame, tc.out[i].pts_ns, cb_ctx);
                CVPixelBufferRelease(tc.out[i].frame);
            }
        }

        // ── (4) 睡到下一 tick ──
        video_sleep();
    }
}
