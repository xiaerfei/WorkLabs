# OBS 输出侧：编码 · a/v 复用 · 录制/推流

> **性质**：OBS 源码级深挖调研 · 系列第 ④ 篇（维度：输出侧 编码/复用/录制推流）。
> **调研对象**：obs-studio `32.1.2-94-gf61619ce3`，主文件 `libobs/obs-encoder.c`（2286 行）、`libobs/obs-output.c`（3340 行）、`libobs/media-io/media-remux.c`（266 行），字段见 `obs-internal.h`。行号实读核对。
> **系列总览**：见 [OBS_架构骨架与WorkLabs模块映射](OBS_架构骨架与WorkLabs模块映射.md)（第 ① 篇）。上游（合成帧/混音如何带系统时间戳产出）见 [第 ③ 篇](OBS_合成tick_音频混音_AV同步.md)。
> **对 WorkLabs 的针对性**：WorkLabs `WLRecorder` 目前仅视频，计划加 AAC 音频 + RTMP 推流——本篇的 a/v interleave 对齐是直接模板。

## 主线一图

```
合成帧 / 混音 (系统时钟 ns, frame->timestamp)
        │
        ▼  receive_video / receive_audio        ← obs-encoder.c
   encoder->start_ts = 首帧系统时钟
   enc_frame.pts = encoder->cur_pts (从 0 单调累加)
        │
        ▼  do_encode → info.encode → send_off_encoder_packet
   pkt->dts_usec = start_ts/1000 + dts_usec(pkt) - offset_usec   ← 编码 pts/dts 拉回"系统时钟域(µs)"
        │
        ▼  interleave_packets(packet)            ← obs-output.c（核心）
   ① 首视频非关键帧前：丢弃早到音频
   ② insert_interleaved_packet：按 dts_usec 插入有序缓冲
   ③ a/v 都到齐 → prune_interleaved_packets：找 a/v 共同起点，丢弃对齐前的早包
   ④ initialize_interleaved_packets：记录 video_offsets/audio_offsets，把所有包归零到从 0 开始
   ⑤ send_interleaved：按 dts 顺序逐个吐出
        │
        ▼  info.encoded_packet(packet)
   ffmpeg_muxer (mp4/mkv) ── 录制       │   rtmp_output ── 推流
   （两者共用上面全部 interleave 逻辑，只是 muxer 实现不同）
        │
        ▼ (录制可选) media-remux.c：mkv → mp4 无损 remux
```

一句话：**编码器把"系统时钟域的原始帧"编成包并把包的时间戳拉回系统时钟域（µs）→ 输出层用一个按 dts 排序的 `interleaved_packets` 缓冲把多路 a/v 对齐到共同起点、归零、单调交错 → 交给具体 muxer（mp4/rtmp）。**

---

## 1. 编码器：原始帧（系统时钟）→ 编码 pts

### 1.1 启动：`obs_encoder_start` 把编码器接到 video/audio output

`obs-encoder.c:809` `obs_encoder_start_internal` 把一个 `(new_packet, param)` 回调登记进 `encoder->callbacks`。**只有首个回调注册时**才真正连接原始帧源，并把 `cur_pts` 清零：

```c
// obs-encoder.c:827
if (first) {
    os_atomic_set_bool(&encoder->paused, false);
    pause_reset(&encoder->pause);

    encoder->cur_pts = 0;
    add_connection(encoder);
}
```

`add_connection`（`obs-encoder.c:369`）按编码器类型订阅原始帧：音频走 `audio_output_connect(... receive_audio ...)`，视频走 `start_raw_video(... receive_video ...)`。注意：一个编码器可被多个 output 共享（同一份编码结果同时录制+推流），所以是 callbacks 数组，连接只建一次。

> `param` 就是 output 本身：`hook_data_capture`（`obs-output.c:2488`）里 `obs_encoder_start(output->audio_encoders[i], encoded_callback, output)`，其中 `encoded_callback = (has_video && has_audio) ? interleave_packets : default_encoded_callback`（`obs-output.c:2499`）。**a/v 双流才走 interleave，纯单流走 default 直接吐。**

### 1.2 video：`start_ts` 锚系统时钟，`cur_pts` 自增

