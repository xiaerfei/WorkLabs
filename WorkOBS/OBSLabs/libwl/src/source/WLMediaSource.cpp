//
//  WLMediaSource.cpp
//  OBSLabs
//
//  解码主循环 + 单一 pace 放行线（对标 OBS mp_media_thread，
//  deps/media-playback/media-playback/media.c:796）。
//
//  ── 主循环五步（顺序照抄 OBS，不能换）──────────────────────────
//    1. 控制检查（pause / stop / seek）
//    2. 起播或重锚：先补货拿到首帧 pts，再锚定放行线（不睡）
//    3. 全循环唯一 sleep：睡到 next_ns_ 这个「绝对时刻」
//    4. 到点才放：视频、音频各自独立判定 CanPlay()
//    5. 补货（PrepareFrames）+ 推进放行线（AdvancePts）
//
//  为什么必须有第 5 步的补货：放行线要靠"下一帧的 pts"推进，而 pts
//  只有解码出来才知道 —— 所以永远提前解一帧攥在手里（v_frame_/a_frame_），
//  是本方案成立的前提。OBS 对应 mp_media_prepare_frames（media.c:278）。
//
//  为什么只有一处 sleep：视频、音频各 pace 一次会把整体节奏锁死成
//  46.875 fps（= 48000/1024）；只 pace 视频则音频 1.28× 超产。
//  单一放行线按 min(v_pts, a_pts) 推进 → 生产速率天然 1.0× 实时。
//

#include "WLMediaSource.hpp"
#include "WLSource.hpp"            // 壳（用于 source_->OutputVideo）
#include "WLSourceRegistry.hpp"
#include "WLTime.hpp"            // NowNs / SleepToNs（全库同一把单调钟）
#include <stdio.h>
#include <stdlib.h>              // free
#include <string.h>              // strdup
#include <CoreVideo/CoreVideo.h>

extern "C" {
#include <libavutil/frame.h>     // AVFrame
#include <libavutil/pixfmt.h>    // AV_PIX_FMT_VIDEOTOOLBOX
}

// ── pacing 常量（全部对标 OBS）──
#define WL_LAG_LIMIT_NS       200000000LL   // 落后上限：单次最多睡 200ms（mp_media_sleep 的 timeout_ms）
#define WL_MAX_TS_JUMP_NS    3000000000LL   // 放行线单次推进上限，超过视为跳变（media.c:543）
#define WL_MAX_TS_VAR_NS     2000000000LL   // 强放阈值（can_play_frame 的 MAX_TS_VAR）
#define WL_STATS_INTERVAL_NS 5000000000LL   // 诊断日志周期

// 诊断日志开关（A2 验收后关掉）
#define WL_MEDIA_PACE_STATS 1

// ═════════════════ 生命周期 ═════════════════

WLMediaSource::WLMediaSource(const char *path, const char *hw_type, WLSource *source) {
    // 壳的反向引用
    source_        = source;

    // 本类成员逐个初始化
    path_          = strdup(path ? path : "");
    decoder_       = new WLDecoder(path_, hw_type);
    if (!decoder_->Valid()) {         // ctor 没有返回值，失败靠 Valid() 暴露
        delete decoder_;
        decoder_ = NULL;              // 本类的 Valid() 就看这里是否为 NULL
    }
    thread_running_ = false;
    atomic_init(&should_stop_, false);
    atomic_init(&seek_pending_, false);
    paused_        = false;
    seek_ts_us_    = 0;

    // 手里攥着的帧
    v_frame_ = NULL; v_pts_ = 0; v_ready_ = false; v_drained_ = false;
    a_frame_ = NULL; a_pts_ = 0; a_ready_ = false; a_drained_ = false;
    read_eof_ = false;

    // 放行线（0 = 尚未锚定，首轮会走 ResetTs）
    next_pts_ns_    = 0;
    next_ns_        = 0;
    start_ts_ns_    = 0;
    base_ts_ns_     = 0;
    play_sys_ts_ns_ = 0;

    // 统计
    video_frames_  = 0;
    audio_frames_  = 0;
    audio_samples_ = 0;
    audio_rate_    = 0;
    stats_next_ns_ = 0;
    late_sum_ns_   = 0;
    late_max_ns_   = 0;
    late_rounds_   = 0;

    pthread_mutex_init(&ctrl_mutex_, NULL);
    pthread_cond_init(&ctrl_cond_, NULL);
}

