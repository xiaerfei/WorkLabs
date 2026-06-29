# wl_media_thread 设计文档

> 创建日期：2026-06-30
> 对标：OBS `mp_media_thread`（`shared/media-playback/media.c:740–830`）
> 状态：M2 骨架完成，output stubs 待 M3/M4 接入

---

## 一、定位与职责

`wl_media_thread` 是 **per-source** 的解码主循环线程。对标 OBS 每个媒体源各一条的 `mp_media_thread`。

**一句话职责**：从文件读 packet → 解码 → 把帧推给下游缓冲区。

```
┌──────────────────────────────────────────────────┐
│              wl_media_thread（per-source）         │
│                                                  │
│  wl_decoder_read()          ← av_read_frame      │
│  wl_decoder_receive_video() ← avcodec_receive    │
│  wl_decoder_receive_audio() ← avcodec_receive    │
│  output_video_frame()       → async_frames       │  ← stub，M3/M4 实现
│  output_audio_frame()       → audio buffer       │  ← stub，M3/M4 实现
└──────────────────────────────────────────────────┘
```

### 为什么是单线程串行？

OBS 的结论（`OBS_媒体源线程模型.md` §一）：

> ① read pkt ② decode video ③ decode audio 完全串行在同一线程，没有单独的 parse/decode 子线程。
> **性能原因**：VideoToolbox 实际硬解是异步的（发包/收包），decode thread 大部分时间在等 GPU，串行不是瓶颈。

对比旧 `WLMediaSource` 的 5 线程模型（parse + 视解 + 音解 + 视渲 + 音渲），`wl_media_thread` 只用 **1 条线程**，减少了线程间同步开销和 A/V 同步复杂度。

---

## 二、整体架构

### 2.1 在系统中的位置

```
                           wl_media_thread (per-source)
                           ┌─────────────────────────────┐
                           │  serial main loop            │
                           │  read pkt → decode → output  │
                           └──────────┬──────────────────┘
                                      │
                     ┌────────────────┼────────────────┐
                     ▼                                 ▼
              async_frames (视频)              audio_input_buf (音频)
              max=30，满丢旧帧                 per-channel deque，补静音
                     │                                 │
                     ▼                                 ▼
            obs_graphics_thread                audio_thread
            (全局，虚拟时钟拉帧)              (全局，混音输出)
```

### 2.2 模块依赖

```
wl_media_thread.c
  ├── wl_decoder.h      ← 细粒度解码 API（read / receive / flush）
  ├── <pthread.h>       ← 线程 + 条件变量
  └── output stubs      ← M3/M4 接入 wl_source 的 async_frames / audio buffer
```

`wl_media_thread` 不拥有解码器的内部状态，只通过 `wl_decoder` 的公开 API 操作。解码器负责 FFmpeg 上下文管理、硬件加速、codec 生命周期。

---

## 三、主循环设计

### 3.1 核心流程（伪代码）

```c
void *media_thread_func(void *arg) {
    wl_media_thread_t *mt = arg;

    while (!mt->should_stop) {

        // ══════════════════════════════════════════
        // 阶段 1：控制检查
        // ══════════════════════════════════════════

        if (mt->paused) {
            cond_wait(mt->ctrl_cond);  // 挂起，等 resume 或 stop
            continue;
        }

        if (mt->seek_requested) {
            wl_decoder_flush(mt->decoder);      // flush codec 缓存
            av_seek_frame(mt->fmt_ctx, ...);     // 跳转到目标位置
            mt->seek_requested = false;
            continue;                            // 回到顶部重新开始
        }

        // ══════════════════════════════════════════
        // 阶段 2：尝试收视频帧（非阻塞）
        // ══════════════════════════════════════════
        // 为什么先 receive 再 read？
        // 一个 packet 送入 codec 后，内部可能缓存了多帧（B 帧延迟）。
        // 先把缓存帧全部取出，直到返回 NO_DATA 才读新 packet。

        vframe = NULL;
        result = wl_decoder_receive_video(mt->decoder, &vframe, &vpts);
        if (result == WL_FRAME_OK) {
            output_video_frame(vframe, vpts);    // → async_frames
            av_frame_free(&vframe);
            continue;  // codec 可能还有帧，继续收
        }
        // NO_DATA → codec 空了，需要新 packet
        // ERROR   → 忽略，尝试音频

        // ══════════════════════════════════════════
        // 阶段 3：尝试收音频帧（非阻塞）
        // ══════════════════════════════════════════

        aframe = NULL;
        result = wl_decoder_receive_audio(mt->decoder, &aframe, &apts);
        if (result == WL_FRAME_OK) {
            output_audio_frame(aframe, apts);    // → audio buffer
            av_frame_free(&aframe);
            continue;
        }

        // ══════════════════════════════════════════
        // 阶段 4：两个 codec 都没产出 → 读新 packet
        // ══════════════════════════════════════════

        if (mt->eof) break;  // 文件已读完 + codec 已 drain → 结束

        switch (wl_decoder_read(mt->decoder)) {
            case WL_READ_VIDEO:   /* pkt 送入 video codec → 回顶部收帧 */ break;
            case WL_READ_AUDIO:   /* pkt 送入 audio codec → 回顶部收帧 */ break;
            case WL_READ_SKIP:    /* 字幕等无关流 → 回顶部继续 */        break;
            case WL_READ_EOF:
                mt->eof = true;
                // 继续循环：阶段 2/3 会取出 codec 内剩余帧
                break;
            case WL_READ_ERROR:
                mt->should_stop = true;
                break;
        }
    }

    return NULL;
}
```

