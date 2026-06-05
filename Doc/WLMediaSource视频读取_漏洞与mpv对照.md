# WLMediaSource FFmpeg 视频读取链路 —— 漏洞清单 & mpv 对照阅读

> **审查对象**：`WorkLabs/Source/MediaFile/WLMediaSource.m`（FFmpeg 读取 → 解码 → 转换 → 渲染）
> **对照基准**：mpv `v0.41`（`/Users/tvum4pro/Documents/github/mpv`）
> **用途**：每条漏洞给出 WorkLabs 现状（文件:行号 + 片段）↔ mpv 对应实现（文件:行号 + 片段），便于打开两边源码并排对照。
> **行号**：WorkLabs 为本次逐行核对，准确；mpv 基于 v0.41 实读核对。

---

## 0. 总览索引

| # | 严重度 | 漏洞 | WorkLabs 位置 | mpv 对照 |
|---|---|---|---|---|
| 1 | 🔴 | EOF 不 drain 解码器 → 丢尾帧 + 丢未解码 packet | `WLMediaSource.m:138,153,205,266` | `vd_lavc.c:1211,1254`、`f_decoder_wrapper.c:1446` |
| 2 | 🔴 | `send_packet` 返回 EAGAIN 时丢弃 packet | `WLMediaSource.m:282-290` | `f_decoder_wrapper.c:1442`、`vd_lavc.c:1186` |
| 3 | 🔴 | 解码后 pts 未判 `AV_NOPTS_VALUE` | `WLMediaSource.m:216,243` | `vd_lavc.c:1292`、`av_common.c:169` |
| 4 | 🟠 | packet 队列阻塞式 enQueue → 一路满饿死另一路 | `WLNodeQueue.m:44`、`WLMediaSource.m:135-149` | `demux.c:2262,473,2289` |
| 5 | 🟠 | 硬解未设 `get_format` → 可能静默走软解 | `WLMediaSource.m:649-658` | `vd_lavc.c:787,1013,671,1308` |
| 6 | 🟠 | 无 IO interrupt callback → stop 中断不了阻塞读 | `WLMediaSource.m:137` | `demux_lavf.c:912,1400` |
| 7 | 🟠 | start_time 归一化 + 帧间隔 clamp 缺失 | `WLMediaSource.m:312` | `loadfile.c:961`、`demux.c:2858`、`video.c:383` |
| 8 | 🟡 | 次要：CLOCK_REALTIME / usleep 轮询 / 软解无 pool 等 | 见下 | 见下 |
| — | ✅ | packet 零拷贝引用（已做对，仅供自查） | `WLMediaSource.m:159-171` | `packet.c:109,119` |

---

## 1. 🔴 EOF 不 drain 解码器 —— 丢尾帧 + 丢未解码 packet

### WorkLabs 现状
读到 EOF 直接 `break`、立刻把 decoding 置 NO 并 abort，解码线程随即退出，**既不解完队列里的 packet，也不向解码器发 NULL 进 drain**：

```objc
// WLMediaSource.m:137-157  parseThread
int size = av_read_frame(self.formatContext, packet);
if (size < 0 || packet->size < 0) {
    av_packet_free(&packet);
    break;                          // ← EOF 直接退出
}
...
self.videoDecoding = NO;            // :153  解码线程下一轮即退出
[self.videoPacketQueue abort];      // :155  队列里未解码的 packet 之后被 flush 丢弃
```
```objc
// WLMediaSource.m:205-228  videoDecodeThread —— 只有「真实 packet」会被 send，从不 send NULL
while (self.isVideoDecoding) { ... decodeFrame ... }   // isVideoDecoding=NO 即退出
[self.videoPacketQueue flush];      // :225  丢弃队列残留 packet
```
```objc
// WLMediaSource.m:262-269  decodeFrame —— AVERROR_EOF 只可能在 drain 后出现，但这里永远到不了 drain
ret = avcodec_receive_frame(avctx, frame);
if (ret >= 0) return 0;
if (ret == AVERROR_EOF) { avcodec_flush_buffers(avctx); return AVERROR_EOF; }
```

**后果**：解码器 pipeline 里缓冲的帧（VideoToolbox 硬解 + B 帧时可达十几帧）全丢；若 EOF 时 packet 队列还有积压（最多 15 个视频 packet），也被 flush 丢弃。**视频结尾少一截**，录制时尾巴被截。