WLMediaSource::~WLMediaSource() {
    Stop();   // 先停线程（幂等）——必须在释放资源前，线程还在用它们

    DropHeldFrames();
    if (decoder_) delete decoder_;
    free(path_);
    pthread_mutex_destroy(&ctrl_mutex_);
    pthread_cond_destroy(&ctrl_cond_);
}

// ═════════════════ 控制（WLSourceProtocol 实现）═════════════════

int WLMediaSource::Start() {
    if (thread_running_) return 0;   // 防重入
    if (pthread_create(&thread_, NULL, MediaThreadFunc, this) != 0)
        return -1;
    thread_running_ = true;   // 守卫：只有 Start 成功，Stop/dtor 才会 join
    return 0;
}

void WLMediaSource::Stop() {
    // 幂等：未 Start（create 完直接销毁）或已停，都安全返回。
    // 对已自行退出（EOF/error）的线程再 join 也安全，立即返回——双重 join 才是 UB，
    // 而 thread_running_ 守卫保证全程只 join 一次。
    if (!thread_running_) return;

    pthread_mutex_lock(&ctrl_mutex_);
    atomic_store(&should_stop_, true); // 在锁内设 + signal，防 lost wakeup
    pthread_cond_signal(&ctrl_cond_);  // 唤醒可能在 pause 上挂起的线程
    pthread_mutex_unlock(&ctrl_mutex_);

    pthread_join(thread_, NULL);
    thread_running_ = false;
}

void WLMediaSource::Pause(bool paused) {
    pthread_mutex_lock(&ctrl_mutex_);
    paused_ = paused;
    if (!paused) pthread_cond_signal(&ctrl_cond_); // 唤醒主循环
    pthread_mutex_unlock(&ctrl_mutex_);
    // 恢复后的重锚在主循环里做（next_ns_ = 0 → 重新补货锚定）。
    // 放在这里做会与解码线程抢状态，所以只置信号。
}

void WLMediaSource::Seek(int64_t seek_ts_us) {
    // 标志位模式（S1 的落点）：只设标志，由主循环自己执行，
    // 避免跨线程动 codec/format 上下文 + 手里攥着的帧。
    // TODO(S1): 主循环里补 av_seek_frame(fmt, -1, seek_ts_us_, ...)。
    seek_ts_us_ = seek_ts_us;
    atomic_store(&seek_pending_, true);
}

// ═════════════════ 时间映射 / 放行判定 ═════════════════

/** 往前看：两路就绪帧里更靠前的那颗豆（对标 mp_media_get_next_min_pts，media.c:322）。 */
int64_t WLMediaSource::MinReadyPts() const {
    int64_t min_pts = INT64_MAX;
    if (v_ready_ && v_pts_ < min_pts) min_pts = v_pts_;
    if (a_ready_ && a_pts_ < min_pts) min_pts = a_pts_;
    return min_pts;
}

/** 到点判定（对标 mp_media_can_play_frame，media.c:353）。 */
bool WLMediaSource::CanPlay(int64_t pts_ns) const {
    return pts_ns <= next_pts_ns_ ||
           (pts_ns - next_pts_ns_ > WL_MAX_TS_VAR_NS);   // 跳变 > 2s 强放，防卡死
}

/**
 * 起播 / 暂停恢复 / reset：重锚放行线（对标 OBS reset_ts，media.c:769）。
 * 音视频共用这一组量，所以恢复不会造成音画错位（P2 的落点）。
 */
