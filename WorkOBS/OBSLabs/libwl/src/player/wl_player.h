#ifndef WL_PLAYER_H
#define WL_PLAYER_H

#include <libavcodec/avcodec.h>

typedef struct wl_player wl_player_t;

// 视频帧回调：调用时 frame 仍有效，用完前须 CFRetain(frame->data[3]) 若要保留 CVPixelBuffer。
// 硬解：frame->data[3] = CVPixelBufferRef；软解：frame->data[0/1/2] = YUV 平面。
typedef void (*wl_player_video_cb)(AVFrame *frame, void *opaque);

// 音频帧回调：frame->data[0] = PCM，frame->format = AVSampleFormat，
// frame->sample_rate / nb_channels / nb_samples 描述格式。
typedef void (*wl_player_audio_cb)(AVFrame *frame, void *opaque);

wl_player_t *wl_player_create(const char *path, const char *hw_type);

void wl_player_set_video_cb(wl_player_t *p, wl_player_video_cb cb, void *opaque);
void wl_player_set_audio_cb(wl_player_t *p, wl_player_audio_cb cb, void *opaque);

// 启动三条线程（decode + video render + audio render）。返回 0 = 成功，-1 = 失败。
int  wl_player_start(wl_player_t *p);

// 停止并阻塞等待所有线程退出。必须在 wl_player_free 之前调用。
void wl_player_stop(wl_player_t *p);

void wl_player_free(wl_player_t *p);

#endif /* WL_PLAYER_H */