### mpv 对照
**送 NULL 进 drain**（`pkt` 为 NULL 时传 NULL 给解码器）：
```c
// video/decode/vd_lavc.c:1211   send_packet
int ret = avcodec_send_packet(avctx, pkt ? ctx->avpkt : NULL);   // pkt==NULL → drain
if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
    return ret;
```
**循环 receive 直到 AVERROR_EOF，且要等内部重排序延迟队列也排空**：
```c
// video/decode/vd_lavc.c:1254   decode_frame
int ret = avcodec_receive_frame(avctx, ctx->pic);
if (ret < 0) {
    if (ret == AVERROR_EOF) {
        if (!ctx->num_delay_queue)
            reset_avctx(vd);          // delay_queue 排空后才真正结束
    } else if (ret == AVERROR(EAGAIN)) {
        // 等调用方再写 packet
    } else { handle_err(vd); }
    return ret;
}
```
驱动层收到上游的 `MP_FRAME_EOF`（pkt=NULL）后才向解码器 drain；`receive` 返回 `AVERROR_EOF` 后向下游写 EOF（`f_decoder_wrapper.c:1446`）。

### 修复方向
EOF 后**不要立刻停**：① 先把 packet 队列里剩余 packet 解完；② 再 `avcodec_send_packet(ctx, NULL)` 进 drain；③ 循环 `avcodec_receive_frame` 直到返回真正的 `AVERROR_EOF`，把缓冲帧全部出帧；④ 最后才置 rendering=NO / abort。

---

## 2. 🔴 `send_packet` 返回 EAGAIN 时丢弃 packet

### WorkLabs 现状
```objc
// WLMediaSource.m:282-290  decodeFrame
ret = avcodec_send_packet(avctx, node.packet);
[node flush];                       // ← 无论 send 结果如何，packet 立即被释放
node = nil;
if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
    return ret;
}
continue;                           // EAGAIN 也只是 continue —— 那个 packet 已经没了
```
**后果**：`send_packet` 返回 `EAGAIN` 的语义是「解码器输入满，本 packet **未被接受**，需先 receive 再重发」。但代码已 `flush` 释放它 → packet 永久丢失 → 特定码流（B 帧多 / 一次 send 出多帧）花屏、解码错位。

### mpv 对照
send 又 EAGAIN 时，把刚读出的 packet **退回输入管脚**，下一轮重发：
```c
// filters/f_decoder_wrapper.c:1442
} else if (ret_recv == AVERROR(EAGAIN)) {
    frame = mp_pin_out_read(f->ppins[0]);     // 取一个 packet
    ...
    int ret_send = send(f, pkt);
    if (ret_send == AVERROR(EAGAIN)) {
        MP_WARN(f, "could not consume packet\n");
        mp_pin_out_unread(f->ppins[0], frame);  // ← 退回 packet，不丢弃
        mp_filter_wakeup(f);
        return;
    }
}
```
另外解码器内部还有 hold 逻辑：尚有待重发队列时拒绝消费新 packet（`vd_lavc.c:1186` `if (ctx->num_requeue_packets && ...) return AVERROR(EAGAIN);`）。

### 修复方向
`send_packet` 返回 `EAGAIN` 时**不要 flush 该 packet**，用你已有的 `requeueFront:` 把它退回队头（或本地暂存），先 `receive` 腾空再重发同一 packet。

---

## 3. 🔴 解码后 pts 未判 `AV_NOPTS_VALUE`

### WorkLabs 现状
```objc
// WLMediaSource.m:216 (video) / 243 (audio)
node.pts = frame->pts * self.videoTimeBase;   // frame->pts 可能是 AV_NOPTS_VALUE(-2^63)
```
**后果**：`frame->pts == AV_NOPTS_VALUE` 时（部分容器/编码很常见），`node.pts ≈ -9.2e18 × timeBase` = 巨大负秒数；渲染节流 `abs_pts = pts*1000 + baseTime`（`:312`）变巨大负值 → `abs_pts + offset < current_time` 恒成立 → 该帧瞬间冲出、时序崩坏。

