//
//  WLMediaSource.cpp
//  OBSLabs
//
//  解码主循环 + pacing（对标 OBS mp_media_thread，
//  shared/media-playback/media.c:740–830）。
//
//  主循环串行执行：
//    1. 控制检查（pause / stop / seek）
//    2. ReceiveVideo   ← 尝试从 video codec 收帧
//    3. ReceiveAudio   ← 尝试从 audio codec 收帧
//    4. Read           ← 若两个 codec 都没产出，读下一个 pkt
//    5/6. 有帧 → pace（视频）→ 提取 CVPixelBufferRef → 壳的缓冲
//
//  关键：步骤 2/3 在步骤 4 之前。
//  原因：一个 packet 可能产出多帧（B 帧延迟），codec 内部缓存了
//  未取出的帧。先尝试 receive，没有帧了才读新 packet。
//

#include "WLMediaSource.hpp"
#include "WLSource.hpp"            // 壳（用于 source_->OutputVideo）
#include "WLSourceRegistry.hpp"
#include "WLTime.hpp"            // NowNs / SleepToNs（全库同一把单调钟）
#include <stdio.h>
#include <stdlib.h>              // free
#include <string.h>              // strdup
#include <CoreVideo/CoreVideo.h>

extern "C" {
#include <libavutil/frame.h>     // AVFrame
#include <libavutil/pixfmt.h>    // AV_PIX_FMT_VIDEOTOOLBOX
}

// ═════════════════ 生命周期 ═════════════════

WLMediaSource::WLMediaSource(const char *path, const char *hw_type, WLSource *source) {
    // 壳的反向引用
    source_        = source;

    // 本类成员逐个初始化
    path_          = strdup(path ? path : "");
    decoder_       = new WLDecoder(path_, hw_type);
    if (!decoder_->Valid()) {         // ctor 没有返回值，失败靠 Valid() 暴露
        delete decoder_;
        decoder_ = NULL;              // 本类的 Valid() 就看这里是否为 NULL
    }
    thread_running_ = false;
    atomic_init(&should_stop_, false);
    paused_        = false;
    eof_           = false;
    base_wall_ns_  = 0;
    first_pts_ns_  = AV_NOPTS_VALUE;  // pacing 未锚定（0 是合法 pts，不能当哨兵）
    pthread_mutex_init(&ctrl_mutex_, NULL);
    pthread_cond_init(&ctrl_cond_, NULL);
}

WLMediaSource::~WLMediaSource() {
    Stop();   // 先停线程（幂等）——必须在释放资源前，线程还在用它们

    if (decoder_) delete decoder_;
    free(path_);
    pthread_mutex_destroy(&ctrl_mutex_);
    pthread_cond_destroy(&ctrl_cond_);
}

// ═════════════════ 控制（WLSourceProtocol 实现）═════════════════

int WLMediaSource::Start() {
    if (thread_running_) return 0;   // 防重入
    if (pthread_create(&thread_, NULL, MediaThreadFunc, this) != 0)
        return -1;
    thread_running_ = true;   // 守卫：只有 Start 成功，Stop/dtor 才会 join
    return 0;
}

void WLMediaSource::Stop() {
    // 幂等：未 Start（create 完直接销毁）或已停，都安全返回。
    // 对已自行退出（EOF/error）的线程再 join 也安全，立即返回——双重 join 才是 UB，
    // 而 thread_running_ 守卫保证全程只 join 一次。
    if (!thread_running_) return;

    pthread_mutex_lock(&ctrl_mutex_);
    atomic_store(&should_stop_, true); // 在锁内设 + signal，防 lost wakeup
    pthread_cond_signal(&ctrl_cond_);  // 唤醒可能在 pause 上挂起的线程
    pthread_mutex_unlock(&ctrl_mutex_);

    pthread_join(thread_, NULL);
    thread_running_ = false;
}

void WLMediaSource::Pause(bool paused) {
    pthread_mutex_lock(&ctrl_mutex_);
    paused_ = paused;
    if (!paused) pthread_cond_signal(&ctrl_cond_); // 唤醒主循环
    pthread_mutex_unlock(&ctrl_mutex_);
}

void WLMediaSource::Seek(int64_t seek_ts_us) {
    // TODO: 设置 seek 标志 + seek_ts，由主循环执行 av_seek_frame
    // 当前 stub：直接 flush 解码器（不执行 seek，后续接入）
    (void)seek_ts_us;
    decoder_->Flush();
}

// ═════════════════ 视频 pacing ═════════════════

/**
 * 按视频帧 pts 把主循环节流到接近实时（对标 OBS mp_media_sleep）。
 *
 * 绝对基准法：
 *   - 第一帧：记下墙钟零点 base_wall_ns_ 与媒体零点 first_pts_ns_，立即放行（不等）。
 *   - 之后每帧："发车墙钟时刻" target = base_wall_ns_ + (pts_ns - first_pts_ns_)；
 *     未到 target 就睡到点。绝对基准不累积漂移，卡顿后自动追回。
 *
 * 依赖：WLDecoder 保证吐出的 pts_ns 不是 AV_NOPTS_VALUE（NOPTS 已在解码器侧外推兜底）。
 */
