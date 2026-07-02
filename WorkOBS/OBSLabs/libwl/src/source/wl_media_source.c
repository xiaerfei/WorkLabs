//
//  wl_media_source.c
//  OBSLabs
//
//  "media_file" 源的 vtable 实现。对齐 OBS ffmpeg_source。
//

#include "wl_media_source.h"
#include "wl_source.h"
#include "wl_source_registry.h"
#include "wl_media_thread.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>       // AV_PIX_FMT_VIDEOTOOLBOX
#include <CoreVideo/CoreVideo.h>

typedef struct {
    wl_media_thread_t *thread;   // 解码主循环（拥有）
    wl_source_t       *source;   // 反向引用，output 回调用（不拥有）
    char              *path;     // 文件路径（拥有）
} media_source_data;

// ─── media_thread 输出回调（在解码线程调用）───

// 视频：AVFrame → 提取 CVPixelBufferRef → 交给 source 统一入口
static void media_video_output(AVFrame *frame, int64_t pts_ns, void *opaque) {
    media_source_data *d = opaque;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        CVPixelBufferRef pb = (CVPixelBufferRef)frame->data[3];  // 硬解帧零拷贝
        if (pb) wl_source_output_video(d->source, pb, pts_ns);
    }
    // 软解（format != VIDEOTOOLBOX）：TODO sws_scale → CVPixelBuffer，M1 暂不支持
}

// 音频：临时日志（音频通用帧形态待 audio buffer 步定，暂不接 wl_source）
static void media_audio_output(AVFrame *frame, int64_t pts_ns, void *opaque) {
    (void)opaque; (void)frame;
    static int cnt = 0;
    fprintf(stderr, "[src A] #%-4d pts=%6lldms\n", cnt++, pts_ns / 1000000);
}

// ─── vtable 回调 ───

static void *media_create(const char *settings, wl_source_t *source) {
    if (!settings) return NULL;
    media_source_data *d = calloc(1, sizeof(*d));
    if (!d) return NULL;

    d->source = source;
    d->path   = strdup(settings);
    d->thread = wl_media_thread_create(d->path, "videotoolbox");
    if (!d->thread) {
        free(d->path);
        free(d);
        return NULL;
    }
    wl_media_thread_set_callbacks(d->thread, media_video_output, media_audio_output, d);
    return d;
}

static void media_destroy(void *data) {
    media_source_data *d = data;
    if (!d) return;
    if (d->thread) wl_media_thread_free(d->thread);  // 内部会先 stop+join
    free(d->path);
    free(d);
}

static int media_start(void *data) {
    media_source_data *d = data;
    return wl_media_thread_start(d->thread);
}

static void media_stop(void *data) {
    media_source_data *d = data;
    wl_media_thread_stop(d->thread);   // 幂等；可 stop 后由 destroy 再 free
}

static void media_pause(void *data, bool paused) {
    media_source_data *d = data;
    wl_media_thread_pause(d->thread, paused);
}

static void media_seek(void *data, int64_t seek_ts_us) {
    media_source_data *d = data;
    wl_media_thread_seek(d->thread, seek_ts_us);
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
    .get_duration   = NULL,   // TODO: 从 wl_decoder 取总时长
    .get_video_size = NULL,   // TODO: 从 wl_decoder 取分辨率
};

void wl_media_source_register(void) {
    wl_source_register(&g_media_source_info);
}
