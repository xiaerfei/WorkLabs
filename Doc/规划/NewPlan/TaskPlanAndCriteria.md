# 实施计划与验收标准

> 从 TaskNewPlan.md 拆分，便于独立跟踪进度。
>
> 🔄 **状态核对（2026-06-15）**：§2 组件清单的部分 ⏳ 已过时，下表已就地修正——`WLAudioMixer`（多路混音）、`WLEncoder`（共享编码器，编一次分发录制/推流两路）、`WLPushStreamer`（实际类名 `WLPusher`，FLV/RTMP 推流）均**已落地**；`WLAudioOutput` 已被 `WLAudioRenderer` 取代；视频滤镜实际类名为 `WLBasicVideoFilter`（镜像/颜色校正/裁剪）。**仍未做**：`WLNetWorkSource`（网络拉流）、`WLScreenCaptureSource`（屏幕采集）、`WLAudioFilter`（独立降噪/AEC——增益与重采样已并入 `WLAudioMixer`）。完整 changelog 见 [TaskNewPlan.md](TaskNewPlan.md) §4.2（已至 v0.22）。

---

## 1. 实施策略：组件优先

**核心思路**：先实现各个独立的基础组件，每个组件独立开发、独立测试，最后通过 `WLStreamsManager` 自由串联组合。

所有组件都遵循对应的 Protocol，互不依赖，可以任意组合。

```
Source → Filter → Mixer/VideoConcat → Output (Encoder / PushStream / Rendering)
```

---

## 2. 组件清单

### 2.1 组件与 Protocol 对应关系

| 组件 | Protocol | 说明 |
|------|----------|------|
| **Source** | `WLStreamSourceProtocol` | 输入源（Camera / Mic / MediaFile / Network） |
| **Filter** | `WLVideoFilterProtocol` / `WLAudioFilterProtocol` | 单路处理（缩放、裁剪、重采样、增益） |
| **Mixer** | `WLAudioFilterProtocol` | 多路音频混音 |
| **VideoConcat** | `WLVideoFilterProtocol` | 多路视频切换/合成 |
| **Encoder** | `WLVideoOutputProtocol` + `WLAudioOutputProtocol` | H264/AAC 编码 |
| **PushStream** | `WLVideoOutputProtocol` + `WLAudioOutputProtocol` | RTMP 推流 |
| **Rendering** | `WLVideoOutputProtocol` | 本地预览 |

### 2.2 组件实现顺序

```
Step 1: Protocol 定义（所有组件的基础）
   ↓
Step 2: Source 组件（Camera / Mic / MediaFile）
   ↓
Step 3: Filter + Mixer + VideoConcat 组件
   ↓
Step 4: Output 组件（Encoder / Rendering / PushStream）
   ↓
Step 5: WLStreamsManager 串联所有组件
```

---

## 3. 详细实施计划

### Step 1: Protocol 定义

定义三个核心 Protocol，所有后续组件都基于此。

| 任务 | 文件 | 状态 |
|------|------|------|
| `WLStreamSourceProtocol` + `WLStreamSourceDelegate` | NewPlan/Common/ | ✅ |
| `WLStreamOutputProtocol` + 子协议 | NewPlan/Common/ | ✅ |
| `WLStreamFilterProtocol` + 子协议 | NewPlan/Common/ | ✅ |
| `WLStreamRenderingProtocol`（Preview frame 反馈） | NewPlan/Common/ | ✅ |
| `WLDefines.h` 补充 `WLFromTypeNetwork` | NewPlan/Common/ | ✅ |
| `WLNode` 扩展支持 `CMSampleBufferRef` | NewPlan/Common/ | ✅ |

### Step 2: Source 组件

每个 Source 独立实现，遵循 `WLStreamSourceProtocol`，通过 delegate 输出数据。

| 组件 | 技术方案 | 输出 | Config | 状态 |
|------|----------|------|--------|------|
| **WLCameraSource** | AVCaptureSession | CVPixelBufferRef | `WLCameraSourceConfig` | ✅ 兼容新协议（同时保留旧 block 回调） |
| **WLMicSource** | AVCaptureSession + AVCaptureAudioDataOutput | CMSampleBufferRef | `WLMicSourceConfig` | ✅ 兼容新协议（同时保留旧 block 回调） |
| **WLMediaSource** | FFmpeg（已适配新协议） | CVPixelBufferRef + CMSampleBufferRef | — | ✅ |
| **WLNetWorkSource** | FFmpeg avformat_open_input | CVPixelBufferRef + CMSampleBufferRef | — | ⏳ |
| **WLScreenCaptureSource** | CGDisplayStream / ScreenCaptureKit | CVPixelBufferRef | — | 后续扩展 |

**验收**：每个 Source 能独立运行，通过 delegate 正确输出帧数据。

### Step 3: Filter + Mixer + VideoConcat 组件

每个处理组件独立实现，接收帧、处理、输出帧。

