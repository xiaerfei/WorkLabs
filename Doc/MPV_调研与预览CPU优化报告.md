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
| **已实施③** | `WLMediaSource` 不再实例化无人消费的 `WLMediaSourcePreview`：省一套 Metal device/queue/cache/pipeline 的运行时创建。编译通过；类文件保留为未来自研 Metal 合成器的复用范本（见 §7.4）。 |
| **待办②** | 渲染线程改条件变量/绝对时间精确等待。 |
| **进行中④** | 抛弃 CoreImage 全面 Metal 化（触发：开镜像 CPU 11%→30%+）。**Phase 0 基础 + Phase 1 滤镜 + Phase 2 合成器均已完成、编译通过**；全工程已无 CoreImage 代码（仅余注释）。**仅剩运行时验证待实机**。详见 §9。 |

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
| ③ 冗余 Metal 管线 ✅已移除 | ~~`WLMediaSourcePreview` 建 device/queue/cache/pipeline 但 canvas 不消费~~ → 已停止实例化（见 §6.1） | — | 原 `WLMediaSource.m:95` |
| 线程数 | 5 线程/源 | 1 demux + 解码池 + VO + 主循环 | — |

---

## 4. 优化方案（按 ROI 排序）

**① 预览时停掉合成（最大收益，低风险）** — 已实施，见第 5 节。
**② 渲染线程改精确等待（中等收益，对齐 mpv）** — 待办，见第 6.2 节。
  `videoRenderThread` 的 `peek + usleep(10ms)` 轮询 → 用 `WLNodeQueue` 已有的 `deQueueWithTimeout:` 阻塞等待 + 按 pts 算绝对唤醒时刻，消除空闲期 ~100Hz 空唤醒。
**③ 删除冗余 `WLMediaSourcePreview` Metal 管线（小收益，省内存/初始化）** — 已实施，见第 6.1 节。
  canvas 不消费它（预览走 `WLStreamPreview`），`WLMediaSource` 已不再创建。

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

## 6. 优化②③：待办② + 已实施③

### 6.1 已实施：优化③ 删除冗余 Metal 管线

**改动清单（2 文件，4 处编辑；编译 `** BUILD SUCCEEDED **`）**

| 文件 | 改动 |
|---|---|
| `WLMediaSource.h` | 删 `#import "WLMediaSourcePreview.h"`；删 `@property (readonly) WLMediaSourcePreview *preview` |
| `WLMediaSource.m` | 删私有 `@property (readwrite) preview`；删 `initWithPath:` 内 `self.preview = [[WLMediaSourcePreview alloc] initWithFrame:NSZeroRect]` |

**为什么是死代码（删除前核对）**

- 全工程仅 `WLMediaSource.h:32`（声明）+ `WLMediaSource.m:53,95`（声明 + 创建）引用 `preview`，**无任何外部消费者读取** `source.preview`。
- `WLStreamViewController` 里加进 canvas 的 `preview` 是局部 `WLStreamPreview`（`AVSampleBufferDisplayLayer` 那条预览路径），与 `WLMediaSourcePreview` 同名但不同类、互不相关。
- 故 `WLMediaSourcePreview` 自创建起就只是被持有、从未上屏，其 `init` 里建的 Metal device / command queue / texture cache / render pipeline state 纯属空耗（每个媒体源一套）。

**收益与边界**

- 省掉**每个媒体源一套** Metal 管线的运行时创建与常驻内存；预览路径（`WLStreamPreview`）不受影响。
- 这是结构清理，非 CPU 主因，单源稳态 CPU 不会有 §5 那种可见跌幅；价值在去耦 + 省初始化/内存。

**为何保留 `.h/.m/.metal` 文件（只删实例化，不删类）**

`WLMediaSourcePreview` 的「`CVMetalTextureCacheCreateTextureFromImage` 双平面绑纹理 + YUV→RGB shader」与 mpv 的 Metal 硬解路径完全同构（见 §7.2/§7.3），是未来「自研 Metal 合成器替换 `WLVideoMix` CoreImage」（§7.4）的现成复用范本。删掉实例化即吃满本优化的运行时收益；保留文件留住这份范本。`project.yml` 的 `sources: WorkLabs` 仍会编译这几个文件，但**不再实例化 = 无运行时开销**，仅多一点编译产物。

### 6.2 待办：优化② 渲染线程精确等待（实施调研）

> 本节为**实施前调研**（不改代码）：核对现状空转点、约束边界、改造设计、风险与验证。

