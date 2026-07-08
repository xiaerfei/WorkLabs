//
//  WLMediaSource.cpp
//  OBSLabs
//
//  Created by erfeixia on 08/07/2026.
//

#include "WLMediaSource.hpp"

WLMediaSource::WLMediaSource(const char *path,
                             const char *hw_type) {
    this->path = path;
    this->hw_type = hw_type;
    atomic_init(&should_stop, false);
    
    first_pts_ns = AV_NOPTS_VALUE;  // pacing 未锚定（calloc 给 0，而 0 是合法 pts）
    pthread_mutex_init(&ctrl_mutex, NULL);
    pthread_cond_init(&ctrl_cond, NULL);
}

WLMediaSource::~WLMediaSource() {
    pthread_mutex_destroy(&ctrl_mutex);
    pthread_cond_destroy(&ctrl_cond);
}

int WLMediaSource::start(wl_media_video_cb video_cb,
                         wl_media_audio_cb audio_cb,
                         void *opaque) {
    if (pthread_create(&this->thread,
                       NULL,
                       media_thread_func,
                       this) != 0)
        return -1;
    thread_running = true;   // 守卫：只有 start 成功，stop/free 才会 join
    this->video_cb = video_cb;
    this->audio_cb = audio_cb;
    this->cb_opaque = opaque;
    return 0;
}

int WLMediaSource::stop() {
    // 幂等：未 start（create 完直接 free）或已停，都安全返回。
    // 对已自行退出（EOF/error）的线程再 join 也安全，立即返回——双重 join 才是 UB，
    // 而 thread_running 守卫保证全程只 join 一次。
    if (!thread_running) return 0;

    pthread_mutex_lock(&ctrl_mutex);
    atomic_store(&should_stop, true); // 在锁内设 + signal，防 lost wakeup
    pthread_cond_signal(&ctrl_cond);  // 唤醒可能在 pause 上挂起的线程
    pthread_mutex_unlock(&ctrl_mutex);

    pthread_join(thread, NULL);
    thread_running = false;
    return 0;
}

void* WLMediaSource::media_thread_func(void* arg) {
    WLMediaSource *self = (WLMediaSource *)arg;
    
    return nullptr;
}

void WLMediaSource::pause(bool paused) {
    pthread_mutex_lock(&ctrl_mutex);
    if (!paused) pthread_cond_signal(&ctrl_cond); // 唤醒主循环
    pthread_mutex_unlock(&ctrl_mutex);
    
}

void WLMediaSource::seek(int64_t seek_ts_us) {
    // TODO: 设置 seek 标志 + seek_ts，由主循环执行 av_seek_frame
    // 当前 stub：直接 flush 解码器（不执行 seek，后续接入）
    (void)seek_ts_us;
}