```c
// obs-encoder.c:1630  receive_video
if (!encoder->start_ts)
    encoder->start_ts = frame->timestamp;   // 首个视频原始帧的系统时钟(ns) → 锚点

enc_frame.frames = 1;
enc_frame.pts = encoder->cur_pts;           // 喂给编码器的 pts：从 0 起、按帧步长自增

if (do_encode(encoder, &enc_frame, &frame->timestamp))
    encoder->cur_pts += encoder->timebase_num * encoder->frame_rate_divisor;
```

要点：**喂给底层编码器的 `pts` 是一个干净的、从 0 单调自增的序号**（步长 = `timebase_num * divisor`），不直接用系统时钟。系统时钟 `frame->timestamp` 单独存进 `encoder->start_ts` 作为"这条流第 0 帧对应的真实墙钟"，留待回包时把编码 pts 翻译回墙钟域。`frame->timestamp` 还作为 `frame_cts`（composition time）传进 `do_encode` 用于打点统计。

### 1.3 audio：先缓冲到与视频起点对齐，再按固定 framesize 切块

音频编码器有固定帧长（AAC=1024 样本），不能任意切，所以 `receive_audio`（`obs-encoder.c:1837`）先把样本推进环形缓冲，攒够一个 framesize 再 `send_audio_data`：

```c
// obs-encoder.c:1844  首次记录首个音频原始帧的系统时钟
if (!encoder->first_received) {
    encoder->first_raw_ts = audio.timestamp;
    encoder->first_received = true;
    clear_audio(encoder);
}
...
if (!buffer_audio(encoder, &audio))   // 与视频起点对齐 + 入缓冲
    goto end;
while (encoder->audio_input_buffer[0].size >= encoder->framesize_bytes) {
    if (!send_audio_data(encoder)) break;   // 攒够一帧就编一帧
}
```

`buffer_audio`（`obs-encoder.c:1690`）是**编码器层的第一道 a/v 对齐**（针对配对的 video↔audio）：

```c
// obs-encoder.c:1704
if (!encoder->start_ts && paired_encoder) {
    uint64_t v_start_ts = paired_encoder->start_ts;  // 视频锚点
    if (!v_start_ts) { success = false; goto fail; }  // 视频还没来 → 不开始音频

    end_ts += util_mul_div64(data->frames, 1000000000ULL, encoder->samplerate);
    if (end_ts <= v_start_ts) { success = false; goto fail; } // 这批音频整体早于视频起点 → 丢

    if (data->timestamp < v_start_ts)        // 这批音频部分早于视频
        offset_size = calc_offset_size(...); // 算出要从头丢多少字节（按采样率换算）
    if (data->timestamp <= v_start_ts)
        clear_audio(encoder);

    encoder->start_ts = v_start_ts;          // 音频起点强制 = 视频起点
    if (v_start_ts < data->timestamp)        // 视频起点更早 → 用已缓冲的音频补齐
        start_from_buffer(encoder, v_start_ts);
}
```

`send_audio_data`（`obs-encoder.c:1747`）同样用 `cur_pts` 自增，步长是 `framesize`（一帧样本数）：

```c
enc_frame.pts = encoder->cur_pts;
if (!do_encode(encoder, &enc_frame, NULL)) return false;
encoder->cur_pts += encoder->framesize;
```

> 注意音频 `do_encode` 第三参 `frame_cts = NULL`：packet-timing（CTS/FER 那套）目前**只对视频**采集（见 `obs-encoder.c:1490` 的 `if (frame_cts)`）。

### 1.4 回包：编码 pts/dts → 系统时钟域（`start_ts`、`offset_usec`）

底层编码器吐包后走 `send_off_encoder_packet`（`obs-encoder.c:1394`）。这是"编码相对 pts → 系统时钟域绝对 dts"的关键转换：

```c
// obs-encoder.c:1402
if (received) {
    if (!encoder->first_received) {
        encoder->offset_usec = packet_dts_usec(pkt);  // 首包 dts → offset，吸收 B 帧负 dts/编码器起始偏移
        encoder->first_received = true;
    }

    /* we use system time here to ensure sync with other encoders,
     * you do not want to use relative timestamps here */
    pkt->dts_usec = encoder->start_ts / 1000 + packet_dts_usec(pkt) - encoder->offset_usec;
    pkt->sys_dts_usec = pkt->dts_usec;
    ...
    pkt->sys_dts_usec += encoder->pause.ts_offset / 1000;  // 暂停补偿
```

