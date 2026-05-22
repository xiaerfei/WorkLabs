# 实施计划与验收标准

> 从 TaskNewPlan.md 拆分，便于独立跟踪进度。

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
| `WLStreamSourceProtocol` + `WLStreamSourceDelegate` | NewPlan/Common/ | ⏳ |
| `WLStreamOutputProtocol` + 子协议 | NewPlan/Common/ | ⏳ |
| `WLStreamFilterProtocol` + 子协议 | NewPlan/Common/ | ⏳ |
| `WLDefines.h` 补充 `WLFromTypeNetwork` | NewPlan/Common/ | ⏳ |
| `WLNode` 扩展支持 `CMSampleBufferRef` | NewPlan/Common/ | ⏳ |

### Step 2: Source 组件

每个 Source 独立实现，遵循 `WLStreamSourceProtocol`，通过 delegate 输出数据。

| 组件 | 技术方案 | 输出 | 状态 |
|------|----------|------|------|
| **WLCameraSource** | AVCaptureSession | CVPixelBufferRef | ⏳ |
| **WLMicSource** | AVCaptureSession + AVCaptureAudioDataOutput | CMSampleBufferRef | ⏳ |
| **WLMediaSource** | FFmpeg（已有，需适配） | CVPixelBufferRef + CMSampleBufferRef | ⏳ |
| **WLNetWorkSource** | FFmpeg avformat_open_input | CVPixelBufferRef + CMSampleBufferRef | ⏳ |

**验收**：每个 Source 能独立运行，通过 delegate 正确输出帧数据。

### Step 3: Filter + Mixer + VideoConcat 组件

每个处理组件独立实现，接收帧、处理、输出帧。

| 组件 | Protocol | 功能 | 状态 |
|------|----------|------|------|
| **WLVideoFilter** | `WLVideoFilterProtocol` | 缩放、裁剪、镜像 | ⏳ |
| **WLAudioFilter** | `WLAudioFilterProtocol` | 重采样、增益、降噪 | ⏳ |
| **WLAudioMixer** | `WLAudioFilterProtocol` | 多路音频混音、音量控制 | ⏳ |
| **WLVideoConcat** | `WLVideoFilterProtocol` | 多路视频切换/画中画 | ⏳ |

**验收**：每个组件能独立处理帧数据，输入和输出格式正确。

### Step 4: Output 组件

每个 Output 独立实现，遵循 `WLVideoOutputProtocol` / `WLAudioOutputProtocol`。

| 组件 | Protocol | 功能 | 状态 |
|------|----------|------|------|
| **WLEncoder** | `WLVideoOutputProtocol` + `WLAudioOutputProtocol` | VideoToolbox H264 + AudioToolbox AAC | ⏳ |
| **WLPreviewOutput** | `WLVideoOutputProtocol` | AVSampleBufferDisplayLayer 预览 | ⏳ |
| **WLAudioOutput** | `WLAudioOutputProtocol` | 系统音频播放 | ⏳ |
| **WLPushStreamer** | `WLVideoOutputProtocol` + `WLAudioOutputProtocol` | RTMP 推流 | ⏳ |

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
- [ ] 每个组件能独立运行和测试
- [ ] 组件通过 Protocol 解耦，可自由组合
- [ ] 支持 Camera + Mic 推流
- [ ] 支持 MediaFile 作为备选源
- [ ] 运行时切换视频源
- [ ] 音视频同步（唇同步 < 100ms）

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