### mpv 对照
解码后用 `frame->pts`（**注意：mpv 全仓不用 `best_effort_timestamp`** —— 新的 `avcodec_receive_frame` API 已把 best-effort 逻辑算进 `frame->pts`），但**必经 `mp_pts_from_av` 把 `AV_NOPTS_VALUE` 翻译成内部哨兵**：
```c
// video/decode/vd_lavc.c:1292
mpi->pts = mp_pts_from_av(ctx->pic->pts, &ctx->codec_timebase);
mpi->dts = mp_pts_from_av(ctx->pic->pkt_dts, &ctx->codec_timebase);
```
```c
// common/av_common.c:169
double mp_pts_from_av(int64_t av_pts, AVRational *tb) {
    AVRational b = get_def_tb(tb);
    return av_pts == AV_NOPTS_VALUE ? MP_NOPTS_VALUE : av_pts * av_q2d(b);   // ← 关键
}
```

### 修复方向
保留用 `frame->pts`（新 API 已含 best-effort，无需 `best_effort_timestamp`），但**必须先判 `AV_NOPTS_VALUE`**：
```objc
node.pts = (frame->pts == AV_NOPTS_VALUE) ? WL_NOPTS_VALUE : frame->pts * self.videoTimeBase;
```
并定义 `WL_NOPTS_VALUE` 哨兵 + 在渲染节流里对它兜底（缺失则用 dts 或「上一帧 + 1/fps」，见 §7）。详见 `Doc/MPV_时间戳与队列设计调研.md` P0 #1。

---

## 4. 🟠 packet 队列阻塞式 enQueue —— 一路满饿死另一路

### WorkLabs 现状
`parseThread` **单线程**喂 video(size=15)/audio(size=20) 两个队列，而 `enQueue` 满则**阻塞等待**：
```objc
// WLNodeQueue.m:41-57  enQueue —— 满则 pthread_cond_wait 阻塞
while (_nodeSize >= _allSize && !_abortRequest) {
    pthread_cond_wait(&_cond, &_mutex);    // ← 队列满，生产者阻塞
}
```
```objc
// WLMediaSource.m:143-147  parseThread 单线程顺序喂两个队列
if (packet->stream_index == self.videoStreamIndex) {
    [self addPacket:packet type:WLNodeTypeVideo];   // 满则阻塞整个 parseThread
} else if (packet->stream_index == self.audioStreamIndex) {
    [self addPacket:packet type:WLNodeTypeAudio];
}
```
**后果**：视频解码一慢 → video packet 队列(15)满 → parseThread 卡在 enQueue → **不再读取 audio packet → 音频饿死/卡顿**（反之亦然）。本质是「按单队列包数限流 + 阻塞生产者」的设计缺陷。

### mpv 对照
单 demux 线程按「**总字节 + 总时长**」限流、消费者驱动，单条流缓冲多不会阻塞整体：
```c
// demux/demux.c:2289-2297  按时长判断是否继续读（每个 eager 流独立看自己缓冲秒数）
if (ds->eager && !ds->reader_head && !ds->eof) { read_more = true; }
...
if (queue->last_ts != MP_NOPTS_VALUE && ds->base_ts != MP_NOPTS_VALUE &&
    queue->last_ts - ds->base_ts < min_secs)
    prefetch_more = true;
```
```c
// demux/demux.c:473  前向缓冲字节 O(1) 计算（不阻塞、不遍历）
return queue->tail_cum_pos - queue->reader_head->cum_pos;
```
字节硬上限 `demuxer-max-bytes` 默认 150MB（`demux.c:141`），到顶则**停读睡眠**而非阻塞在某条队列。

### 修复方向
packet 入队改非阻塞（你已有 `enQueueNonBlocking:`，满则丢最旧），或按「总缓冲字节/秒数」限流让 demux 主动停读，**不要让单条队列阻塞拉流线程**。详见 `Doc/MPV_时间戳与队列设计调研.md` P1 #8。

---

## 5. 🟠 硬解未设 `get_format` —— 可能静默走软解

