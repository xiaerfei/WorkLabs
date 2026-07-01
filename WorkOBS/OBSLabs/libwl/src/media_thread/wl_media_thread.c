//
//  wl_media_thread.c
//  OBSLabs
//
//  对标 OBS mp_media_thread（shared/media-playback/media.c:740–830）
//
//  主循环串行执行：
//    1. 控制检查（pause / stop / seek）
//    2. mp_decode_next(video)   ← 尝试从 video codec 收帧
//    3. mp_decode_next(audio)   ← 尝试从 audio codec 收帧
//    4. mp_media_next_packet()  ← 若两个 codec 都没产出，读下一个 pkt
//    5. mp_media_next_video()   ← 有视频帧 → 塞入 async_frames
//    6. mp_media_next_audio()   ← 有音频帧 → 塞入 audio buffer
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
    bool            thread_running; // start 成功后置 true：守卫 free 里的 join

    // 控制标志
    atomic_bool     should_stop;   // 终止信号（跨线程，原子读写）
    bool            paused;        // 暂停状态（ctrl_mutex 保护）
    bool            eof;           // decoder 已读完且 drain 完毕（仅本线程访问）

    // 视频 pacing（pts-based，仿 OBS mp_media_sleep）—— 仅本线程访问，无需加锁
    int64_t         base_wall_ns;  // 墙钟零点：第一帧那刻的 CLOCK_MONOTONIC 读数
    int64_t         first_pts_ns;  // 媒体零点：第一帧 pts；AV_NOPTS_VALUE = 尚未锚定

    // pause 条件变量（替代 OBS 的 semaphore）
    pthread_mutex_t ctrl_mutex;
    pthread_cond_t  ctrl_cond;     // pause→resume 或 stop 时 signal
};

// ---------- output stubs（M3/M4 接入全局缓冲时实现）----------

/**
 * 把视频帧塞入 async_frames 缓冲区。
 *
 * OBS 对标：obs_source_output_video() → cache_video() → da_push_back(async_frames)
 * 当前 stub：直接打印日志，后续接入 wl_source 的 async_frames。
 *
 * @param frame    解码后的 AVFrame（硬解：data[3] = CVPixelBufferRef）
 * @param pts_ns   纳秒时间戳（已从 stream time_base 转换）
 */
static void output_video_frame(AVFrame *frame, int64_t pts_ns) {
    // TODO: 接入 async_frames 缓冲（max=30，满则丢旧帧）
    // TODO: 回调 wl_source 的 video_output 回调
    (void)frame;
    (void)pts_ns;
}

/**
 * 把音频帧塞入 audio buffer。
 *
 * OBS 对标：obs_source_output_audio() → resample → deque_push_back
 * 当前 stub：直接丢弃，后续接入 wl_source 的 audio_input_buf。
 *
 * @param frame    解码后的 AVFrame（data[0] = PCM）
 * @param pts_ns   纳秒时间戳
 */
static void output_audio_frame(AVFrame *frame, int64_t pts_ns) {
    // TODO: 接入 audio buffer（per-channel deque，补静音而非丢帧）
    // TODO: 回调 wl_source 的 audio_output 回调
    (void)frame;
    (void)pts_ns;
}

// ---------- 视频 pacing ----------

/**
 * 单调时钟当前值（纳秒）。
 *
 * 必须用 CLOCK_MONOTONIC：它只增不减、不受系统对时 / NTP 回拨影响，做时间差才安全。
 * 绝不能用 gettimeofday / CLOCK_REALTIME（会被往回拨，offset 可能突然变负甚至倒退）。
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
 *   - 之后每帧："发车墙钟时刻" target = base_wall_ns + (pts_ns - first_pts_ns)，
 *     即墙钟零点往后推"这帧相对片头已流逝的时长"；未到 target 就睡到点。
 *
 * 为什么每帧都从固定的 base_wall_ns 重新推算（而非累加帧间隔）：
 *   绝对基准不累积误差，长片也不会越跑越偏；累加式每帧的舍入误差会滚雪球。
 *
 * 依赖：wl_decoder 保证吐出的 pts_ns 不是 AV_NOPTS_VALUE（NOPTS 已在解码器侧外推兜底），
 *   否则首帧哨兵判断会误判。
 *
 * @param pts_ns  这帧的纳秒时间戳（wl_decoder 已从 stream time_base 换算好）
 */