| 组件 | Protocol | 功能 | 状态 |
|------|----------|------|------|
| **WLVideoFilter** | `WLVideoFilterProtocol` | 缩放、裁剪、镜像（实际类名 `WLBasicVideoFilter`，Core Image + Metal `CIContext`；含颜色校正） | ✅ |
| **WLAudioFilter** | `WLAudioFilterProtocol` | 重采样、增益、降噪、音频格式转换 | 🚧 部分（重采样/增益已并入 `WLAudioMixer`；独立降噪/AEC 未做） |
| **WLAudioMixer** | — | 多路音频混音、按源音量控制（swresample 统一格式 + TPCircularBuffer + ~23ms 定时器叠加限幅） | ✅ |
| **WLVideoMix** | —（带 layoutFrame 的合成器，非 Filter） | 固定画布上多路视频按 layoutFrame 合成（CoreImage） | ✅ |

> **格式转换**：不同 Source 输出的像素格式（BGRA / YUV）和音频格式（采样率 / 声道数）差异，由 Filter 组件统一处理。

**验收**：每个组件能独立处理帧数据，输入和输出格式正确。

### Step 4: Output 组件

每个 Output 独立实现，遵循 `WLVideoOutputProtocol` / `WLAudioOutputProtocol`。

| 组件 | Protocol | 功能 | 状态 |
|------|----------|------|------|
| **WLEncoder** | — | 共享编码器：`h264_videotoolbox` + `aac_at` + swscale/swresample，编一次分发录制/推流两路（配套 `WLEncodedPacket` / `WLEncoderConfig`） | ✅ |
| **WLStreamPreview** | `WLStreamRenderingProtocol`（继承 `WLVideoOutputProtocol`） | AVSampleBufferDisplayLayer 渲染 + 拖动/缩放交互 + interactive 开关 | ✅ |
| **WLAudioRenderer**（原 WLAudioOutput） | — | 系统音频播放（AudioQueue，按首帧 formatDescription 动态适配） | ✅ |
| **WLPusher**（原 WLPushStreamer） | — | RTMP 推流（FLV muxer + `avio_open2` rtmp，纯 muxer 接 `WLEncoder` 输出包） | ✅ |
| **WLRecorder** | — | mp4 录制（FLV/mp4 muxer，纯 muxer 接 `WLEncoder` 输出包；header 延迟首视频包） | ✅ |

### Step 5: WLStreamsManager 串联

**组件生命周期**：`start` 按 Source → Filter → Output 顺序启动，`stop` 反序停止。

```objc
// 示例：Camera + Mic → Filter → Mix → Encoder + Preview + RTMP

**验收**：每个 Output 能独立接收帧数据并完成输出。

### Step 5: WLStreamsManager 串联

用 `addSource:` / `addFilter:` / `addOutput:` 自由组合组件。

```objc
// 示例：Camera + Mic → Filter → Mix → Encoder + Preview + RTMP
WLStreamsManager *mgr = [WLStreamsManager sharedManager];

// 注册 Source
[mgr addSource:cameraSource];
[mgr addSource:micSource];

// 注册 Filter
[mgr addFilter:videoFilter];
[mgr addFilter:audioFilter];

// 注册 Output
[mgr addOutput:encoder];
[mgr addOutput:previewOutput];
[mgr addOutput:pushStreamer];

// 启动
[mgr start];
```

**验收**：Camera + Mic → Filter → Mix → Encoder → RTMP 全链路跑通。

---

## 3.X 已落地：Preview 管线（2026-05-26）

对应 [TaskNewPlan.md §2.3 Preview 渲染管线](TaskNewPlan.md#23-preview-渲染管线)，本次实现了从 Source 到 MainPreview 的完整可视化链路（不含 Encoder / PushStream）：

```
Source ─delegate→ WLStreamsManager
                    │
            perStreamFilter (可选, WLVideoFilter)
                    │
        ┌──────────┴──────────┐
        ▼                     ▼
  Overlay Preview         WLVideoMix（固定画布 1920×1080，CoreImage）
  (WLStreamPreview, 浮层)       │
        │                      ▼
        └──frame反馈──→  layoutFrame
                               │
                               ▼
                       PostFilter (可选, WLVideoFilter)
                               │
                               ▼
                    MainPreview（WLStreamPreview, 铺满 canvas、不拦截鼠标）
