//
//  WLMediaSource.hpp
//  OBSLabs
//
//  "media_file" 源：本地媒体文件解码（WLSourceProtocol 的第一个实现体）。
//  主体是解码主循环 + **单一 pace 放行线**（对标 OBS mp_media_thread，
//  deps/media-playback/media-playback/media.c:529/632/796）。
//
//  继承 WLSourceProtocol（纯协议），持有 WLSource* 反向引用（用于回喂帧）。
//  通过 source_->OutputVideo(pb, pts) 将解码帧送入壳的缓冲。
//
//  ── pacing 模型（一句话）──────────────────────────────────────
//  整条循环只有一处 sleep，睡的是"下一位出场的帧"——不管它是视频还是音频：
//      delta     = min(视频就绪帧 pts, 音频就绪帧 pts) − next_pts_ns_
//      next_ns_ += delta                    ← 累加：绝对时刻，误差不累积
//      next_pts_ns_ = min(...)               ← 赋值：放行线
//      pts ≤ next_pts_ns_ 的帧才可投放（CanPlay）
//  关键前提：**提前解一帧攥在手里**（v_frame_ / a_frame_），
//  否则拿不到"下一帧的 pts"，也就算不出 delta。见 PrepareFrames()。
//  ────────────────────────────────────────────────────────────
//
//  命名规范：对外 PascalCase，内部 camelCase。
//

#ifndef WLMediaSource_hpp
#define WLMediaSource_hpp

#include <stdatomic.h>         // atomic_bool（Clang 的 C++ 扩展 _Atomic，gnu++20 可用）
#include <stdint.h>            // int64_t / INT64_MAX（seek / pts 时间戳）
#include <pthread.h>

extern "C" {                   // FFmpeg 头没有 extern "C" 守卫，C++ 侧必须自己包
#include <libavutil/avutil.h>  // AV_NOPTS_VALUE
#include <libavutil/frame.h>   // AVFrame（攥在手里的帧）
}

#include "WLSourceProtocol.hpp" // 纯协议（虚析构 + 纯虚/默认实现）
#include "WLDecoder.hpp"       // 解封装 + 解码

class WLSource;                // 前置声明（持有指针，不 include 壳头）

class WLMediaSource : public WLSourceProtocol {
    WLSource   *source_;       // 反向引用壳（用于回喂帧）

    char *path_;               // strdup 拥有拷贝（调用方的 C 串可能是临时缓冲）

    WLDecoder *decoder_;       // 创建失败留 NULL，由 Valid() 暴露

    pthread_t thread_;         // 未初始化也安全：thread_running_ 守卫所有 join
    bool      thread_running_; // Start 成功后置 true：守卫 Stop 里的 join

    atomic_bool should_stop_;  // 终止信号（跨线程，原子读写）
    bool paused_;              // 暂停状态（ctrl_mutex_ 保护）

    atomic_bool seek_pending_; // seek 请求（外部线程置位，主循环执行）
    int64_t     seek_ts_us_;   // seek 目标（S1 接入 av_seek_frame 时使用）

    // ── 手里攥着的帧（已解码、未投放）──
    // 存在的唯一理由：提前知道"下一帧的 pts"，才算得出放行线该推进多少。
    AVFrame *v_frame_;  int64_t v_pts_;  bool v_ready_;  bool v_drained_;
    AVFrame *a_frame_;  int64_t a_pts_;  bool a_ready_;  bool a_drained_;
    bool     read_eof_;        // av_read_frame 已 EOF（Read() 内已给 codec send NULL）

    // ── 放行线（对标 OBS next_pts_ns / next_ns）──
    int64_t next_pts_ns_;      // 媒体时基：pts ≤ 它的帧才可投放
    int64_t next_ns_;          // 它对应的墙钟绝对时刻；0 = 需要重新锚定
    int64_t start_ts_ns_;      // 本次播放的媒体起点
    int64_t base_ts_ns_;       // 媒体轴平移量（seek / loop 时 +=，不动 play_sys_ts_ns_）
    int64_t play_sys_ts_ns_;   // 本次播放起点的墙钟

    // ── 统计（验证"输出 = 1.0× 实时"，A2 验收点用）──
    int64_t video_frames_;
    int64_t audio_frames_;
    int64_t audio_samples_;
    int     audio_rate_;       // 最近一帧的采样率（用于把 samples 换算成秒）
    int64_t stats_next_ns_;
    int64_t late_sum_ns_;      // sleep 醒来滞后（实际醒来 − 本轮目标，>0 = 醒晚）
    int64_t late_max_ns_;
    int64_t late_rounds_;

    // pause 条件变量（替代 OBS 的 semaphore）
    pthread_mutex_t ctrl_mutex_;
    pthread_cond_t  ctrl_cond_;  // pause→resume 或 stop 时 signal

    static void *MediaThreadFunc(void *arg);  // pthread 入口：转回成员函数

    // ---- 主循环五步（顺序照抄 OBS mp_media_thread）----
    void ThreadLoop();                        // 睡 → 放 → 补货 → 推进
    bool PrepareFrames();                     // 补货：解到两路手里各攥一帧
    bool TryReceiveVideo();                   // 收一帧视频存进 v_frame_
    bool TryReceiveAudio();                   // 收一帧音频存进 a_frame_
    void ReleaseVideo();                      // 投放视频帧（到点的）
    void ReleaseAudio();                      // 投放音频帧（A3/A4 接入点）
    void AdvancePts();                        // 推进放行线
    void DropHeldFrames();                    // 丢弃手里未投放的帧（seek / dtor）
    void LogStats();                          // 周期诊断（可关）

    // ---- 时间映射 / 判定 ----
    int64_t MinReadyPts() const;              // min(视频就绪帧 pts, 音频就绪帧 pts)
    bool    CanPlay(int64_t pts_ns) const;    // 对标 mp_media_can_play_frame
    void    ResetTs();                        // 起播 / 暂停恢复 / reset 重锚

public:
    // 三参 ctor：path + hw_type + 壳指针
    WLMediaSource(const char *path, const char *hw_type, WLSource *source);
    ~WLMediaSource();   // dtor 内 Stop() → join 解码线程

    bool Valid() const { return decoder_ != NULL; }  // ctor 里 decoder 是否创建成功

    // 媒体时基 → 系统钟（音视频共用；A4 接入音频输出时使用）
    int64_t SysOf(int64_t pts_ns) const {
        return base_ts_ns_ + pts_ns - start_ts_ns_ + play_sys_ts_ns_;
    }

    // ---- WLSourceProtocol 实现 ----
    int  Start() override;      // 一次性：Stop 后不支持再 Start（与 C 版语义一致）
    void Stop()  override;      // 幂等；join 解码线程
    void Pause(bool paused) override;
    void Seek(int64_t seek_ts_us) override;

    // 注册 "media_file" 类型到全局表（WLCore::Startup 调用一次）
    static void RegisterType();
};

#endif /* WLMediaSource_hpp */
