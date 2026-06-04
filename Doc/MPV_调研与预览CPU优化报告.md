# mpv 调研与 WorkLabs 预览 CPU 优化报告

> **调研对象**：mpv `v0.41`（`v0.41.0-718-g1d82932cce`），源码位于 `/Users/tvum4pro/Documents/github/mpv`
> **触发问题**：单个本地视频文件 *Preview* 时，WorkLabs CPU ≥ 20%，而 mpv 仅 ~12%
> **关联文档**：`Doc/IINA_*_Report.md`（IINA 是基于 mpv 的 macOS 播放器，可对照阅读）
> **行号说明**：mpv 行号基于 v0.41 调研，随版本可能微调；WorkLabs 行号为本次逐一核对，准确。

---

## 0. 结论速览（TL;DR）

| 项 | 结论 |
|---|---|
| **差距主因** | 纯预览时 WorkLabs 仍以 60fps 跑**完整 CoreImage 合成**（`WLVideoMix`），合成结果在非录制时直接丢弃。mpv 播单视频**根本没有"合成"这一步**。 |
| **次因** | 渲染线程用 `usleep` 轮询而非条件变量精确等待；`WLMediaSourcePreview` 建了整套 Metal 管线却不被画布消费。 |
| **做对的地方** | VideoToolbox 硬解走 `frame->data[3]` 零拷贝拿 `CVPixelBuffer`，与 mpv 的 IOSurface 零拷贝同理，这条路不亏。 |
| **已实施①** | `WLVideoMix` 加 `renderingEnabled` 开关：纯预览跳过合成，仅录制/推流时开启。**实测 CPU 从 20%+ 降至 ~11%**，已对齐/略优于 mpv（~12%），预览结构对齐其「硬解 → 直接上屏」。 |
| **待办②③** | ② 渲染线程改条件变量/绝对时间精确等待；③ 删除冗余 `WLMediaSourcePreview` Metal 管线。 |

---

## 1. 背景与问题

WorkLabs 的单路视频预览数据流（见 `CLAUDE.md` Data flow）：

```
WLMediaSource ──(硬解 CVPixelBuffer)──► WLStreamsManager.source:didOutputVideoFrame:
                                              ├─ Fork 1 ─► WLStreamPreview (AVSampleBufferDisplayLayer) ── 上屏 ✅ 必要
                                              └─ Fork 2 ─► WLVideoMix 合成 ──► 录制/推流 muxer
```

观察到的现象：**只接一路本地视频文件、只做预览（不录制不推流）时，CPU 仍 ≥ 20%**，明显高于功能相近、且功能更全的 mpv（~12%）。

mpv 是公认 CPU 效率极高的播放器，因此以它作为对照基准，从三个维度调研：**① 读取/解码线程模型**、**② 队列与缓存设计**、**③ 渲染与帧定时**，再回头定位 WorkLabs 的开销大头。

---

## 2. mpv 调研

### 2.1 读取与解码：线程模型

**核心：事件驱动 + 条件变量 + 按需拉取（pull），全程零忙等。**

#### Demux 线程（1 个）

- 入口 `demux_thread()` — `demux/demux.c:2661`；启动 `demux_start_thread()` — `demux/demux.c:1203`。
- 主循环结构（`demux.c:2661-2689`）：

  ```c
  while (!in->thread_terminate) {
      if (thread_work(in))            // 有活立刻再做一轮
          continue;
      mp_cond_signal(&in->wakeup);    // 通知消费者有数据
      mp_cond_timedwait_until(&in->wakeup, &in->lock, in->next_cache_update);
  }
  ```

- **阻塞点是 `mp_cond_timedwait_until()`，用绝对时间 `in->next_cache_update`**，不是短间隔轮询。仅在「消费者取走包并置 `in->reading=true`」「缓存更新时间到」「线程终止」时被唤醒。
- 何时读 `av_read_frame`：由 `thread_work()`→`read_packet()`（`demux.c:2262` 起）判断；缓存未达 `readahead-secs` 才继续读，达到上限即停止读取并睡眠。

