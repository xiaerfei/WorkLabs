//
//  WLMediaSource.cpp
//  OBSLabs
//
//  解码主循环 + pacing（对标 OBS mp_media_thread，
//  shared/media-playback/media.c:740–830）。
//
//  主循环串行执行：
//    1. 控制检查（pause / stop / seek）
//    2. receive_video   ← 尝试从 video codec 收帧
//    3. receive_audio   ← 尝试从 audio codec 收帧
//    4. read            ← 若两个 codec 都没产出，读下一个 pkt
//    5/6. 有帧 → pace（视频）→ 提取 CVPixelBufferRef → 基类缓冲
//
//  关键：步骤 2/3 在步骤 4 之前。
//  原因：一个 packet 可能产出多帧（B 帧延迟），codec 内部缓存了
//  未取出的帧。先尝试 receive，没有帧了才读新 packet。
//

#include "WLMediaSource.hpp"
#include "WLSourceRegistry.hpp"
#include "WLTime.hpp"            // now_ns / sleep_to_ns（全库同一把单调钟）
#include <stdio.h>
#include <stdlib.h>              // free
#include <string.h>              // strdup
#include <CoreVideo/CoreVideo.h>

extern "C" {
#include <libavutil/frame.h>     // AVFrame
#include <libavutil/pixfmt.h>    // AV_PIX_FMT_VIDEOTOOLBOX
}

// ═════════════════ 生命周期 ═════════════════

WLMediaSource::WLMediaSource(const char *path, const char *hw_type) {
    // 基类 ctor 已跑完（缓冲就绪）；本类成员逐个初始化
    this->path     = strdup(path ? path : "");
    decoder        = new WLDecoder(this->path, hw_type);
    if (!decoder->valid()) {          // ctor 没有返回值，失败靠 valid() 暴露
        delete decoder;
        decoder = NULL;               // 本类的 valid() 就看这里是否为 NULL
    }
    thread_running = false;
    atomic_init(&should_stop, false);
    paused         = false;
    eof            = false;
    base_wall_ns   = 0;
    first_pts_ns   = AV_NOPTS_VALUE;  // pacing 未锚定（0 是合法 pts，不能当哨兵）
    pthread_mutex_init(&ctrl_mutex, NULL);
    pthread_cond_init(&ctrl_cond, NULL);
}

WLMediaSource::~WLMediaSource() {
    stop();   // 先停线程（幂等）——必须在释放资源前，线程还在用它们；
              // 也必须早于基类 dtor 清缓冲（生产者死透，缓冲才无并发）

    if (decoder) delete decoder;
    free(path);
    pthread_mutex_destroy(&ctrl_mutex);
    pthread_cond_destroy(&ctrl_cond);
}

// ═════════════════ 控制（WLSource 虚接口）═════════════════

int WLMediaSource::start() {
    if (thread_running) return 0;   // 防重入
    if (pthread_create(&thread, NULL, media_thread_func, this) != 0)
        return -1;
    thread_running = true;   // 守卫：只有 start 成功，stop/dtor 才会 join
    return 0;
}

void WLMediaSource::stop() {
    // 幂等：未 start（create 完直接销毁）或已停，都安全返回。
    // 对已自行退出（EOF/error）的线程再 join 也安全，立即返回——双重 join 才是 UB，
    // 而 thread_running 守卫保证全程只 join 一次。
    if (!thread_running) return;

    pthread_mutex_lock(&ctrl_mutex);
    atomic_store(&should_stop, true); // 在锁内设 + signal，防 lost wakeup
    pthread_cond_signal(&ctrl_cond);  // 唤醒可能在 pause 上挂起的线程
    pthread_mutex_unlock(&ctrl_mutex);

    pthread_join(thread, NULL);
    thread_running = false;
}

void WLMediaSource::pause(bool paused) {
    pthread_mutex_lock(&ctrl_mutex);
    this->paused = paused;
    if (!paused) pthread_cond_signal(&ctrl_cond); // 唤醒主循环
    pthread_mutex_unlock(&ctrl_mutex);
}

void WLMediaSource::seek(int64_t seek_ts_us) {
    // TODO: 设置 seek 标志 + seek_ts，由主循环执行 av_seek_frame
    // 当前 stub：直接 flush 解码器（不执行 seek，后续接入）
    (void)seek_ts_us;
    decoder->flush();
}

// ═════════════════ 视频 pacing ═════════════════