#### 6.2.1 现状与空转根因（`WLMediaSource.m`）

两个渲染线程都是「`peek`（不取出）看 pts → 判断到点否 → 没到就 `usleep`」结构：

```
videoRenderThread (while isVideoRendering)         WLMediaSource.m:296-339
  ├─ 循环顶无条件 if baseTime==0 → baseTime = now   :301-302   ← 见 6.2.2 关键点
  ├─ node = [queue peek]; if (!node) usleep(10ms)   :309-313   ← 队列空 100Hz 空转
  ├─ abs_pts = pts*1000 + baseTime                  :312
  ├─ 到点(abs_pts+offset < now)：deQueue→出帧→flush :314-328
  └─ 没到：usleep(min(waitMs, 50ms))                :329-336   ← 定时睡（合理），但 usleep 不能被新帧/stop 提前唤醒

audioRenderThread (while isAudioRendering)         WLMediaSource.m:345-384
  ├─ if baseTime==0 → usleep(10ms) continue         :348       ← 等 video 设基准，启动期 100Hz 空转
  ├─ node = [queue peek]; if (!node) usleep(10ms)   :356-360   ← 队列空 100Hz 空转
  └─ 余同 video（按 audioPtsOffset 节流）
```

空转点共 3 处，均为 100Hz：① 视频队列空、② 音频队列空、③ 音频等 `baseTime` 就绪。稳态有帧时走「定时 `usleep`」属正常节流、非空转，故 ② 的收益定位为**小～中等 + 结构对齐 mpv + stop 响应更快**，而非 §5 那种主因级跌幅。

#### 6.2.2 关键约束与边界（决定方案可行性）

| 约束 | 来源 | 对 ② 的意义 |
|---|---|---|
| **文件必含视频流 + 音频流**，否则源启动即失败 | `configureFFmpeg` 任一 `openXxxStream` 失败即 `return errorMsg` → `parseThread` return（`WLMediaSource.m:549-561`） | **必有视频帧** → `baseTime` 由 video 线程设定的假设安全，不存在「纯音频无人设 baseTime」的卡死 |
| **无 pause / seek / loop** | 全工程 grep 无命中 | 渲染线程只需「按 pts 出帧 → EOF 退出」，无需处理时钟重置/跳转，状态机极简 |
| **解码线程已用 `deQueueWithTimeout:30`** | `decodeFrame` EAGAIN 分支（`WLMediaSource.m:275`，注释「替代忙轮询，零 CPU」） | 项目内已有同款范本，渲染线程照搬即可，无需新增原语 |
| **stop / EOF 会 abort frame queue** | EOF：解码线程末尾 `videoRendering=NO` + `videoFrameQueue abort`（`:226-227`）；stop：`parseThread` 退出 → packetQueue abort → 解码退出 → frameQueue abort | 阻塞在 `deQueueWithTimeout` 上的渲染线程会被 abort 的 `cond_broadcast` **立即唤醒**返回 nil，无需额外停止信号 |
| `baseTime` 现于**循环顶、取帧前**无条件设 | `WLMediaSource.m:301-302` | 若改为「取出首帧后设」，基准 = 首帧真正可呈现时刻（更准），audio 相应等待，A/V 基准仍一致——属可接受的行为微调 |

#### 6.2.3 改造设计（伪代码）

核心：把「`peek` + `usleep` 轮询」换成「`deQueueWithTimeout` 阻塞取帧（队列空时挂条件变量，0 CPU）→ 取出后按 pts 分段睡到呈现时刻 → 出帧」。分段睡（每段 ≤ 20ms 并复检 `isRendering`）保留 stop 的及时性，替代原 `usleep(≤50ms)` 一次性睡。

