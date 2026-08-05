//
//  WLSource.cpp
//  OBSLabs
//
//  原 wl_source.c 的类化：环形缓冲 + 追赶式挑帧逻辑逐行保持不变。
//  C 版的 create/destroy/控制透传（vtable NULL 检查）由语言接管：
//  create → 工厂 + 基类 ctor，destroy → 虚析构链，可选回调 → 虚函数默认实现。
//

#include "WLSource.hpp"
#include <stdio.h>
#include <stdlib.h>

// async_frames 默认容量。ctor 时定、运行期固定（要换大小改这里 / 将来给工厂加参数，重启生效）。
#define WL_DEFAULT_ASYNC_CAPACITY 30

// ---- 生命周期 ----

WLSource::WLSource() {
    // new 不像 calloc 会清零：所有成员逐个初始化
    info_.id           = NULL;   // 真值由 WLCore::AddSource 按注册表条目填
    info_.type         = WL_SOURCE_TYPE_INPUT;
    info_.output_flags = 0;
    info_.type_name    = NULL;
    info_.create       = NULL;

    frames_   = (wl_async_frame *)calloc(WL_DEFAULT_ASYNC_CAPACITY, sizeof(wl_async_frame));
    capacity_ = frames_ ? WL_DEFAULT_ASYNC_CAPACITY : 0;   // 0 = 缓冲不可用（output/get 都会短路）
    if (!frames_) fprintf(stderr, "[source] async_frames alloc failed\n");
    head_  = 0;
    count_ = 0;
    pthread_mutex_init(&async_mutex_, NULL);

    consume_anchored_  = false;
    consume_first_pts_ = 0;
    consume_first_sys_ = 0;
    cur_frame_         = NULL;
    cur_frame_pts_     = 0;
}

WLSource::~WLSource() {
    // 执行到这里时子类 dtor 已跑完（C++ 析构顺序：子类先、基类后），
    // 生产线程已被子类停掉 —— 清缓冲无并发。
    for (int i = 0; i < count_; i++) {
        int idx = (head_ + i) % capacity_;
        CVPixelBufferRelease(frames_[idx].pixbuf);
    }
    if (cur_frame_) CVPixelBufferRelease(cur_frame_);

    free(frames_);
    pthread_mutex_destroy(&async_mutex_);
}

// ---- 可选控制 / 查询的默认实现（对应 C 版 vtable 条目可为 NULL）----

void WLSource::Pause(bool paused) { (void)paused; }        // 默认不支持暂停
void WLSource::Seek(int64_t seek_ts_us) { (void)seek_ts_us; } // 默认不支持 seek
void WLSource::Update(const char *settings) { (void)settings; } // 默认不支持运行时改参

int64_t WLSource::GetDuration() { return -1; }
int     WLSource::GetWidth()    { return 0; }   // 异步源尺寸随帧走，不必报
int     WLSource::GetHeight()   { return 0; }

void WLSource::VideoRender() {}   // 异步源不用管；同步源（M3）override

// ---- 生产端 ----

void WLSource::OutputVideo(CVPixelBufferRef pixbuf, int64_t pts_ns) {
    if (!pixbuf || capacity_ == 0) return;

    CVPixelBufferRetain(pixbuf);   // 队列持有一份
    pthread_mutex_lock(&async_mutex_);

    if (count_ == capacity_) {
        // 满 → 丢最旧（非阻塞，绝不停生产者）
        CVPixelBufferRelease(frames_[head_].pixbuf);
        head_ = (head_ + 1) % capacity_;
        count_--;
    }
    int tail = (head_ + count_) % capacity_;
    frames_[tail].pixbuf = pixbuf;
    frames_[tail].pts_ns = pts_ns;
    count_++;

    pthread_mutex_unlock(&async_mutex_);
}

// ---- 消费端 ----

CVPixelBufferRef WLSource::GetFrame(int64_t sys_time_ns, int64_t *out_pts_ns) {
    pthread_mutex_lock(&async_mutex_);

    // 首次锚定（需缓冲里有帧，才能拿最旧帧 pts 当媒体零点）
    if (!consume_anchored_ && count_ > 0) {
        consume_first_pts_ = frames_[head_].pts_ns;
        consume_first_sys_ = sys_time_ns;
        consume_anchored_  = true;
    }

    if (consume_anchored_) {
        // 此刻按墙钟推算，媒体本该播到的位置（与生产端 pace 对偶）
        int64_t target = consume_first_pts_ + (sys_time_ns - consume_first_sys_);

        // 追赶：把 pts <= target 的帧逐个提升为 cur_frame_（跳过的旧帧 release），
        // 停在"pts ≤ target 的最新一帧"。
        while (count_ > 0 && frames_[head_].pts_ns <= target) {
            if (cur_frame_) CVPixelBufferRelease(cur_frame_);
            cur_frame_     = frames_[head_].pixbuf;   // 转移所有权给 cur_frame_
            cur_frame_pts_ = frames_[head_].pts_ns;
            head_ = (head_ + 1) % capacity_;
            count_--;
        }
    }

    // owned：锁内 +1 再递出。所有对 cur_frame_ 的 release 也都在本锁内，
    // 互斥保证"我 +1"与"别人 -1"不可能交错——出锁后这份引用铁定合法。
    CVPixelBufferRef ret = cur_frame_;   // 缓冲空时保持上一帧，不黑屏
    if (ret) CVPixelBufferRetain(ret);
    if (out_pts_ns) *out_pts_ns = cur_frame_pts_;
    pthread_mutex_unlock(&async_mutex_);

    return ret;
}
