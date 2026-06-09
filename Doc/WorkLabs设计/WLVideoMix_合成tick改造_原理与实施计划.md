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

### 阶段三：录制带音频的 A/V 同步（接 AAC mux 时）

按 OBS `timing_adjust = wallclock − 源pts` 把每源音频 pts 归一到**同一单调钟**；视频帧 + 音频包都带该钟时间戳交 muxer interleave。**不要 video 追 audio**（合成器范式）。WLRecorder 已用同一 `_baseUs`（首视频帧 pts）做 a/v 公共零点（`WLRecorder.m:25/155/192/205`），正好契合——音视频必须共享同一零点，否则音画错位。

---

## 6. 决策点（待斟酌）

1. **落地顺序**：先阶段一跑通框架、再上阶段二虚拟钟？还是直接一步到位做阶段二（数据结构和选帧一次建好，省返工）？
2. **tick 时钟 / pts**：推荐专用线程睡到绝对单调时刻，**pts 用理论值 `n·interval`**（严格 CFR、完全均匀），而非实测 now（带 jitter）。epoch 用相对合成启动的秒（数值范围同当前源 pts，WLRecorder 行为不变）。
3. **tick fps**：设成画布输出 fps（如 30）可减少阶段一重复合成；预览想流畅可设 60。

---

## 7. 兼容性与风险

- **WLRecorder CFR 兼容** ✅：用 `_baseUs`（首帧 pts）做公共零点、之后全相对（`outPts = ptsUs - _baseUs`），对输入 pts 绝对数值不敏感，只要单调递增即可。tick 改造不需动 recorder。
- **预览不动**：per-source preview 走 push 直出（低延迟），只有合成/录制走 tick。
- **纯预览不录制**：tick 仅在 `renderingEnabled` 时跑（当前 `compositingEnabled` 已控制），零空转。
- **拖动 layout 实时性**：tick 60fps 下 layout 变化最多延迟 1 tick（16ms），无感；`setLayoutFrame:` 仍即时更新 layouts 缓存。
- **judder（阶段一）**：见 §3.5，匀速运动画面轻微，阶段二根治。

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
