//
//  WLMediaSource.hpp
//  OBSLabs
//
//  Created by erfeixia on 08/07/2026.
//

#ifndef WLMediaSource_hpp
#define WLMediaSource_hpp

#include <stdio.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdint.h>            // int64_t（seek 时间戳）
#include <stdlib.h>
#include <time.h>              // nanosleep / struct
extern "C" {
    #include <libavutil/avutil.h> // AV_NOPTS_VALUE（pacing 未锚定哨兵）
    #include <libavutil/frame.h>  // AVFrame（output 回调签名）
}

// output 回调：解码线程解出一帧后调用，把帧交给上层（wl_source）。
// 视频：硬解 frame->data[3] = CVPixelBufferRef；软解 frame->data[0..] = YUV。
// 音频：frame->data[0] = PCM。pts_ns 已换算为纳秒。
typedef void (*wl_media_video_cb)(AVFrame *frame, int64_t pts_ns, void *opaque);
typedef void (*wl_media_audio_cb)(AVFrame *frame, int64_t pts_ns, void *opaque);

class WLMediaSource {
    const char *path;
    const char *hw_type;
    
    pthread_t thread;
    bool thread_running; // start 成功后置 true：守卫 stop/free 里的 join
    
    atomic_bool should_stop;   // 终止信号（跨线程，原子读写）
    bool    paused;        // 暂停状态（ctrl_mutex 保护）
    bool    eof;           // decoder 已读完且 drain 完毕（仅本线程访问）

    // 视频 pacing（pts-based，仿 OBS mp_media_sleep）—— 仅本线程访问，无需加锁
    int64_t base_wall_ns;  // 墙钟零点：第一帧那刻的 CLOCK_MONOTONIC 读数
    int64_t first_pts_ns;  // 媒体零点：第一帧 pts；AV_NOPTS_VALUE = 尚未锚定
    // output 回调（把解码帧交给上层 wl_source）—— 在 start 之前设好，之后只读
    wl_media_video_cb video_cb;
    wl_media_audio_cb audio_cb;
    void *cb_opaque;

    // pause 条件变量（替代 OBS 的 semaphore）
    pthread_mutex_t ctrl_mutex;
    pthread_cond_t  ctrl_cond;     // pause→resume 或 stop 时 signal
    
    static void* media_thread_func(void* arg);
public:
    WLMediaSource(const char *path, const char *hw_type);
    ~WLMediaSource();
    
    int start(wl_media_video_cb video_cb,
              wl_media_audio_cb audio_cb,
              void *opaque);
    int stop();
    
    void pause(bool paused);
    void seek(int64_t seek_ts_us);
};










#endif /* WLMediaSource_hpp */
