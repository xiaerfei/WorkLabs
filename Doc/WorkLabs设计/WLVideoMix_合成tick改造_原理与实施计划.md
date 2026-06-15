# WLVideoMix 合成 tick 改造：原理与实施计划

> **性质**：架构改造设计 + 分阶段实施计划（基于**当前代码** WLVideoMix / WLStreamsManager / WLMediaSource，非宏观愿景）。
> **日期**：2026-06-09
> **涉及文件**：`WorkLabs/Mix/WLVideoMix.m`（主战场）、`WorkLabs/Core/WLStreamsManager.m`（fork 不动）、`WorkLabs/Source/MediaFile/WLMediaSource.m`（节流即「生产层」，不动）、`WorkLabs/Output/WLRecorder.m`（CFR 兼容，不动）。
> **取经来源**：`Doc/调研/OBS/OBS_源异步帧缓冲与时间戳节流.md`（`ready_async_frame`/`get_closest_frame` 源码级）、`Doc/调研/OBS/OBS_合成tick_音频混音_AV同步.md`。
> **宏观愿景对照**：`Doc/WorkLabs设计/OBS架构设计.md`（WLScene/WLSceneRenderer 全新命名的远期蓝图；本篇是当前代码上的渐进落地）。

---

## 0. 一句话与目标

WorkLabs 是**合成器**（多源合到一张画布、live 预览、录制/推流）。当前 `WLVideoMix` 是**「输入事件驱动」**合成——哪个源来帧就触发一次合成。要转成 OBS 式的**「固定节拍 tick 驱动」**——合成线程按固定 fps 主动拉取各源当前帧、统一输出。

**这么改的根本动机**：合成器没有哪一路源天然是「主」，唯一公平的基准是系统单调时钟；让一个固定节拍统一拉取，才能解决「多源 fps 不一致」「输出 pts 不统一」「静止时无帧」三个问题（§1）。范式依据见附录 A（mpv vs OBS）。

---

## 1. 现状：push（输入事件驱动）模型

```
源 render 线程(已按 baseTime 自节流) ──didOutputVideoFrame:pts──► WLStreamsManager
   ├─ Fork1: preview.receiveVideoFrame        (每源预览，push 直出)
   └─ Fork2: mix.inputVideoFrame:pts:sid ──► WLVideoMix.serialQueue:
         更新 latestFrames[sid] → renderWithPts:pts → [60fps 最小间隔节流] → Metal 合成 → output(pb, pts)
                                                                                              │
                                                                          mixedFrameOutput ──► WLRecorder / 推流
```

合成被 **6 个地方**触发，全都 `→ renderWithPts:`：`inputVideoFrame:`（每源帧）、`setLayoutFrame:`、`setBackgroundColor:`、`setBackgroundImage:`、`setStreamOrder:`、`updateCanvasSize:`（`WLVideoMix.m:134~193`）。节流在 `renderWithPts:` 内（`WLVideoMix.m:220-222`）：`if (now - lastRenderTime < minRenderInterval) return;`（默认 60fps 上限）。

**三个结构性问题：**

1. **输出 pts = 恰好触发这次合成的那个源帧的 pts**（`renderWithPts:` 的入参直接透传到 `output(pb, pts)`）。多源时，谁的帧没被节流掉就用谁的 pts → pts 来源不统一、抖动跳变。
2. **没有源帧就不产帧**（静止画面、源卡顿）→ 输出不是 CFR，录制时间轴可能有洞。
3. **双重节流语义重叠**：源自己按 `baseTime` 节流一次（按 pts 出帧），mix 再按 60fps 最小间隔节流一次，两套节奏互不同步 → 拍频（judder，见 §3）。

---

## 2. 目标：tick（固定节拍拉取）模型

一个**固定 fps 的合成线程主动 tick**；每 tick 从各源缓冲取当前帧合成，**输出 pts = tick 自己的时钟刻度**（统一时钟）；源只投帧进缓冲，不再触发合成。

**收益：**
- **多源对齐**：所有源在同一 tick 时刻被一起合成、共享同一 pts → 天然对齐到同一时间轴。
- **CFR**：静止也持续产帧 → 录制/推流时间戳规整。
- **解耦**：合成节奏与源节奏分离，源 fps 各异不影响输出节拍（§3）。

---

## 3. 核心原理：fps 不一致怎么被「吸收」

### 3.1 大白话

每个源是一本**不停翻页的画册**，翻页速度 = 它的 fps。合成器是一个**按固定鼓点拍照的人**（鼓点 = 合成帧率）。鼓点一响，就瞄一眼每本画册「现在停在哪一页」，把那页拍下来凑成合影。

- **翻得慢的源**：鼓点响好几次它还停在同一页 → 那页被拍好几张（**重复**）。
- **翻得快的源**：两个鼓点之间它翻过去好几页 → 中间几页没人拍（**跳过**）。

因为**所有源被同一个鼓点同时拍**，每张合影里每个源都是「这一刻它该停的那页」，所以 fps 再千差万别，合出来照样对齐。**谁也不用改自己的速度去迁就别人。**

### 3.2 OBS 的精确做法：每源一个「虚拟时钟」

难点：`frame.timestamp`（源 pts 轴）和 `sys_time`（系统钟轴）**不同基准、没法直接比**。OBS 的技巧是给每源一个虚拟时钟 `last_frame_ts`，它处在**源 pts 轴**上，但**用系统钟的流速推进**（`ready_async_frame`，源码级见调研文档 §2.4）：

```
每源维护: last_frame_ts(虚拟时钟,在源pts轴), last_sys_ts(上次tick系统时刻)
每个 tick(系统时刻 sys_now):
    sys_offset = sys_now - last_sys_ts          // ① 这次 tick 真实流逝(≈合成帧间隔)
    last_frame_ts += sys_offset                 // ② ★ 虚拟钟按"系统钟的速度"在源轴上前进
    while (队头帧 && last_frame_ts > 队头帧.pts):    // ③ 虚拟钟已走过队头 → 它到点/过期
        if (已选过帧 && last_frame_ts - 队头.pts < 2ms): break   // 平滑:不为绝对精确多丢一帧
        出队/丢弃队头
    当前显示帧 = 队头                            // 虚拟钟还没越过的第一帧
    last_sys_ts = sys_now
```

