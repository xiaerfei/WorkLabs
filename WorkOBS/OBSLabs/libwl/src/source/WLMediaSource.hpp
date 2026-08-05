//
//  WLMediaSource.hpp
//  OBSLabs
//
//  "media_file" 源：本地媒体文件解码（WLSource 的第一个子类）。
//  主体是解码主循环 + 视频 pacing（对标 OBS mp_media / ffmpeg_source）。
//
//  继承取代了 C 版的三层胶水：
//    - vtable 函数指针表 → 直接重写基类虚函数
//    - media_source_data（thread/source/path）→ 本类成员，this 就是 source
//    - output 回调 + opaque → 解码线程直接调基类 protected OutputVideo()
//

#ifndef WLMediaSource_hpp
#define WLMediaSource_hpp

#include <stdatomic.h>         // atomic_bool（Clang 的 C++ 扩展 _Atomic，gnu++20 可用）
#include <stdint.h>            // int64_t（seek / pts 时间戳）
#include <pthread.h>

extern "C" {                   // FFmpeg 头没有 extern "C" 守卫，C++ 侧必须自己包
#include <libavutil/avutil.h>  // AV_NOPTS_VALUE（pacing 未锚定哨兵）
}

#include "WLSource.hpp"        // 基类：async_frames 缓冲 + 挑帧 + 虚控制接口
#include "WLDecoder.hpp"       // 解封装 + 解码

class WLMediaSource : public WLSource {
    // 所有成员在构造函数里逐个初始化：new 不像 calloc 会清零，漏一个就是垃圾值
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
    WLMediaSource(const char *path, const char *hw_type);  // hw_type 只在构造时用，不保存
    // 子类 dtor 必须自己先 Stop（join 解码线程）：等基类 dtor 再停就晚了
    //（析构期间虚表已退化，且基类清缓冲时生产线程必须已死）。
    virtual ~WLMediaSource();

    bool Valid() const { return decoder_ != NULL; }  // ctor 里 decoder 是否创建成功

    // ---- WLSource 虚接口实现 ----
    virtual int  Start();      // 一次性：Stop 后不支持再 Start（与 C 版语义一致）
    virtual void Stop();       // 幂等；join 解码线程
    virtual void Pause(bool paused);
    virtual void Seek(int64_t seek_ts_us);

    // 注册 "media_file" 类型到全局表（WLCore::Startup 调用一次）
    static void RegisterType();
};

#endif /* WLMediaSource_hpp */
