//
//  WLMediaSource.cpp
//  OBSLabs
//
//  上半部：解码主循环 + pacing（原 wl_media_thread.c，对标 OBS mp_media_thread，
//          shared/media-playback/media.c:740–830）。
//  下半部：vtable 桥接（原 wl_media_source.c，对齐 OBS ffmpeg_source）。
//
//  主循环串行执行：
//    1. 控制检查（pause / stop / seek）
//    2. receive_video   ← 尝试从 video codec 收帧
//    3. receive_audio   ← 尝试从 audio codec 收帧
//    4. read            ← 若两个 codec 都没产出，读下一个 pkt
//    5/6. 有帧 → pace（视频）→ 回调交给上层（wl_source）
//
//  关键：步骤 2/3 在步骤 4 之前。
//  原因：一个 packet 可能产出多帧（B 帧延迟），codec 内部缓存了
//  未取出的帧。先尝试 receive，没有帧了才读新 packet。
//

#include "WLMediaSource.hpp"
#include "wl_source.h"           // wl_source_output_video（C 头，自带 __cplusplus 守卫）
#include "wl_source_registry.h"
#include "wl_media_source.h"     // wl_media_source_register 声明（C 入口保持不变）
#include "wl_time.h"             // wl_now_ns / wl_sleep_to_ns（全库同一把单调钟）
#include <stdio.h>
#include <stdlib.h>              // free
#include <string.h>              // strdup
#include <CoreVideo/CoreVideo.h>

extern "C" {
#include <libavutil/pixfmt.h>    // AV_PIX_FMT_VIDEOTOOLBOX
}

// ═════════════════ 生命周期 ═════════════════

WLMediaSource::WLMediaSource(const char *path, const char *hw_type) {
    // new 不像 calloc 会清零：所有成员逐个初始化（pthread_t 除外，见头文件注释）
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
    video_cb       = NULL;
    audio_cb       = NULL;
    cb_opaque      = NULL;
    pthread_mutex_init(&ctrl_mutex, NULL);
    pthread_cond_init(&ctrl_cond, NULL);
}

WLMediaSource::~WLMediaSource() {
    stop();   // 先停线程（幂等）——必须在释放资源前，线程还在用它们

    if (decoder) delete decoder;
    free(path);
    pthread_mutex_destroy(&ctrl_mutex);
    pthread_cond_destroy(&ctrl_cond);
}

// ═════════════════ 控制 ═════════════════

void WLMediaSource::set_callbacks(wl_media_video_cb video_cb,
                                  wl_media_audio_cb audio_cb,
                                  void *opaque) {
    // 约定在 start 之前调用，故无需加锁：主循环启动后这几个字段只读
    this->video_cb  = video_cb;
    this->audio_cb  = audio_cb;
    this->cb_opaque = opaque;
}

int WLMediaSource::start() {
    if (thread_running) return 0;   // 防重入
    if (pthread_create(&thread, NULL, media_thread_func, this) != 0)
        return -1;
    thread_running = true;   // 守卫：只有 start 成功，stop/dtor 才会 join
    return 0;
}

int WLMediaSource::stop() {
    // 幂等：未 start（create 完直接销毁）或已停，都安全返回。
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
 * 依赖：wl_decoder 保证吐出的 pts_ns 不是 AV_NOPTS_VALUE（NOPTS 已在解码器侧外推兜底）。
 */
void WLMediaSource::pace_video(int64_t pts_ns) {
    if (first_pts_ns == AV_NOPTS_VALUE) {
        base_wall_ns = wl_now_ns();
        first_pts_ns = pts_ns;
        return;
    }

    int64_t target = base_wall_ns + (pts_ns - first_pts_ns); // 这帧应放出的墙钟时刻

    // 已到点/落后则立即放行（wl_sleep_to_ns 对过去的 target 直接返回 false）
    // TODO(后续): sleep 不可被 stop/pause 打断，最坏要等约一帧间隔（~33ms）
    //   才响应停止；且异常大的 target（seek / 时间戳跳变）会傻睡。后续改为
    //   pthread_cond_timedwait 复用 ctrl_cond（signal 即醒）+ 上限 clamp。
    wl_sleep_to_ns(target);
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
                pace_video(vpts);                        // 按 pts 节流到 ~实时
                if (video_cb) video_cb(vframe, vpts, cb_opaque);
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
                // 音频未 pace：靠单线程串行"搭便车"被视频 sleep 间接节流
                if (audio_cb) audio_cb(aframe, apts, cb_opaque);
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

// ═════════════════ vtable 桥接（原 wl_media_source.c）═════════════════
//
// C 侧（wl_source / wl_core）只认 wl_source_info_t 里的函数指针；桥接函数
// 每个只做一件事：void* ↔ WLMediaSource* 转型后转发。
// C 版 media_source_data 的 thread/path 字段都已并入本类，桥接层不再需要
// 自己的 struct：vtable 的 data 直接就是 WLMediaSource*，回调的 opaque
// 直接就是 wl_source_t*。

// 视频：AVFrame → 提取 CVPixelBufferRef → 交给 source 统一入口
static void media_video_output(AVFrame *frame, int64_t pts_ns, void *opaque) {
    wl_source_t *source = (wl_source_t *)opaque;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        CVPixelBufferRef pb = (CVPixelBufferRef)frame->data[3];  // 硬解帧零拷贝
        if (pb) wl_source_output_video(source, pb, pts_ns);
    }
    // 软解（format != VIDEOTOOLBOX）：TODO sws_scale → CVPixelBuffer，M1 暂不支持
}

// 音频：临时日志（音频通用帧形态待 audio buffer 步定，暂不接 wl_source）
static void media_audio_output(AVFrame *frame, int64_t pts_ns, void *opaque) {
    (void)opaque; (void)frame;
    static int cnt = 0;
    fprintf(stderr, "[src A] #%-4d pts=%6lldms\n", cnt++, pts_ns / 1000000);
}

static void *media_create(const char *settings, wl_source_t *source) {
    if (!settings) return NULL;

    WLMediaSource *ms = new WLMediaSource(settings, "videotoolbox");
    if (!ms->valid()) {        // decoder 打不开（路径/格式错）
        delete ms;
        return NULL;
    }
    ms->set_callbacks(media_video_output, media_audio_output, source);
    return ms;
}

static void media_destroy(void *data) {
    delete (WLMediaSource *)data;   // dtor 内部先 stop+join
}

static int media_start(void *data) {
    return ((WLMediaSource *)data)->start();
}

static void media_stop(void *data) {
    ((WLMediaSource *)data)->stop();  // 幂等；stop 后由 destroy 收尾
}

static void media_pause(void *data, bool paused) {
    ((WLMediaSource *)data)->pause(paused);
}

static void media_seek(void *data, int64_t seek_ts_us) {
    ((WLMediaSource *)data)->seek(seek_ts_us);
}

// ─── 注册 ───

static const wl_source_info_t g_media_source_info = {
    .id             = "media_file",
    .type_name      = "Media File",
    .create         = media_create,
    .destroy        = media_destroy,
    .start          = media_start,
    .stop           = media_stop,
    .pause          = media_pause,
    .seek           = media_seek,
    // get_duration / get_video_size：TODO，省略的成员聚合初始化补 NULL
};

// wl_core.c（C）在 startup 里调用，必须保持 C 链接名（不被 C++ mangle）
extern "C" void wl_media_source_register(void) {
    wl_source_register(&g_media_source_info);
}
