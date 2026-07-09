//
//  WLGraphics.hpp
//  OBSLabs
//
//  全局合成节拍线程（原 wl_graphics，对标 obs_graphics_thread）。
//  阶段一：只拉帧（tick 所有源挑帧），合成/输出是 TODO stub。
//  由 WLCore 拥有：startup 时创建并启动（空转等源），shutdown 时最先销毁。
//

#ifndef WLGraphics_hpp
#define WLGraphics_hpp

#include <stdatomic.h>   // atomic_bool（Clang 的 C++ 扩展 _Atomic，gnu++20 可用）
#include <stdint.h>
#include <pthread.h>

class WLGraphics {
    // 所有成员在构造函数里逐个初始化：new 不像 calloc 会清零
    pthread_t   thread;           // 未初始化也安全：thread_running 守卫所有 join
    bool        thread_running;   // start 成功后置 true：守卫 stop 里的 join
    atomic_bool should_stop;

    int     fps;
    int64_t interval_ns;      // 一个 tick 的标称时长 = 1e9 / fps
    int64_t video_time;       // 虚拟当前时刻（起点 = 启动时的单调钟，每 tick +interval）

    // 健康度统计（对标 OBS total_frames / lagged_frames）
    uint64_t total_frames;
    uint64_t lagged_frames;

    static void *graphics_thread_func(void *arg);  // pthread 入口：转回成员函数
    void thread_loop();       // 主循环：tick 源 →（合成/输出 TODO）→ video_sleep
    void video_sleep();       // 睡到下一 tick 的绝对时刻；卡顿一次跳 count 帧

public:
    WLGraphics(int fps);      // 契约：fps > 0（由 WLCore::startup 把关）
    ~WLGraphics();            // 幂等 stop（join 节拍线程）

    int  start();
    void stop();
};

#endif /* WLGraphics_hpp */
