# MPV 源码阅读 — FFmpeg 流程在 mpv 中的映射

## 对照表：FFmpeg 标准流程 vs mpv 实现

| FFmpeg 标准流程                    | mpv 对应位置                                                              | 说明                               |
| ------------------------------ | --------------------------------------------------------------------- | -------------------------------- |
| 1. `avformat_open_input`       | `demux/demux_lavf.c:1452`                                             | 在 `demux_open_lavf()` 中调用        |
| 2. `avformat_find_stream_info` | `demux/demux_lavf.c:1470`                                             | 紧跟其后                             |
| 3a. `av_find_best_stream`      | **mpv 不使用**                                                           | mpv 自己遍历所有流                      |
| 3b. 配置解码器 + `avcodec_open2`    | `video/decode/vd_lavc.c:866` (视频) / `audio/decode/ad_lavc.c:144` (音频) | 解码器 filter 初始化时调用                |
| 4. `av_read_frame`             | `demux/demux_lavf.c:1581`                                             | 在 `demux_lavf_read_packet()` 中调用 |

---

## 1. 打开输入 — `avformat_open_input`

### 调用链

```
demux_open_url()                          demux/demux.c:3598
  └─ stream_create()                      stream/stream.c:474      ← 打开 I/O 流
  └─ demux_open()                         demux/demux.c:3511       ← 选择 demuxer
       └─ open_given_type()               demux/demux.c:3373       ← 初始化 demuxer
            └─ demuxer->desc->open()      demux/demux.c:3446       ← 多态调用
                 └─ demux_open_lavf()      demux/demux_lavf.c:1310  ← lavf 实现
                      └─ avformat_open_input()   demux_lavf.c:1452
```

### 关键细节

#### 1.1 stream 层 — mpv 自己的 I/O 抽象

mpv 不直接把文件路径给 ffmpeg，而是用自己的 `stream` 层做 I/O：

```c
// stream/stream.c:474
struct stream *stream_create(const char *url, int flags,
                             struct mp_cancel *c, struct mpv_global *global)
```

`stream` 层支持本地文件、网络流、磁盘缓存等，对上层透明。

#### 1.2 AVIOContext 桥接

mpv 通过自定义 `AVIOContext` 把自己的 `stream` 桥接给 ffmpeg：

```c
// demux/demux_lavf.c:1369-1380
void *buffer = av_malloc(lavfdopts->buffersize);
priv->pb = avio_alloc_context(buffer, lavfdopts->buffersize, 0,
                              demuxer, mp_read, NULL, mp_seek);
priv->pb->read_seek = mp_read_seek;
priv->pb->seekable = demuxer->seekable ? AVIO_SEEKABLE_NORMAL : 0;
avfc->pb = priv->pb;
```

