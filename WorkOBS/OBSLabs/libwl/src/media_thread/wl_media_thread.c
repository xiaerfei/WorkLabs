//
//  wl_media_thread.c
//  OBSLabs
//
//  对标 OBS mp_media_thread（shared/media-playback/media.c:740–830）
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

#include "wl_media_thread.h"
#include "wl_decoder.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>              // clock_gettime / nanosleep / struct timespec（pacing）
#include <libavutil/avutil.h> // AV_NOPTS_VALUE（pacing 未锚定哨兵）

// ---------- 状态结构体 ----------

struct wl_media_thread {
    wl_decoder_t   *decoder;
    pthread_t       thread;
    bool            thread_running; // start 成功后置 true：守卫 stop/free 里的 join

    // 控制标志
    atomic_bool     should_stop;   // 终止信号（跨线程，原子读写）
    bool            paused;        // 暂停状态（ctrl_mutex 保护）
    bool            eof;           // decoder 已读完且 drain 完毕（仅本线程访问）

    // 视频 pacing（pts-based，仿 OBS mp_media_sleep）—— 仅本线程访问，无需加锁
    int64_t         base_wall_ns;  // 墙钟零点：第一帧那刻的 CLOCK_MONOTONIC 读数
    int64_t         first_pts_ns;  // 媒体零点：第一帧 pts；AV_NOPTS_VALUE = 尚未锚定

    // output 回调（把解码帧交给上层 wl_source）—— 在 start 之前设好，之后只读
    wl_media_video_cb video_cb;
    wl_media_audio_cb audio_cb;
    void             *cb_opaque;

    // pause 条件变量（替代 OBS 的 semaphore）
    pthread_mutex_t ctrl_mutex;
    pthread_cond_t  ctrl_cond;     // pause→resume 或 stop 时 signal
};

// ---------- 视频 pacing ----------

/**
 * 单调时钟当前值（纳秒）。
 *
 * 必须用 CLOCK_MONOTONIC：它只增不减、不受系统对时 / NTP 回拨影响，做时间差才安全。
 * base_wall_ns 也取自同一时钟，两者相减才有意义（同一把"墙钟尺"）。
 */
static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

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
static void pace_video(wl_media_thread_t *mt, int64_t pts_ns) {
    if (mt->first_pts_ns == AV_NOPTS_VALUE) {
        mt->base_wall_ns = now_ns();
        mt->first_pts_ns = pts_ns;
        return;
    }

    int64_t target = mt->base_wall_ns + (pts_ns - mt->first_pts_ns); // 这帧应放出的墙钟时刻
    int64_t offset = target - now_ns();                              // 离发车还差多久

    // offset <= 0：已到点或落后 → 立即放行，不睡
    if (offset > 0) {
        // TODO(第二步): nanosleep 不可被 stop/pause 打断，最坏要等约一帧间隔（~33ms）
        //   才响应停止；且异常大的 offset（seek / 时间戳跳变）会傻睡。后续改为
        //   pthread_cond_timedwait 复用 ctrl_cond（signal 即醒）+ offset 上限 clamp。
        struct timespec req = {
            .tv_sec  = (time_t)(offset / 1000000000LL),
            .tv_nsec = (long)  (offset % 1000000000LL),
        };
        nanosleep(&req, NULL);
    }
}

// ---------- 主循环 ----------

static void *media_thread_func(void *arg) {
    wl_media_thread_t *mt = arg;

    while (!atomic_load(&mt->should_stop)) {
        // ── 1. 控制检查 ──

        // pause：在条件变量上挂起，直到 resume 或 stop
        pthread_mutex_lock(&mt->ctrl_mutex);
        while (mt->paused && !atomic_load(&mt->should_stop)) {
            pthread_cond_wait(&mt->ctrl_cond, &mt->ctrl_mutex);
        }
        pthread_mutex_unlock(&mt->ctrl_mutex);
        if (atomic_load(&mt->should_stop)) break;

        // TODO: 检查 seek 标志（flush + av_seek_frame）

        // ── 2. 尝试收视频帧（非阻塞）──
        //    先收帧再读 pkt，处理 B 帧延迟：上一轮 send_packet 可能在 codec 内缓存了多帧
        {
            AVFrame *vframe = NULL;
            int64_t  vpts   = 0;
            wl_frame_result_t vr = wl_decoder_receive_video(mt->decoder, &vframe, &vpts);
            if (vr == WL_FRAME_OK) {
                pace_video(mt, vpts);                              // 按 pts 节流到 ~实时
                if (mt->video_cb) mt->video_cb(vframe, vpts, mt->cb_opaque);
                av_frame_free(&vframe);
                continue;   // codec 可能还有帧，继续收
            }
            // AGAIN/EOF: codec 暂/永久没帧了，往下尝试音频 / 读包；ERROR: 忽略
        }

        // ── 3. 尝试收音频帧（非阻塞）──
        {
            AVFrame *aframe = NULL;
            int64_t  apts   = 0;
            wl_frame_result_t ar = wl_decoder_receive_audio(mt->decoder, &aframe, &apts);
            if (ar == WL_FRAME_OK) {
                // 音频未 pace：靠单线程串行"搭便车"被视频 sleep 间接节流
                if (mt->audio_cb) mt->audio_cb(aframe, apts, mt->cb_opaque);
                av_frame_free(&aframe);
                continue;
            }
        }

        // ── 4. 两个 codec 都没产出 → 读下一个 packet ──
        if (mt->eof) break;   // 文件已读完且 codec 已 drain，主循环结束

        wl_read_result_t rr = wl_decoder_read(mt->decoder);
        switch (rr) {
            case WL_READ_VIDEO:
            case WL_READ_AUDIO:
            case WL_READ_SKIP:
                break;   // pkt 已送入 codec，回顶部收帧

            case WL_READ_EOF:
                // 文件读完，codec 已被 flush（send NULL）；继续循环 drain 残余帧
                mt->eof = true;
                break;

            case WL_READ_ERROR:
                fprintf(stderr, "[wl_media_thread] read error, stopping\n");
                atomic_store(&mt->should_stop, true);
                break;
        }
    }

    return NULL;
}