void WLMediaSource::ResetTs() {
    play_sys_ts_ns_ = WLTime::NowNs();
    start_ts_ns_    = MinReadyPts();      // 本次播放的媒体起点
    next_pts_ns_    = start_ts_ns_;
    next_ns_        = play_sys_ts_ns_;    // 本轮不睡，立即放首帧
}

/** 推进放行线（对标 mp_media_calc_next_ns，media.c:529）。 */
void WLMediaSource::AdvancePts() {
    int64_t min_next = MinReadyPts();
    if (min_next == INT64_MAX) return;    // 两路都排空，不再推进

    int64_t delta = min_next - next_pts_ns_;
    if (delta < 0)                delta = 0;                 // 单调保护
    if (delta > WL_MAX_TS_JUMP_NS) delta = 0;                // 3s 跳变：本轮不推进

    next_ns_    += delta;        // ★ 累加：绝对时刻，误差不累积
    next_pts_ns_ = min_next;     // ★ 赋值：走到那颗豆
}

// ═════════════════ 帧的持有 / 补货 / 投放 ═════════════════

void WLMediaSource::DropHeldFrames() {
    if (v_frame_) av_frame_free(&v_frame_);   // free 内部会把指针置 NULL
    if (a_frame_) av_frame_free(&a_frame_);
    v_ready_ = false;
    a_ready_ = false;
}

bool WLMediaSource::TryReceiveVideo() {
    AVFrame *f   = NULL;
    int64_t  pts = 0;
    wl_frame_result_t r = decoder_->ReceiveVideo(&f, &pts);
    if (r == WL_FRAME_OK) {
        if (v_frame_) av_frame_free(&v_frame_);
        v_frame_ = f;
        v_pts_   = pts;
        v_ready_ = true;
        return true;
    }
    if (r == WL_FRAME_EOF) v_drained_ = true;   // 真排空（EAGAIN 不算）
    return false;
}

bool WLMediaSource::TryReceiveAudio() {
    AVFrame *f   = NULL;
    int64_t  pts = 0;
    wl_frame_result_t r = decoder_->ReceiveAudio(&f, &pts);
    if (r == WL_FRAME_OK) {
        if (a_frame_) av_frame_free(&a_frame_);
        a_frame_ = f;
        a_pts_   = pts;
        a_ready_ = true;
        return true;
    }
    if (r == WL_FRAME_EOF) a_drained_ = true;
    return false;
}

/**
 * 补货：一直解到"不需要帧的那一路之外，其余每路手里都攥着一帧"
 * （对标 mp_media_prepare_frames + mp_media_ready_to_start，media.c:278/204）。
 *
 * @return true = 手里至少还有一帧（可继续）；false = 两路都排空，播放结束。
 */
bool WLMediaSource::PrepareFrames() {
    for (;;) {
        bool v_need = !v_ready_ && !v_drained_;
        bool a_need = !a_ready_ && !a_drained_;
        if (!v_need && !a_need) break;

        // 先收：一个 packet 可能产出多帧（B 帧延迟），codec 内缓存要取干净
        if (v_need && TryReceiveVideo()) continue;
        if (a_need && TryReceiveAudio()) continue;

        // 收不到 → 需要新 packet
        if (read_eof_) {
            // 文件已读完且 codec 已 send(NULL)；再收不到就是真没了。
            // （正常应由 ReceiveX 返回 WL_FRAME_EOF 置 drained，这里是兜底。）
            if (v_need) v_drained_ = true;
            if (a_need) a_drained_ = true;
            continue;
        }

        wl_read_result_t rr = decoder_->Read();
        if (rr == WL_READ_EOF) {
            read_eof_ = true;        // 继续循环，把 codec 内残余帧 drain 干净
        } else if (rr == WL_READ_ERROR) {
            fprintf(stderr, "[WLMediaSource] read error, stopping\n");
            atomic_store(&should_stop_, true);
            return false;
        }
    }
    return v_ready_ || a_ready_;
}