其中 `packet_dts_usec` 把"编码 timebase 下的 dts"换成微秒（`obs-internal.h:55`）：

```c
static inline int64_t packet_dts_usec(struct encoder_packet *packet)
{
    return packet->dts * MICROSECOND_DEN / packet->timebase_den;
}
```

**这一步的含义**：每路编码器算出的 `dts_usec` 公式是 `首原始帧系统时钟(µs) + (本包相对 dts µs - 首包相对 dts µs)`。于是 video 编码器和 audio 编码器的 `dts_usec` 落在**同一个系统时钟坐标系**里——这就是 video/audio 编码器"共享时间基准对齐"的根：它们各自的 `start_ts` 都来自同一个时钟（`os_gettime_ns`），所以 `dts_usec` 直接可比。注意 `pkt->dts`/`pkt->pts`（编码 timebase 的相对值）此刻**仍未归零**，归零留到 output 层做。

随后 `send_packet`（`obs-encoder.c:1360`）把包发给每个登记的 output 回调；视频首包会先 `send_first_video_packet`（`obs-encoder.c:1326`）等到首个关键帧、并把 SEI/headers 塞进去——**保证 muxer 拿到的第一帧视频一定是关键帧**。

---

## 2. 输出层 a/v 复用对齐（最核心）

字段（`obs-internal.h:1211`）：

```c
struct obs_output {
    bool received_video[MAX_OUTPUT_VIDEO_ENCODERS];
    bool received_audio;
    int64_t video_offsets[MAX_OUTPUT_VIDEO_ENCODERS];   // 归零用的偏移
    int64_t audio_offsets[MAX_OUTPUT_AUDIO_ENCODERS];
    int64_t highest_audio_ts;
    int64_t highest_video_ts[MAX_OUTPUT_VIDEO_ENCODERS];
    pthread_mutex_t interleaved_mutex;
    DARRAY(struct encoder_packet) interleaved_packets;  // 按 dts 排序的待送出缓冲
    size_t interleaver_max_batch_size;
};
```

所有逻辑都在 `interleave_packets`（`obs-output.c:2222`）内、`interleaved_mutex` 保护下完成。它经历两个阶段：**未启动（对齐期）**和**已启动（稳态）**。

### 2.0 入口：丢弃首关键帧之前的早到音频

```c
// obs-output.c:2233
packet->track_idx = get_encoder_index(output, packet);
pthread_mutex_lock(&output->interleaved_mutex);

/* if first video frame is not a keyframe, discard until received */
if (packet->type == OBS_ENCODER_VIDEO &&
    !output->received_video[packet->track_idx] && !packet->keyframe) {
    discard_unused_audio_packets(output, packet->dts_usec);  // 丢掉 dts 早于此的音频
    pthread_mutex_unlock(&output->interleaved_mutex);
    ...
    return;
}
```

`discard_unused_audio_packets`（`obs-output.c:2113`）把缓冲里 `dts_usec < 这个 dts` 的早期音频整段丢掉——**避免文件开头出现一段没有画面的音频**。这正对应 WorkLabs `WLRecorder` 里"首关键帧之前的音频丢弃"。

### 2.1 入缓冲：按 dts_usec 有序插入

```c
// obs-output.c:2255
was_started = output->received_audio && received_video;

if (output->active_delay_ns) out = *packet;
else obs_encoder_packet_create_instance(&out, packet);  // 拷一份（带引用计数）
...
if (was_started)
    apply_interleaved_packet_offset(output, &out, output_packet_time); // 稳态：立即归零
else
    check_received(output, packet);  // 对齐期：仅标记"该类型已收到"

insert_interleaved_packet(output, &out);
```

`insert_interleaved_packet`（`obs-output.c:2073`）按 `dts_usec` 升序插入；同 dts 的视频按 track_idx 排，保证多轨稳定：