#### 解码（不是独立的 mpv 线程）

- 视频解码在 **libavcodec 内部线程池**，由 mpv 的过滤器框架同步驱动，非 mpv 自建解码线程。配置 `vd-lavc-threads`（`video/decode/vd_lavc.c:111`，默认 0=自动≈核数）；硬解另有 `hwdec-threads`（默认 4）。
- 音频解码默认单线程（`audio/decode/ad_lavc.c`，`threads=1`）。
- **拉取模式（pull）**：仅当播放主循环需要下一帧时才解码 —— `run_playloop()`(`player/playloop.c:1260`) → `write_video()`(`player/video.c:1034`) → `video_output_image()`(`player/video.c:470`) → 过滤器框架 `mp_pin_out_read()`。下游缓冲满，解码自动停。

#### 线程总数（播放含音频的本地文件）

```
主线程 / 播放循环   run_playloop()        player/playloop.c:1260
Demux 线程 × 1      demux_thread()        demux/demux.c:2661
VO 渲染线程 × 1     vo_thread()           video/out/vo.c:1117
libavcodec 内部线程 × N（仅在 send/receive 时活跃，由 FFmpeg 调度）
```

最少约 4 线程，最多 `4 + 核数`。

#### 不浪费 CPU 的关键

- 主循环 `mp_wait_events()`(`playloop.c:54`) 用 `mp_dispatch_queue_process(dispatch, sleeptime)` 睡到下次事件，`sleeptime` 用 `mp_set_timeout()`(`playloop.c:75`) 按**绝对时间**算。
- 过滤器图 `mp_filter_graph_run()`(`filters/filter.c:211`) **同步单线程**执行所有 filter，无跨线程同步开销、无海量上下文切换。

### 2.2 队列与缓存设计

**核心：引用计数零拷贝 + 字节/时长限流 + 迟滞背压 + 解码后仅缓存 1 帧 + 条件变量精确唤醒。**

- **Demux 缓存**：多范围链表（`demux_cached_range` / `demux_queue`，`demux/demux.c:306,345`）。`demux_packet` 仅持指针与元数据（`demux/packet.h:26`）。
- **限流（按字节 + 时长，不按包数）**：`demuxer-max-bytes` 默认 **150 MB**（`demux.c:141`），后向 50 MB；`demuxer-readahead-secs`(`min_secs`) 默认 **1.0 秒**（`demux.c:144`）。缓存满 → demux **停止读取并睡眠**，非阻塞、非空转（`demux.c:2309`）。
- **背压**：消费者取包时若 `!in->reading` 则置 `reading=true` 并 `mp_cond_signal` 唤醒 demux（`demux.c:2759`）；迟滞 `demuxer-hysteresis-secs` 防止在阈值附近反复切换读/不读。
- **解码后 frame 队列**：解码线程→显示用 `mp_async_queue`（`filters/f_async_queue.*`），**默认 `max_samples=1`（仅缓存 1 帧）**。mpv 是流式处理，不囤大量解码帧。
- **零拷贝**：`new_demux_packet_from_avpacket()` 用 `av_packet_ref()` 增引用计数而非深拷贝（`demux/packet.c:109`）；`demux_packet_pool` 复用包结构体减少分配（`demux/packet_pool.c`）。
- **唤醒**：全程条件变量（`mp_cond_signal`/`mp_cond_timedwait_until`）+ `mp_filter_wakeup`，无忙轮询。

### 2.3 渲染与帧定时

**核心：硬解零拷贝 → GPU shader 做 YUV→RGB（CPU 不碰像素）→ 绝对时间精确 sleep 到呈现时刻 → 暂停/静止接近 0 CPU。**

#### 硬解零拷贝（macOS / VideoToolbox）