```objc
// 视频
while (self.isVideoRendering) {
    WLNode *node = [self.videoFrameQueue deQueueWithTimeout:100];   // 空闲挂 cond；abort 立即返回 nil
    if (!node) continue;                                            // 超时/abort → 复检 while 条件
    Float64 now = CFAbsoluteTimeGetCurrent() * 1000;
    if (self.baseTime == 0) self.baseTime = now;                   // 首帧定基准（必有视频帧，见 6.2.2）
    Float64 target = node.pts * 1000 + self.baseTime + self.videoPtsOffset;
    Float64 wait;
    while ((wait = target - (CFAbsoluteTimeGetCurrent()*1000)) > 1 && self.isVideoRendering)
        usleep((useconds_t)(MIN(wait, 20) * 1000));                // 分段睡，stop 最迟 20ms 内响应
    CVPixelBufferRef pb = [self convertVideoFrame:node.frame];
    if (pb && _delegate) [_delegate source:self didOutputVideoFrame:pb pts:node.pts];
    else if (pb) CVPixelBufferRelease(pb);
    [node flush];
}

// 音频：同构，区别仅在 baseTime 未就绪时把帧放回队头短等（audio 队列 size=20，窗口很短）
while (self.isAudioRendering) {
    WLNode *node = [self.audioFrameQueue deQueueWithTimeout:100];
    if (!node) continue;
    if (self.baseTime == 0) { [self.audioFrameQueue requeueFront:node]; usleep(5*1000); continue; }
    ... target = pts*1000 + baseTime + audioPtsOffset; 分段睡; 出帧 ...
}
```

- 队列已有 `deQueueWithTimeout:`（`WLNodeQueue.m:101`）与 `requeueFront:`（`:129`），无需改队列。
- `baseTime` / `videoPtsOffset` / `audioPtsOffset` 语义与节流公式 `pts*1000 + baseTime + offset` **完全保留**。

#### 6.2.4 风险与回归点

| 风险 | 说明 | 缓解 |
|---|---|---|
| A/V 同步 | `baseTime` 设定点从「循环顶」移到「取出首帧后」，基准时刻略有变化 | 仍由 video 设、audio 共享同一基准；公式不变。回归：录一段含明显口型/拍点的素材，肉眼对齐 |
| stop 响应延迟 | 取出帧后若 `wait` 很大，持帧睡眠期间若不复检会延迟退出 | 分段睡（≤20ms）每段复检 `isRendering`；且 frameQueue abort 不影响已取出的帧——分段睡是兜底 |
| 持帧睡眠占队列槽 | 取出后才睡 vs 原 peek 不取出，视频队列(size=4)空出 1 槽 | 解码可多塞 1 帧，无本质差异；音频 size=20 充裕 |
| EOF 残帧丢弃 | 现状 EOF 即 `rendering=NO`，队列残帧被丢——此行为**不变**（不在 ② 范围内修） | 如需「放完再停」是独立改动，调研标注、暂不动 |

#### 6.2.5 验证方法

1. **CPU**：Activity Monitor 下单源预览，对比改造前后；重点看「解码慢/接近 EOF/启动期」是否还有 100Hz 空唤醒（可用 `sample` 抓 `wl-render-*` 线程栈）。
2. **功能回归**：播放流畅度、A/V 同步、录制 mp4 时长与音画一致、stop/切源即时无卡顿。
3. **退出链路**：start→stop 反复多次，确认渲染线程能被 frameQueue abort 即时唤醒退出，无泄漏（线程名 `com.wl-render-video/audio.thread`）。

> 既有约束副记：**文件须同时含音视频流**，否则当前 `configureFFmpeg` 直接失败（纯视频/纯音频文件均不支持）——属项目已知限制，非本优化范围。

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
| `WLMediaSourcePreview.m:184-235` | ✅ **与 mpv Metal 路径完全相同** | `CVMetalTextureCacheCreateTextureFromImage` 双平面（Y=R8 / CbCr=RG8）+ shader YUV→RGB，实现正确。**canvas 不消费它**（预览走 `WLStreamPreview`）——§6.1 已停止实例化（去运行时开销），文件保留作 §7.4 复用范本。 |
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
  - **起点**：`WLMediaSourcePreview` 的绑纹理 + YUV→RGB shader 可升级复用。§6.1 已停掉它的实例化（去运行时开销）但**特意保留类文件**，正是为此留种——「删冗余实例化 vs 升级为合成器内核」两种取向可并存：先省开销，未来再以它为起点扩成合成器。
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
| 删冗余 Metal 管线（优化③） | `WLMediaSource.h`（删 import + preview 属性）/ `WLMediaSource.m`（删私有属性 + `initWithPath:` 实例化） |
| 预览上屏（AVSampleBufferDisplayLayer） | `WLStreamPreview.m:80,145-185` |
| 录制/推流启停联动开关 | `WLStreamViewController.m:ensureEncoderRunning / stopEncoderIfIdle` |

---

## 9. 实施：抛弃 CoreImage，全面改用 Metal（代码完成，待运行时验证）