void WLMediaSource::ReleaseVideo() {
    if (v_frame_ && v_frame_->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        // 硬解帧零拷贝：data[3] 就是 CVPixelBufferRef
        CVPixelBufferRef pb = (CVPixelBufferRef)v_frame_->data[3];
        if (pb) source_->OutputVideo(pb, v_pts_);   // 壳内部 retain，free 后仍有效
    }
    // 软解（format != VIDEOTOOLBOX）：TODO sws_scale → CVPixelBuffer，M1 暂不支持

    av_frame_free(&v_frame_);
    v_ready_ = false;
    video_frames_++;
}

void WLMediaSource::ReleaseAudio() {
    // A3/A4 接入点：WLResampler → source_->OutputAudio(data, frames, SysOf(a_pts_))
    // 现在音频只参与放行线（决定节拍），产出量用于验证 1.0× 实时。
    if (a_frame_) {
        audio_samples_ += a_frame_->nb_samples;
        if (a_frame_->sample_rate > 0) audio_rate_ = a_frame_->sample_rate;
    }
    av_frame_free(&a_frame_);
    a_ready_ = false;
    audio_frames_++;
}

// ═════════════════ 解码主循环 ═════════════════

void *WLMediaSource::MediaThreadFunc(void *arg) {
    ((WLMediaSource *)arg)->ThreadLoop();
    return NULL;
}

void WLMediaSource::ThreadLoop() {
    while (!atomic_load(&should_stop_)) {
        // ── 1. 控制检查 ──

        // pause：在条件变量上挂起，直到 resume 或 stop
        bool resumed = false;
        pthread_mutex_lock(&ctrl_mutex_);
        while (paused_ && !atomic_load(&should_stop_)) {
            pthread_cond_wait(&ctrl_cond_, &ctrl_mutex_);
            resumed = true;
        }
        pthread_mutex_unlock(&ctrl_mutex_);
        if (atomic_load(&should_stop_)) break;

        if (resumed) next_ns_ = 0;   // 暂停期间墙钟照走，旧放行线作废 → 重新锚定

        // ── 2. seek（S1 stub：flush + 重锚，av_seek_frame 待接入）──
        if (atomic_load(&seek_pending_)) {
            atomic_store(&seek_pending_, false);
            (void)seek_ts_us_;
            decoder_->Flush();
            DropHeldFrames();
            read_eof_ = false;
            v_drained_ = false;
            a_drained_ = false;
            next_ns_ = 0;            // 触发重新补货 + 重锚
            continue;
        }

        // ── 3. 起播 / 重锚：先补货拿到首帧 pts，才锚得放行线 ──
        if (next_ns_ == 0) {
            if (!PrepareFrames()) break;    // 两路都排空 → 播放结束
            ResetTs();
        }

        // ── 4. 全循环唯一 sleep：睡到 next_ns_ 这个绝对时刻 ──
        {
            int64_t now = WLTime::NowNs();
            if (next_ns_ > now) {
                int64_t delta = next_ns_ - now;
                if (delta > WL_LAG_LIMIT_NS) {
                    // 落后 > 200ms：分段追（每次最多睡 200ms），本轮不放帧，
                    // 防止"卡完一次性倾泻一堆帧"（对标 mp_media_sleep 的 timeout）
                    WLTime::SleepToNs(now + WL_LAG_LIMIT_NS);
                    continue;
                }
                WLTime::SleepToNs(next_ns_);
            }
            // 已到点 / 略落后：不睡，直接放帧（自动追赶，误差不累积）
        }

        // sleep 精度统计：实际醒来时刻 − 本轮目标（>0 = 醒晚了）
        // ⚠️ 必须在 AdvancePts() 之前取：推进后 next_ns_ 就变成"下一轮"的目标了
        {
            int64_t late = WLTime::NowNs() - next_ns_;
            if (late > 0) {
                late_sum_ns_ += late;
                if (late > late_max_ns_) late_max_ns_ = late;
            }
            late_rounds_++;
        }

        // ── 5. 到点才放（视频、音频各自独立判定，互不等待）──
        if (v_ready_ && CanPlay(v_pts_)) ReleaseVideo();
        if (a_ready_ && CanPlay(a_pts_)) ReleaseAudio();

        // ── 6. 补货：解到两路手里各攥一帧 —— 这样才知道下一帧的 pts ──
        if (!PrepareFrames()) break;   // 两路都排空且手里没帧 → 结束

        // ── 7. 推进放行线 ──
        AdvancePts();

#if WL_MEDIA_PACE_STATS
        LogStats();
#endif
    }
}