- 解码帧的 `CVPixelBuffer` 从 `mapper->src->planes[3]` 直接取（`video/out/hwdec/hwdec_vt.c:121`）。
- GL 路径：`CVPixelBufferGetIOSurface()` 拿 IOSurface → `CGLTexImageIOSurface2D()` 直接绑定为纹理，**不拷像素**（`hwdec_mac_gl.c:92,114`）。
- Metal 路径：`CVMetalTextureCacheCreateTextureFromImage()` 从 CVPixelBuffer 平面建 Metal 纹理，仍由 IOSurface 背书（`hwdec_vt_pl.m:241`）。
- **YUV→RGB 全在 GPU fragment shader 完成**（`pass_convert_yuv()`，`video/out/gpu/video.c:2542` 起；颜色矩阵在 CPU 算一次，转换在 shader 内一遍过），无中间纹理、无 CPU 像素操作。

#### 帧定时（最关键的 CPU 点）

- VO 线程 `vo_thread()`(`video/out/vo.c:1117`)：渲染需要显示的帧 → 算出下一帧目标呈现时刻 `wakeup_pts` → `wait_vo()` **睡到那一刻**。
- `vo_wait_default()`(`vo.c:714`) 用 `mp_cond_timedwait_until(&in->wakeup, &in->lock, until_time)` —— **条件变量 + 绝对超时**，不是 `sleep(1ms)` 轮询。新帧到达 / 用户输入 / 超时才提前唤醒。
- macOS 用 `CVDisplayLink` 在每次 vsync 回调（`osdep/mac/*`），精确得到「帧已显示」时刻反馈，消除漂移。

#### 空闲/暂停

- 暂停时 `vo_set_paused()`(`vo.c:1225`) 关闭 vsync 计时，**只重绘最后一帧一次**，随后无限睡眠。静止画面 ≈ 0 CPU，无"无新内容仍重绘"。

---

## 3. WorkLabs 现状与 CPU 诊断

### 3.1 单源预览数据流（实测代码核对）

```
WLMediaSource（5 线程：parse + videoDecode + audioDecode + videoRender + audioRender）
   │  硬解：convertVideoFrame 直接返回 frame->data[3] 的 CVPixelBuffer（零拷贝）✅
   ▼  WLMediaSource.m:395-401
WLStreamsManager.source:didOutputVideoFrame:        WLStreamsManager.m:312-344
   ├─ Fork 1：previewOutputs[sid] receiveVideoFrame  ──► WLStreamPreview
   │         → CMSampleBuffer → AVSampleBufferDisplayLayer 上屏       ✅ 预览必要、相对高效
   │         WLStreamPreview.m:80,145-185
   └─ Fork 2：[self.mix inputVideoFrame:...]（无条件，每帧）          ❌ 非录制时纯浪费
             WLStreamsManager.m:341
             → WLVideoMix.renderWithPts 整套 CoreImage 合成           WLVideoMix.m:175-247
               （建背景 CIImage → imageWithCVPixelBuffer → 仿射变换
                → imageByCompositingOverImage → pool 取 BGRA buffer
                → [ciContext render:toCVPixelBuffer:]）
             → output 判断在合成之后（行 247）：非录制时把成品直接 Release（WLStreamsManager.m:65）
```

**关键**：`self.mix` 是懒加载 getter，第一帧进来就建好 mix 并开始合成；合成的 GPU 提交 + 像素写入在 `output` 判断**之前**就花掉了。预览画面靠的是 Fork 1 的 `AVSampleBufferDisplayLayer`，**Fork 2 在非录制/推流时 100% 多余**。

### 3.2 CPU 大头清单（对照 mpv）

| 开销点 | WorkLabs | mpv | 代码位置 |
|---|---|---|---|
| **① 空转合成** ⭐主因 | 预览时仍 60fps 跑完整 CoreImage 合成后丢弃 | 无"合成"概念 | `WLVideoMix.m:175`、`WLStreamsManager.m:341` |
| ② 渲染线程等待 | `usleep(10ms)` + `peek` 轮询；每轮 `CFAbsoluteTimeGetCurrent` | 条件变量 + 绝对时间精确 sleep，空闲≈0 唤醒 | `WLMediaSource.m:311,336,357,381` |
| 硬解上屏 | `frame->data[3]` 零拷贝 ✅ | IOSurface 零拷贝 ✅ | `WLMediaSource.m:395-401` |
| ③ 冗余 Metal 管线 | `WLMediaSourcePreview` 建 device/queue/cache/pipeline 但 canvas 不消费 | — | `WLMediaSource.m:95` |
| 线程数 | 5 线程/源 | 1 demux + 解码池 + VO + 主循环 | — |