② 是灵魂：把系统钟的流速映射到源时间轴，于是「现在该显示哪帧」变成同一根（源）轴上的简单比大小。

### 3.3 三类情况如何被吸收

| 场景 | 帧间隔 vs tick 间隔 | 每 tick 行为（③ 循环） | 效果 |
|---|---|---|---|
| **慢源**(24fps / 60 tick) | 42ms > 16ms | 多数 tick 虚拟钟没越过队头 → 不出队 | **同帧重复** ~2–3 tick |
| **快源**(120fps / 60 tick) | 8ms < 16ms | 每 tick 虚拟钟越过 ~2 帧 → while 丢 1 取 1 | **抽帧**(2 选 1) |
| **掉帧追赶**(某 tick 卡顿) | sys_offset 变大 | 虚拟钟一次跳很多 → 连续丢帧 | **自动追上**，不累积延迟 |
| **多源各异** | 各源帧间隔不同 | **共用同一个 sys_offset** 推进各自虚拟钟 | 全部锚到同一系统钟 → **天然同步** |

最后一行是关键：多源 fps 再不一样，都用**同一 tick 的 sys_offset** 推进各自虚拟钟，等于都对齐到同一根墙钟。

### 3.4 工程细节（均从 OBS 源码核实）

- **2ms 平滑阈值**：虚拟钟仅超前队头不到 2ms 就停止丢帧——宁可显示一帧「早 2ms 以内」的，也不在帧边界多丢造成顿挫。精确 vs 平滑的折中。
- **`MAX_TS_VAR = 2s` 跳变重锚**：帧 pts 暴涨 >2s（seek、流不连续）→ 重锚虚拟钟，不当正常推进。
- **`MAX_ASYNC_FRAMES = 30` + 冷启动哨兵**：缓冲堆到 30 帧 → 整池清空 + `last_frame_ts=0`；下一帧立即显示并用其 pts 重锚。这正是 seek/loop 重建时间基准的合成器做法。

### 3.5 观众能感知到吗？

- **大多数情况感知不到**：慢源重复 → 观众看到的还是它原本的流畅度（24fps 电影还是电影感，30fps 摄像头够顺）；快源抽帧 → 30fps 合成对直播够用。
- **少数会轻微露馅 = judder（一顿一顿）**：仅在**匀速横移画面**（平摇、滚动字幕、横向运动）+ 低 fps 源进高 fps 合成时（3:2 不均匀重复）。静止/慢动作看不出。阶段一（取最新帧）抖得更明显；阶段二（虚拟钟选帧）能压到**和正常播放器一样**的水平。
- **最关键、最反直觉**：观众眼睛对「视频帧重复/跳过」很迟钝（几十 ms 视频错位无感），真正一秒被发现的是**音画不同步**（嘴型对不上，差 100ms 就难受）。**所以 fps 吸收的 judder 不是大事；要死守的是音画同步 + 合成帧率别设太低。**

---

## 4. 关键认知：两层分工（生产节流 vs 消费选帧）

OBS 的本地媒体源其实是**两层节流，分工不重复**——这厘清了「我们刚做的 WLMediaSource 节流在新架构里的命运」：

| 层 | 职责 | OBS | WorkLabs 对应 |
|---|---|---|---|
| **生产层** | 控制解码推进速度，别一口气解码完塞爆缓冲（背压） | `media-playback` 按 pts `sleepto` | **正是已做好的 WLMediaSource `baseTime` 节流** ✅（见 `WLMediaSource_渲染节流改造与时间戳锚定陷阱.md`） |
| **消费层** | 把不同 fps 的源对齐到合成 fps（选帧） | `obs_source` async tick + 虚拟时钟 | **要新增的 WLVideoMix tick 选帧**（本计划阶段二） |

**结论：我们刚做的 render 节流改造不会白费**——它对应 OBS 生产层（让源大致按实时速度投帧、做背压）。tick 选帧是另一层。两层都要：源管「以正常速度产出帧」，mix 管「这一刻每源露哪帧、怎么对齐」。pts 归一化（start_time / NOPTS / isfinite / int64 防护）在新架构里**仍然必需**（投进缓冲的帧必须带正确归一化 pts）。

---

## 5. 实施计划（分阶段）

### 阶段一：push → tick 框架（取 latestFrames 最新帧）

改动集中在 **WLVideoMix 一个文件**：

| 改动 | 说明 |
|---|---|
| `inputVideoFrame:` **删末尾 `renderWithPts`** | 只更新 `latestFrames`/`streamOrder`，不再触发合成 |
| `setLayoutFrame`/`setBg*`/`setStreamOrder`/`updateCanvasSize` **删 `renderWithPts`** | 只更新缓存，下个 tick 自然生效（layout 变化最多延迟 1 tick ≈16ms，无感） |
| **新增 tick 驱动** | 专用线程睡到绝对单调时刻 `tickEpoch + n·interval`（复用 `wl_mono` 基础设施，不漂）；每 tick `dispatch` 到 serialQueue 调 `renderTick` |
| `renderWithPts:` → 拆出 `renderComposite:` | 合成+输出主体不变，pts 由 tick 给 |
| **删 `minRenderInterval` 最小间隔节流** | 被 tick 间隔取代；`setRenderFrameRate:` 改成设 tick interval |
| `renderingEnabled` 切换 | enable 启动 tick 线程，disable 停止（纯预览不录制时 tick 不跑，零空转，保留当前语义） |

本质：把「6 处调 renderWithPts」收敛成「一个 tick 调 renderComposite」。`WLStreamsManager` / `WLMediaSource` / preview / WLRecorder **全不动**。

- **收益**：立刻拿到「统一 pts + CFR 输出 + 多源同时刻合成」。
- **局限**：取最新帧、无虚拟钟 → 源投递节奏与 tick 采样拍频 → judder（§3.5）。适合先把框架跑通。
- **状态**：✅ **已落地**（commit 141507f，实机验证 OK）。实现用 `dispatch_source_timer` 挂 serialQueue（非专用线程，weak self 更安全），输出 pts 用理论累加 `ptsAccum`（改帧率仍连续）。

### 阶段二：每源 async 缓冲 + 虚拟时钟选帧（根治 fps judder）

