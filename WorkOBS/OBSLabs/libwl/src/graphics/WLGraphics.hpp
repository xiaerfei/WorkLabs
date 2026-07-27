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
#include <CoreVideo/CoreVideo.h>   // CVPixelBufferRef（合成帧输出）

class WLSource;   // 回调签名只用指针，前置声明即可

// per-source 帧输出回调（对标 OBS render_displays：渲染线程逐 display push，UI 不拉）。
// graphics 线程每 tick 给"本 tick 有帧"的每个源调一次。约定：
//   - 在 graphics 线程被调，回调内只做轻量转发（勿阻塞、勿回头调 WLCore 增删源 → 同锁死锁）；
//   - src 只可当路由 key 做指针比较，不可解引用——出了源列表锁，源随时可能被删
//     （OBS 靠源引用计数保活，我们用这条契约简化）；
//   - frame 仅保证回调内有效（graphics 攥着一份 owned 引用，回调返回后才放手），
//     要跨线程/留到之后用必须自己 retain。这个 borrow 与 get_frame 旧契约不同：
//     持有者是调用方栈上的引用，回调返回前不可能被并发释放，绝对安全。
// M2/M3 真合成落地后，编码走的"合成后单帧"出口另行新增；Step1 的 last-wins
// 假合成出口已废弃，就是本签名的前身。
typedef void (*wl_frame_output_cb)(WLSource *src, CVPixelBufferRef frame,
                                   int64_t pts_ns, void *ctx);

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

    // per-source 帧输出出口：set_output 写（主线程）、thread_loop 每 tick 读（节拍线程），
    // output_mutex 护住这对指针的读写（避免撕裂 / 半更新）
    wl_frame_output_cb output_cb;
    void              *output_ctx;
    pthread_mutex_t    output_mutex;

    static void *graphics_thread_func(void *arg);  // pthread 入口：转回成员函数
    void thread_loop();       // 主循环：tick 源 →（合成/输出 TODO）→ video_sleep
    void video_sleep();       // 睡到下一 tick 的绝对时刻；卡顿一次跳 count 帧

public:
    WLGraphics(int fps);      // 契约：fps > 0（由 WLCore::startup 把关）
    ~WLGraphics();            // 幂等 stop（join 节拍线程）

    int  start();
    void stop();

    // 注册 per-source 帧输出回调（cb=NULL 注销）。线程安全，可在节拍运行时调用。
    void set_output(wl_frame_output_cb cb, void *ctx);
};

#endif /* WLGraphics_hpp */