### 3.2 为什么 receive 在 read 之前？

这是 FFmpeg `avcodec_send_packet` / `avcodec_receive_frame` API 的特性决定的：

```
send_packet(pkt_1) → receive_frame() → frame_A  ← B帧，需要参考后面帧
                   → receive_frame() → frame_B  ← 继续取缓存帧
                   → receive_frame() → EAGAIN   ← codec 空了
send_packet(pkt_2) → ...
```

一个 packet 送入 codec 后，可能产出 0~N 帧。如果先 read 再 receive，当 video_q 满时（背压），read 出来的 packet 会覆盖 codec 内部状态，导致帧丢失。

**正确的顺序**：先 drain codec → 确认空了 → 再 read 新 packet。

### 3.3 EOF 处理时序

```
时间线：
  read() → VIDEO pkt
  receive_video() → frame_1
  receive_video() → frame_2（B帧缓存）
  receive_video() → NO_DATA
  receive_audio() → NO_DATA
  read() → AUDIO pkt
  receive_audio() → frame_a
  receive_audio() → NO_DATA
  read() → EOF（自动 flush 两个 codec）
  receive_video() → frame_3（flush 后的残余帧）
  receive_video() → NO_DATA（drained）
  receive_audio() → frame_b（flush 后的残余帧）
  receive_audio() → NO_DATA（drained）
  eof=true + drained → 主循环结束
```

关键：`wl_decoder_read()` 在 EOF 时自动 `send_packet(NULL)` 触发 codec drain，之后的 `receive_*()` 会逐个返回 codec 内缓存的最后几帧，直到 `NO_DATA`（即 `AVERROR_EOF`）。

---

## 四、状态机

### 4.1 线程状态

```
              create
                │
                ▼
            ┌───────┐   start()   ┌────────┐
            │ IDLE  │ ──────────→ │ RUNNING│
            └───────┘             └───┬────┘
                                      │
                          pause(true) │ pause(false)
                          ┌───────────┴──────────┐
                          ▼                      ▼
                    ┌──────────┐            ┌──────────┐
                    │  PAUSED  │ ──────────→│ RUNNING  │
                    └──────────┘  resume    └──────────┘
                                      │
                                  stop/EOF/error
                                      │
                                      ▼
                                ┌──────────┐
                                │ STOPPED  │
                                └──────────┘
```

### 4.2 控制标志

| 标志 | 类型 | 写线程 | 读线程 | 说明 |
|------|------|--------|--------|------|
| `should_stop` | `bool` | 任意（stop API） | media thread | 终止信号 |
| `paused` | `bool` | 任意（pause API） | media thread | 暂停状态 |
| `eof` | `bool` | media thread 自身 | media thread | 文件读完 + codec drain 完毕 |
| `seek_requested` | `bool` | 任意（seek API） | media thread | seek 请求（TODO） |

`should_stop` 和 `paused` 通过 `pthread_mutex` + `pthread_cond` 保护，外部线程调用 `stop()` / `pause()` 时 signal 条件变量唤醒 media thread。

---

## 五、output stubs 设计

### 5.1 视频输出路径

```c
// 当前 stub
static void output_video_frame(AVFrame *frame, int64_t pts_ns) {
    (void)frame;  // 直接丢弃
    (void)pts_ns;
}

// M3/M4 目标实现（参考 OBS obs_source_output_video）
static void output_video_frame(AVFrame *frame, int64_t pts_ns) {
    // 1. 硬解帧：frame->data[3] = CVPixelBufferRef → 直接使用（零拷贝）
    //    软解帧：需要 sws_scale 转换

    // 2. 包装成 obs_source_frame（带 pts、format、尺寸信息）

    // 3. push 到 async_frames[]（加锁）
    //    pthread_mutex_lock(&source->async_mutex);
    //    da_push_back(source->async_frames, &output);
    //    pthread_mutex_unlock(&source->async_mutex);

    // 4. 背压策略：async_frames.size >= MAX_ASYNC_FRAMES(30) → 丢弃最旧帧
    //    视频可以丢帧重用旧帧，人眼不敏感
}
```