---

## 4. 优化方案（按 ROI 排序）

**① 预览时停掉合成（最大收益，低风险）** — 已实施，见第 5 节。
**② 渲染线程改精确等待（中等收益，对齐 mpv）** — 待办。
  `videoRenderThread` 的 `peek + usleep(10ms)` 轮询 → 用 `WLNodeQueue` 已有的 `deQueueWithTimeout:` 阻塞等待 + 按 pts 算绝对唤醒时刻，消除空闲期 ~100Hz 空唤醒。
**③ 删除冗余 `WLMediaSourcePreview` Metal 管线（小收益，省内存/初始化）** — 待办。
  canvas 不消费它（预览走 `WLStreamPreview`），`WLMediaSource` 可不创建。

---

## 5. 已实施：优化① 预览停掉空转合成

### 5.1 改动清单（5 文件，6 处编辑；编译 `** BUILD SUCCEEDED **`）

| 文件 | 改动 |
|---|---|
| `WLVideoMix.h/.m` | 新增 `@property (atomic) renderingEnabled`（默认 NO）；`renderWithPts` 入口 `if (!renderingEnabled) return;`，跳过整套 CoreImage 合成 |
| `WLStreamsManager.h/.m` | 新增 `@property compositingEnabled`，自定义 setter 透传给 `_mix`；mix 懒创建时继承当前开关状态 |
| `WLStreamViewController.m` | `ensureEncoderRunning` 成功后置 `compositingEnabled=YES`；`stopEncoderIfIdle`（两路全停）置 `NO` |

### 5.2 运行时行为（闭环）

```
纯预览（常态）：     compositingEnabled = NO
                   → mix.renderWithPts 入口即 return，零 CoreImage 合成
                   → 预览画面照常（各路走自己的 AVSampleBufferDisplayLayer 上屏）

点录制 / 推流：      ensureEncoderRunning 成功 → compositingEnabled = YES
                   → mix 开始合成 → encoder 编码 → 分发 recorder/pusher

两路全停：           stopEncoderIfIdle → compositingEnabled = NO → 回到零空转
```

- `ensureEncoderRunning` 是录制与推流的**共同入口**，`stopEncoderIfIdle` 是两路全停的**唯一收口**，故开关一开一关严格配对、无遗漏。
- 编码器启动失败时**不开**合成，避免"开关开着却无消费者"的空转。

### 5.3 为什么不丢状态、无残影

关闭合成期间，`inputVideoFrame` 仍在 `serialQueue` 上持续刷新 `latestFrames` / `streamOrder`（更新发生在 `renderWithPts` 入口 `return` **之前**，`WLVideoMix.m:113-119`）；`setLayoutFrame` / `setBackgroundColor` / `setStreamOrder` 同理只更新缓存。因此：

- 开启瞬间，下一帧输入（视频源持续出帧，30fps 下 ≤ 33ms）即用**最新全量状态**合成首帧 —— 无延迟、无状态丢失。
- 录制 muxer 处于 `awaitingKeyframe`，配合 `requestKeyframe` 使首个合成帧即 IDR，mp4 开头内容完整（A/V 同步用统一 epoch，不受此 ≤33ms 影响）。

### 5.4 预期与实测效果

预览路径只剩「VideoToolbox 零拷贝硬解 → `AVSampleBufferDisplayLayer` 上屏」，结构上对齐 mpv 的「硬解 → 直接上屏」，那条 60fps 的 CoreImage 合成管线整个不跑 —— 即第 3.2 节的主因开销被消除。

