//
//  WLMediaSource.hpp
//  OBSLabs
//
//  "media_file" 源（Orthodox C++：只用 class + 成员函数组织代码，
//  数据成员、内存管理、并发原语全部保持 C 写法，不用 STL）。
//
//  合并 C 版两个模块的职责：
//    - wl_media_thread：解码主循环 + 视频 pacing（本类主体，对标 OBS mp_media）
//    - wl_media_source：vtable 桥接（在 WLMediaSource.cpp 底部，extern "C" 注册）
//  C 侧（wl_source / registry / wl_core）完全不动，vtable 的 data 就是 WLMediaSource*。
//

#ifndef WLMediaSource_hpp
#define WLMediaSource_hpp

#include <stdatomic.h>         // atomic_bool（Clang 的 C++ 扩展 _Atomic，gnu++20 可用）
#include <stdint.h>            // int64_t（seek / pts 时间戳）
#include <pthread.h>

extern "C" {                   // FFmpeg 头没有 extern "C" 守卫，C++ 侧必须自己包
#include <libavutil/avutil.h>  // AV_NOPTS_VALUE（pacing 未锚定哨兵）
#include <libavutil/frame.h>   // AVFrame（output 回调签名）
}

#include "WLDecoder.hpp"       // 解封装 + 解码（wl_read/frame_result_t 类型经它可见）

// output 回调：解码线程解出一帧后调用，把帧交给上层（wl_source）。
// 视频：硬解 frame->data[3] = CVPixelBufferRef；软解 frame->data[0..] = YUV。
// 音频：frame->data[0] = PCM。pts_ns 已换算为纳秒。
typedef void (*wl_media_video_cb)(AVFrame *frame, int64_t pts_ns, void *opaque);
typedef void (*wl_media_audio_cb)(AVFrame *frame, int64_t pts_ns, void *opaque);

class WLMediaSource {
    // 所有成员在构造函数里逐个初始化：new 不像 calloc 会清零，漏一个就是垃圾值
    char *path;                // strdup 拥有拷贝（调用方的 C 串可能是临时缓冲）

    WLDecoder *decoder;        // 创建失败留 NULL，由 valid() 暴露

    pthread_t thread;          // 未初始化也安全：thread_running 守卫所有 join
    bool      thread_running;  // start 成功后置 true：守卫 stop 里的 join

    atomic_bool should_stop;   // 终止信号（跨线程，原子读写）
    bool paused;               // 暂停状态（ctrl_mutex 保护）
    bool eof;                  // decoder 已读完且 drain 完毕（仅解码线程访问）

    // 视频 pacing（pts-based，仿 OBS mp_media_sleep）—— 仅解码线程访问，无需加锁
    int64_t base_wall_ns;      // 墙钟零点：第一帧那刻的 CLOCK_MONOTONIC 读数
    int64_t first_pts_ns;      // 媒体零点：第一帧 pts；AV_NOPTS_VALUE = 尚未锚定

    // output 回调（把解码帧交给上层 wl_source）—— set_callbacks 在 start 之前调好，
    // 线程跑起来后只读，不加锁
    wl_media_video_cb video_cb;
    wl_media_audio_cb audio_cb;
    void             *cb_opaque;

    // pause 条件变量（替代 OBS 的 semaphore）
    pthread_mutex_t ctrl_mutex;
    pthread_cond_t  ctrl_cond;  // pause→resume 或 stop 时 signal

    static void *media_thread_func(void *arg);  // pthread 入口：转回成员函数
    void thread_loop();                         // 解码主循环
    void pace_video(int64_t pts_ns);            // 按 pts 节流到 ~实时

public:
    WLMediaSource(const char *path, const char *hw_type);  // hw_type 只在构造时用，不保存
    ~WLMediaSource();   // 幂等 stop → free decoder → 销毁锁

    bool valid() const { return decoder != NULL; }  // ctor 里 decoder 是否创建成功

    // 必须在 start 之前调用（约定见成员注释）
    void set_callbacks(wl_media_video_cb video_cb,
                       wl_media_audio_cb audio_cb,
                       void *opaque);

    int  start();       // 一次性：stop 后不支持再 start（与 C 版语义一致）
    int  stop();        // 幂等；join 解码线程
    void pause(bool paused);
    void seek(int64_t seek_ts_us);
};

#endif /* WLMediaSource_hpp */
