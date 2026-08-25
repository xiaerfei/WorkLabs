//
//  WLSource.cpp
//  OBSLabs
//
//  源壳实现。环形缓冲 + 追赶式挑帧逻辑逐行保持不变。
//  析构顺序：第一行 delete backend_（触发虚析构链 join 生产线程），
//  之后才清缓冲（生产者已死，无并发）。
//

#include "WLSource.hpp"
#include "WLSourceProtocol.hpp"
#include <stdio.h>
#include <stdlib.h>

// async_frames 默认容量
#define WL_DEFAULT_ASYNC_CAPACITY 30

// ---- 静态成员 ----

uint32_t WLSource::next_uuid_ = 0;

// ---- 生命周期 ----

WLSource::WLSource(const wl_source_type_info *info) {
    // 实例标识
    info_ = *info;   // 按值拷贝（与注册表解耦）
    // 简单递增（单线程创建场景够用，多线程需加锁）
    uuid_ = next_uuid_++;

    backend_ = NULL;   // 尚未绑定

    // async_frames：按 ASYNC 位条件分配（同步源不背缓冲）
    if (info->output_flags & WL_SOURCE_ASYNC) {
        frames_   = (wl_async_frame *)calloc(WL_DEFAULT_ASYNC_CAPACITY, sizeof(wl_async_frame));
        capacity_ = frames_ ? WL_DEFAULT_ASYNC_CAPACITY : 0;
        if (!frames_) fprintf(stderr, "[source] async_frames alloc failed\n");
    } else {
        frames_   = NULL;
        capacity_ = 0;
    }
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
    // ⚠️ 第一行：delete backend_ 触发虚析构链 → 子类 dtor join 生产线程
    // 之后才清缓冲（生产者已死，无并发）
    delete backend_;

    for (int i = 0; i < count_; i++) {
        int idx = (head_ + i) % capacity_;
        CVPixelBufferRelease(frames_[idx].pixbuf);
    }
    if (cur_frame_) CVPixelBufferRelease(cur_frame_);

    free(frames_);
    pthread_mutex_destroy(&async_mutex_);
}

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

// ---- 控制透传（带 backend NULL 防御）----

int WLSource::Start()    { return backend_ ? backend_->Start()    : -1; }
void WLSource::Stop()    {        if (backend_) backend_->Stop();       }
void WLSource::Pause(bool p)           { if (backend_) backend_->Pause(p);  }
void WLSource::Seek(int64_t ts)        { if (backend_) backend_->Seek(ts);  }
void WLSource::Update(const char *s)   { if (backend_) backend_->Update(s); }

// ---- 信息透传 ----

int64_t WLSource::GetDuration() { return backend_ ? backend_->GetDuration() : -1; }
int     WLSource::GetWidth()    { return backend_ ? backend_->GetWidth()    : 0; }
int     WLSource::GetHeight()   { return backend_ ? backend_->GetHeight()   : 0; }
