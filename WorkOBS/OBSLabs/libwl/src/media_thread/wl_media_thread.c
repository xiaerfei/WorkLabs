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
#include <stdio.h>
#include <stdlib.h>

// ---------- 状态结构体 ----------

struct wl_media_thread {
    wl_decoder_t   *decoder;
    pthread_t       thread;

    // 控制标志
    bool            should_stop;   // 终止信号
    bool            paused;        // 暂停状态
    bool            eof;           // decoder 已读完且 drain 完毕

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

// ---------- 主循环 ----------

static void *media_thread_func(void *arg) {
    wl_media_thread_t *mt = arg;

    while (!mt->should_stop) {
        // ── 1. 控制检查 ──

        // pause：在条件变量上挂起，直到 resume 或 stop
        pthread_mutex_lock(&mt->ctrl_mutex);
        while (mt->paused && !mt->should_stop) {
            pthread_cond_wait(&mt->ctrl_cond, &mt->ctrl_mutex);
        }
        pthread_mutex_unlock(&mt->ctrl_mutex);
        if (mt->should_stop) break;

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
                output_video_frame(vframe, vpts);
                av_frame_free(&vframe);
                // 有帧产出，继续循环（可能还有更多帧在 codec 里）
                continue;
            }
            // WL_FRAME_NO_DATA: codec 空了，需要新 packet
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
                mt->should_stop = true;
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

    pthread_mutex_init(&mt->ctrl_mutex, NULL);
    pthread_cond_init(&mt->ctrl_cond, NULL);

    return mt;
}

int wl_media_thread_start(wl_media_thread_t *mt) {
    if (pthread_create(&mt->thread, NULL, media_thread_func, mt) != 0)
        return -1;
    return 0;
}

void wl_media_thread_stop(wl_media_thread_t *mt) {
    if (!mt) return;

    // 设置停止标志并唤醒可能在 pause 上挂起的线程
    pthread_mutex_lock(&mt->ctrl_mutex);
    mt->should_stop = true;
    pthread_cond_signal(&mt->ctrl_cond);
    pthread_mutex_unlock(&mt->ctrl_mutex);

    pthread_join(mt->thread, NULL);
}

void wl_media_thread_free(wl_media_thread_t *mt) {
    if (!mt) return;

    wl_media_thread_stop(mt);

    if (mt->decoder)
        wl_decoder_free(mt->decoder);

    pthread_mutex_destroy(&mt->ctrl_mutex);
    pthread_cond_destroy(&mt->ctrl_cond);

    free(mt);
}

void wl_media_thread_pause(wl_media_thread_t *mt, bool pause) {
    pthread_mutex_lock(&mt->ctrl_mutex);
    mt->paused = pause;
    if (!pause)
        pthread_cond_signal(&mt->ctrl_cond); // 唤醒主循环
    pthread_mutex_unlock(&mt->ctrl_mutex);
}

void wl_media_thread_seek(wl_media_thread_t *mt, int64_t seek_ts_us) {
    // TODO: 设置 seek 标志 + seek_ts，由主循环执行 av_seek_frame
    // 当前 stub：直接 flush 解码器（不执行 seek，后续接入）
    (void)seek_ts_us;
    wl_decoder_flush(mt->decoder);
}