### 5.2 音频输出路径

```c
// 当前 stub
static void output_audio_frame(AVFrame *frame, int64_t pts_ns) {
    (void)frame;  // 直接丢弃
    (void)pts_ns;
}

// M3/M4 目标实现（参考 OBS obs_source_output_audio）
static void output_audio_frame(AVFrame *frame, int64_t pts_ns) {
    // 1. swr_convert 重采样到统一格式（44100Hz / stereo / float32）

    // 2. 按 channel 拆分，push 到 audio_input_buf[ch]（per-channel deque）

    // 3. 背压策略：deque 满 → 补静音（gap fill），不丢帧
    //    音频必须连续，跳 sample 会有爆音
}
```

### 5.3 视频 vs 音频的背压策略对比

| 维度 | 视频 | 音频 |
|------|------|------|
| 缓冲区 | `async_frames[]`（帧指针数组） | `audio_input_buf[ch]`（PCM deque） |
| 满时策略 | **丢旧帧**，重用上一帧 `cur_async_frame` | **补静音**（gap fill） |
| 消费方式 | 按时间戳挑最近帧，可跳帧可重复帧 | 顺序读 N 个 sample，不跳不选 |
| 为什么不同 | 视频丢帧人眼不敏感 | 音频跳 sample 会有爆音 |

---

## 六、与 OBS mp_media_thread 的映射

| OBS 函数 | wl_media_thread 对应 | 说明 |
|----------|---------------------|------|
| `mp_media_next_packet()` | `wl_decoder_read()` | 读一个 pkt，送入对应 codec |
| `mp_decode_next(video)` | `wl_decoder_receive_video()` | 从 video codec 收一帧 |
| `mp_decode_next(audio)` | `wl_decoder_receive_audio()` | 从 audio codec 收一帧 |
| `mp_media_next_video()` → `v_cb()` | `output_video_frame()` | 推到 async_frames |
| `mp_media_next_audio()` → `a_cb()` | `output_audio_frame()` | 推到 audio buffer |
| `semaphore wait`（paused） | `pthread_cond_wait` | pause 时挂起主循环 |
| `check flags`（seek/reset） | `seek_requested` 标志检查 | seek 时 flush + seek |

主循环结构与 OBS `media.c:740–830` **一一对应**。

---

## 七、线程安全

### 7.1 调用方 → media thread

| API | 线程安全机制 | 说明 |
|-----|-------------|------|
| `wl_media_thread_stop()` | `mutex` + `cond_signal` + `pthread_join` | 设置 should_stop，唤醒 pause 等待，join 等线程退出 |
| `wl_media_thread_pause()` | `mutex` + `cond_signal` | 设置 paused 标志，resume 时唤醒 |
| `wl_media_thread_seek()` | TODO：需要 mutex 保护 seek 标志 | 当前 stub 只 flush codec |

### 7.2 media thread → wl_decoder

`wl_decoder` 内部的 `AVCodecContext` / `AVFormatContext` 只被 media thread 一条线程访问，无需额外加锁。

**唯一例外**：`wl_decoder_flush()` 可能被 seek API 从外部线程调用。OBS 的做法是设置 seek 标志，由 media thread 自己执行 flush + seek，避免竞态。当前实现是直接调用 flush（TODO：改为标志位模式）。

### 7.3 media thread → output stubs

output stubs 最终会 push 到共享缓冲区（`async_frames` / `audio_input_buf`），这些缓冲区被全局 render 线程消费。OBS 用 `pthread_mutex` 保护 `async_frames`，用 `deque` 的内部锁保护 `audio_input_buf`。

---

## 八、wl_decoder 细粒度 API

为支撑 `wl_media_thread` 的串行主循环，`wl_decoder` 从原来的粗粒度 API 拆分为细粒度 API：

### 8.1 旧 API（已移除）

```c
// 一步到位：read + decode + push 到队列
wl_decode_result_t wl_decoder_next_frames(decoder, video_q, audio_q);
```

问题：把 read、decode、output 三步耦合在一起，无法控制每一步。

### 8.2 新 API

```c
// 读一个 packet，送入对应 codec（send_packet）
wl_read_result_t wl_decoder_read(decoder);

// 尝试从 codec 收一帧（receive_frame，非阻塞）
wl_frame_result_t wl_decoder_receive_video(decoder, &frame, &pts_ns);
wl_frame_result_t wl_decoder_receive_audio(decoder, &frame, &pts_ns);

// 查询状态
bool wl_decoder_drained(decoder);  // 两个 codec 都 drain 完毕

// 控制
void wl_decoder_flush(decoder);    // send_packet(NULL) 触发 drain
```

