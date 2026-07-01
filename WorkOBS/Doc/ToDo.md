# WorkOBS ToDo

## 进行中

- [ ]  M1：本地播放器 — 视频硬解 + 音频解码 + 同步播放

## 待办

### P2 — 源注册机制

- [ ]  设计 `wl_source` 统一接口（对齐 OBS `obs_source_info`）
  - 所有源类型（本地文件 / Camera / 麦克风 / 网络流 / 屏幕采集）实现同一套 vtable
  - 核心回调：`create` / `destroy` / `start` / `stop` / `pause` / `seek`
- [ ]  实现 `wl_source_register` / `wl_source_unregister` 注册表
  - 运行时注册源类型，按 type name 查找
  - 对标 OBS 的 `obs_register_source()` + `obs_source_info` 链表
- [ ]  本地媒体源（`wl_media_source`）作为第一个实现
  - 内部持有 `wl_media_thread`，走已有的串行主循环
  - output stubs 接入 `async_frames` / `audio_input_buf`
- [ ]  Camera 源（`wl_camera_source`）接口预留
  - AVFoundation 回调驱动，无需解码，直接 `output_video_frame`
- [ ]  麦克风源（`wl_mic_source`）接口预留
  - CoreAudio 回调驱动，PCM 直接 `output_audio_frame`

### P2 — 待讨论：解码节奏控制（pacing）

- [ ]  **`wl_media_thread` 缺 pacing，接 `async_frames` 前必须先定方案**
  - 现状：主循环没有任何 sleep，output 是丢弃 stub → **全速狂解整个文件**
  - 隐患：M3 接上 `async_frames`（max 30 / 丢旧帧 / 非阻塞）后，依然会瞬间解完
    整个文件再疯狂丢帧，因为上游不节流、下游不反压
  - 对比：OBS `mp_media_thread` 用 `mp_media_sleep()` 按 `帧pts vs 墙钟`节流到接近实时；
    `wl_player` 则靠有界阻塞队列 `wl_queue`(max 8) 天然背压（队列满 decode 阻塞）
  - 待定方案：① media thread 内做 pts-based pacing（仿 OBS）② 靠下游 tick 节拍反压
    ③ 两者结合（OBS 实际是 media 粗节流 + graphics 精确按 fps 消费）

### P2 — seek 操作

- [ ]  **`wl_media_thread` seek 实现**（当前 `wl_media_thread_seek` 是 stub，只调 flush）
  - 改标志位模式：seek API 设置 `seek_requested` + `seek_ts`，由主循环自己执行，避免跨线程动 codec/format 上下文
  - 主循环内：`av_seek_frame(fmt_ctx, ...)` 跳转 → `wl_decoder_flush()` 重置解码器
    （flush 已修为 `avcodec_flush_buffers` 语义，可安全继续喂包）
  - seek 后丢弃旧帧：epoch 世代号机制，参考老 `WLMediaSource`（8e2d813）
  - 进度条交互沿用老经验：跟随选中源、松手才 seek、抑制回显 0.5s
- [ ]  循环播放（loop）：EOF 后 seek 回起点 + 重置 `eof` 标志

### P2 — Preview 渲染
- [ ] Preview 渲染设计

### P3 — 低优先级

- [ ]  Audio 解码器支持外部指定 codec（如强制使用 `aac_at` 硬件解码，当前由 codec_id 自动选择）
- [ ]  音视频同步（PTS 对齐 + A/V sync 策略）
- [ ]  播放控制（暂停 / 恢复 / 跳转 / 倍速）
- [ ]  帧队列管理（生产者-消费者模型 + 背压控制）
- [ ]  渲染输出（Metal / OpenGL 画面渲染）
- [ ]  音频输出（AudioQueue / AudioUnit 播放）

### P4 — 暂不支持 / 稍后支持

- [ ]  `wl_decoder` 支持单流文件（纯视频 / 纯音频）
  - 现状：`wl_decoder_create` 要求视频+音频流**都存在**，任一缺失即返回 NULL
    （`find_video_stream` / `find_audio_stream` 任一失败就 fail）
  - 改：缺某一路时不 fail，把对应 index/codec 置空即可；`read` / `receive_*`
    已有 `codec_ctx` 判空保护，下游按"该路永久排空"处理
- [ ]  网络源关闭/seek 的阻塞中断：AVIOInterruptCB
  - 问题：网络流断连时 `av_read_frame` 会干等到超时（可能几秒），导致
    `wl_media_thread_free` / seek 阻塞在 join 上迟迟不返回
  - 方案（对标 OBS `media.c:642` `interrupt_callback`）：给非本地源注册
    `fmt_ctx->interrupt_callback`，回调里检查 `should_stop`，置位后
    `av_read_frame` 立即中止、不再傻等网络超时
  - 仅非本地源需要（OBS 用 `if (!is_local_file)` 把本地文件排除）
  - 依赖：先有网络拉流源（`wl_network_source`，RTMP/RTSP/HLS）

## 已完成

- [X]  wl_decoder 基础框架（AVFormatContext 打开 + 流探测）
- [X]  wl_decoder Video 解码器配置（软解 + VideoToolbox 硬解）
- [X]  wl_decoder Audio 解码器配置（自动选择解码器）
- [X]  wl_decoder 资源管理（统一释放 + 置 NULL）
- [X]  wl_decoder_get_supported_hwaccels（硬件加速列表查询）
