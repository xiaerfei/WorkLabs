//
//  WLSource.hpp
//  OBSLabs
//
//  源抽象基类（原 wl_source.c + wl_source_info.h 的合体）。
//
//  C 版用 wl_source_info_t 手写函数指针表模拟继承（对齐 OBS obs_source_info，
//  OBS 因 C ABI / 插件边界必须如此）；C with Class 下这套 vtable 的语言级
//  对应物就是虚函数——编译器替我们生成虚表，7 个桥接函数消失：
//
//      C 版                          C++ 版
//      info->start(data)      →      虚函数 start()（编译器查虚表）
//      data（void* 私有数据）  →      子类成员（this 就是 source，反向引用消失）
//      pause 可为 NULL         →      基类空默认实现
//
//  基类持有所有源共用的东西：async_frames 环形缓冲（生产端 output_video）
//  + 消费端挑帧（get_frame）。子类（WLMediaSource / 将来的 Camera 等）只管
//  产帧：在自己的线程里调 output_video 即可。
//

#ifndef WLSource_hpp
#define WLSource_hpp

#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <CoreVideo/CoreVideo.h>   // CVPixelBufferRef

// 环形缓冲的一个 slot
typedef struct wl_async_frame {
    CVPixelBufferRef pixbuf;   // retain 持有
    int64_t          pts_ns;
} wl_async_frame;

class WLSource {
    // async_frames：堆分配环形缓冲（容量运行期固定），生产者(解码线程)/消费者(tick) 共享
    wl_async_frame  *frames;
    int              capacity;      // ctor 时定；0 = 分配失败，缓冲不可用
    int              head;          // 最旧帧下标
    int              count;         // 当前帧数
    pthread_mutex_t  async_mutex;

    // 消费端挑帧的时钟基准（首次 get_frame 锚定）+ 当前显示帧（source 持有）
    bool             consume_anchored;
    int64_t          consume_first_pts;   // 媒体零点
    int64_t          consume_first_sys;   // 墙钟零点
    CVPixelBufferRef cur_frame;
    int64_t          cur_frame_pts;

protected:
    WLSource();   // 抽象类：只能被子类构造

    // 视频帧入口（生产端：子类在自己的线程调用）。所有源统一走这里
    // （解码源提取出 CVPixelBufferRef、采集源天然就是）。
    // retain 一份 push 进环形缓冲；满则丢最旧（drop-oldest，非阻塞）。
    void output_video(CVPixelBufferRef pixbuf, int64_t pts_ns);

public:
    // 必须 virtual：WLCore 存的是 WLSource*，delete 基类指针时非虚析构
    // 不会调子类 dtor —— 解码线程不 join、decoder 泄漏。
    // 注意基类 dtor 里不能调虚函数 stop()（析构期间虚表已退化到本类层级），
    // 所以契约是：子类 dtor 自己先停自己的线程。C++ 的析构顺序（子类先、
    // 基类后）恰好保证"先停生产者、再清缓冲"。
    virtual ~WLSource();

    // ---- 控制（原 vtable 条目；start/stop 必须实现，其余可选）----
    virtual int  start() = 0;                   // 返回 0 成功
    virtual void stop()  = 0;                   // 停止产出帧（幂等）
    virtual void pause(bool paused);            // 默认空实现 = 不支持暂停
    virtual void seek(int64_t seek_ts_us);      // 默认空实现 = 不支持 seek

    // ---- 信息查询（默认实现 = 不支持）----
    virtual int64_t get_duration();             // 微秒；无意义返回 -1
    virtual void    get_video_size(int *w, int *h);   // 默认回 0

    // ---- 消费端（渲染 tick 调用）----
    // 按系统时钟（纳秒，CLOCK_MONOTONIC）挑"当前该显示的帧"：追赶式跳过并
    // 释放过期帧，缓冲空时重复上一帧。返回 borrow（source 持有，调用者勿
    // release），无帧返回 NULL。out_pts_ns 可为 NULL。
    // 当前假定单消费者（一个 tick）调用。
    CVPixelBufferRef get_frame(int64_t sys_time_ns, int64_t *out_pts_ns);
};

#endif /* WLSource_hpp */
