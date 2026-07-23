# WorkOBS ToDo

> 按里程碑组织（M0–M6）。**✅ 已完成 · 🚧 进行中 · ⬜ 待办**
> 最后刷新：2026-07-23 —— 反映真实进度（旧版很多"待办"其实早已落地未勾）。

## 当前位置

M1 主体完成（视频解码 + pacing + 源注册 + 协议化 + 节拍）+ 源管理 UI + 预览 Step1 直显。
站在 **M1 收尾 ↔ M3 合成** 交界。

**架构主线**：`WLGraphics::set_output` 出口 = M2 录制 + M5 推流的共同接入点（对齐 OBS shared
encoder）｜M3 Metal 合成兑现预览出口的价值（Step1 直显只是半成品）｜音频横跨 M1(播放)↔M4(混音编码)。

---

## M0 环境热身 ✅
- xcodegen 独立工程（`WorkOBS/OBSLabs/`）+ ffmpeg-kit 集成 + 基础骨架

## M1 本地播放器 🚧（主体完成，差收尾）

### 已完成 ✅
- **`wl_decoder`**：AVFormatContext 打开 + 流探测 + 视频软解/VideoToolbox 硬解 + 音频解码 + 资源管理 + 硬件加速列表查询
- **`WLMediaSource` 主循环**：串行（控制检查 → receive_video → receive_audio → read → pace）
- **视频 pacing**：pts 绝对基准 `target = base_wall + (pts − first_pts)`，nanosleep + CLOCK_MONOTONIC（仿 OBS `mp_media_sleep`）
- **源注册机制**：`wl_source_type_info` / `WLSourceRegistry` / 工厂，回调输出
- **async_frames**：堆分配环形缓冲、drop-oldest、追赶式挑帧、cur_frame borrow 兜底
- **`WLCore`** 全局核心（对标 obs 单例，源列表 + 一把锁，tick 遍历持同锁）
- **`WLGraphics`** 节拍骨架（video_sleep 绝对时刻 + count 补帧）+ **`WLTime`** 共用单调钟
- **Orthodox C++ 化**（全库无 .c）+ **协议化重构**（`WLSource` 壳 + `WLSourceProtocol`，对齐 `obs_source_info` 三元结构）+ info 元数据 / ASYNC 位分流
- **源管理 UI**（动态增删源，OBS Sources dock 形状）
- **预览 Step1**：`AVSampleBufferDisplayLayer` 直显 + `WLGraphics::set_output` 合成帧输出出口（tick 挑帧锁内 retain → 锁外 push → graphics 线程 hop 主线程 enqueue）

### 待办 ⬜（收尾）
- [ ] **运行验证**：Cmd+R 选 60fps 视频，看画面流畅 + `[get] advanced=2` + 关窗 shutdown 干净不崩
- [ ] 验证通过后：删临时日志 `[get]/[gfx]/[src A]`、清 `queue/`(wl_node/wl_queue) 死代码
- [ ] **音频线**：音频 pacing + AudioQueue 播放 ← *现在纯视频没声音，M1 最大的洞*
- [ ] **pause/resume** + 可中断 sleep（现在 nanosleep 打不断，stop 最坏等一个 interval）
- [ ] **seek**（当前是 stub）
  - 标志位模式：seek API 设 `seek_requested` + `seek_ts`，主循环自己执行（避免跨线程动 codec/format 上下文）
  - `av_seek_frame` 跳转 → `wl_decoder` flush（`avcodec_flush_buffers` 语义）
  - epoch 世代号丢旧帧（参考老 `WLMediaSource` 8e2d813）
  - 进度条交互：跟随选中源、松手才 seek、抑制回显 0.5s
- [ ] **loop 循环**：EOF 后 seek 回起点 + 重置 `eof`（时间线摊平、baseTime 不重锚）
- [ ] **pacing 精修**：从 OBS 带走 2ms 平滑窗、2s 跳变重锚