**实测（Activity Monitor，单个本地视频文件预览）：CPU 从 20%+ 降至 ~11%，已对齐/略优于 mpv（~12%）。第 3.1 节"Fork 2 空转合成"为主因的判断得到验证。**

---

## 6. 待办：优化②③

- **② 渲染线程精确等待**：`videoRenderThread` / `audioRenderThread` 用条件变量（`deQueueWithTimeout:`）+ 按 pts 的绝对唤醒时刻替代 `usleep` 轮询。注意保持现有 `baseTime + pts` 节流时序。
- **③ 删冗余 Metal 管线**：`WLMediaSource` 不再创建 `WLMediaSourcePreview`（或延迟到真正需要时），省一套 Metal 资源与初始化。

---

## 7. 专题：直接绑纹理（零拷贝纹理绑定）

> 承接 §2.3「渲染与帧定时」中提到的 IOSurface 零拷贝，本专题深入「直接绑纹理」机制及其对 WorkLabs 的适用性。

### 7.1 原理：为什么零拷贝

`CVPixelBuffer` 若由 **IOSurface** 背书，其像素内存就是一块 GPU 可直接寻址的共享内存。「直接绑纹理」= 把这块 IOSurface 内存**包装**成纹理对象交给 GPU 采样，**全程不拷贝像素**。

对比普通上传（`glTexImage2D` / `MTLTexture replaceRegion`）：CPU 内存 → GPU 显存的 memcpy（外加可能的格式转换）。1080p BGRA 每帧约 8 MB、60fps ≈ 480 MB/s 的拷贝量。直接绑纹理把这部分降到 **0**。

### 7.2 mpv 实现（两条路径，均按平面绑定）

**GL 路径** — `video/out/hwdec/hwdec_mac_gl.c:84-148`：

```c
p->pbuf = (CVPixelBufferRef)mapper->src->planes[3];        // VT 硬解帧
IOSurfaceRef surface = CVPixelBufferGetIOSurface(p->pbuf);
for (每个平面 i)                                            // NV12 → 2 平面
    CGLTexImageIOSurface2D(ctx, GL_TEXTURE_RECTANGLE, internal_format,
                           IOSurfaceGetWidthOfPlane(surface, i), ...,
                           surface, i);                     // IOSurface 第 i 面 → 纹理，零拷贝
```

**Metal 路径** — `video/out/hwdec/hwdec_vt_pl.m:214-286`：

```objc
p->pbuf = (CVPixelBufferRef)mapper->src->planes[3];
for (每个平面 i)
    CVMetalTextureCacheCreateTextureFromImage(cache, p->pbuf, NULL, format,
                                              widthOfPlane, heightOfPlane, i,
                                              &mtl_planes[i]);               // 零拷贝
    MTLTexture tex = CVMetalTextureGetTexture(mtl_planes[i]);               // 交给 shader
```

共性：**NV12 拆成 Y(R8) + CbCr(RG8) 两个纹理分别绑**，YUV→RGB 在 fragment shader 一遍算完，CPU 全程不碰像素。

### 7.3 WorkLabs 现状对照

| 组件 | 是否直接绑纹理 | 说明 |
|---|---|---|
| `WLMediaSourcePreview.m:184-235` | ✅ **与 mpv Metal 路径完全相同** | `CVMetalTextureCacheCreateTextureFromImage` 双平面（Y=R8 / CbCr=RG8）+ shader YUV→RGB，实现正确。但 **canvas 不消费它**（预览走 `WLStreamPreview`），即 §6 待办③所指冗余件。 |
| `WLStreamPreview`（实际预览路径） | ✅ 系统内部零拷贝 | `AVSampleBufferDisplayLayer` 内部自行绑 IOSurface 纹理并上屏，无需手写。 |
| `WLVideoMix`（合成器） | ⚠️ 半零拷贝 | `CIImage imageWithCVPixelBuffer` + `CIContext render`：CoreImage 内部也走 IOSurface/Metal 纹理（非 CPU 拷贝），但额外背 CIContext / filter-graph / 中间纹理开销。 |