> **触发**：§7.4 判断「自研 Metal 合成器是唯一增量价值」+ 用户实测「开镜像滤镜单源预览 CPU 11% → 30%+」。
> **根因**：镜像走 `WLBasicVideoFilter` 的 **CoreImage 逐帧 `ciContext render`**，且该滤镜挂在数据流 **fork 之前**（`WLStreamsManager.m:332-347`），输出同时喂预览(`:343`)与合成(`:347`)——即使纯预览（优化①已关合成空转），滤镜的 CoreImage render 仍每帧强制跑，绕不过去。镜像/颜色/裁剪本身在 GPU 上近乎免费，30% 全在 CoreImage 的 `CIImage 包装 → filter-graph → CIContext render` 逐帧固定成本上。
> **决策**：移除两处 CoreImage（滤镜 `WLBasicVideoFilter` + 合成器 `WLVideoMix`），全部改 Metal 离屏渲染到 IOSurface-backed CVPixelBuffer。① 分阶段：先滤镜（解当前痛点）后合成；② 颜色基准对齐现有逐源预览（`WLMediaSourcePreview`，BT.601 + 标准颜色校正公式），不追求与旧 CoreImage 像素级一致。完整方案：`~/.claude/plans/sunny-yawning-plum.md`。

### 9.1 已完成：Phase 0（共享基础）+ Phase 1（滤镜）— 编译 `** BUILD SUCCEEDED **`

| 文件 | 改动 |
|---|---|
| `Source/MediaFile/WLMetalShaderTypes.h`（新） | `.metal`/`.m` 共享的 `WLFilterParams`（纯 C，全 4 字节标量，布局逐字节一致） |
| `Common/WLMetalContext.{h,m}`（新） | 共享单例：device/commandQueue/library + pipeline 缓存(按 fragment名+blend)；`newTextureCache`（带 `RenderTarget\|ShaderRead` usage）；`bindSampling`（NV12双平面/BGRA/RGBA + range 检测）；`bindRenderTarget`（BGRA8Unorm plane0）；`WLMetalTextureBinding` 持 `CVMetalTextureRef` 生命周期 |
| `Source/MediaFile/WLMetalPreviewShaders.metal` | 新增 `filterFragment`：镜像(翻 uv) + 裁剪(remap uv，`v∈[cropTop,1-cropBottom]`) + YUV→RGB(601, full/video) + 颜色校正(sat→contrast→bright, 709 luma) + hue(YIQ 旋转)，复用现有 `vertexShader` |
| `Filter/WLBasicVideoFilter.m` | 移除 CoreImage；改 Metal 离屏渲染：取裁剪后尺寸输出 buffer → 绑输入/输出 → 一个 draw → `commit + waitUntilCompleted` → 返回(`CF_RETURNS_RETAINED`)。`isIdentity` 透传与「裁剪改输出尺寸」语义保留；Metal 不可用时降级透传 |
| `Source/MediaFile/WLMediaSource.m` | 软解帧 `CVPixelBufferCreate` 补 `IOSurface + MetalCompatibility` attrs（否则软解帧绑 Metal 纹理失败；顺带软解预览零拷贝） |

**关键正确性点**（经独立设计验证）：
- **同步必须 `waitUntilCompleted`**：`WLEncoder.m:283-297` 对输出 buffer `CVPixelBufferLockBaseAddress(ReadOnly)` + `sws_scale` **CPU 读**，预览也消费同一 buffer；`commit` 后须等 GPU 完成再交下游，`waitUntilScheduled` 不够。
- **颜色不偏暗**：输出用 `MTLPixelFormatBGRA8Unorm`（**非 `_sRGB`**）—— YUV→RGB 得到的是 gamma-encoded R'G'B'，passthrough 写入即与旧 CoreImage 显式 sRGB 输出等价；用 `_sRGB` 会二次编码致过亮。
- **`CVMetalTextureCache` 非线程安全** → 每个渲染对象各持一份，只在自己串行队列用；device/queue/library/pipeline 才共享。

### 9.2 实现中纠正/发现