// ---------- 公开 API ----------

wl_media_thread_t *wl_media_thread_create(const char *path, const char *hw_type) {
    wl_media_thread_t *mt = calloc(1, sizeof(*mt));
    if (!mt) return NULL;

    mt->decoder = wl_decoder_create(path, hw_type);
    if (!mt->decoder) {
        free(mt);
        return NULL;
    }

    atomic_init(&mt->should_stop, false);
    mt->first_pts_ns = AV_NOPTS_VALUE;  // pacing 未锚定（calloc 给 0，而 0 是合法 pts）
    pthread_mutex_init(&mt->ctrl_mutex, NULL);
    pthread_cond_init(&mt->ctrl_cond, NULL);

    return mt;
}

void wl_media_thread_set_callbacks(wl_media_thread_t *mt,
                                   wl_media_video_cb video_cb,
                                   wl_media_audio_cb audio_cb,
                                   void *opaque) {
    // 约定在 start 之前调用，故无需加锁：主循环启动后这几个字段只读
    mt->video_cb  = video_cb;
    mt->audio_cb  = audio_cb;
    mt->cb_opaque = opaque;
}

int wl_media_thread_start(wl_media_thread_t *mt) {
    if (pthread_create(&mt->thread, NULL, media_thread_func, mt) != 0)
        return -1;
    mt->thread_running = true;   // 守卫：只有 start 成功，stop/free 才会 join
    return 0;
}

void wl_media_thread_stop(wl_media_thread_t *mt) {
    // 幂等：未 start（create 完直接 free）或已停，都安全返回。
    // 对已自行退出（EOF/error）的线程再 join 也安全，立即返回——双重 join 才是 UB，
    // 而 thread_running 守卫保证全程只 join 一次。
    if (!mt || !mt->thread_running) return;

    pthread_mutex_lock(&mt->ctrl_mutex);
    atomic_store(&mt->should_stop, true); // 在锁内设 + signal，防 lost wakeup
    pthread_cond_signal(&mt->ctrl_cond);  // 唤醒可能在 pause 上挂起的线程
    pthread_mutex_unlock(&mt->ctrl_mutex);

    pthread_join(mt->thread, NULL);
    mt->thread_running = false;
}

void wl_media_thread_free(wl_media_thread_t *mt) {
    if (!mt) return;

    wl_media_thread_stop(mt);   // 先停线程（幂等）——必须在释放资源前，线程还在用它们

    if (mt->decoder) wl_decoder_free(mt->decoder);
    pthread_mutex_destroy(&mt->ctrl_mutex);
    pthread_cond_destroy(&mt->ctrl_cond);

    free(mt);
}

void wl_media_thread_pause(wl_media_thread_t *mt, bool pause) {
    pthread_mutex_lock(&mt->ctrl_mutex);
    mt->paused = pause;
    if (!pause) pthread_cond_signal(&mt->ctrl_cond); // 唤醒主循环
    pthread_mutex_unlock(&mt->ctrl_mutex);
}

void wl_media_thread_seek(wl_media_thread_t *mt, int64_t seek_ts_us) {
    // TODO: 设置 seek 标志 + seek_ts，由主循环执行 av_seek_frame
    // 当前 stub：直接 flush 解码器（不执行 seek，后续接入）
    (void)seek_ts_us;
    wl_decoder_flush(mt->decoder);
}
