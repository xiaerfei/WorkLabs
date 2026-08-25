//
//  WLMediaSource.hpp
//  OBSLabs
//
//  "media_file" 源：本地媒体文件解码（WLSourceProtocol 的第一个实现体）。
//  主体是解码主循环 + 视频 pacing（对标 OBS mp_media / ffmpeg_source）。
//
//  继承 WLSourceProtocol（纯协议），持有 WLSource* 反向引用（用于回喂帧）。
//  通过 source_->OutputVideo(pb, pts) 将解码帧送入壳的缓冲。
//
//  命名规范：对外 PascalCase，内部 camelCase。
//

#ifndef WLMediaSource_hpp
#define WLMediaSource_hpp

#include <stdatomic.h>         // atomic_bool（Clang 的 C++ 扩展 _Atomic，gnu++20 可用）
#include <stdint.h>            // int64_t（seek / pts 时间戳）
#include <pthread.h>

extern "C" {                   // FFmpeg 头没有 extern "C" 守卫，C++ 侧必须自己包
#include <libavutil/avutil.h>  // AV_NOPTS_VALUE（pacing 未锚定哨兵）
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
    bool eof_;                 // decoder 已读完且 drain 完毕（仅解码线程访问）

    // 视频 pacing（pts-based，仿 OBS mp_media_sleep）—— 仅解码线程访问，无需加锁
    int64_t base_wall_ns_;     // 墙钟零点：第一帧那刻的 CLOCK_MONOTONIC 读数
    int64_t first_pts_ns_;     // 媒体零点：第一帧 pts；AV_NOPTS_VALUE = 尚未锚定

    // pause 条件变量（替代 OBS 的 semaphore）
    pthread_mutex_t ctrl_mutex_;
    pthread_cond_t  ctrl_cond_;  // pause→resume 或 stop 时 signal

    static void *MediaThreadFunc(void *arg);  // pthread 入口：转回成员函数
    void ThreadLoop();                        // 解码主循环
    void PaceVideo(int64_t pts_ns);           // 按 pts 节流到 ~实时

public:
    // 三参 ctor：path + hw_type + 壳指针
    WLMediaSource(const char *path, const char *hw_type, WLSource *source);
    ~WLMediaSource();   // dtor 内 Stop() → join 解码线程

    bool Valid() const { return decoder_ != NULL; }  // ctor 里 decoder 是否创建成功

    // ---- WLSourceProtocol 实现 ----
    int  Start() override;      // 一次性：Stop 后不支持再 Start（与 C 版语义一致）
    void Stop()  override;      // 幂等；join 解码线程
    void Pause(bool paused) override;
    void Seek(int64_t seek_ts_us) override;

    // 注册 "media_file" 类型到全局表（WLCore::Startup 调用一次）
    static void RegisterType();
};

#endif /* WLMediaSource_hpp */