### WorkLabs 现状
```objc
// WLMediaSource.m:649-658  setupHardwareDecoder —— 只设了 hw_device_ctx
int err = av_hwdevice_ctx_create(&hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
if (err < 0) return err;
ctx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
av_buffer_unref(&hw_device_ctx);
return 0;                            // ← 没设 ctx->get_format 回调
```
**后果**：FFmpeg 硬解标准流程要靠 `get_format` 回调协商硬件像素格式（返回 `AV_PIX_FMT_VIDEOTOOLBOX`）。不设回调时，硬解可能不生效、**静默回退软解还不自知**（行为依赖 FFmpeg 版本）。

### mpv 对照
**设置 get_format 回调**：
```c
// video/decode/vd_lavc.c:787
if (ctx->hwdec.pix_fmt != AV_PIX_FMT_NONE)
    avctx->get_format = get_format_hwdec;
```
**回调里在候选格式中匹配硬件格式，匹配不到则标记失败**：
```c
// video/decode/vd_lavc.c:1013  get_format_hwdec
for (int i = 0; fmt[i] != AV_PIX_FMT_NONE; i++) {
    if (ctx->hwdec.pix_fmt == fmt[i]) {
        if (init_generic_hwaccel(avctx, fmt[i]) < 0) break;
        select = fmt[i];
        break;
    }
}
if (select == AV_PIX_FMT_NONE)
    ctx->hwdec_failed = true;        // ← 协商失败 → 触发软解回退
```
**失败回退软解，并用保留的 packet 重发**（`vd_lavc.c:1308` 检测 `hwdec_failed` → `force_fallback` `vd_lavc.c:671` → 逐级降到软解 + `requeue_packets`）。

### 修复方向
先核实当前到底走没走硬解（打印 `frame->format` 是否 `AV_PIX_FMT_VIDEOTOOLBOX`）；补 `ctx->get_format` 回调返回 `AV_PIX_FMT_VIDEOTOOLBOX`，并设清晰的软解 fallback 路径。

---

## 6. 🟠 无 IO interrupt callback —— stop 中断不了阻塞读

### WorkLabs 现状
```objc
// WLMediaSource.m:137  parseThread —— av_read_frame 可能长时间阻塞，stop 打断不了
int size = av_read_frame(self.formatContext, packet);
```
`stop`（`:103-109`）只设 `running=NO`；若 `av_read_frame` 阻塞在慢盘/网络流上，无法被打断 → **stop 卡顿**（且 release 依赖线程退出，连带卡住）。

### mpv 对照
给 `AVFormatContext.interrupt_callback` 装回调，取消令牌为真时返回 1，FFmpeg 立刻中止阻塞 IO 返回 `AVERROR_EXIT`：
```c
// demux/demux_lavf.c:912  回调本体
static int interrupt_cb(void *ctx) {
    struct demuxer *demuxer = ctx;
    return mp_cancel_test(demuxer->cancel);   // 已请求取消 → 返回非 0
}
```
```c
// demux/demux_lavf.c:1400  挂到 AVFormatContext
avfc->interrupt_callback = (AVIOInterruptCB){
    .callback = interrupt_cb,
    .opaque = demuxer,
};
```

### 修复方向
给 `formatContext->interrupt_callback` 设 `AVIOInterruptCB`，回调读一个原子标志（`running==NO` 时返回 1）。注意：`avformat_open_input` 也支持中断，可在打开阶段就挂上。

---

## 7. 🟠 start_time 归一化 + 帧间隔 clamp 缺失

### WorkLabs 现状
```objc
// WLMediaSource.m:312  videoRenderThread —— 直接用裸 pts，未减 start_time、未 clamp 异常间隔
Float64 abs_pts = node.pts * 1000 + self.baseTime;
```
**后果**：① 起始 pts 不为 0 的文件（TS 流常见）→ 首帧 `abs_pts` 偏大/偏小 → 瞬冲或久等；② pts 倒退/跳变时按异常值节流 → 卡死或狂刷。

### mpv 对照
**起始时间归一化**（固定偏移 `ts_offset = -start_time`，音视频一致）：
```c
// player/loadfile.c:961
if (filter != STREAM_SUB && opts->rebase_start_time)
    demux_set_ts_offset(demuxer, -demuxer->start_time);
```
```c
// demux/demux.c:2858  每个 packet 出 demuxer 时统一平移（MP_ADD_PTS 对 NOPTS 安全）
pkt->pts = MP_ADD_PTS(pkt->pts, in->ts_offset);
```
**帧间隔 clamp**（倒退/巨跳则间隔归零、立即显示，绝不按异常值 sleep）：
```c
// player/video.c:383-392  handle_new_frame
frame_time = pts - mpctx->video_pts;
double tolerance = ts_resets_possible && !is_sparse ? 5 : 1e4;
if (frame_time <= 0 || frame_time >= tolerance) {
    MP_WARN(mpctx, "Invalid video timestamp ...");
    frame_time = 0;                  // ← 立即显示，不按异常间隔 sleep
}
```