/**
 * 按视频帧 pts 把主循环节流到接近实时（对标 OBS mp_media_sleep）。
 *
 * 绝对基准法：
 *   - 第一帧：记下墙钟零点 base_wall_ns 与媒体零点 first_pts_ns，立即放行（不等）。
 *   - 之后每帧："发车墙钟时刻" target = base_wall_ns + (pts_ns - first_pts_ns)；
 *     未到 target 就睡到点。绝对基准不累积漂移，卡顿后自动追回。
 *
 * 依赖：WLDecoder 保证吐出的 pts_ns 不是 AV_NOPTS_VALUE（NOPTS 已在解码器侧外推兜底）。
 */
void WLMediaSource::pace_video(int64_t pts_ns) {
    if (first_pts_ns == AV_NOPTS_VALUE) {
        base_wall_ns = WLTime::now_ns();
        first_pts_ns = pts_ns;
        return;
    }

    int64_t target = base_wall_ns + (pts_ns - first_pts_ns); // 这帧应放出的墙钟时刻

    // 已到点/落后则立即放行（sleep_to_ns 对过去的 target 直接返回 false）
    // TODO(后续): sleep 不可被 stop/pause 打断，最坏要等约一帧间隔（~33ms）
    //   才响应停止；且异常大的 target（seek / 时间戳跳变）会傻睡。后续改为
    //   pthread_cond_timedwait 复用 ctrl_cond（signal 即醒）+ 上限 clamp。
    WLTime::sleep_to_ns(target);
}

// ═════════════════ 解码主循环 ═════════════════

void *WLMediaSource::media_thread_func(void *arg) {
    ((WLMediaSource *)arg)->thread_loop();
    return NULL;
}

void WLMediaSource::thread_loop() {
    while (!atomic_load(&should_stop)) {
        // ── 1. 控制检查 ──

        // pause：在条件变量上挂起，直到 resume 或 stop
        pthread_mutex_lock(&ctrl_mutex);
        while (paused && !atomic_load(&should_stop)) {
            pthread_cond_wait(&ctrl_cond, &ctrl_mutex);
        }
        pthread_mutex_unlock(&ctrl_mutex);
        if (atomic_load(&should_stop)) break;

        // TODO: 检查 seek 标志（flush + av_seek_frame）

        // ── 2. 尝试收视频帧（非阻塞）──
        //    先收帧再读 pkt，处理 B 帧延迟：上一轮 send_packet 可能在 codec 内缓存了多帧
        {
            AVFrame *vframe = NULL;
            int64_t  vpts   = 0;
            wl_frame_result_t vr = decoder->receive_video(&vframe, &vpts);
            if (vr == WL_FRAME_OK) {
                pace_video(vpts);   // 按 pts 节流到 ~实时

                // 硬解帧零拷贝提取 CVPixelBufferRef → 基类缓冲统一入口
                //（C 版这里是 output 回调跳到 wl_media_source.c；继承后直接调）
                if (vframe->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                    CVPixelBufferRef pb = (CVPixelBufferRef)vframe->data[3];
                    if (pb) output_video(pb, vpts);
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
            wl_frame_result_t ar = decoder->receive_audio(&aframe, &apts);
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
        if (eof) break;   // 文件已读完且 codec 已 drain，主循环结束

        switch (decoder->read()) {
            case WL_READ_VIDEO:
            case WL_READ_AUDIO:
            case WL_READ_SKIP:
                break;   // pkt 已送入 codec，回顶部收帧

            case WL_READ_EOF:
                // 文件读完，codec 已被 flush（send NULL）；继续循环 drain 残余帧
                eof = true;
                break;

            case WL_READ_ERROR:
                fprintf(stderr, "[WLMediaSource] read error, stopping\n");
                atomic_store(&should_stop, true);
                break;
        }
    }
}

// ═════════════════ 类型注册（原 vtable 桥接区，虚函数化后只剩工厂）═════════════════

static WLSource *create_media_source(const char *settings) {
    if (!settings) return NULL;

    WLMediaSource *ms = new WLMediaSource(settings, "videotoolbox");
    if (!ms->valid()) {        // decoder 打不开（路径/格式错）
        delete ms;
        return NULL;
    }
    return ms;
}

static const wl_source_type_info g_media_source_info = {
    "media_file",          // id
    "Media File",          // type_name
    create_media_source,   // 工厂
};

void WLMediaSource::register_type() {
    WLSourceRegistry::register_type(&g_media_source_info);
}
