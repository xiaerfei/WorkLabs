#include "wl_node.h"
#include <stdlib.h>
#include <libavcodec/avcodec.h>

wl_node_t *wl_node_create(wl_node_type_t type, void *data, int64_t pts) {
    wl_node_t *node = malloc(sizeof(wl_node_t));
    if (!node) return NULL;
    node->data = data;
    node->type = type;
    node->pts  = pts;
    node->next = NULL;
    return node;
}

void wl_node_free(wl_node_t *node) {
    if (!node) return;
    switch (node->type) {
        case WL_NODE_VIDEO_PACKET:
        case WL_NODE_AUDIO_PACKET: {
            AVPacket *pkt = (AVPacket *)node->data;
            av_packet_free(&pkt);
            break;
        }
        case WL_NODE_VIDEO_FRAME:
        case WL_NODE_AUDIO_FRAME: {
            AVFrame *frame = (AVFrame *)node->data;
            av_frame_free(&frame);
            break;
        }
    }
    free(node);
}