- `WLMediaSourcePreview.m:188-200` 的绑纹理范本里 `height=0` / `planeIndex=0`（Y 与 CbCr 都传 0）**参数可疑**（CbCr 应 planeIndex=1）——因该 view 从不被消费，bug 未暴露。`WLMetalContext.bindSampling` **未照搬**，改用 `CVPixelBufferGetWidthOfPlane/HeightOfPlane` 真实宽高 + 正确 planeIndex(0/1)。
- 编译期命名冲突：command buffer 变量 `cb` 与裁剪局部 `cb`(cropBottom) 撞名 → 改 `cmdBuf`（已修）。
- **内存暴涨 1GB（运行时实测，已修）**：添加本地视频流后开颜色校正 / 镜像滤镜，内存几秒飙到 1GB+。**根因**：`processVideoFrame:`（在 `WLMediaSource.videoRenderThread` while 循环里调用，该循环**无 per-frame `@autoreleasepool`**）/ `renderWithPts:` 每帧创建的 `MTLCommandBuffer` 是 autoreleased 对象，而 **command buffer 会持有它引用的输入/输出纹理 → 进而持有 CVPixelBuffer 的 IOSurface 像素内存**，直到自身释放；无 pool 排空则每帧累积（~11MB/帧，30fps 数秒到 1GB）。透传路径（`isIdentity`）不建任何 Metal 对象，故**仅开滤镜时暴露**；旧 CoreImage 由 `CIContext` 内部管理、不产生长持有的 autoreleased command buffer，故无此问题。**修复**：`WLBasicVideoFilter.processVideoFrame:` 与 `WLVideoMix.renderWithPts:` 的 Metal 工作整体包 `@autoreleasepool`（在 `waitUntilCompleted` 后排空，GPU 已完成、安全），每帧确定性释放 command buffer 及其持有的纹理 / IOSurface。`videoRenderThread` 循环本身加 per-frame pool 是可选的根本加固，但 filter/mix 内部包裹已覆盖全部 Metal 调用路径（含摄像头采集队列）。
- **裁剪内存尖峰 200MB→700MB→200MB（运行时实测，已修）**：拖动时内存瞬时尖峰后**立即回落**（**非泄漏**）。
  - **先误诊为 pool 重建**：裁剪改输出尺寸 → `acquirePixelBufferWidth:height:` 每帧重建 pool、旧 pool buffer 飞行堆积。据此加了「输出尺寸量化到 16」，但**实测尖峰依旧** —— 假设被证伪。
  - **真正根因**：`WLStreamPreview.enqueueSampleBuffer:` 每帧 `dispatch_async(主队列)` 投递 enqueue，每个 block `CFRetain` 一帧 sample buffer（持有 filter pool 输出 buffer）。拖动（裁剪滑块 / 缩放 / 移动浮层）时**主线程被鼠标事件占满**，这些 block 在主队列积压不执行，而渲染线程仍 30/60fps 持续投递 → 数十帧堆积成尖峰；松手后主线程瞬间清空积压 → 立即回落（这「瞬间回落」正是主线程积压的指纹，pool 假设解释不了）。
  - **修复**：`enqueueSampleBuffer:` 加**丢帧背压**（`atomic_int _pendingEnqueues` 在途计数，旧值 ≥2 即丢弃当前帧）—— 预览本就应跟不上时丢帧而非积压，限制在途 ≤2 帧即彻底削平尖峰。预览丢帧无害，且**不影响录制**（录制走 mix 的 Fork 2，与预览 Fork 1 独立）。
  - 输出尺寸量化到 16 作为减少 pool churn 的**辅助优化**保留（拖动裁剪时少 create/release pool；副作用裁剪精度 ±8px，显示侧缩放无感）。
- **裁剪内存随比例升降 200↔400MB（运行时实测，已修）**：稳态下内存与「当前裁剪后帧尺寸」成正比且稳定（0% / 30% 大帧 ≈400MB，45% 小帧 ≈200MB）。这与上面的拖动尖峰是**两个独立问题**：尖峰是拖动期间主队列 dispatch 积压（背压已修），本条是稳态下持有了固定帧数、尺寸随裁剪变的一批帧。**根因**：`WLStreamPreview.createSampleBufferFromPixelBuffer:` 给每帧打 `presentationTimeStamp`（媒体 pts）却未声明「立即显示」，`AVSampleBufferDisplayLayer` 据此**按 pts 缓冲一整窗口（≈1s、数十帧）等待呈现** → 持有帧数恒定、单帧尺寸随裁剪变，故内存 ∝ 帧尺寸且稳定（几十帧 × 全尺寸 8MB ≈ 数百 MB，正好对上量级）。背压只挡主队列 dispatch、挡不住 layer 内部这个队列，故为独立现象。**修复**：sample buffer 打 `kCMSampleAttachmentKey_DisplayImmediately` —— 渲染线程已按 pts 把出帧节流到实时，预览只需「来一帧显一帧」，layer 队列即降到 ~1 帧、内存与裁剪比例解耦。无副作用（实时节流在上游，呈现时机不变）。

