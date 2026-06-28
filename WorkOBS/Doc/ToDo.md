# WorkOBS ToDo

## 进行中

- [ ] M1：本地播放器 — 视频硬解 + 音频解码 + 同步播放

## 待办

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