```c
// obs-output.c:2083
if (out->dts_usec == cur_packet->dts_usec && out->type == OBS_ENCODER_VIDEO &&
    cur_packet->type == OBS_ENCODER_VIDEO && out->track_idx > cur_packet->track_idx)
    continue;
if (out->dts_usec == cur_packet->dts_usec && out->type == OBS_ENCODER_VIDEO) break;
else if (out->dts_usec < cur_packet->dts_usec) break;
```

`check_received`（`obs-output.c:1431`）把对应类型标记为已到。当 **video 和 audio 都至少各到一个**（`received_audio && received_video`）时，进入下面的"对齐 + 首次送出"分支。

### 2.2 确定 a/v 共同起点 & 丢弃对齐前的早包

```c
// obs-output.c:2282
if (output->received_audio && received_video) {
    if (!was_started) {                            // 首次对齐
        if (prune_interleaved_packets(output)) {
            if (initialize_interleaved_packets(output)) {
                resort_interleaved_packets(output);
                apply_ept_offsets(output);
                send_interleaved(output);
            }
        }
    } else {                                        // 稳态
        set_higher_ts(output, &out);
        size_t streamable = count_streamable_frames(output);
        if (streamable) {
            send_interleaved(output);
            if (--streamable > output->interleaver_max_batch_size)
                send_interleaved(output);
        }
    }
}
```

**`prune_interleaved_packets`（`obs-output.c:1902`）**：决定从哪个下标开始保留。

- `prune_premature_packets`（`obs-output.c:1824`）：若首音频与首视频 dts 差 > 一个视频帧时长，说明对齐窗里某一方"过早"，返回要砍掉的下标。
- 否则 `get_interleaved_start_idx`（`obs-output.c:1776`）：**找 a/v 时间戳最接近的那个点**作为共同起点：

```c
// obs-output.c:1776  "gets the point where audio and video are closest together"
struct encoder_packet *first_video = find_first_packet_type(output, OBS_ENCODER_VIDEO, 0);
for (size_t i = 0; i < output->interleaved_packets.num; i++) {
    struct encoder_packet *packet = &output->interleaved_packets.array[i];
    if (packet->type != OBS_ENCODER_AUDIO) { if (packet == first_video) video_idx = i; continue; }
    diff = llabs(packet->dts_usec - first_video->dts_usec);  // 离首视频最近的音频
    if (diff < closest_diff) { closest_diff = diff; idx = i; }
}
idx = video_idx < idx ? video_idx : idx;   // 起点取 两者更靠前 的
```

随后 `discard_to_idx(output, start_idx)`（`obs-output.c:1885`）把起点之前的所有包 `da_erase_range` 删除并释放——**这就是"丢弃对齐前的包，保证 a/v 从同一时刻开始"**。（例外：`get_interleaved_start_idx:1802` 会保留 pts ≤ 0 的 AAC/Opus priming 静音包，不丢。）

### 2.3 归一化到从 0 开始

`initialize_interleaved_packets`（`obs-output.c:1998`）确认对齐后的不变量，再把每路的起始 dts/pts 记成 offset：

```c
// obs-output.c:2040  记录归零偏移
for (size_t i = 0; i < MAX_OUTPUT_VIDEO_ENCODERS; i++)
    if (output->video_encoders[i]) output->video_offsets[i] = video[i]->pts;
for (size_t i = 0; i < MAX_OUTPUT_AUDIO_ENCODERS; i++)
    if (output->audio_encoders[i] && audio[i]->dts > 0) output->audio_offsets[i] = audio[i]->dts;

output->highest_audio_ts -= audio[first_audio_idx]->dts_usec;

// obs-output.c:2064  把所有已缓冲包统一减去 offset
for (size_t i = 0; i < output->interleaved_packets.num; i++)
    apply_interleaved_packet_offset(output, &output->interleaved_packets.array[i], NULL);
```

`apply_interleaved_packet_offset`（`obs-output.c:1442`）就是减偏移、并刷新 `dts_usec`：

```c
// "audio and video need to start at timestamp 0 ..."
offset = (out->type == OBS_ENCODER_VIDEO) ? output->video_offsets[out->track_idx]
                                          : output->audio_offsets[out->track_idx];
out->dts -= offset;
out->pts -= offset;
out->dts_usec = packet_dts_usec(out);  // 用归零后的 dts 重算 µs，供后续排序
```

