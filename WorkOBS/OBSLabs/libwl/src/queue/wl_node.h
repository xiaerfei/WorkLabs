#ifndef WL_NODE_H
#define WL_NODE_H

#include <stdint.h>

// data 的实际类型，初始化时确定，free 时据此选择正确的释放路径
typedef enum {
    WL_NODE_VIDEO_PACKET = 0,   // data → AVPacket*
    WL_NODE_AUDIO_PACKET,       // data → AVPacket*
    WL_NODE_VIDEO_FRAME,        // data → AVFrame*
    WL_NODE_AUDIO_FRAME,        // data → AVFrame*
} wl_node_type_t;

typedef struct wl_node {
    void            *data;
    wl_node_type_t   type;
    int64_t          pts;       // 纳秒，调用方换算后传入
    struct wl_node  *next;      // 侵入式链表，由 wl_queue 维护
} wl_node_t;

// 创建节点；data 的所有权转移给 node，由 wl_node_free 负责释放
wl_node_t *wl_node_create(wl_node_type_t type, void *data, int64_t pts);

// 释放节点：根据 type 释放 data，再 free node 本身
void wl_node_free(wl_node_t *node);

#endif // WL_NODE_H