### 9.3 已完成：Phase 2（合成器 `WLVideoMix`）— 编译 `** BUILD SUCCEEDED **`

| 文件 | 改动 |
|---|---|
| `Mix/WLVideoMix.m` | 移除 CoreImage（`CIContext`/`CIImage`/`CIColor`）；改 Metal 离屏：共享 `WLMetalContext` + 自有 `CVMetalTextureCacheRef` + `fragmentShader`(blending) pipeline。`renderWithPts:` 单 render pass：`loadAction=Clear` 背景色铺底 → 背景图全屏 quad（`MTKTextureLoader` NSImage→MTLTexture，`SRGB:NO`）→ 按 `streamOrder` 各源 quad（layout 左下原点→NDC **y 不翻**、翻转在 texCoord v、alpha blend、逐源 YUV/BGRA+range）→ `commit + waitUntilCompleted` → `output(out,pts)`。pool 补 `MetalCompatibility`。公开接口 / 契约 / 节流 / `renderingEnabled` / 铺底防残影全保留，`WLStreamsManager` fork 点零改动。 |

**关键正确性点**：
- **坐标**：layout 左下原点像素 → `ndcB=y/H*2-1`（**y 不翻**），texCoord 底 v=1 / 顶 v=0（源纹理 row0=顶），方向正立；全画布 layout→NDC `[-1,1]²`、左下 1/4→左下象限，校验通过。
- **颜色**：pipeline 与 render target 均 `BGRA8Unorm`（非 `_sRGB`）；clearColor 用 sRGB gamma 分量直写、背景图 `SRGB:NO` —— 同处 gamma 域、与源 YUV→RGB 输出一致、不偏暗（同 Phase 1 结论）。
- **同步 / 生命周期**：`waitUntilCompleted` 后才交下游（编码器 CPU swscale 读同一 buffer）；输入 binding 收进数组持有至 GPU 完成后释放；`fragmentShader` 的 `texture(1)` 在 BGRA 分支绑占位纹理（满足绑定校验，shader 不采样）。
- **全工程脱离 CoreImage**：Phase 1 移滤镜 + Phase 2 移合成器后，`grep CoreImage` 仅余注释，无任何 CI* 实际调用。§7.5 判断的「自研 Metal 合成器替换 CoreImage」增量价值至此落地。

**运行时验证（Phase 1+2，待实机）**：
- **Phase 1（滤镜）**：开镜像 CPU 应从 30%+ 回落到接近无滤镜（十几%）；**内存平稳不暴涨**（验 §9.2 autoreleasepool 修复，开滤镜后内存应稳定在正常水位、不随时间爬升）；isIdentity 等于透传基线；镜像方向 / 裁剪边 / 颜色观感对齐逐源预览且不偏暗；软解文件开滤镜不黑屏。
- **Phase 2（合成器，仅录制 / 推流路径生效；纯预览被优化①关闭合成）**：z-order 遮挡、各源画布位置 / 缩放、背景色 + 背景图正确；拖动时 60fps 节流不出陈帧；录制 mp4 逐帧无上下颠倒 / 撕裂（验 NDC y 方向 + `waitUntilCompleted`）；camera + media 同时录制；start/stop 反复无泄漏（CVMetalTexture 包装 + 输出 buffer 引用计数）。

### 9.4 注意事项：`xcodegen generate` + `pod install` 后 IDE 需手动刷新

新增源文件后跑了 `xcodegen generate`（重写 `.xcodeproj`）+ `pod install`（重集成 workspace）。`use_frameworks!` 下 `#import "TPCircularBuffer.h"` 等 pod 头靠 `HEADER_SEARCH_PATHS → ${PODS_CONFIGURATION_BUILD_DIR}/*.framework/Headers` 解析，**前提是该 framework 已构建**。命令行 `xcodebuild` 带依赖顺序会先构建、故 `clean build` 已验证 `BUILD SUCCEEDED`；但 Xcode IDE 若状态陈旧或误开 `.xcodeproj`（而非 `.xcworkspace`）会报 `'TPCircularBuffer.h' file not found`。**处理**：确认打开 `WorkLabs.xcworkspace` → `Product → Clean Build Folder (⇧⌘K)` → 重新 Build；必要时关闭重开 workspace 或删 `~/Library/Developer/Xcode/DerivedData/WorkLabs-*`。