效果：**muxer 看到的第一个包 pts/dts 从 0（或附近）起步**。注意此处 `pts/dts` 用的是各自编码 timebase 的相对值（视频减 `video_offsets`=首 pts，音频减 `audio_offsets`=首 dts），而 `dts_usec` 是跨流统一的微秒坐标——前者给 muxer，后者给 interleave 排序。`resort_interleaved_packets`（`obs-output.c:2097`）随后用归零后的 `dts_usec` 重排一遍，并刷新 `highest_*_ts`。

### 2.4 按 dts 单调交错送出

`send_interleaved`（`obs-output.c:1681`）每次只吐缓冲头（dts 最小者），保证 muxer 拿到的是**单调递增、a/v 交错**的包：

```c
struct encoder_packet out = output->interleaved_packets.array[0];
da_erase(output->interleaved_packets, 0);
...
output->info.encoded_packet(output->context.data, &out);  // → 具体 muxer
obs_encoder_packet_release(&out);
```

稳态下"何时可以安全吐头"由 `count_streamable_frames`（`obs-output.c:2204`）+ `has_higher_opposing_ts`（`obs-output.c:1468`）判定：**只有当缓冲里存在"另一类型且时间戳更高"的包时**，头包才算可发——否则后续可能来一个更早的对方包，破坏单调性。这保证了交错送出的全局单调。`interleaver_max_batch_size`（`obs-output.c:2731` 附近按各编码器帧长算出）用于在积压时多吐一包追赶，防止缓冲无界增长。

> 小结对齐三件套：**discard（丢早包）→ offset（归零）→ sorted-send（单调交错）**。

---

## 3. 录制 vs 推流：共用 interleave，只换 muxer

`obs_output` 用 flag 抽象，编码型输出统一带 `OBS_OUTPUT_ENCODED`，因此 `hook_data_capture`（`obs-output.c:2488`）对录制和推流走的是**同一条** `interleave_packets` 路径——区别只在每个 output 的 `info.encoded_packet`：

| 输出 | id | flags | encoded_packet | muxer |
|---|---|---|---|---|
| 录制 | `ffmpeg_muxer`（`obs-ffmpeg-mux.c:865`） | `OBS_OUTPUT_AV \| ENCODED \| MULTI_TRACK \| CAN_PAUSE` | `ffmpeg_mux_data`（:872） | FFmpeg muxer（mp4/mkv/…），子进程 ffmpeg-mux |
| 推流 | `rtmp_output`（`rtmp-stream.c:1983`） | `OBS_OUTPUT_AV \| ENCODED \| SERVICE \| MULTI_TRACK_AV`（:1984） | `rtmp_stream_data`（:2001） | librtmp / FLV over RTMP |
| TS 推流 | `ffmpeg_mpegts_muxer`（:893） | `…\| SERVICE`（:894） | `ffmpeg_mux_data` | mpegts |

也就是说：**对齐/归零/交错/单调全部在 `obs-output.c` 通用层完成，到 `encoded_packet` 时包已是"干净、从 0、单调交错"的；录制端只管把它写进容器，推流端只管把它打成 FLV/TS 推走。** 推流多出来的差异是 `OBS_OUTPUT_SERVICE`（需要 `obs_service_initialize` 连服务器，见 `obs_output_start:403`）和断线重连（`reconnect_*` 字段 + `process_delay` 延迟缓冲），但这些都在 interleave 之外，不影响 a/v 对齐本身。

`obs_output_start`（`obs-output.c:396`）→ `obs_output_actual_start`（:359）调 `info.start`；具体输出在其 `start` 里通过 `obs_output_begin_data_capture`（:2758）→ `hook_data_capture` 完成编码器连接与回调挂载。

---

## 4. media-remux.c：录制后的容器转封装

`media-remux.c` 与实时管线无关，是**录制结束后的离线 remux**（最典型：边录边写 `.mkv`（崩溃也不丢帧）→ 停录后无损转 `.mp4`）。它纯做 demux→copy→mux，不重新编码：

