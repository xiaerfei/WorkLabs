//
//  WLGraphics.cpp
//  OBSLabs
//
//  主循环对标 obs_graphics_thread_loop（obs-video.c:1097）：
//    (1) tick 所有源（逐源按 video_time_ 挑帧，owned +1 收集）
//    (2) 合成            ← M3 Metal，当前 stub
//    (3) per-source 输出（预览浮层用；合成后单帧出口随 M2 编码再加）
//    (4) VideoSleep：睡到下一 tick 的绝对时刻，卡顿一次跳 count 帧
//

#include "WLGraphics.hpp"
#include "WLCore.hpp"
#include "WLSource.hpp"
#include "WLTime.hpp"
#include <stdio.h>

// ---------- 生命周期 ----------

WLGraphics::WLGraphics(int fps) {
    // new 不像 calloc 会清零：所有成员逐个初始化（pthread_t 除外，thread_running_ 守卫）
    thread_running_ = false;
    atomic_init(&should_stop_, false);
    fps_           = fps;
    interval_ns_   = 1000000000LL / fps;
    video_time_    = 0;
    total_frames_  = 0;
    lagged_frames_ = 0;
    output_cb_     = NULL;
    output_ctx_    = NULL;
    pthread_mutex_init(&output_mutex_, NULL);
}

WLGraphics::~WLGraphics() {
    Stop();   // 幂等；join 节拍线程——之后没人再读 output_cb_，销毁锁才安全
    pthread_mutex_destroy(&output_mutex_);
}

int WLGraphics::Start() {
    if (thread_running_) return 0;   // 防重入
    if (pthread_create(&thread_, NULL, GraphicsThreadFunc, this) != 0)
        return -1;
    thread_running_ = true;   // 守卫：只有 Start 成功，Stop/dtor 才会 join
    return 0;
}

void WLGraphics::Stop() {
    if (!thread_running_) return;
    atomic_store(&should_stop_, true);   // 无 pause 挂起点，置位后最坏等一个 interval
    pthread_join(thread_, NULL);
    thread_running_ = false;
}

void WLGraphics::SetOutput(wl_frame_output_cb cb, void *ctx) {
    pthread_mutex_lock(&output_mutex_);
    output_cb_  = cb;
    output_ctx_ = ctx;
    pthread_mutex_unlock(&output_mutex_);
}

// ---------- 节拍核心 ----------

/**
 * 睡到下一 tick 的绝对时刻，并推进 video_time_（对标 OBS video_sleep，obs-video.c:805）。
 *
 * - 目标永远是 video_time_ + interval 这个"绝对时刻"：即使本帧合成耗时不定，
 *   下一目标仍从上一目标推算，误差不累积（与 PaceVideo 的绝对基准同一原理）。
 * - 卡顿（目标已成过去）：算出实际落后几个 interval，把 video_time_ 一次性跳到位，
 *   本帧记作"顶 count 帧"。下游接编码后按 count 复帧，时间轴保持规整 CFR。
 */
void WLGraphics::VideoSleep() {
    int64_t t = video_time_ + interval_ns_;
    int count;

    if (WLTime::SleepToNs(t)) {
        video_time_ = t;              // 正常：平滑 +interval
        count = 1;
    } else {
        int64_t diff = WLTime::NowNs() - video_time_;
        if (diff < interval_ns_) diff = interval_ns_;
        count = (int)(diff / interval_ns_);   // 落后了几个完整 interval
        video_time_ += interval_ns_ * count;  // 一次性跳到该到的位置
    }

    total_frames_  += count;
    lagged_frames_ += count - 1;

    if (count > 1) {
        fprintf(stderr, "[gfx] lag: 本 tick 顶 %d 帧 (total=%llu lagged=%llu)\n",
                count, total_frames_, lagged_frames_);
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
        CVPixelBufferRef frame;     // owned（GetFrame 已 +1，ThreadLoop 负责 release）
        int64_t          pts_ns;
    } out[WL_TICK_MAX_SOURCES];
};

// tick 单个源：把本 tick 的 video_time 当"现在几点"传给挑帧，有帧就收集
static void TickOneSource(WLSource *src, void *ctx) {
    tick_ctx *tc = (tick_ctx *)ctx;
    // 分流唯一依据 = ASYNC 位（对齐 obs_source_video_tick，obs-source.c:1367）：
    // 异步源本 tick 挑帧；同步源没有帧队列，render 阶段直接 VideoRender() 现画（M3）
    if ((src->Info().output_flags & WL_SOURCE_ASYNC) == 0) return;
    if (tc->count >= WL_TICK_MAX_SOURCES) {
        fprintf(stderr, "[gfx] tick 源数超 %d，多余的本拍丢弃\n", WL_TICK_MAX_SOURCES);
        return;
    }

    int64_t pts = 0;
    CVPixelBufferRef f = src->GetFrame(tc->video_time, &pts);   // owned：+1 到手
    if (!f) return;

    tc->out[tc->count].src    = src;
    tc->out[tc->count].frame  = f;      // 接管 GetFrame 给的那份引用
    tc->out[tc->count].pts_ns = pts;
    tc->count++;
}

void *WLGraphics::GraphicsThreadFunc(void *arg) {
    ((WLGraphics *)arg)->ThreadLoop();
    return NULL;
}

void WLGraphics::ThreadLoop() {
    video_time_ = WLTime::NowNs();   // 时钟锚定（对标 obs->video.video_time = os_gettime_ns()）

    while (!atomic_load(&should_stop_)) {
        // 先看有没有人接帧：锁内只拷指针（避免持 output_mutex_ 期间跑用户代码），
        // 没人接就整拍跳过挑帧——不白做 retain/release，缓冲靠 drop-oldest 自净。
        pthread_mutex_lock(&output_mutex_);
        wl_frame_output_cb cb = output_cb_;
        void *cb_ctx = output_ctx_;
        pthread_mutex_unlock(&output_mutex_);

        if (cb) {
            // ── (1) tick 所有源 + 逐源挑帧（锁内遍历，见 WLCore::ForeachSource 并发说明）──
            tick_ctx tc;
            tc.video_time = video_time_;
            tc.count      = 0;
            WLCore::ForeachSource(TickOneSource, &tc);

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
        VideoSleep();
    }
}
