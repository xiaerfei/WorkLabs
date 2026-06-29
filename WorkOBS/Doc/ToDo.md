# WorkOBS ToDo

## 进行中

- [ ] M1：本地播放器 — 视频硬解 + 音频解码 + 同步播放

## 待办

### P2 — 源注册机制

- [ ] 设计 `wl_source` 统一接口（对齐 OBS `obs_source_info`）
  - 所有源类型（本地文件 / Camera / 麦克风 / 网络流 / 屏幕采集）实现同一套 vtable
  - 核心回调：`create` / `destroy` / `start` / `stop` / `pause` / `seek`
- [ ] 实现 `wl_source_register` / `wl_source_unregister` 注册表
  - 运行时注册源类型，按 type name 查找
  - 对标 OBS 的 `obs_register_source()` + `obs_source_info` 链表
- [ ] 本地媒体源（`wl_media_source`）作为第一个实现
  - 内部持有 `wl_media_thread`，走已有的串行主循环
  - output stubs 接入 `async_frames` / `audio_input_buf`
- [ ] Camera 源（`wl_camera_source`）接口预留
  - AVFoundation 回调驱动，无需解码，直接 `output_video_frame`
- [ ] 麦克风源（`wl_mic_source`）接口预留
  - CoreAudio 回调驱动，PCM 直接 `output_audio_frame`

### P3 — 低优先级
- [ ] Audio 解码器支持外部指定 codec（如强制使用 `aac_at` 硬件解码，当前由 codec_id 自动选择）

- [ ] 音视频同步（PTS 对齐 + A/V sync 策略）
- [ ] 播放控制（暂停 / 恢复 / 跳转 / 倍速）
- [ ] 帧队列管理（生产者-消费者模型 + 背压控制）
- [ ] 渲染输出（Metal / OpenGL 画面渲染）
- [ ] 音频输出（AudioQueue / AudioUnit 播放）

## 已完成

- [x] wl_decoder 基础框架（AVFormatContext 打开 + 流探测）
- [x] wl_decoder Video 解码器配置（软解 + VideoToolbox 硬解）
- [x] wl_decoder Audio 解码器配置（自动选择解码器）
- [x] wl_decoder 资源管理（统一释放 + 置 NULL）
- [x] wl_decoder_get_supported_hwaccels（硬件加速列表查询）