void WLMediaSource::PaceVideo(int64_t pts_ns) {
    if (first_pts_ns_ == AV_NOPTS_VALUE) {
        base_wall_ns_ = WLTime::NowNs();
        first_pts_ns_ = pts_ns;
        return;
    }

    int64_t target = base_wall_ns_ + (pts_ns - first_pts_ns_); // 这帧应放出的墙钟时刻

    // 已到点/落后则立即放行（SleepToNs 对过去的 target 直接返回 false）
    // TODO(后续): sleep 不可被 stop/pause 打断，最坏要等约一帧间隔（~33ms）
    //   才响应停止；且异常大的 target（seek / 时间戳跳变）会傻睡。后续改为
    //   pthread_cond_timedwait 复用 ctrl_cond_（signal 即醒）+ 上限 clamp。
    WLTime::SleepToNs(target);
}

// ═════════════════ 解码主循环 ═════════════════

void *WLMediaSource::MediaThreadFunc(void *arg) {
    ((WLMediaSource *)arg)->ThreadLoop();
    return NULL;
}

void WLMediaSource::ThreadLoop() {
    while (!atomic_load(&should_stop_)) {
        // ── 1. 控制检查 ──

        // pause：在条件变量上挂起，直到 resume 或 stop
        pthread_mutex_lock(&ctrl_mutex_);
        while (paused_ && !atomic_load(&should_stop_)) {
            pthread_cond_wait(&ctrl_cond_, &ctrl_mutex_);
        }
        pthread_mutex_unlock(&ctrl_mutex_);
        if (atomic_load(&should_stop_)) break;

        // TODO: 检查 seek 标志（flush + av_seek_frame）

        // ── 2. 尝试收视频帧（非阻塞）──
        //    先收帧再读 pkt，处理 B 帧延迟：上一轮 send_packet 可能在 codec 内缓存了多帧
        {
            AVFrame *vframe = NULL;
            int64_t  vpts   = 0;
            wl_frame_result_t vr = decoder_->ReceiveVideo(&vframe, &vpts);
            if (vr == WL_FRAME_OK) {
                PaceVideo(vpts);   // 按 pts 节流到 ~实时

                // 硬解帧零拷贝提取 CVPixelBufferRef → 壳的缓冲统一入口
                // 通过反向引用 source_->OutputVideo() 回喂帧
                if (vframe->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                    CVPixelBufferRef pb = (CVPixelBufferRef)vframe->data[3];
                    if (pb) source_->OutputVideo(pb, vpts);
                }
                // 软解（format != VIDEOTOOLBOX）：TODO sws_scale → CVPixelBuffer，M1 暂不支持

                av_frame_free(&vframe);
                continue;   // codec 可能还有帧，继续收
            }
            // AGAIN/EOF: codec 暂/永久没帧了，往下尝试音频 / 读包；ERROR: 忽略
        }

        // ── 3. 尝试收音频帧（非阻塞）──
        {
            AVFrame *aframe = NULL;
            int64_t  apts   = 0;
            wl_frame_result_t ar = decoder_->ReceiveAudio(&aframe, &apts);
            if (ar == WL_FRAME_OK) {
                // 音频未 pace：靠单线程串行"搭便车"被视频 sleep 间接节流。
                // 临时日志（音频通用帧形态待 audio buffer 步定，暂不进缓冲）；
                // 函数内 static = 多实例共用计数，仅验证用，验证完删除。
                static int cnt = 0;
                fprintf(stderr, "[src A] #%-4d pts=%6lldms\n", cnt++, apts / 1000000);
                av_frame_free(&aframe);
                continue;
            }
        }

        // ── 4. 两个 codec 都没产出 → 读下一个 packet ──
        if (eof_) break;   // 文件已读完且 codec 已 drain，主循环结束

        switch (decoder_->Read()) {
            case WL_READ_VIDEO:
            case WL_READ_AUDIO:
            case WL_READ_SKIP:
                break;   // pkt 已送入 codec，回顶部收帧

            case WL_READ_EOF:
                // 文件读完，codec 已被 flush（send NULL）；继续循环 drain 残余帧
                eof_ = true;
                break;

            case WL_READ_ERROR:
                fprintf(stderr, "[WLMediaSource] read error, stopping\n");
                atomic_store(&should_stop_, true);
                break;
        }
    }
}

// ═════════════════ 类型注册（工厂 + 类型声明）═════════════════

// 双参工厂（对齐 OBS create(settings, source)）
static WLSourceProtocol *CreateMediaSource(const char *settings, WLSource *source) {
    if (!settings || !source) return NULL;

    WLMediaSource *ms = new WLMediaSource(settings, "videotoolbox", source);
    if (!ms->Valid()) {        // decoder 打不开（路径/格式错）
        delete ms;
        return NULL;
    }
    return ms;
}

// 类型声明（对齐 OBS ffmpeg_source 的 obs_source_info，obs-ffmpeg-source.c:787：
// 它声明 ASYNC_VIDEO | AUDIO | DO_NOT_DUPLICATE|…，后者是场景复制语义，不搬）。
// output_flags 描述的是这类源的能力，不是当前接线状态：AUDIO 位如实报——
// 音频输出通道 M4 才接，届时消费者按位取用，类型声明不用改。
// （C++20 支持 C99 的 designated initializer，但要求按字段声明顺序写。）
static const wl_source_type_info g_media_source_info = {
    .id           = "media_file",
    .type         = WL_SOURCE_TYPE_INPUT,
    .output_flags = WL_SOURCE_ASYNC_VIDEO | WL_SOURCE_AUDIO,
    .type_name    = "Media File",
    .create       = CreateMediaSource,
};

void WLMediaSource::RegisterType() {
    WLSourceRegistry::RegisterType(&g_media_source_info);
}