**IOSurface 前提（一个隐藏拷贝点）** — 零拷贝绑纹理要求 buffer 为 **IOSurface-backed**：

- VT 硬解帧 ✅（`frame->data[3]` 天然带 IOSurface）；
- `WLVideoMix` 输出 pool ✅（`ensurePool` 指定了 `kCVPixelBufferIOSurfacePropertiesKey`）；
- **软解帧 `WLMediaSource.m:420` `CVPixelBufferCreate(..., NULL, ...)` attrs 为 NULL → 非 IOSurface-backed** → 下游（CIImage / 绑纹理 / `AVSampleBufferDisplayLayer`）可能触发 CPU 拷贝。软解是 fallback、优先级低，但可一行修复（补 IOSurface 属性）。

### 7.4 应用价值与取舍

- **预览**：已零拷贝（系统代劳 + 一份未启用的手写范本），「直接绑纹理」无增量空间。
- **唯一增量价值 = 自研 Metal 合成器替换 `WLVideoMix` 的 CoreImage**（仅作用于录制/推流；预览侧已被优化①关掉合成）：
  - 输入：各路源 CVPixelBuffer → `CVMetalTextureCache` 绑纹理（读）；
  - 输出：画布 CVPixelBuffer 用 `CVMetalTextureCache` 反向绑成 **render target**（写），合成结果直接落进 IOSurface，再零拷贝给编码器；
  - 一个 shader 完成 YUV→RGB + 缩放 + 按 layout/z-order 叠加 + 背景，一遍过、零中间纹理；
  - **起点**：`WLMediaSourcePreview` 的绑纹理 + YUV→RGB shader 可升级复用 —— 与 §6 待办③「删除」构成两种取向：**删冗余 vs 升级为合成器内核**。
  - **代价**：多源叠加 / alpha / 缩放 / z-order / 背景这些 CoreImage 现成能力需自写 shader 与 pass 管理；收益仅限录制/推流。
- **低成本顺手项**：软解帧 `CVPixelBufferCreate` 加 IOSurface 属性，使软解路径也零拷贝。

### 7.5 小结

预览侧的零拷贝已吃满。「直接绑纹理」对 WorkLabs 的唯一增量价值在**自研 Metal 合成器替换 CoreImage** —— 中等工作量、收益限录制/推流场景。

---

## 8. 关键代码位置速查

### mpv（v0.41）

| 功能 | 位置 |
|---|---|
| 播放主循环 / 主循环 sleep | `player/playloop.c:1260` / `:54` / `:75` |
| Demux 线程 / 读包 / 唤醒 | `demux/demux.c:2661` / `:2262` / `:2759` |
| Demux 限流（字节/时长） | `demux/demux.c:141` / `:144` |
| 解码后帧队列（默认 1 帧） | `filters/f_async_queue.*`（`max_samples=1`） |
| 包零拷贝 / 包池 | `demux/packet.c:109` / `demux/packet_pool.c` |
| VT 硬解零拷贝（GL/Metal） | `video/out/hwdec/hwdec_mac_gl.c:92,114` / `hwdec_vt_pl.m:241` |
| YUV→RGB GPU shader | `video/out/gpu/video.c:2542` |
| VO 线程 / 精确等待 / 暂停 | `video/out/vo.c:1117` / `:714` / `:1225` |

### WorkLabs（本次核对）

| 功能 | 位置 |
|---|---|
| 硬解零拷贝取 CVPixelBuffer | `WLMediaSource.m:395-401` |
| 渲染线程 usleep 轮询 | `WLMediaSource.m:311,336,357,381` |
| 帧分发（Fork 1 预览 / Fork 2 合成） | `WLStreamsManager.m:335-341` |
| 合成开关（优化①） | `WLVideoMix.m:renderWithPts 入口` / `WLStreamsManager.m:setCompositingEnabled:` |
| 预览上屏（AVSampleBufferDisplayLayer） | `WLStreamPreview.m:80,145-185` |
| 录制/推流启停联动开关 | `WLStreamViewController.m:ensureEncoderRunning / stopEncoderIfIdle` |
