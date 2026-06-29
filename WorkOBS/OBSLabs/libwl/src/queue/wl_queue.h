#ifndef WL_QUEUE_H
#define WL_QUEUE_H

#include <stdbool.h>
#include "wl_node.h"

typedef struct wl_queue wl_queue_t;

// 操作结果：取代裸指针/裸 int 的多义返回值
typedef enum {
    WL_QUEUE_OK = 0,    // 成功（pop 时节点写入 *out）
    WL_QUEUE_EMPTY,     // 队列空（block=false 未取到，或超时）
    WL_QUEUE_ABORTED,   // 已 abort（push 被拒；pop 立即终止，不再吐残留数据）
} wl_queue_status_t;

wl_queue_t       *wl_queue_create(int max_size, const char *name);
void              wl_queue_destroy(wl_queue_t *q);

// 入队：满则阻塞；abort 后返回 WL_QUEUE_ABORTED
wl_queue_status_t wl_queue_push(wl_queue_t *q, wl_node_t *node);

// 出队：block=true 空队列阻塞；block=false 空队列立即返回 WL_QUEUE_EMPTY。
// 取到节点 → WL_QUEUE_OK 且 *out 被写入；其余情况 *out 不变。
wl_queue_status_t wl_queue_pop(wl_queue_t *q, bool block, wl_node_t **out);

// 出队（带超时，毫秒）：超时返回 WL_QUEUE_EMPTY，其余同 wl_queue_pop
wl_queue_status_t wl_queue_pop_timeout(wl_queue_t *q, int timeout_ms, wl_node_t **out);

// 唤醒所有等待者；之后 push 被拒、pop 立即返回 ABORTED（残留节点由 flush/destroy 释放）
void              wl_queue_abort(wl_queue_t *q);

// 清空队列并释放所有节点（调用 wl_node_free）
void              wl_queue_flush(wl_queue_t *q);

int               wl_queue_count(wl_queue_t *q);

#endif // WL_QUEUE_H