static void pace_video(wl_media_thread_t *mt, int64_t pts_ns) {
    // 第一帧：同时锚定墙钟侧与媒体侧两个零点，立即放行
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
        //   才响应停止；且异常大的 offset（seek / 时间戳跳变）会傻睡很久。后续改为
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

        // TODO: 检查 seek 标志
        // if (mt->seek_requested) {
        //     wl_decoder_flush(mt->decoder);
        //     // 执行 av_seek_frame ...
        //     mt->seek_requested = false;
        // }

        // ── 2. 尝试收视频帧（非阻塞）──
        //    先收帧再读 pkt，处理 B 帧延迟：
        //    上一轮 send_packet 可能在 codec 内缓存了多帧
        {
            AVFrame *vframe = NULL;
            int64_t  vpts   = 0;
            wl_frame_result_t vr = wl_decoder_receive_video(mt->decoder,
                                                             &vframe, &vpts);
            if (vr == WL_FRAME_OK) {
                pace_video(mt, vpts);            // 按 pts 节流到 ~实时，再放帧
                output_video_frame(vframe, vpts);
                av_frame_free(&vframe);
                // 有帧产出，继续循环（可能还有更多帧在 codec 里）
                continue;
            }
            // WL_FRAME_AGAIN/EOF: codec 暂时/永久没帧了，继续往下尝试音频 / 读包
            // WL_FRAME_ERROR: 忽略，尝试音频
        }

        // ── 3. 尝试收音频帧（非阻塞）──
        {
            AVFrame *aframe = NULL;
            int64_t  apts   = 0;
            wl_frame_result_t ar = wl_decoder_receive_audio(mt->decoder,
                                                             &aframe, &apts);
            if (ar == WL_FRAME_OK) {
                output_audio_frame(aframe, apts);
                av_frame_free(&aframe);
                continue;
            }
        }

        // ── 4. 两个 codec 都没产出 → 读下一个 packet ──
        if (mt->eof) {
            // 文件已读完且 codec 已 drain，主循环结束
            break;
        }

        wl_read_result_t rr = wl_decoder_read(mt->decoder);
        switch (rr) {
            case WL_READ_VIDEO:
            case WL_READ_AUDIO:
            case WL_READ_SKIP:
                // packet 已送入 codec，回到循环顶部尝试收帧
                break;

            case WL_READ_EOF:
                // 文件读完，codec 已被 flush（send NULL）
                // 继续循环：步骤 2/3 会取出 codec 内缓存的剩余帧
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
    mt->first_pts_ns = AV_NOPTS_VALUE;  // pacing 未锚定（calloc 给 0，而 0 是合法 pts，须显式置哨兵）
    pthread_mutex_init(&mt->ctrl_mutex, NULL);
    pthread_cond_init(&mt->ctrl_cond, NULL);

    return mt;
}

int wl_media_thread_start(wl_media_thread_t *mt) {
    if (pthread_create(&mt->thread, NULL, media_thread_func, mt) != 0)
        return -1;
    mt->thread_running = true;   // 守卫：只有 start 成功，free 才会 join
    return 0;
}

void wl_media_thread_free(wl_media_thread_t *mt) {
    if (!mt) return;

    // 通知线程退出并等它真正结束。
    // thread_running 守卫：只有 start 过才 join，避免 join 一个没创建的线程
    // （create 完没 start 就 free）。对已自行退出（EOF/error）的线程再 join 也
    // 安全，会立即返回——双重 join 才是 UB，而这里全程只 join 一次。
    if (mt->thread_running) {
        pthread_mutex_lock(&mt->ctrl_mutex);
        atomic_store(&mt->should_stop, true); // 在锁内设 + signal，防 lost wakeup
        pthread_cond_signal(&mt->ctrl_cond);  // 唤醒可能在 pause 上挂起的线程
        pthread_mutex_unlock(&mt->ctrl_mutex);
        pthread_join(mt->thread, NULL);
        mt->thread_running = false;
    }

    // 线程已停，独占 mt，顺序释放（必须在 join 之后——线程还在用这些资源）
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