### 修复方向
打开文件记 `start_time = fmt_ctx->start_time/AV_TIME_BASE`，渲染用 `pts - start_time`；节流前算 `frame_time = pts - last_pts`，`<=0` 或 `>=5s` 则按 0 处理。详见 `Doc/MPV_时间戳与队列设计调研.md` P0 #2/#3。

---

## 8. 🟡 次要 / 已知

| 项 | WorkLabs | mpv 对照 / 说明 |
|---|---|---|
| cond 用 `CLOCK_REALTIME` | `WLNodeQueue.m:105` `clock_gettime(CLOCK_REALTIME, ...)` | mpv condvar 用 `CLOCK_MONOTONIC`（`osdep/threads-posix.h:135-154`），系统改时间不乱 |
| 渲染线程 usleep 轮询 | `WLMediaSource.m:308,333,355,378` | mpv `mp_cond_timedwait_until` 绝对超时（`vo.c:720`、`threads-posix.h:201`），稳态零空转（待办② / 时间戳文档 P0 #5）|
| EOF 时 `avcodec_flush_buffers` 语义可去 | `WLMediaSource.m:267` | drain 正确实现后（§1）无需此调用 |
| `av_read_frame` 所有负返回都当结束 | `WLMediaSource.m:138` | 本地文件影响小；网络流应区分 EOF vs 可恢复错误 |
| 软解每帧 `CVPixelBufferCreate` 无 pool | `WLMediaSource.m:422` | 性能项，fallback 路径优先级低；可加 `CVPixelBufferPool` |

---

## ✅ 已做对的（仅供自查）

**packet 零拷贝引用**：`addPacket` 用 `av_packet_alloc` + `av_packet_ref`（引用计数，不 memcpy），与 mpv 同理：
```objc
// WLMediaSource.m:159-171
AVPacket *nodeP = av_packet_alloc();
av_packet_ref(nodeP, packet);        // 零拷贝引用
```
```c
// demux/packet.c:119
r = av_packet_ref(dp->avpacket, avpkt);   // mpv 同样用 av_packet_ref，不 memcpy
```
（`WLNode.flush` `WLNode.m:16-33` 正确 `av_packet_free`，无泄漏。）

---

## 建议落地分组

- **第一组（解码循环重构，最该先做）**：#1 EOF drain + #2 EAGAIN 保留 packet + #3 NOPTS 判断 —— 三者都在 `decodeFrame` / `parseThread` / `videoDecodeThread` 这一块，改在一起最连贯。
- **第二组**：#4 队列饿死（非阻塞/总量限流）+ #5 硬解 get_format + #6 interrupt callback。
- **第三组**：#7 start_time / clamp（与时间戳文档 P0 合并做）+ #8 次要项。

### 关键文件速查
- **WorkLabs**：`Source/MediaFile/WLMediaSource.m`（parseThread / decodeFrame / videoDecodeThread / convertVideoFrame / setupHardwareDecoder）、`Common/WLNodeQueue.m`（enQueue / deQueueWithTimeout）、`Common/WLNode.m`（flush）。
- **mpv**：`video/decode/vd_lavc.c`（send/receive/drain `:1186,1211,1254`、get_format `:787,1013`、fallback `:671,1308`、pts `:1292`）、`filters/f_decoder_wrapper.c`（EAGAIN 退回 `:1442`、EOF 下发 `:1446`）、`common/av_common.c:169`（NOPTS 转换）、`demux/demux_lavf.c`（interrupt `:912,1400`、av_read_frame `:1581`）、`demux/demux.c`（限流 `:2262,473,2289`、ts_offset `:2858`）、`player/video.c:383`（帧间隔 clamp）、`player/loadfile.c:961`（start_time 归一化）、`demux/packet.c:119`（零拷贝）。