- `mp_read()` ([demux_lavf.c:296](demux/demux_lavf.c#L296)) → 调用 `stream_read_partial()`
- `mp_seek()` ([demux_lavf.c:311](demux/demux_lavf.c#L311)) → 调用 `stream_seek()`

这样 ffmpeg 的所有 I/O 都经过 mpv 的 stream 层，mpv 可以在此加缓存、取消控制等。

#### 1.3 avformat_open_input 调用

```c
// demux/demux_lavf.c:1452
if (avformat_open_input(&avfc, priv->filename, priv->avif, &dopts) < 0) {
    MP_ERR(demuxer, "avformat_open_input() failed\n");
    goto fail;
}
```

- `priv->filename`：文件路径或 URL
- `priv->avif`：ffmpeg 的 `AVInputFormat`（可以由用户 `--demuxer=lavf` 强制指定，或由 ffmpeg 自动探测）
- `dopts`：额外选项（如 rtsp_transport、http_persistent 等）

---

## 2. 探测流信息 — `avformat_find_stream_info`

```c
// demux/demux_lavf.c:1470
if (avformat_find_stream_info(avfc, NULL) < 0) {
    MP_ERR(demuxer, "av_find_stream_info() failed\n");
    goto fail;
}
```

此函数会让 ffmpeg 读取一部分数据来确定每个流的编解码参数、时长、帧率等。

之后 mpv 立即调用：

```c
// demux/demux_lavf.c:1487
add_new_streams(demuxer);
```

### 流发现 — `add_new_streams` → `handle_new_stream`

```c
// demux/demux_lavf.c:895
static void add_new_streams(demuxer_t *demuxer) {
    while (priv->num_streams < priv->avfc->nb_streams)
        handle_new_stream(demuxer, priv->num_streams);
}
```

遍历 ffmpeg 发现的所有流，逐一调用 `handle_new_stream()`。

### `handle_new_stream()` — 流类型分发 ([demux_lavf.c:688](demux/demux_lavf.c#L688))

**mpv 不使用 `av_find_best_stream`**。它遍历 ffmpeg 的所有 `AVStream`，根据 `codecpar->codec_type` 做 switch-case 分发：

```c
// demux/demux_lavf.c:697
switch (codec->codec_type) {
case AVMEDIA_TYPE_AUDIO:
    sh = demux_alloc_sh_stream(STREAM_AUDIO);
    // 填充 samplerate、ch_layout、bitrate、replaygain ...
    break;

case AVMEDIA_TYPE_VIDEO:
    sh = demux_alloc_sh_stream(STREAM_VIDEO);
    // 填充 width/height/fps/rotation/Dolby Vision/attached_picture ...
    break;

case AVMEDIA_TYPE_SUBTITLE:
    sh = demux_alloc_sh_stream(STREAM_SUB);
    // 填充 extradata ...
    break;

case AVMEDIA_TYPE_ATTACHMENT:
    demuxer_add_attachment(demuxer, filename, mimetype, ...);
    break;
}
```

然后统一填充通用信息并注册：

```c
// demux/demux_lavf.c:825-869
mp_codec_info_from_avcodecpar(codec, sh->codec);  // 从 AVCodecParameters 复制
sh->codec->codec_tag = codec->codec_tag;
sh->codec->lav_codecpar = avcodec_parameters_alloc();  // 保存原始参数
// ... disposition、metadata、language ...
demux_add_sh_stream(demuxer, sh);  // 注册到 demuxer
```

---

## 3. 打开解码器 — 配置解码器 + `avcodec_open2`

mpv 的解码器不在 demux 层打开，而是在 **播放器层按需创建**。与 ffmpeg 的 `av_find_best_stream` + `avcodec_open2` 不同，mpv 有自己的一套 decoder 框架。

### 调用链

```
reinit_video_chain()                    player/video.c:208
  └─ mp_decoder_wrapper_create()        filters/f_decoder_wrapper.c:1326
       └─ reinit_decoder()              filters/f_decoder_wrapper.c:421
            └─ driver->add_decoders()   枚举所有可用解码器
            └─ mp_select_decoders()     根据 codec 名称和用户配置选择
            └─ driver->init()           调用具体解码器的 init
                 └─ init_avctx()        vd_lavc.c:715 (视频)
                 └─ init()              ad_lavc.c:83   (音频)
```

### 3.1 解码器列表枚举

mpv 不用 `av_find_best_stream`，而是自己枚举所有 ffmpeg decoder：

```c
// common/av_common.c:225
static void add_codecs(struct mp_decoder_list *list, enum AVMediaType type, bool decoders) {
    void *iter = NULL;
    for (;;) {
        const AVCodec *cur = av_codec_iterate(&iter);
        if (!cur) break;
        if (av_codec_is_decoder(cur) == decoders &&
            (type == AVMEDIA_TYPE_UNKNOWN || cur->type == type))
        {
            mp_add_decoder(list, mp_codec_from_av_codec_id(cur->id),
                           cur->name, cur->long_name);
        }
    }
}
```

### 3.2 解码器选择

```c
// filters/f_decoder_wrapper.c:421-471
static bool reinit_decoder(struct priv *p) {
    if (p->codec->type == STREAM_VIDEO) {
        driver = &vd_lavc;
        user_list = p->opts->video_decoders;   // --vd 选项
        fallback = "h264";
    } else if (p->codec->type == STREAM_AUDIO) {
        driver = &ad_lavc;
        user_list = p->opts->audio_decoders;   // --ad 选项
        fallback = "aac";
    }

    // 枚举所有解码器，按用户配置和 codec 名称选择
    driver->add_decoders(full);
    list = mp_select_decoders(p->log, full, codec, user_list);
}
```

### 3.3 视频解码器初始化 — `init_avctx()` ([vd_lavc.c:715](video/decode/vd_lavc.c#L715))

```c
static void init_avctx(struct mp_filter *vd) {
    // 选择 codec
    if (ctx->use_hwdec) {
        lavc_codec = ctx->hwdec.codec;       // 硬解：用 hwdec 选中的 codec
    } else {
        lavc_codec = avcodec_find_decoder_by_name(ctx->decoder);  // 软解
    }

    // 创建 AVCodecContext
    ctx->avctx = avcodec_alloc_context3(lavc_codec);   // L742
    avctx->codec_type = AVMEDIA_TYPE_VIDEO;
    avctx->codec_id = lavc_codec->id;

    // 硬解配置
    if (ctx->use_hwdec) {
        if (ctx->hwdec.use_hw_device)
            avctx->hw_device_ctx = av_buffer_ref(ctx->hwdec_dev);   // L778
        if (ctx->hwdec.use_hw_frames)
            avctx->hw_frames_ctx = ...;                              // L782+
    }

    // 设置 codec headers (extradata 等)
    mp_set_avctx_codec_headers(avctx, c);    // L853

    // 打开解码器
    avcodec_open2(avctx, lavc_codec, NULL);   // L866
}
```

### 3.4 音频解码器初始化 — `init()` ([ad_lavc.c:83](audio/decode/ad_lavc.c#L83))

```c
static bool init(struct mp_filter *da, struct mp_codec_params *codec,
                 const char *decoder) {
    lavc_codec = avcodec_find_decoder_by_name(decoder);    // L97

    ctx->avctx = avcodec_alloc_context3(lavc_codec);       // L103
    ctx->avctx->codec_type = AVMEDIA_TYPE_AUDIO;
    ctx->avctx->codec_id = lavc_codec->id;

    // 设置 downmix、DRC 等选项
    mp_set_avctx_codec_headers(ctx->avctx, codec);         // L136

    avcodec_open2(ctx->avctx, lavc_codec, NULL);            // L144
}
```

### 3.5 硬解码选择 — `select_and_set_hwdec()` ([vd_lavc.c:499](video/decode/vd_lavc.c#L499))

在 `init_avctx` 之前调用，决定是否使用硬解：

```c
static void select_and_set_hwdec(struct mp_filter *vd) {
    add_all_hwdec_methods(&hwdecs, &num_hwdecs);  // 枚举所有 ffmpeg hw decoder

    for (int i = 0; hwdec_api[i]; i++) {
        // 根据 --hwdec 参数值（auto/vaapi/nvdec/...）筛选
        // 检查白名单、已尝试列表、codec 匹配
        // 创建 hwdevice
        ctx->use_hwdec = true;
        ctx->hwdec = *hwdec;
        break;
    }
}
```

硬解方法枚举 ([vd_lavc.c:341](video/decode/vd_lavc.c#L341))：

```c
static void add_all_hwdec_methods(struct hwdec_info **infos, int *num_infos) {
    while (codec = av_codec_iterate(&iter)) {
        for (int n = 0; ; n++) {
            const AVCodecHWConfig *cfg = avcodec_get_hw_config(codec, n);
            // 根据 cfg->methods 生成 direct 和 copy 两种变体
            add_hwdec_item(infos, num_infos, info);
        }
    }
}
```

---

## 4. 读取数据包 — `av_read_frame`

### 调用链

```
demux_thread()                           demux/demux.c:2661    ← 独立线程
  └─ thread_work()                       demux/demux.c:2626
       └─ read_packet()                  demux/demux.c:2262
            └─ demux->desc->read_packet()  demux/demux.c:2368  ← 多态调用
                 └─ demux_lavf_read_packet()  demux/demux_lavf.c:1574
                      └─ av_read_frame()     demux/demux_lavf.c:1581
```

### `demux_lavf_read_packet()` ([demux_lavf.c:1574](demux/demux_lavf.c#L1574))

```c
static bool demux_lavf_read_packet(struct demuxer *demux, struct demux_packet **mp_pkt) {
    AVPacket *pkt = av_packet_alloc();
    int r = av_read_frame(priv->avfc, pkt);          // L1581: 读一个 packet

    if (r < 0) {
        if (r == AVERROR_EOF) return false;           // EOF
        // 错误重试逻辑（最多 10 次）
        return true;
    }

    add_new_streams(demux);    // L1599: 动态添加新发现的流（如 HLS 切换码率）

    // 跳过未选中的流
    if (!demux_stream_is_selected(stream)) {
        av_packet_free(&pkt);
        return true;
    }

    // 转换 AVPacket → demux_packet
    struct demux_packet *dp = new_demux_packet_from_avpacket(demux->packet_pool, pkt);
    dp->pts = mp_pts_from_av(pkt->pts, &st->time_base);
    dp->dts = mp_pts_from_av(pkt->dts, &st->time_base);
    dp->duration = pkt->duration * av_q2d(st->time_base);
    dp->keyframe = pkt->flags & AV_PKT_FLAG_KEY;
    dp->stream = stream->index;

    *mp_pkt = dp;
    return true;
}
```

### `read_packet()` — demux 线程的读取调度 ([demux.c:2262](demux/demux.c#L2262))

这是 demux 线程循环的核心，决定**是否需要读、读多少**：

```c
static bool read_packet(struct demux_internal *in) {
    // 1. 检查各 stream 是否需要更多数据
    for (int n = 0; n < in->num_streams; n++) {
        struct demux_stream *ds = in->streams[n]->ds;
        if (ds->eager) {
            read_more |= !ds->reader_head;          // 队列为空
        } else {
            if (lazy_stream_needs_wait(ds))
                read_more = true;
            else
                mark_stream_eof(ds);                // lazy stream 直接标 EOF
        }
        // 预取：缓冲时间 < min_secs
        prefetch_more |= ds->queue->last_ts - ds->base_ts < in->min_secs;
    }

    // 2. 检查总字节数上限
    if (total_fw_bytes >= in->max_bytes) return false;

    // 3. 实际读取（释放锁，避免阻塞其他线程）
    in->reading = true;
    mp_mutex_unlock(&in->lock);

    bool eof = true;
    if (demux->desc->read_packet && !demux_cancel_test(demux))
        eof = !demux->desc->read_packet(demux, &pkt);    // 调用 demux_lavf_read_packet

    mp_mutex_lock(&in->lock);

    if (pkt)
        add_packet_locked(in->streams[pkt->stream], pkt);  // 加入 packet queue

    if (eof) {
        for (int n = 0; n < in->num_streams; n++)
            mark_stream_eof(in->streams[n]->ds);
    }
}
```

---

## 5. 完整数据流全景图

```
┌─────────────────────────────────────────────────────────────────────┐
│                        播放器层 (player/)                            │
│  reinit_video_chain() / reinit_audio_chain()                       │
│    └─ mp_decoder_wrapper_create()                                   │
│         └─ reinit_decoder() → select decoder                       │
│              └─ vd_lavc.init / ad_lavc.init                        │
│                   └─ select_and_set_hwdec() (视频)                  │
│                   └─ avcodec_open2()                                │
│         └─ demux_read_packet()  ← 消费端                            │
│              └─ dequeue_packet()                                    │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ packet queue (生产者-消费者)
┌──────────────────────────────┴──────────────────────────────────────┐
│                     demux 层 (demux/)                               │
│  demux_thread() (独立线程)                                           │
│    └─ thread_work()                                                 │
│         └─ read_packet()                                            │
│              └─ demux->desc->read_packet()  (多态)                   │
│                   └─ demux_lavf_read_packet()                       │
│                        └─ av_read_frame()    ← FFmpeg 读 packet     │
│                        └─ add_packet_locked()                       │
│                                                                     │
│  demux_open_lavf() (初始化)                                         │
│    └─ avformat_open_input()       ← FFmpeg 打开输入                  │
│    └─ avformat_find_stream_info() ← FFmpeg 探测流信息                │
│    └─ handle_new_stream()         ← 遍历所有流，按类型注册           │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ AVIOContext 桥接
┌──────────────────────────────┴──────────────────────────────────────┐
│                     stream 层 (stream/)                              │
│  stream_create()                                                    │
│    └─ stream_read_partial()  ← mp_read() 回调给 ffmpeg              │
│    └─ stream_seek()          ← mp_seek() 回调给 ffmpeg              │
│    └─ 支持：本地文件、HTTP、缓存、磁盘缓存等                         │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 6. 关键设计差异总结

| 方面        | FFmpeg 标准用法                | mpv 实现                                       |
| --------- | -------------------------- | -------------------------------------------- |
| I/O       | 直接传文件路径                    | 自定义 stream 层 + AVIOContext 桥接                |
| 流选择       | `av_find_best_stream` 只选一条 | 遍历所有流，全部注册，按需 select/deselect                |
| 解码器打开     | demux 阶段打开                 | 播放器层按需创建，独立于 demux                           |
| 硬解码       | 手动配置 hw device/frame       | `select_and_set_hwdec()` 自动枚举 + 白名单          |
| 读循环       | 用户直接调用 `av_read_frame`     | 独立 demux 线程，带缓冲/预取/限流                        |
| 多 demuxer | 通常只用 lavf                  | 支持多种 demuxer（matroska、edl、cue 等），lavf 只是其中之一 |
| Packet 管理 | 用户自己管理                     | 统一 packet queue，支持缓存/回退/录制                   |

---

## 7. 关键文件索引

| 文件                            | 职责                                          |
| ----------------------------- | ------------------------------------------- |
| `demux/demux.c`               | demux 核心：线程、packet queue、seek、缓存管理          |
| `demux/demux_lavf.c`          | ffmpeg demuxer 封装：avformat 调用、流发现、packet 读取 |
| `video/decode/vd_lavc.c`      | 视频解码器：硬解选择、avcodec 初始化、解码                   |
| `audio/decode/ad_lavc.c`      | 音频解码器：avcodec 初始化、解码                        |
| `audio/decode/ad_spdif.c`     | SPDIF passthrough 解码器                       |
| `filters/f_decoder_wrapper.c` | 解码器框架：选择、创建、调度                              |
| `common/av_common.c`          | ffmpeg 公共工具：codec 列表枚举、参数转换                 |
| `stream/stream.c`             | I/O 流抽象层                                    |
| `video/hwdec.c`               | 硬解码设备管理                                     |
| `player/video.c`              | 播放器视频链初始化                                   |
| `player/audio.c`              | 播放器音频链初始化                                   |