> **状态**：✅ **已落地**（commit `2403c1e` 缓冲+虚拟钟选帧、`977c086` 每秒观测埋点；实机验证 OK）。
> **代码逐段对照 + 为什么这样设计：见 [§8 阶段二落地实现详解](#8-阶段二落地实现详解代码用了哪些设计为什么这样设计)。** 本节是当初的实施计划口吻，保留备查；§8 是落地后的实现真相。

把 §3.2 的 OBS 算法搬进 WLVideoMix。下面是落地级的大白话讲解 + 数据结构 + 改动清单。

#### 大白话：托盘 + 指针

> 每个源 = 一摞**贴了时间标签**（pts）的照片，按时间排好放在各自的**小托盘**里（不再只留一张）。
> 合成器 = 墙上一个**统一的大钟** + 拍照的人。每个托盘边插一根**小指针**（= 该源的虚拟时钟）。

每次 tick（拍照），拍照的人做三件事：
1. **看墙钟**：距上次拍过了多久（实测，比如 16ms）。
2. **推指针**：把**每个**托盘的小指针都往前推这 16ms（所有源用同一步长 → 步调一致 → 自动对齐）。
3. **挑照片**：每个托盘里，指针已**越过**的旧照片丢掉，露出"指针还没越过的第一张"——那就是这一刻该显示的。

慢源例子（源 25fps＝每 40ms 一张：A@0 B@40 C@80…，tick 60fps＝每 16ms）：

| tick | 指针 | 挑谁 | 结果 |
|---|---|---|---|
| 1 | 0ms | A(0) | 露 A |
| 2 | 16ms | 没越过 B(40) | 还露 **A**（重复） |
| 3 | 32ms | 没越过 B(40) | 还露 **A**（重复） |
| 4 | 48ms | 越过 B(40) | 露 B |
| 5 | 64ms | 没越过 C(80) | 还露 **B**（重复） |

A 露 3 次、B 露 2 次……重复发生在**精确该重复的时刻**（按时间标签），不是阶段一的碰运气。快源反过来：指针一次跨过几张，中间的丢掉（抽帧）。

#### 四种特殊情况（都是 OBS 的招）

- **指针差一丁点（<2ms）就够到下一张**：别急着翻，显示当前这张——免得在照片边界反复纠结造成顿挫（"精确 vs 平滑"折中）。
- **下一张时间标签突然跳了 >2 秒**：不是正常播放（多半 seek）→ 别一张张翻过去，直接把指针重设到那张的时间重新对齐（重锚）。
- **托盘堆爆（攒到 30 张还没拍）**：拍照长期跟不上 → 整盘倒掉、指针清零；下一张直接露 + 用它时间重设指针（冷启动）。
- **刚开始放 / 刚倒过盘**：第一张直接露，用它的时间作为指针起点（冷启动）。

#### 数据结构升级（WLVideoMix 内部）

```
latestFrames[sid]  : 每源 1 帧（裸 CVPixelBufferRef）             （阶段一）
        ↓ 升级为
asyncFrames[sid]   : 每源 FIFO 队列，元素 = WLMixFrame{pixelBuffer, pts}   （托盘）
curFrames[sid]     : 每源当前显示帧 WLMixFrame*（慢源重复时仍有帧合成）
lastFrameTs[sid]   : 每源虚拟时钟（秒，nil = 冷启动待锚）           （指针）
lastSysTs          : 全局，上次 tick 实测系统时刻（算 sys_offset 用）
```

- 新增内部小类 **`WLMixFrame`**（持有 retain 的 pixelBuffer，dealloc 里 release）→ 队列/字典的 retain/release 全交给 ARC，反而比阶段一手动管 latestFrames 更干净。

#### 改动清单

| 改动 | 阶段一 | 阶段二 |
|---|---|---|
| `inputVideoFrame:pts:` | 覆盖 `latestFrames[sid]`、**忽略 pts** | 把 `WLMixFrame{pb,pts}` **入队尾**；队满（≥30）先清空 + 标记冷启动（**重新用起 pts**） |
| 选帧 | 无（直接取最新） | 新增 `selectFramesForTick`：实测 now 算 sys_offset、推进各源 `lastFrameTs`、丢过期帧、定 `curFrames[sid]`（含 2ms 平滑 / >2s 重锚 / 冷启动） |
| `renderComposite:` 合成循环 | 取 `latestFrames[sid]` | 先 `selectFramesForTick`，再取 `curFrames[sid].pixelBuffer` 合成 |
| `removeStreamID:` / dealloc | 手动 release latestFrames | 清 asyncFrames/curFrames/lastFrameTs（ARC 自动 release pb，dealloc 手动段简化） |
| 单调钟 | 无（删了 mach） | 加 `wl_mono_now_ns`（`CLOCK_UPTIME_RAW`，与 WLMediaSource 一致） |

> **选帧用实测时钟，输出 pts 仍用理论值**：`selectFramesForTick` 的 sys_offset 用实测 now（反映真实流逝，掉帧时多推进、自动追帧）；而 `output(pb, pts)` 的 pts 仍是 tick 理论累加 `ptsAccum`（严格 CFR）。两者分工，不矛盾。

#### 一个要注意的点（否则阶段二白费）

托盘里得**常备 2~3 张**照片，指针才挑得动。若生产层（WLMediaSource）卡着点每张刚好到点才投一张，托盘随时只有 0~1 张，等于退回阶段一。所以阶段二要配合：**生产层投帧略提前一丢丢、留一点缓冲**（OBS 的做法：源略超前生产、合成端虚拟钟精确挑）。这呼应 §4 两层分工——源管"多备点货"，mix 管"这一刻挑哪张"。

#### 工作量 / 风险

- 核心就 `selectFramesForTick` 一段（OBS `ready_async_frame` 的简化版，几十行），`Doc/调研/OBS/OBS_源异步帧缓冲与时间戳节流.md §2.4` 有逐行源码可照搬。
- 比阶段一大：数据结构「一张→一队列」，CVPixelBuffer 在队列里的 retain/release 配平（用 `WLMixFrame` + ARC 兜住）。
- 有阶段一打底：tick 框架 / renderComposite / 启停现成，阶段二只换「挑哪张」+ 数据结构。

### 阶段三：录制带音频的 A/V 同步（接 AAC mux 时）✅ 已落地

> ✅ **已落地（2026-06-15 核对）**：带音频录制（AAC `aac_at`）+ 音视频同步已实现（TaskNewPlan v0.14 起）；视频帧时间戳改用单调墙钟、a/v 共享同一 `_baseUs`（首视频帧 pts）公共零点，麦克风录制无声、音频断流补静音漂移均已实测通过。本节为当初的实施设想，结论与落地一致，保留备查。

按 OBS `timing_adjust = wallclock − 源pts` 把每源音频 pts 归一到**同一单调钟**；视频帧 + 音频包都带该钟时间戳交 muxer interleave。**不要 video 追 audio**（合成器范式）。WLRecorder 已用同一 `_baseUs`（首视频帧 pts）做 a/v 公共零点（`WLRecorder.m:25/155/192/205`），正好契合——音视频必须共享同一零点，否则音画错位。

---

## 6. 决策点（已定，落地结论）

1. **落地顺序** → **已定：分两步走**。先 `141507f` 落阶段一（取最新帧）跑通 tick 框架，再 `2403c1e` 落阶段二（缓冲+虚拟钟）。事实证明数据结构「一张→一队列」是增量替换，没返工。
2. **tick 时钟 / pts** → **已定但与原推荐有出入**：pts 确实用**理论累加值**（`ptsAccum += tickInterval`，严格 CFR，见 §8.B）；但 tick **没有用专用线程**，而是 `dispatch_source_timer` 挂在合成 `serialQueue` 上（weak self 更安全、与所有状态访问同队列免锁、leeway 省电）。理论 pts 不依赖线程定时精度，故 timer jitter 不进时间戳。理由详见 §8.B 与 §8.H。
3. **tick fps** → **已定**：`WLStreamViewController` 把 `renderFrameRate` 设成 `encoderConfig.fps`（如 30），合成帧率对齐编码 fps，避免过度合成致编码丢帧（`WLStreamViewController.m:218`）。`WLVideoMix` 默认 60（`WLVideoMix.m:94`）。

---

## 7. 兼容性与风险

- **WLRecorder CFR 兼容** ✅：用 `_baseUs`（首帧 pts）做公共零点、之后全相对（`outPts = ptsUs - _baseUs`），对输入 pts 绝对数值不敏感，只要单调递增即可。tick 改造不需动 recorder。
- **预览不动**：per-source preview 走 push 直出（低延迟），只有合成/录制走 tick。
- **纯预览不录制**：tick 仅在 `renderingEnabled` 时跑（当前 `compositingEnabled` 已控制），零空转。
- **拖动 layout 实时性**：tick 60fps 下 layout 变化最多延迟 1 tick（16ms），无感；`setLayoutFrame:` 仍即时更新 layouts 缓存。
- **judder（阶段一）**：见 §3.5，匀速运动画面轻微，阶段二根治。

---

## 8. 阶段二落地实现详解（代码用了哪些设计、为什么这样设计）

> 本节对照 `WorkLabs/Mix/WLVideoMix.m` **当前真实代码**逐部分拆解：每块先「大白话」讲它在干嘛、再「伪代码/代码锚点」、最后「为什么这么设计（取舍理由）」。供对照代码慢慢斟酌。
> 行号基于当前版本（commit `977c086` 之后）。
>
> ⚠️ **注意 `WLVideoMix.h` 注释已过时**：头文件里还写着 "CoreImage 合成 / renderWithPts"（`WLVideoMix.h` 的 `renderingEnabled` 注释段），那是 push 时代的残留；实际早已是 Metal + tick。读头文件注释时以本节 / .m 为准。

### 8.0 一张图：push→tick 之后的真实数据流

```
源 render 线程(生产层, baseTime 自节流)
   │ didOutputVideoFrame:pts
   ▼
WLStreamsManager  ──fork──┬─► preview.receiveVideoFrame   (各源预览, push 直出, 不经 tick)
                          └─► mix.inputVideoFrame:pts:sid
                                   │ CVPixelBufferRetain + dispatch_async
                                   ▼
                          ┌─────────── serialQueue (com.worklabs.videomix) ───────────┐
                          │  inputVideoFrame:  WLMixFrame{pb,pts} 入 asyncFrames[sid] 队尾 │
                          │  setLayout/Bg/Order/CanvasSize: 只改缓存                       │
                          │                                                              │
                          │  tickTimer(dispatch_source_timer, 挂本队列) 每 interval 触发: │
                          │    renderComposite(pts = ptsAccum):                          │
                          │      selectFramesForTick()   ← 虚拟钟选帧(消费层)            │
                          │      Metal 合成 curFrames[*] → out(BGRA)                      │
                          │      output(out, pts)  ──► WLRecorder / 推流                  │
                          └──────────────────────────────────────────────────────────────┘
```

**两个关键事实**（决定了所有线程/锁/所有权设计）：
1. **所有 mix 内部状态只在一条 `serialQueue` 上读写**（`WLVideoMix.m:38, 93`）。tick timer 也挂在这条队列（`:264`）。所有 public setter 都 `dispatch_async` 到它（`:136,160,174,199,207,219,228,241,255`）。→ **全程免锁**，不存在数据竞争。
2. **预览不走 tick**：`WLStreamsManager` fork 的第一路直接进各源 `WLStreamPreview`（push 直出，低延迟）；只有合成/录制这一路进 tick。所以 tick 的 judder / CFR 只影响录制输出，不影响预览手感。

---

### 8.A 数据结构：托盘 + 指针 + 当前帧

大白话（呼应 §5「托盘+指针」）：每个源一个**托盘**装着贴了时间标签的照片，一根**指针**（虚拟钟）指着「现在该看哪张」，外加记一张**当前正展示的照片**（指针在两张之间时还得有东西可合成）。

| 字段（`WLVideoMix.m:42-48`） | 角色 | 大白话 |
|---|---|---|
| `asyncFrames[sid]` : `NSMutableArray<WLMixFrame*>` | 每源 FIFO 队列 | **托盘**：源投进来的照片按时间排队 |
| `curFrames[sid]` : `WLMixFrame*` | 每源当前显示帧 | **手上正展示的那张**：指针没翻页时继续用它（慢源重复的关键） |
| `lastFrameTs[sid]` : `NSNumber*`(秒) | 每源虚拟时钟 | **指针**：在「源 pts 轴」上的位置；缺键 = 冷启动待锚 |
| `lastSysTs` : `uint64_t`(ns) | 全局上次 tick 系统时刻 | **上次看墙钟的读数**，用来算「这次过了多久」 |

`WLMixFrame`（`:25-32`）是个极小的内部类：持有一个 retain 的 `pixelBuffer` + `pts`，`dealloc` 里 `CVPixelBufferRelease`。

**为什么引入 `WLMixFrame`**：阶段一只存「每源一张裸 `CVPixelBufferRef`」，retain/release 全手动。阶段二队列里可能有几十张，手动配平极易漏。把 pb 包进对象、release 写在 `dealloc`，**retain/release 就全交给 ARC**（数组增删元素自动管）——反而比阶段一更不容易错。这是「用 ARC 兜住 CF 对象生命周期」的常见手法。

---

### 8.B tick 引擎：固定节拍怎么来的

大白话：有个闹钟每 `interval` 秒响一次，响一次就合成一帧、输出。闹钟挂在合成队列上，响的时候直接在这条队列里干活，不用切线程、不用加锁。

伪代码（对应 `startTick` `:262-280` / `rescheduleTick` `:282-289`）：

```
setRenderingEnabled(YES):           # :253  录制/推流开启时
    _renderingEnabled = YES         # 立即写 ivar(getter 读它)
    dispatch_async(serialQueue): startTick()

startTick():                        # 全程在 serialQueue
    if tickTimer exists: return     # 幂等
    tickTimer = dispatch_source_timer(serialQueue)   # ★ 挂合成队列, 不开专用线程
    ptsAccum = 0                    # 输出 pts 从 0 累加
    lastSysTs = 0                   # 墙钟基准清零 → 第一拍 sysOffset=0
    asyncFrames.clear()             # 丢开启前堆的陈帧
    lastFrameTs.clear()             # 各源下次投帧冷启动重锚
    timer.handler = {               # 每拍:
        pts = ptsAccum              # ★ 理论 CFR pts(累加, 不取实测 now)
        ptsAccum += tickInterval
        renderComposite(pts)
    }
    rescheduleTick()                # 设周期: 首拍 NOW 立即出, 周期 = interval, leeway = interval/10
    resume(timer)
```

**为什么这样设计：**

1. **用 `dispatch_source_timer` 挂 serialQueue，而不是专用线程**（§6 决策点 2 原本推荐专用线程，落地改了）：
   - timer handler 用 `__weak self`（`:270-273`），对象销毁后回调安全空转，不会野指针。
   - handler 与所有 setter / 选帧 / 渲染**同在一条队列**，天然串行 → 访问 `asyncFrames`/`curFrames`/`layouts`/`textureCache` **全程免锁**（`textureCache` 本身非线程安全，这点尤其重要）。
   - `leeway = interval/10`（`:288`）允许内核合并定时器省电；**因为输出 pts 用理论值，定时抖动（jitter）不进时间戳**，省电不损 CFR。

2. **输出 pts 用理论累加 `ptsAccum`，不用实测 `now`**（`:274-275`）：
   - 严格 CFR：每帧 pts 精确 = `n·interval`，完全均匀，muxer/编码器最省心。
   - 改帧率时（`setRenderFrameRate:` → `rescheduleTick`）pts 仍从当前值继续累加，**单调连续不跳变**。
   - 反直觉但关键：**选帧用实测墙钟、输出 pts 用理论值**，两者分工（详见 8.C 末）。

3. **`startTick` 里清 `lastSysTs=0` + 清 `asyncFrames`/`lastFrameTs`**（`:266-269`）：
   - `lastSysTs=0` → 第一拍 `sysOffset=0`（见 8.C），**不会把「上次停止到这次开启之间的暂停时长」一股脑灌进虚拟钟**导致瞬间狂丢帧。
   - 清 `asyncFrames` 丢掉开启前堆积的陈帧；但**保留 `curFrames`**（上次的画面），让重新开启时有帧过渡、不黑屏。

4. **`renderingEnabled=NO` 停 tick**（`stopTick` `:291-295`）：纯预览不录制时 tick 不跑，**零空转**（各源自己的 `WLStreamPreview` 上屏，不需要合成）。省 CPU/GPU。

---

### 8.C 选帧：虚拟时钟怎么吸收 fps 差异（最核心）

大白话（§3.1 / §5「托盘+指针」的代码版）：每拍做三件事——①看墙钟过了多久 `sysOffset`；②把**每个源**的指针都往前推这么多（同一步长 → 多源天然对齐）；③每个托盘里，指针已越过的旧照片丢掉，露出「指针还没越过的第一张」当作 `curFrames`。

#### selectFramesForTick（`:301-322`）：全局推进 + 统计

```
selectFramesForTick():
    now = wl_mono_now_ns()                              # CLOCK_UPTIME_RAW 单调钟
    sysOffset = (lastSysTs != 0) ? (now-lastSysTs)/1e9 : 0   # ★ 第一拍=0
    lastSysTs = now
    for sid in streamOrder:
        selectFrameForStream(sid, sysOffset)            # 各源用同一 sysOffset 推进
    # ...每秒汇总统计(见 8.I)
```

**`sysOffset` 用「实测流逝」而非「理论 interval」**：若某拍卡顿（系统忙、断点），`now-lastSysTs` 会偏大，指针一次多推 → 自动多丢几帧**追上进度**，不累积延迟。这正是 §3.3 表里「掉帧追赶」那行。

#### selectFrameForStream（`:353-396`）：单源的指针推进 + 挑帧

逐分支伪代码（带行号锚点）：

```
selectFrameForStream(sid, sysOffset):
    q = asyncFrames[sid]
    if q.empty:                                  # :355  托盘空(没新帧投来)
        dup++; return                            #   → 不动 curFrames, 慢源「重复」上一张

    vt0 = lastFrameTs[sid]
    if vt0 == nil:                               # :361  冷启动(刚开始/刚倒过盘)
        curFrames[sid] = q.pop_front()           #   首帧立即显示
        lastFrameTs[sid] = thatFrame.pts         #   ★ 用首帧 pts 锚定指针(对齐到源时间轴)
        return

    vt = vt0 + sysOffset                         # :371  ★指针在源 pts 轴上, 以墙钟速度前进

    if |q.head.pts - vt| > 2.0:                  # :374  跳变重锚(seek/不连续, MAX_TS_VAR)
        vt = q.head.pts                           #   不一张张追, 直接对齐到队头

    took = 0                                     # :380  挑帧循环
    while q not empty:
        head = q.head
        if vt < head.pts: break                  # :383  队头在未来 → 停(它还没到点)
        if took>0 and (vt-head.pts) < 0.002: break # :384 已取过且仅超前<2ms → 平滑停
        curFrames[sid] = head; q.pop_front(); took++   # 取它当当前帧, 继续看下一张
    lastFrameTs[sid] = vt                        # :389  指针落在 vt

    if took==0: dup++                            # :391  没翻页 → 重复
    elif took>=2: drop += took-1                 # :393  翻过好几张只留末张 → 中间是丢帧(抽帧)
```

**逐设计点 & 为什么：**

- **队空就保持 `curFrames`（`:355-358`）**：慢源（24fps 进 60 tick）大多数拍没有新帧，靠「继续用上一张」实现重复。这要求 `curFrames` 一直持有上次选中的 `WLMixFrame`（见 8.D 所有权）。
- **冷启动用首帧 pts 锚定（`:360-369`）**：源 pts 轴的零点是任意的（可能从 100.0s 开始）。直接拿第一帧的 pts 当指针起点，**把虚拟钟对齐到这条源自己的时间轴**，之后才能比大小。`lastFrameTs` 缺键就是「待锚」哨兵。
- **`vt = lastFrameTs + sysOffset`（`:371`）是灵魂**：指针的**位置**在源 pts 轴上，但**前进速度**用墙钟（sysOffset）。于是「现在该显示哪帧」退化成同一根轴上的比大小（`vt vs head.pts`）——把「两个不同基准的时钟」难题化简掉了。
- **>2s 跳变重锚（`:374-377`）**：seek、循环回到开头、流不连续时，帧 pts 会突然跳一大截。若还一张张「追」会狂丢一堆。检测到 >2s 直接把指针重设到队头 pts。对应 OBS `MAX_TS_VAR`，也正是未来 seek/loop 重建时间基准的合成器做法。
- **2ms 平滑停（`:384`）**：指针只超前队头不到 2ms 时，宁可显示这张「早 ≤2ms」的，也不在帧边界多丢一张造成顿挫。注意条件是 `took>0`——**第一张该取的一定取**，只有在「已经取过、要不要再多丢一张」时才平滑。精确 vs 平滑的折中。
- **took 记账（`:391-395`）**：`took==0` 这拍没翻页=重复（dup）；`took>=2` 翻过多张只留最后一张、中间的算丢帧（drop）。这两个计数喂给观测（8.I），用来验证「慢源 dup 多、快源 drop 多」。

#### 大白话：2ms 平滑到底在平滑什么

> 这是一处「工业级」处理里很典型、但第一次见会陌生的小技巧——**用一点点看不见的误差，换稳定的节奏**。单独讲清楚：

想象你在**按鼓点翻一摞照片**给大家看。每张照片背后贴了张纸条，写着「我该在第几秒露脸」（= 帧的 pts）。鼓点一响（= 一个 tick），你就瞄一眼墙上的钟（= 虚拟时钟 `vt`），把**时间已经到了的**那张翻出来举给大家（= 选 `curFrames`）。

正常时候一拍翻一张，很顺。

**麻烦出在：照片该露脸的节奏，和你敲鼓的节奏几乎一模一样的时候**（比如源 60fps、tick 也 60fps）。两边总会差那么一丁点、对不齐。于是某一拍你看钟，发现「咦，下一张的时间也刚刚好到了（就过了那么一丝丝）」，手一快这拍翻了两张；结果下一拍一看没有新的到点，只好把同一张又举一遍。

观众看到的就是：刚才那张一闪就过去了（被跳了），这张又举了两次（卡住了）——画面**一顿一顿**的（judder）。

**2ms 平滑就是给你定的一条规矩：**

> 「下一张的时间要是**只刚刚过了一丁点（不到 2ms）**，就当它还没到，先别翻，留着下一拍再翻。」

这样你就能**稳稳地一拍一张**，不忽快忽慢。代价是某张照片可能被多举了不到 2ms——但这点时间人眼**根本看不出来**（视频画面差几十毫秒都无感；真正难受的是声音和嘴型对不上）。拿这点看不见的误差，换顺滑的节奏，划算。这就是注释里写的「**精确 vs 平滑的折中**」。

两个容易绕的点：
- **为什么要「已经翻过一张」(`took>0`) 才生效**：本拍第一张该露的照片**一定要露**（否则没东西可显示、还会卡住不前进）。2ms 只管「已经露了一张，要不要再多翻一张」这种**多翻**的情况。
- **它不挡真正的快源**：要是照片哗哗地翻（源 120fps 进 60 tick），一拍之间下一张早就过去了远不止 2ms，`(vt - 它的 pts)` 远大于 2ms → 照常翻、照常丢中间帧（正常抽帧）。2ms 只在「帧率撞帧率」的边界上抹平那种一跳一卡的小抖动。

一句话：**2ms 是一个「别太较真」的宽限，专治「源帧率 ≈ 合成帧率」时那种忽跳忽卡的小抖动。** 值照搬自 OBS（不是拍脑袋定的），因为它远小于人眼能察觉的时序误差。

#### 三类 fps 情况映射到这段代码（§3.3 的代码版）

| 场景 | 这段代码发生什么 |
|---|---|
| **慢源** 24fps/60tick | 多数拍 `vt < head.pts`（`:383` break），`took==0` → dup++ → 重复 `curFrames` |
| **快源** 120fps/60tick | 每拍 `vt` 越过 ~2 张，while 取 2 张、`took>=2` → drop += 1（只留末张） |
| **掉帧追赶** | 卡顿那拍 `sysOffset` 大 → `vt` 跳很多 → while 连续取多张追上 |
| **多源各异** | `selectFramesForTick` 里所有源**共用同一 `sysOffset`**（`:306-308`）→ 各自指针同步前进 → 锚到同一墙钟 → 天然对齐 |

#### 「选帧用实测、pts 用理论」为什么不矛盾

- 选帧的 `sysOffset` 用**实测 now**：要反映真实流逝，掉帧能追、不漂。
- 输出的 `output(pb, pts)` 的 pts 用**理论 `ptsAccum`**：要严格 CFR、均匀。
- 两者是两件事：**「这一刻每源该露哪张」用真实时间判断；「这一帧打什么时间戳交给录制」用规整时间。** 互不干扰。

---

### 8.D 内存与所有权（CVPixelBuffer 在队列里怎么不泄漏/不早释放）

大白话：照片是 GPU 显存里的稀缺资源，谁拿着、谁放手必须一笔笔对清，否则要么花屏（早放）、要么内存爆（不放）。

链路（`inputVideoFrame:` `:168-195` → 队列 → `curFrames` → 合成）：

```
inputVideoFrame(pb):
    CVPixelBufferRetain(pb)            # :173  本方法先 retain 一份
    dispatch_async(serialQueue):
        f = WLMixFrame{pb}             # :175-176 所有权转移给 f (f.dealloc 会 release)
        asyncFrames[sid].push_back(f)  # :187  ARC 管数组持有
        if asyncFrames[sid].count >= 30:   # :183  MAX_ASYNC_FRAMES
            removeAll + lastFrameTs.remove   # 倒池 + 标冷启动(下帧重锚)
```

- **谁 retain 谁 release 配平**：`inputVideoFrame` retain 一次 → 交给 `WLMixFrame` → `WLMixFrame.dealloc` release 一次。`WLMixFrame` 进出数组/字典由 ARC 增减引用。**整条链没有手动 release 散落各处**。
- **`curFrames[sid]` 持有「上次选中的 `WLMixFrame`」**（`:364,385`）：所以慢源重复期间那张照片不会被释放（数组里被 pop 了，但 `curFrames` 还强引用着）。
- **队满 30 倒池（`:183-186`）**：tick 长期跟不上（缓冲只涨不消）→ 整盘 `removeAllObjects`（ARC 连带 release 所有 pb）+ 清 `lastFrameTs` 触发下帧冷启动重锚。对应 OBS `MAX_ASYNC_FRAMES`，防显存无限堆积。
- **`removeStreamID:` / `dealloc`（`:205-215, 109-121`）**：清四个字典即可，pb 的 release 由 `WLMixFrame.dealloc` 自动完成，手动段大幅简化（dealloc 只需管 timer/pool/textureCache 这三个非 ARC 的 CF 资源）。

**为什么不直接存裸 `CVPixelBufferRef` 数组**：那样每次数组增删都要手动 retain/release，几十张、多源、还有倒池/重锚分支，极易漏一处。`WLMixFrame` + ARC 把这层心智负担消掉了。

---

### 8.E 合成渲染 renderComposite（`:400-511`）

大白话：选好每源该露哪张后，开一张空画布（铺背景色）→ 先贴背景图 → 按 z-order 从底到顶把每源画到它的 layout 矩形里（透明叠加）→ 等 GPU 画完 → 把画布交给录制。

骨架伪代码：

```
renderComposite(pts):
    selectFramesForTick()                          # :405  先选帧
    if 无背景色 且 无背景图 且 无源: return         # :408  纯空画布不输出
    if !pipeline or !textureCache: return          # :411  Metal 不可用
    out = pool.createPixelBuffer()                 # :417  从画布 pool 取 BGRA
    @autoreleasepool {                             # :425  ★ 必须, 见下
        target = bindRenderTarget(out)             # :426
        pass.loadAction = Clear; clearColor = bgClearColor   # :429-433 铺背景色
        enc = cmdBuf.encoder(pass)
        if bgTexture: 画全屏 quad(背景图)            # :447-460
        for sid in streamOrder:                    # :463  从底到顶
            pb = curFrames[sid].pixelBuffer        # :464  虚拟钟选出的当前帧
            layout = layoutForStreamID(sid)        # :467
            in = bindSampling(pb); inputs.add(in)  # :470-472 持有到 GPU 完成
            quad = layout→NDC (左下原点, y 不翻)    # :474-483
            setFragmentTexture + isYUV/isFullRange # :485-489
            draw(triangle strip, 4)                # :490
        commit(); waitUntilCompleted()             # :494-495 ★ 必须等
        flush(textureCache)                        # :496
    }                                              # :499 pool 排空 → 释放 cmdBuf/enc/inputs
    output(out, pts)  // 所有权转移给 block         # :506-510
```

**逐设计点 & 为什么：**

- **`@autoreleasepool` 包住整个编码（`:425-499`）**：`MTLCommandBuffer`/encoder/纹理 binding 都是 autoreleased 对象，会持有输入输出纹理及其 **IOSurface 像素内存**。本方法在录制时每秒跑几十次，**不主动排空 pool，autoreleased 对象每帧累积 → 内存暴涨**（之前实测开滤镜从十几% 飙到 1GB+ 同理）。pool 在 `waitUntilCompleted` 之后排空（GPU 已用完这些纹理），安全。
- **`waitUntilCompleted`（`:495`）**：下游编码器是 **CPU swscale** 读这块 BGRA 像素（BGRA→NV12）。必须等 GPU 真正画完再交付，否则读到半成品。代价是合成线程阻塞到 GPU 完成——对录制可接受（合成队列独立于预览）。
- **`loadAction=Clear` 用背景色铺底（`:431-432`）**：既是「背景色」语义，也兼当「每帧把整张画布刷一遍」**防 pool 复用的旧 buffer 残影**（pool 回收的 buffer 里可能还是上一帧内容）。一举两得，替代了旧 CoreImage 时代的「全屏铺底 quad」。
- **layout→NDC，左下角原点，y 不翻（`:474-477`）**：画布 layout 用画布像素、左下原点；NDC y 直接线性映射不翻转。图像上下翻转放在 **texCoord 的 v 分量**（`:479-482` 底=1 顶=0），和 `vertexShader` 约定一致。把「翻转」固定在 texCoord 一处，避免 NDC 和 texCoord 两头都翻导致绕晕。
- **`blending:YES` 的 painter's algorithm（pipeline 建于 `:88`）**：按 `streamOrder` 从底到顶画，源 alpha 叠加；不透明视频直接覆盖下层。z-order 就是数组顺序。
- **空画布不输出（`:408`）**：没有任何背景/源时不产帧，避免录进一段纯黑空画布。
- **`output(out, pts)` 转移所有权（`:506-509`）**：`out` 是 CF 对象，不受上面 `@autoreleasepool` 影响；交给 block 后由下游（`WLStreamsManager` 的 `mix.output`）负责 release（`WLStreamsManager.m:60-68`）。

---

### 8.F 「只改缓存、下个 tick 生效」的状态更新模式

所有外部状态变更——`setLayoutFrame:`（`:197`）、`setBackgroundColor:`（`:125`）、`setBackgroundImage:`（`:143`）、`setStreamOrder:`（`:217`）、`updateCanvasSize:`（`:226`）——都是：`dispatch_async` 到 serialQueue，**只更新内部缓存，不主动触发合成**。下一个 tick 自然读到新值。

**为什么**：
- 与 tick 同队列串行 → **免锁**，且不会和正在进行的合成抢状态。
- 拖动 layout / 改背景时，变更最多延迟 1 个 tick（60fps 下 ≈16ms）才反映到输出——**无感**，但换来了「6 处触发点收敛成 1 处 tick」的简洁（对比 §1 push 模型的 6 处 `renderWithPts`）。
- `updateCanvasSize:`（`:226-237`）额外重建 `pixelBufferPool`（画布尺寸变了，pool 的 buffer 尺寸也得变），同样下个 tick 生效。

---

### 8.G 线程模型一句话总结

> **一条 `serialQueue` 统管一切**：tick timer 挂它、所有 setter dispatch 到它、选帧/合成在它上面跑、`textureCache` 只在它上面碰。对外 API 可在任意线程调用（内部都 `dispatch_async` 收口）。`renderingEnabled` 是 `atomic` + 自定义 setter，ivar 立即写供 getter 读、启停 tick 入队执行。**没有锁，因为不需要锁。**

---

### 8.H 实现 vs 原计划的差异 / 取舍记录

| 点 | §5/§6 原计划 | 实际落地 | 为什么改 |
|---|---|---|---|
| tick 载体 | 专用线程睡到绝对单调时刻 | `dispatch_source_timer` 挂 serialQueue | weak self 安全 + 同队列免锁（尤其 textureCache）+ leeway 省电；理论 pts 不依赖线程精度，jitter 不进时间戳 |
| 输出 pts | 理论值 `n·interval` | ✅ 理论累加 `ptsAccum`（`:274`） | 一致：严格 CFR、改帧率单调连续 |
| 选帧时钟 | （阶段二新增） | 实测 `sysOffset`（`:303`） | 实测才能掉帧追赶、不漂；与理论 pts 分工 |
| 缓冲上限 | OBS `MAX_ASYNC_FRAMES=30` | ✅ 30 倒池 + 冷启动重锚（`:183`） | 一致 |
| 平滑/重锚 | 2ms / 2s | ✅ 2ms（`:384`）/ 2s（`:374`） | 一致，照搬 OBS |

---

### 8.I 观测埋点（阶段二自带，验证用）

为验证「fps 吸收 / 多源对齐 / 缓冲深度」是否真的对，阶段二带了**每秒一行**的汇总日志（commit `977c086`）。

- **采集**（散在选帧/投帧里，几乎零成本）：`statIn`（每源投帧数，`:188`）、`statDup`（重复次数，`:356,392`）、`statDrop`（丢帧数，`:394`）、`statTickCount`（tick 数，`:311`）。
- **每秒输出**（`emitStatsSummary` `:325-345`）：先 `WLLog shouldLog` gate（`:326`，**默认关时连字符串都不拼**，零开销）；一行含 `tick=实际fps`、各源 `in=投帧fps q=队深 dup= drop= pts=`、以及多源 `skew=（最大−最小当前 pts，毫秒）`。
- **怎么读**：
  - 慢源：`dup` 高、`drop≈0`、`q` 浅 → 「重复」在工作。
  - 快源：`drop` 高、`q` 不爆 → 「抽帧」在工作。
  - 多源：`skew` 应很小（个位/十几 ms）→ 「对齐同一墙钟」成立；若 skew 持续大，说明某源冷启动锚偏或在重锚。
  - `tick=` 应≈设定合成 fps；明显偏低 = 合成跟不上（GPU/CPU 瓶颈）。

> 这套埋点是「阶段二是否真生效」的体检表；调参/排查 judder 时先看它，再决定要不要动选帧逻辑。

---

## 附录 A：mpv vs OBS 范式对照（为什么 WorkLabs 选 OBS 路线）

| 维度 | mpv（回放器） | OBS（合成器） ← WorkLabs 取向 |
|---|---|---|
| **主时钟** | 音频主时钟，视频追音频 | 无主从，系统单调钟 `os_gettime_ns` 是唯一基准 |
| **同步机制** | 闭环反馈：视频比 audio clock，早了多睡、晚了丢帧/快进 | 开环：两条线各自睡到系统钟绝对刻度，源入口 `timing_adjust` 归一，无反馈天然对齐 |
| **出帧驱动** | 源自驱动（按音频钟调度） | **统一 tick 拉动**（固定 fps，`get_closest_frame` 选帧） |
| **fps 不一致** | 单文件 a/v，不涉及多源异 fps | 每源虚拟钟选帧，慢重复/快抽帧，对齐同一钟（§3） |

**为什么 WorkLabs 选 OBS**：mpv 的音频主时钟要求「可信主钟 + 可回退内容」，live 多源都不满足（不能让实时摄像头快进追上）。OBS 用统一墙钟换鲁棒可扩展，正是 live 合成所需。完整对比见 `Doc/调研/mpv/MPV_时间戳源码深挖.md` 与 `Doc/调研/OBS/`（四篇）。

---

## 附录 B：关键位置速查

- 现状 push：`WLVideoMix.m:134` `inputVideoFrame:`、`:204` `renderWithPts:`、`:220-222` 最小间隔节流、`:317` `output(pb,pts)`；`WLStreamsManager.m:318-350` fork 双路、`:60` mix.output→mixedFrameOutput。
- 生产层节流：`WLMediaSource.m` `videoRenderThread`/`audioRenderThread`（baseTime CAS 锚定 + 分段睡眠）。
- 录制零点：`WLRecorder.m:25` `_baseUs`、`:192/205` `outPts = ptsUs - _baseUs`。
- 取经：`Doc/调研/OBS/OBS_源异步帧缓冲与时间戳节流.md`（§2.4 `ready_async_frame` 逐行）、`OBS_合成tick_音频混音_AV同步.md`。