```

### 落地清单

| 文件 | 角色 | 备注 |
|------|------|------|
| `NewPlan/Common/WLStreamFilterProtocol.h` | 新增 | Filter 协议（video/audio），返回值标注 `CF_RETURNS_RETAINED` |
| `NewPlan/Filter/WLVideoFilter.{h,m}` | 新增 | CoreImage Filter：scale / crop / mirror；CVPixelBufferPool 复用；Metal-backed CIContext |
| `NewPlan/Mix/WLVideoMix.{h,m}` | 新增 | 固定画布合成器；串行 dispatch queue；streamID → 缓存帧 + layoutFrame 字典；维持插入顺序作为图层顺序 |
| `NewPlan/Core/WLStreamsManager.{h,m}` | 重写 | 编排器：`addSource:previewOutput:` / `setFilter:forSource:` / `setLayoutFrame:forSource:` / `start` / `stop`；实现 `WLStreamSourceDelegate` + `WLStreamRenderingDelegate`（浮层 Preview 拖拽自动同步 layout 到 Mix） |
| `NewPlan/UI/WLStreamPreview.{h,m}` | 修改 | 增加 `interactive` 属性 + `hitTest:` 重写，MainPreview 设为 `NO` 不拦截鼠标 |
| `NewPlan/UI/WLStreamViewController.{h,m}` | 修改 | 暴露 `mainPreview`（铺满 canvas，底层）；`addOverlayPreview:` / `removeOverlayPreview:` 浮层叠加在 mainPreview 之上 |
| `NewPlan/Source/Camera/WLCameraSource.{h,m}` | 修改 | 同时遵循 `WLStreamSourceProtocol`；新增 `streamType` / `delegate` / `start:(NSError**)`；回调时 delegate 优先于旧 `frameOutput` block |
| `NewPlan/Source/Mic/WLMicSource.{h,m}` | 修改 | 同上（音频路径） |
| `Core/Streams/`、`Core/Utils/` | **删除** | 旧 `WLVideoModeStreams` / `WLAudioMixStreams` / `WLCoreUtils` 三个死代码模块整体清理 |

### 关键设计决策

- **技术栈**：CoreImage（Phase 1，单源/合成均够用），后续可 swap 为 Metal Performance Shaders 优化。
- **画布**：固定 1920×1080（可配置），`WLStreamPreview` 浮层的 frame 直接作为 `WLVideoMix` 的 `layoutFrame`（macOS NSView 默认左下角坐标，与 CoreImage 一致）。
- **MainPreview 布局**：`MainPreview` 铺满画布底层，`Preview₁/Preview₂` 作为浮层叠加 —— 类似 OBS / 海报类 App 的"画布即合成结果"风格。
- **CVPixelBuffer 所有权**：统一遵循 Create Rule。`processVideoFrame:pts:` 返回值与 Source delegate 回调中的 buffer 所有权一律转移给调用方，`StreamsManager` 内 fork 时显式 `CVPixelBufferRetain/Release` 配平。
- **双协议过渡**：Camera/Mic 同时支持旧 `WLSourceProtocol`（block 回调，被 `WLPipelineManager` / `WLSceneManager` 使用）和新 `WLStreamSourceProtocol`（delegate 回调）。delegate 非空时只走 delegate，避免双重 release。

### 已验证

- ✅ `xcodegen generate` + `pod install` + `xcodebuild ... -configuration Debug` 整个工程 **BUILD SUCCEEDED**。
- ❌ Runtime 未验证（需要在调用方完成 `addSource:previewOutput:` + `manager.mainPreviewOutput = controller.mainPreview` 的接线后才能跑起来）。

### 未做（Preview 管线相关）

1. **管线接线示例**：尚未在 `WLStreamViewController` 或 `WLTestSourceController` 中编写"创建 Source + addOverlayPreview + addSource"的入口代码。
2. **旧体系清理**：`WLPipelineManager` / `WLSceneManager` / 旧 `WLSourceProtocol` 仍被 `WLMenuPanelViewController` / `WLSourcePanel` 引用，未删除。等待后续将旧 UI 迁移到新 manager 后再清理。
3. **Audio 链路**：`WLStreamsManager` 收到音频 delegate 回调后直接 release，未接入 `WLAudioMixer`。

---

## 4. 组合示例

组件实现后，可以通过 WLStreamsManager 自由组合：

| 场景 | Source | Filter | Output |
|------|--------|--------|--------|
| 纯摄像头推流 | Camera + Mic | VideoFilter + AudioFilter | Encoder + PushStream |
| 带预览 | Camera + Mic | VideoFilter + AudioFilter | Encoder + PushStream + Preview |
| 画中画 | Camera + MediaFile | VideoFilter x2 + VideoConcat | Encoder + PushStream |
| 混音推流 | Camera + Mic + MediaFile | AudioFilter x2 + AudioMixer | Encoder + PushStream |
| 录屏推流 | ScreenCapture + Mic | VideoFilter + AudioFilter | Encoder + PushStream |

---

## 5. 成功标准与验收指标

### 5.1 功能完整性
- [x] 每个组件能独立运行和测试
- [x] 组件通过 Protocol 解耦，可自由组合
- [x] 支持 Camera + Mic 推流
- [x] 支持 MediaFile 作为备选源
- [ ] 运行时切换视频源（设计见《可切源推流时间戳设计.md》，未落地）
- [~] 音视频同步（主体已实现：a/v 共享单调墙钟同一零点；唇同步 < 100ms 未量化实测）

### 5.2 性能指标
- **CPU 占用** < 50% (Mac mini M1)
- **内存占用** < 500MB
- **端到端延迟** < 3 秒（可配置优化到 < 1s）
- **推流稳定性** 连续推流 2 小时不中断
- **帧率** ≥ 25 fps（720p）

### 5.3 代码质量
- [ ] 无明显内存泄漏（Instruments 验证）
- [ ] 无线程安全 bug
- [ ] 关键流程有日志记录
