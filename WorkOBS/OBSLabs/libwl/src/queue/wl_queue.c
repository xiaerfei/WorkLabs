#include "wl_queue.h"
#include <stdlib.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>

struct wl_queue {
    wl_node_t      *head;
    wl_node_t      *tail;
    int             count;
    int             max_size;   // 0 = 无限
    pthread_mutex_t mutex;
    pthread_cond_t  cond_not_empty;
    pthread_cond_t  cond_not_full;
    bool            aborted;
    const char     *name;
};

wl_queue_t *wl_queue_create(int max_size, const char *name) {
    wl_queue_t *q = calloc(1, sizeof(wl_queue_t));
    if (!q) return NULL;
    q->max_size = max_size;
    q->name     = name;
    pthread_mutex_init(&q->mutex, NULL);
    pthread_cond_init(&q->cond_not_empty, NULL);
    pthread_cond_init(&q->cond_not_full, NULL);
    return q;
}

void wl_queue_destroy(wl_queue_t *q) {
    if (!q) return;
    wl_queue_flush(q);
    pthread_mutex_destroy(&q->mutex);
    pthread_cond_destroy(&q->cond_not_empty);
    pthread_cond_destroy(&q->cond_not_full);
    free(q);
}

wl_queue_status_t wl_queue_push(wl_queue_t *q, wl_node_t *node) {
    pthread_mutex_lock(&q->mutex);

    while (q->max_size > 0 && q->count >= q->max_size && !q->aborted) {
        pthread_cond_wait(&q->cond_not_full, &q->mutex);
    }

    if (q->aborted) {
        pthread_mutex_unlock(&q->mutex);
        return WL_QUEUE_ABORTED;
    }

    node->next = NULL;
    if (q->tail) {
        q->tail->next = node;
    } else {
        q->head = node;
    }
    q->tail = node;
    q->count++;

    pthread_cond_signal(&q->cond_not_empty);
    pthread_mutex_unlock(&q->mutex);
    return WL_QUEUE_OK;
}

// 队列非空时摘下队头写入 *out，调用方已持锁
static void dequeue_locked(wl_queue_t *q, wl_node_t **out) {
    wl_node_t *node = q->head;
    q->head = node->next;
    if (!q->head) q->tail = NULL;
    node->next = NULL;
    q->count--;
    *out = node;
    pthread_cond_signal(&q->cond_not_full);
}

wl_queue_status_t wl_queue_pop(wl_queue_t *q, bool block, wl_node_t **out) {
    pthread_mutex_lock(&q->mutex);

    if (block) {
        while (q->count == 0 && !q->aborted) {
            pthread_cond_wait(&q->cond_not_empty, &q->mutex);
        }
    }

    // abort 优先于剩余数据：一旦终止立即返回，丢弃队列残留（由 flush/destroy 释放）
    if (q->aborted) {
        pthread_mutex_unlock(&q->mutex);
        return WL_QUEUE_ABORTED;
    }

    if (q->count == 0) {
        pthread_mutex_unlock(&q->mutex);
        return WL_QUEUE_EMPTY;
    }

    dequeue_locked(q, out);
    pthread_mutex_unlock(&q->mutex);
    return WL_QUEUE_OK;
}

wl_queue_status_t wl_queue_pop_timeout(wl_queue_t *q, int timeout_ms, wl_node_t **out) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec  +=  timeout_ms / 1000;
    ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&q->mutex);

    while (q->count == 0 && !q->aborted) {
        if (pthread_cond_timedwait(&q->cond_not_empty, &q->mutex, &ts) == ETIMEDOUT) break;
    }

    // abort 优先于剩余数据：一旦终止立即返回，丢弃队列残留（由 flush/destroy 释放）
    if (q->aborted) {
        pthread_mutex_unlock(&q->mutex);
        return WL_QUEUE_ABORTED;
    }

    if (q->count == 0) {
        pthread_mutex_unlock(&q->mutex);
        return WL_QUEUE_EMPTY;
    }

    dequeue_locked(q, out);
    pthread_mutex_unlock(&q->mutex);
    return WL_QUEUE_OK;
}

void wl_queue_abort(wl_queue_t *q) {
    pthread_mutex_lock(&q->mutex);
    q->aborted = true;
    pthread_cond_broadcast(&q->cond_not_empty);
    pthread_cond_broadcast(&q->cond_not_full);
    pthread_mutex_unlock(&q->mutex);
}

void wl_queue_flush(wl_queue_t *q) {
    pthread_mutex_lock(&q->mutex);
    wl_node_t *node = q->head;
    while (node) {
        wl_node_t *next = node->next;
        wl_node_free(node);
        node = next;
    }
    q->head  = NULL;
    q->tail  = NULL;
    q->count = 0;
    pthread_mutex_unlock(&q->mutex);
}

int wl_queue_count(wl_queue_t *q) {
    pthread_mutex_lock(&q->mutex);
    int count = q->count;
    pthread_mutex_unlock(&q->mutex);
    return count;
}