## M2 录制器 ⬜
- [ ] **共享编码器**（h264_videotoolbox + aac_at）← 从 `set_output` 出口接
- [ ] mp4 muxer：写 header 延迟到首包（VideoToolbox extradata 首帧才有）、首个视频关键帧对齐为零点、BT.709 limited

## M3 合成 + 同步源 ⬜（= 预览 Step2）
- [ ] **Metal offscreen 合成**：背景清屏 + 多源 z-order 叠加 + 每源变换（位置/缩放/裁剪）→ 一张纹理
- [ ] 预览改**采样合成纹理**（替 Step1 单源直显，多源真叠加）
- [ ] **画布模型**：canvas size / 每源 layout rect / z-order（对应 WorkLabs `WLCanvasModel`）
- [ ] **源变换 UI**：拖拽 / 8-handle 等比缩放 / 选中框 / 右键 z-order
- [ ] **同步源分流**：无 ASYNC 位的源，render 阶段调 `video_render()` 现画（不走缓冲，抄 OBS `render_video` obs-source.c:2906）
- [ ] 图片源（第一个同步源，练分流）
- [ ] 屏幕采集（ScreenCaptureKit）
- [ ] 摄像头源（AVFoundation 回调驱动，无需解码，直接 `output_video`）
- [ ] **per-source 滤镜链**（Metal shader：镜像 / 色彩校正 / 裁剪…）
  - 性能铁律：帧上传成纹理后，合成 / 滤镜全留在 Metal 里，别回读 CPU（详见性能讨论）

## M4 音频节拍 + 混音 ⬜
- [ ] 多源 PCM 混音：重采样统一（44.1k / 立体声 / Float32）、按增益求和 + 削顶、gap → 补静音
- [ ] 麦克风源（CoreAudio 回调驱动，PCM 直接 `output_audio`）
- [ ] 音频编码接入编码器 + A/V 同步（PTS 对齐）
- [ ] （低优先）Audio 解码器支持外部指定 codec（如强制 `aac_at` 硬解，当前按 codec_id 自动选）

## M5 推流 ⬜
- [ ] flv/rtmp muxer（avio rtmp、realtime、2s GOP、独立串行队列隔离，rtmp 卡不影响录制/编码）
- [ ] 可切源推流时间戳设计（`Doc/WorkLabs设计/可切源推流时间戳设计.md` 已有前篇）

## M6 收尾 ⬜
- [ ] 性能验收（GPU lag / `lagged_frames`）+ 内存泄漏 acceptance pass
- [ ] **网络拉流源**（RTMP/RTSP/HLS）+ **AVIOInterruptCB 断连中断**
  - 问题：网络断连时 `av_read_frame` 干等超时（几秒），free/seek 阻塞在 join 上
  - 方案（对标 OBS `media.c:642` `interrupt_callback`）：非本地源注册 `fmt_ctx->interrupt_callback`，回调查 `should_stop`，置位后立即中止（`if (!is_local_file)` 排除本地文件）
- [ ] 晶振漂移补偿（低优先，被动水位填充，"先观察"）

---

## 低优先级技术笔记（暂不做，留记录）

- **`wl_decoder` 单流文件支持**：现状 `create` 要求视频+音频流都在，任一缺失返回 NULL。改：缺某路不 fail，置空 index/codec 即可（`read`/`receive_*` 已有 codec_ctx 判空保护，下游按"该路永久排空"处理）。
- **PTS 外推漂移检测（mpv 式，比 OBS 更完整）**：现状按 OBS 方式（`best_effort_timestamp` 为 NOPTS 时用 `next_pts` 外推），单帧偶丢自愈；隐患是**连续多帧**丢时间戳时外推误差累积，真实值回来后可能非单调。方案（对标 mpv `correct_audio_pts`，`f_decoder_wrapper.c:834-875`）：新真实值 vs 外推位置比差 —— 容器舍入内忽略、较大打警告、离谱（>5s）判漂移重校准。M1 仅处理完好本地文件，概率极低故暂缓。详见 `Doc/调研/OBS/OBS_mpv_PTS缺失时间戳修复对比.md`。
