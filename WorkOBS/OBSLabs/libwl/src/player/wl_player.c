#include "wl_player.h"
#include "wl_decoder.h"
#include "wl_queue.h"
#include "wl_node.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>

// video_q 满 → decode 阻塞（背压）；audio 一帧通常很小，队列可以深一点
#define VIDEO_QUEUE_MAX  8
#define AUDIO_QUEUE_MAX 32

struct wl_player {
    wl_decoder_t       *decoder;
    wl_queue_t         *video_q;
    wl_queue_t         *audio_q;

    pthread_t           decode_tid;
    pthread_t           video_tid;
    pthread_t           audio_tid;

    atomic_bool         should_stop;

    wl_player_video_cb  video_cb;
    void               *video_opaque;
    wl_player_audio_cb  audio_cb;
    void               *audio_opaque;
};

// ---------- decode thread ----------

static void *decode_thread_func(void *arg) {
    wl_player_t *p = arg;

    while (!atomic_load(&p->should_stop)) {
        wl_decode_result_t r = wl_decoder_next_frames(p->decoder, p->video_q, p->audio_q);
        if (r == WL_DECODE_EOF || r == WL_DECODE_ABORTED) break;
        if (r == WL_DECODE_ERROR) {
            fprintf(stderr, "[wl_player] decode error, stopping\n");
            break;
        }
        // WL_DECODE_OK / WL_DECODE_AGAIN: 继续循环
    }

    // 通知 render 线程不再有数据
    wl_queue_abort(p->video_q);
    wl_queue_abort(p->audio_q);
    return NULL;
}

// ---------- video render thread（Phase 1：直接透传，无 A/V sync）----------

static void *video_render_thread_func(void *arg) {
    wl_player_t *p = arg;

    while (1) {
        wl_node_t *node = NULL;
        if (wl_queue_pop(p->video_q, true, &node) != WL_QUEUE_OK) break;

        if (p->video_cb) p->video_cb((AVFrame *)node->data, p->video_opaque);
        wl_node_free(node);
    }
    return NULL;
}

// ---------- audio render thread（Phase 1：直接透传）----------

static void *audio_render_thread_func(void *arg) {
    wl_player_t *p = arg;

    while (1) {
        wl_node_t *node = NULL;
        if (wl_queue_pop(p->audio_q, true, &node) != WL_QUEUE_OK) break;

        if (p->audio_cb) p->audio_cb((AVFrame *)node->data, p->audio_opaque);
        wl_node_free(node);
    }
    return NULL;
}

// ---------- public API ----------

wl_player_t *wl_player_create(const char *path, const char *hw_type) {
    wl_player_t *p = calloc(1, sizeof(*p));
    if (!p) return NULL;

    p->decoder = wl_decoder_create(path, hw_type);
    if (!p->decoder) goto fail;

    p->video_q = wl_queue_create(VIDEO_QUEUE_MAX, "video_q");
    p->audio_q = wl_queue_create(AUDIO_QUEUE_MAX, "audio_q");
    if (!p->video_q || !p->audio_q) goto fail;

    atomic_init(&p->should_stop, false);
    return p;

fail:
    wl_player_free(p);
    return NULL;
}

void wl_player_set_video_cb(wl_player_t *p, wl_player_video_cb cb, void *opaque) {
    p->video_cb = cb;
    p->video_opaque = opaque;
}

void wl_player_set_audio_cb(wl_player_t *p, wl_player_audio_cb cb, void *opaque) {
    p->audio_cb = cb;
    p->audio_opaque = opaque;
}

int wl_player_start(wl_player_t *p) {
    // render 线程先起，确保队列有消费者后 decode 才开始生产
    if (pthread_create(&p->video_tid, NULL, video_render_thread_func, p) != 0) return -1;
    if (pthread_create(&p->audio_tid, NULL, audio_render_thread_func, p) != 0) return -1;
    if (pthread_create(&p->decode_tid, NULL, decode_thread_func, p) != 0) return -1;
    return 0;
}

void wl_player_stop(wl_player_t *p) {
    // 告诉 decode_thread 退出，同时唤醒可能阻塞在 push/pop 上的线程
    atomic_store(&p->should_stop, true);
    wl_queue_abort(p->video_q);
    wl_queue_abort(p->audio_q);

    // decode_thread 退出时会再次 abort 队列（幂等），render 线程收到 ABORTED 后退出
    pthread_join(p->decode_tid, NULL);
    pthread_join(p->video_tid,  NULL);
    pthread_join(p->audio_tid,  NULL);
}

void wl_player_free(wl_player_t *p) {
    if (!p) return;
    if (p->decoder) wl_decoder_free(p->decoder);
    if (p->video_q) wl_queue_destroy(p->video_q);
    if (p->audio_q) wl_queue_destroy(p->audio_q);
    free(p);
}