```c
// media-remux.c:86   逐流复制编码参数
ret = avcodec_parameters_copy(out_stream->codecpar, in_stream->codecpar);
// media-remux.c:169  时间基转换
pkt->pts = av_rescale_q_rnd(pkt->pts, in_stream->time_base, out_stream->time_base, ...);
pkt->dts = av_rescale_q_rnd(pkt->dts, in_stream->time_base, out_stream->time_base, ...);
// media-remux.c:203  写入
ret = av_interleaved_write_frame(job->ofmt_ctx, &pkt);
```

注意它依赖 `av_interleaved_write_frame`（FFmpeg 内部再做一次 muxer 级交错），且对 HEVC 打 `hvc1` tag、对 5 声道改 4.1（`media-remux.c:95/113`）以提高兼容性。这一层和 WorkLabs 关系不大，知道"OBS 录制实际是 mkv→mp4 两步、用容器转封装而非重编码"即可。

---

## 5. 对 WorkLabs 的启示

WorkLabs `WLRecorder` 现状：单调墙钟 epoch、`_baseUs` = 首关键帧 pts、"首关键帧前音频丢弃保单调"，且目前**仅视频**。计划加 AAC 音频 + RTMP。OBS 这套是直接模板，逐项对照：

1. **时间戳分层，正是 WorkLabs 已经在做的事**。OBS 的"`start_ts` 锚系统时钟 + `cur_pts` 从 0 自增 + 回包时 `start_ts/1000 + dts_usec - offset_usec` 拉回墙钟域"= WorkLabs 的"墙钟 epoch + `_baseUs` 归零"。WorkLabs 加音频时，关键是让**音频编码 pts 和视频用同一个墙钟基准**（OBS 用 `paired_encoder->start_ts` 强制音频起点 = 视频起点，见 `buffer_audio:1728`），否则 a/v 会漂。

2. **把"首关键帧前丢音频"升级成完整的 interleave 对齐**。WorkLabs 现在只做了 OBS 三件套里的第一件（discard 早音频，对应 `discard_unused_audio_packets`）。加音频录制时应补齐另两件：
   - **共同起点对齐**：维护一个按 dts 排序的 a/v 待写缓冲，a/v 都到齐后用"最接近点"（`get_interleaved_start_idx`）确定起点，丢弃之前的包。
   - **归零 + 单调交错送出**：记录 `video_offset`/`audio_offset` 把首包拉到 ~0，然后只在"存在更高时间戳的对方类型包"时才吐缓冲头（`count_streamable_frames` / `has_higher_opposing_ts`），保证写进 muxer 的 dts 全局单调。这比 WorkLabs 现在"每帧实时写"更稳——FFmpeg muxer 对非单调 dts 会直接报错丢帧。

3. **AAC 攒帧逻辑别忘**。AAC 一帧固定 1024 样本，不能任意切。参考 `receive_audio` 的环形缓冲 + `framesize_bytes` 攒够再编（`obs-encoder.c:1856`）。WorkLabs 用的是 `aac_at`（CLAUDE.md 已确认可用），编码前同样要先按 1024 样本对齐缓冲，pts 按 `+= framesize` 自增。

4. **录制和推流共用同一套对齐**。OBS 的强结论：a/v 对齐是输出**通用层**的事，录制（ffmpeg_muxer）和推流（rtmp）只是末端 muxer 不同。WorkLabs 加 RTMP 时，应把"对齐+归零+单调交错"做成一个独立的 interleave 组件，录制 mp4 和 RTMP 推流复用它，末端只换 `av_interleaved_write_frame`（mp4） vs RTMP/FLV 写出。不要在两条路径里各写一份对齐逻辑。

5. **mkv→mp4 remux 是可选的稳健性增强**。若担心录制中途崩溃导致 mp4 moov 写不进（mp4 的 moov 在文件尾），可学 OBS：先录容错性更好的 mkv/fmp4，停录后用 `media-remux` 风格的 demux-copy-mux 转 mp4。WorkLabs 当前 `WLRecorder` 把 `avformat_write_header` 延迟到首包（因 VideoToolbox extradata 滞后），这点和 OBS 思路一致；remux 这步属于锦上添花。