// ═════════════════ 诊断（验证 1.0× 实时，A2 验收点）════════════════

/**
 * 每 5 秒一行。核心看三个数：
 *   - audio=x.xxx  ：音频产出 / 墙钟。旧方案 ≈1.28（超产），本方案应 ≈1.00
 *   - media vs wall：两者差值应恒定（放行线领先量），不增长 = 无漂移
 *   - late avg/max ：sleep 醒来滞后（macOS nanosleep 过睡量），
 *                    典型 0.8~2.5ms；因为睡的是绝对时刻，过睡不累积
 */
void WLMediaSource::LogStats() {
    if (play_sys_ts_ns_ == 0) return;      // 还没锚定

    int64_t now = WLTime::NowNs();
    if (stats_next_ns_ == 0) { stats_next_ns_ = now + WL_STATS_INTERVAL_NS; return; }
    if (now < stats_next_ns_) return;
    stats_next_ns_ = now + WL_STATS_INTERVAL_NS;

    double wall_s  = (double)(now - play_sys_ts_ns_) / 1e9;
    double media_s = (double)(next_pts_ns_ - start_ts_ns_) / 1e9;
    double audio_s = audio_rate_ > 0 ? (double)audio_samples_ / (double)audio_rate_ : 0.0;
    double ratio   = wall_s > 0 ? audio_s / wall_s : 0.0;

    // sleep 醒来滞后（本周期内的均值/最大值），反映 sleep 精度与耗时抖动
    double late_avg_ms = late_rounds_ > 0 ? (double)late_sum_ns_ / late_rounds_ / 1e6 : 0.0;
    double late_max_ms = (double)late_max_ns_ / 1e6;
    late_sum_ns_ = 0;
    late_max_ns_ = 0;
    late_rounds_ = 0;

    fprintf(stderr, "[media pace] wall=%.2fs media=%.2fs v=%lld a=%lld audio=%.3fx late avg=%.2fms max=%.1fms\n",
            wall_s, media_s, (long long)video_frames_, (long long)audio_frames_,
            ratio, late_avg_ms, late_max_ms);
}

// ═════════════════ 类型注册（工厂 + 类型声明）═════════════════

// 双参工厂（对齐 OBS create(settings, source)）
static WLSourceProtocol *CreateMediaSource(const char *settings, WLSource *source) {
    if (!settings || !source) return NULL;

    WLMediaSource *ms = new WLMediaSource(settings, "videotoolbox", source);
    if (!ms->Valid()) {        // decoder 打不开（路径/格式错）
        delete ms;
        return NULL;
    }
    return ms;
}

// 类型声明（对齐 OBS ffmpeg_source 的 obs_source_info，obs-ffmpeg-source.c:787：
// 它声明 ASYNC_VIDEO | AUDIO | DO_NOT_DUPLICATE|…，后者是场景复制语义，不搬）。
// output_flags 描述的是这类源的能力，不是当前接线状态：AUDIO 位如实报——
// 音频输出通道 M4 才接，届时消费者按位取用，类型声明不用改。
// （C++20 支持 C99 的 designated initializer，但要求按字段声明顺序写。）
static const wl_source_type_info g_media_source_info = {
    .id           = "media_file",
    .type         = WL_SOURCE_TYPE_INPUT,
    .output_flags = WL_SOURCE_ASYNC_VIDEO | WL_SOURCE_AUDIO,
    .type_name    = "Media File",
    .create       = CreateMediaSource,
};

void WLMediaSource::RegisterType() {
    WLSourceRegistry::RegisterType(&g_media_source_info);
}