### 8.3 返回值语义

**`wl_read_result_t`**：

| 值 | 含义 | 后续动作 |
|----|------|---------|
| `WL_READ_VIDEO` | 读到视频 pkt，已送入 video codec | 回循环顶部 receive_video |
| `WL_READ_AUDIO` | 读到音频 pkt，已送入 audio codec | 回循环顶部 receive_audio |
| `WL_READ_SKIP` | 字幕/数据流，已跳过 | 继续循环 |
| `WL_READ_EOF` | 文件读完，codec 已 flush | 继续循环 drain 残余帧 |
| `WL_READ_ERROR` | 致命错误 | 退出主循环 |

**`wl_frame_result_t`**：

| 值 | 含义 | 后续动作 |
|----|------|---------|
| `WL_FRAME_OK` | 解出一帧，`*out_frame` 有效 | output 帧，继续循环 |
| `WL_FRAME_NO_DATA` | codec 无更多输出 | 尝试另一路 / 读新 pkt |
| `WL_FRAME_ERROR` | 致命错误 | 忽略或退出 |

---

## 九、API 参考

### 9.1 生命周期

```c
// 创建（分配 decoder + 初始化 mutex/cond）
wl_media_thread_t *wl_media_thread_create(const char *path, const char *hw_type);

// 启动主循环线程
int wl_media_thread_start(wl_media_thread_t *mt);

// 停止主循环，join 等线程退出（幂等）
void wl_media_thread_stop(wl_media_thread_t *mt);

// 释放所有资源（内部先 stop）
void wl_media_thread_free(wl_media_thread_t *mt);
```

### 9.2 控制

```c
// 暂停/恢复（线程安全，可从任意线程调用）
void wl_media_thread_pause(wl_media_thread_t *mt, bool pause);

// Seek 到指定时间戳（微秒）（TODO：当前只 flush codec）
void wl_media_thread_seek(wl_media_thread_t *mt, int64_t seek_ts_us);
```

### 9.3 典型使用

```c
// 创建并启动
wl_media_thread_t *mt = wl_media_thread_create("/path/to/video.mp4", "videotoolbox");
wl_media_thread_start(mt);

// ... 播放中 ...

// 暂停
wl_media_thread_pause(mt, true);

// 恢复
wl_media_thread_pause(mt, false);

// Seek 到 30 秒
wl_media_thread_seek(mt, 30 * 1000000);

// 停止并释放
wl_media_thread_free(mt);  // 内部会先 stop
```

---

## 十、与 wl_player 的关系

`wl_player` 是 M1 阶段的临时壳，包含 3 条线程（decode + video render + audio render）。`wl_media_thread` 是其替代方案：

| 维度 | wl_player（M1，临时） | wl_media_thread（M2+，目标） |
|------|---------------------|---------------------------|
| 线程数 | 3（decode + 2 render） | 1（串行主循环） |
| render 线程 | per-player，独立 | 全局共享（M3/M4） |
| 帧缓冲 | `wl_queue`（阻塞队列） | stub → async_frames（非阻塞，M3/M4） |
| 阻塞策略 | 背压（队列满 → decode 阻塞） | 非阻塞（满丢旧帧，M3/M4） |
| 生命周期 | 临时，M3/M4 退役 | 持续演进 |

`wl_player` 的 decode thread 已迁移到 `wl_decoder` 新 API，逻辑与 `wl_media_thread` 主循环一致。等 M3/M4 全局 render 线程搭好后，`wl_player` 将被移除。

---

## 十一、后续演进

### M3：接入 async_frames

- [ ] `output_video_frame` 实现：push 到 `wl_source.async_frames[]`
- [ ] 背压：`MAX_ASYNC_FRAMES = 30`，满则丢旧帧
- [ ] 硬解帧零拷贝（`frame->data[3]` = `CVPixelBufferRef`）
- [ ] 软解帧 sws_scale 转换

### M4：接入 audio buffer

- [ ] `output_audio_frame` 实现：push 到 `wl_source.audio_input_buf[ch]`
- [ ] swr_convert 重采样到统一格式
- [ ] 背压：补静音（gap fill），不丢帧

### seek 实现

- [ ] `wl_media_thread_seek` 改为标志位模式（设置 `seek_requested` + `seek_ts`）
- [ ] 主循环内执行 `av_seek_frame` + `wl_decoder_flush`
- [ ] seek 后丢弃旧帧（epoch 机制，参考 `WLMediaSource`）

### 循环播放

- [ ] EOF 后 seek 回起点，重置 `eof` 标志
