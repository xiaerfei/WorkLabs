# mpv 时间戳取经 —— 讨论纪要与功能规划

> **性质**：讨论纪要 / 决策参考（非实现方案）。记录围绕「mpv 时间戳设计」展开的几轮讨论，供后续斟酌。
> **日期**：2026-06-08
> **配套调研报告**：[MPV_时间戳源码深挖.md](MPV_时间戳源码深挖.md)（源码级、逐函数；本文是它的「应用层」延伸）、[MPV_时间戳与队列设计调研.md](MPV_时间戳与队列设计调研.md)（取经清单 + 队列/同步全景）。
> **mpv 版本**：`v0.41.0-718-g1d82932cce`。**WorkLabs 现状代码**：本文引用的行号基于讨论当日核实，后续改动可能漂移。

---

## 0. 这份文档是什么 / 怎么用

它把三个议题的讨论结论沉淀下来：
1. **议题一**：mpv 时间戳对**现在**的 WorkLabs 有什么参考意义（结合现状核实）。
2. **议题二**：mpv 时间戳设计的**本质意义**（设计哲学，可脱离视频理解）。
3. **议题三**：面向**未来功能**（拖进度条 seek + 循环 loop + 较精确 A/V 同步）能参考什么、怎么落地。

议题一/二是"理解与判断"，议题三是"行动规划"。文末 §4 汇总**待斟酌的决策点**——那是你后续要拍板的地方。

---

## 1. 议题一：mpv 时间戳对现在 WorkLabs 的参考意义

> **提问**：它（mpv）的时间戳对现在的我们有什么参考意义？

讨论中**核实了 WorkLabs 当前代码**（`WorkLabs/Source/MediaFile/WLMediaSource.m`、`WorkLabs/Output/WLEncoder.m`/`WLRecorder.m`），结论是：状态比早期调研文档/CLAUDE.md 描述的要新，P0「防崩三件套」已做了两件。参考意义因此从"补一堆清单"收窄成了很具体的几条。

### 1.1 已经吃到的（这几条不用再回头看 mpv）

| 取经点 | WorkLabs 现状 | 对照 mpv |
|---|---|---|
| **NOPTS 哨兵** | `WLMediaSource.m:23-37` `wl_pts_from_av` / `wl_add_pts` / `WL_NOPTS_VALUE (-0x1p+63)` / `wl_pts_is_valid` | `av_common.c:169` + `MP_ADD_PTS` |
| **start_time 归一化** | `:646` `_startTime = start_time/AV_TIME_BASE`；节流处 `:339/:395` `wl_add_pts(node.pts, -startTime)`（容器 start_time 固定偏移、音视频共用） | `loadfile.c:961` + `demux.c:2858` |
| **录制侧单调墙钟 epoch** | `WLEncoder.m:9-26` `mach_absolute_time`、`_lastVideoPts` 保单调；`WLRecorder.m` 共享 `_baseUs`（首关键帧 pts 为零点） | 「输出侧用墙钟、录实时所见」理念 |

> 注：录制墙钟 epoch **本来就该用墙钟**，别被"音频主时钟"带去改它——它属于输出侧，求"实时"，不求"还原素材"。

### 1.2 现在最该看 mpv 的一件事：源内节流仍踩在 mpv 极力避免的设计上

源内节流（`videoRenderThread` `:322` / `audioRenderThread` `:377`）当前是 **绝对锚定 + 固定 baseTime + 过期立即冲 + usleep 轮询**：

```objc
current_time = CFAbsoluteTimeGetCurrent()*1000;     // :325 墙钟 ms
if (baseTime == 0) baseTime = current_time;          // :327 只设一次，永不重建
abs_pts = normalized_pts*1000 + baseTime;            // :347 绝对锚定
if (abs_pts + offset < current_time) 立即出帧;        // :349 过期就冲
else { waitMs 封顶 50ms; usleep; }                   // :365-368
```

这正是深挖报告 §2.5 讲的**绝对锚定**，mpv 用**相对积分时钟 + 帧间隔 clamp**（`video.c:383-392`）就是为躲开它的两个真实崩坏：

1. **pts reset → 整流瞬间冲完 / 卡死**。`baseTime` 只设一次、永不变。pts 一旦 reset（TS 回绕、拼接、**未来的 seek/loop**）：
   - 往小跳 → `abs_pts < current_time` 恒成立 → 后续帧全判"过期"瞬间冲出（画面快进/乱序）；
   - 往大跳 → 一直 `peek` 同帧、每次睡 50ms 等墙钟爬到那点 → 忙等卡住（50ms 封顶只防"单次睡太久"，不防"总等待"）。
2. **B 帧素材**：直接用 `frame->pts`，无 mpv 那套"pts 非单调退 dts"（`crazy_video_pts_stuff`）。

**结论**：把源内节流从「绝对锚定 baseTime」换成「相对增量 `frame_time = pts − last_pts` + clamp 归零」，是补完 P0 三件套的最后一件（**P0 #3 帧间隔 clamp**），成本几十行，直接消除 pts reset/倒退类崩坏。

> 留意：当前对 NOPTS 帧是「丢弃」（`:342`），mpv 是「立即显示不等待」。单源影响不大，但丢弃会丢内容。

### 1.3 顺带的性能收益（接你们的 CPU 优化主线）

源内节流是 `peek + usleep(10ms)` 轮询（`:334/:368/:390`），空转。mpv 的 **condvar + 单调时钟绝对 deadline**（`threads-posix.h:201` + `mach_wait_until`）= "优化②渲染线程精确等待"的标准答案：稳态零空唤醒、出帧更准。与已做的预览 CPU 优化一脉相承。

### 1.4 先别动的（留给多源/多轨成熟后）

- **音频主时钟实测**（`ao_get_delay` / `AudioQueueGetCurrentTime`，视频追音频）：现各源独立节流，单源够用。等多源帧级严格对齐或漂移成问题再做（`WLAudioMixer` 成熟后的下一步）。
- **队列按字节+时长限流**（替代按包数 `:201` size=15/20、`:207` frame size=4）：纯内存优化，不紧急。
- **display-sync 消 judder**：合成器用不上。

---

## 2. 议题二：mpv 时间戳设计的本质意义

> **提问**：mpv 的设计意义是什么？

跳出机制清单，从设计哲学层面提炼。

### 2.1 核心命题

> **当输入数据本身就是错的，你怎么还能输出正确的行为？**

容器时间戳是**脏的**（缺失/倒退/跳变/取整抖动/起点非零/各流不一致），这是常态不是边缘情况。天真播放器把时间戳当**指令**照做 → 输入一脏就崩。mpv 的根本转变：**把时间戳当成"来自不可信来源的、含噪声的观测值"**，播放器职责是**在脏数据之上自己维护一条稳定、自愈的播放时间轴**。

意义不在"播得准"，而在 **让系统的正确性不依赖于输入的正确性**——这就是"鲁棒性"的真正含义。

### 2.2 由此推出的五个设计姿态

1. **边界消毒，内部干净**：`mp_pts_from_av` 是 FFmpeg↔mpv 唯一关口，脏数据只在门口处理一次，门内代码都能信任时间戳干净。（"边界校验、内部信任"的时间版）
2. **相对积分 > 绝对锚定**（最深）：`time_frame += 理想增量 − 真实流逝`，把时间轴从外部数据解耦成内部自维护量 → 单帧异常 clamp 成 0 只影响一帧、误差不累积、seek 是"清零重起"。本质是**用反馈调节取代前馈命令**，系统因此获得**自愈**能力——不必枚举所有出错方式。
3. **向物理实测 > 按理论推算**：音频主时钟向声卡问"还剩多少没播"（`ao_get_delay`），不按"样本数÷采样率"算。承认**理论模型 ≠ 物理现实**。`adjust_sync` 每次只吃 10% = 承认测量有噪声、不过度反应。
4. **优雅降级 > 追求完美**：落后到绝望也强制 10fps 不冻屏（100ms 上限）；非法 time_base 宁可单位错也不除零崩；无帧率兜底 25fps。健壮系统的标志是**失败模式渐进劣化、非灾难性崩溃**。
5. **分层职责：输入侧求"正确"，输出侧求"实时"**：源内按 pts 还原素材时间关系；显示/录制按设备/墙钟打戳。不强求一个时钟统治一切。（这也是 WorkLabs 录制用墙钟 epoch 正确的原因）

### 2.3 超出播放器的意义

去掉"音视频"，这是一份 **"如何在不可靠输入流上构建可靠系统"的范本**，适用于日志摄取、传感器融合、行情、网络协议、分布式时钟。共同答案：边界消毒一次 / 内部靠反馈增量自维护、不钉死外部绝对值 / 关键量向真相源实测 / 失败降级 / 不同目标用不同基准。

一句话：**正确性来自系统对错误的免疫力，而不是来自对输入的信任。**

---

## 3. 议题三：面向未来功能（seek 拖进度条 + loop 循环 + 精确 A/V 同步）

> **提问**：未来要增加「拖动进度条」和「循环播放」，能从 mpv 参考什么，比如较精确的 A/V 同步输出。

### 3.1 当前架构（讨论中核实）

`WLMediaSource` 是**一次性播放模型**：
- 五线程：`parseThread`（`:140`）→ video/audio `decodeThread`（`:227/:256`）→ video/audio `renderThread`（`:322/:377`）。
- `parseThread` 读到 `AVERROR_EOF` 直接 `break`、线程全退（`:158-183`）。
- 队列：`videoPacketQueue`(15) / `audioPacketQueue`(20) / `videoFrameQueue`(4) / 音频 frame 队列；`WLNodeQueue` 有 `flush`/`abort`/`enQueue`/`deQueue`/`peek`。
- 公开接口（`.h`）仅 `initWithPath` / `start` / `stop` / `state` / `totalDuration`——**无 seek / loop / pause 概念**。

### 3.2 关键判断：两功能撞同一面墙

seek 和 loop 底层是**同一个要求**：流不停、读取位置可变、时间基准可重建。两道坎：
1. **一次性播放模型**：`EOF → break`（`:159`）。loop 要"EOF 别退、跳回开头继续"；seek 要"播放中跳到任意位置"。
2. **固定 baseTime + 绝对锚定**：**loop 会第一时间引爆**——回跳后 `normalized_pts` 变小 → 后续帧全判过期瞬间冲出 → 狂闪/炸响，因 `baseTime` 不重建。

→ **前提**：先把"一次性 + 固定 baseTime"改成"可重入 + 可重建基准"。mpv §4 正是这套。

### 3.3 seek（拖进度条）——参考 mpv §4「清零重建，不修正」

mpv 灵魂：**seek 后不"修正"时间戳接旧轴，而是清零计时状态、让新位置第一帧自然重建时间轴**。映射到五线程，一次 seek = 五个动作：

| mpv | WorkLabs 落地 |
|---|---|
| 命令进 demuxer 线程 | UI 线程设原子 `seekTarget`，`parseThread` 循环顶检查（勿在 UI 线程碰 ffmpeg） |
| `demux_seek` 跳关键帧 | `parseThread` 里 `avformat_seek_file(fmt, -1, INT64_MIN, targetTs, INT64_MAX, 0)` |
| 清空 packet 缓存 | flush `videoPacketQueue` / `audioPacketQueue` |
| reset 解码器/帧队列 | `avcodec_flush_buffers`(video & audio) + flush 两个 frame 队列 |
| `video_pts=NOPTS, time_frame=0` | **`baseTime = 0`**（让下一帧重设）= "清零重建"等价物 |

**两个量别混**：
- `startTime`（容器 `start_time`, `:646`）**seek 后不变**，`normalized_pts = pts − startTime` 始终成立。
- `baseTime`（墙钟↔pts 锚, `:327`）**seek 后归零重建**——seek 改的是它。

**精确度（hr-seek）**：FFmpeg 只能 seek 到目标**之前**最近关键帧（可能差几秒）。要精确到拖动点，照搬 mpv hr-seek：解码后**丢弃 `normalized_pts < 目标` 的帧**，到目标帧才出（对应 §4.4 `clip_timestamps`）。

**多线程协调**：render 线程阻塞在 `deQueue`/`peek`，flush 要能唤醒（`WLNodeQueue` 的 `flush`/`abort` 可用）；时序须"先停喂→flush→seek→放行"，防旧帧混入新位置。

### 3.4 loop（循环）= EOF 检测 + 自动 seek 回 0

loop 是 seek 的特例（mpv `--loop-file` 即 EOF 时 seek 到起点）。落地：

```objc
// parseThread :159
if (ret == AVERROR_EOF) {
    if (self.loop) { /* 执行 §3.3 那套 seek(0) + flush + baseTime 归零 */ continue; }
    break;
}
```

复用 seek 全部机制；**接缝平滑**靠"清零重起 + §3.5(A) 对齐重起"。注意 EOF 要等**帧队列也排空**再回跳（否则结尾几帧没播完就跳），mpv 用 DRAINING 状态处理这个尾巴。

### 3.5 「较精确 A/V 同步输出」——分清两种同步，别一上来做大的

**(A) seek/loop 后的「对齐重起」——直接相关，必做，成本低。**
参考 mpv §4.4：**两流都就绪才同时起步 + 统一起点 + 按样本裁齐**。WorkLabs 已有雏形——`audioRenderThread` 在 `baseTime==0` 时空等（`:383`），即**音频跟随视频设的 baseTime**（隐式 video 定锚、audio 对齐）。seek/loop 后只需：
- `baseTime` 由 seek 后第一个有效帧**统一设定**、两线程共用（现状如此，保持）；
- 两流都**丢弃 < 目标 pts 的帧**（hr-seek），从同一 pts 起步。

**(B) 持续播放中的严格 A/V 同步（视频追音频主时钟）——更大工程，建议缓。**
当前 video/audio 两线程各自按墙钟 `abs_pts` 独立节流、靠共用 `baseTime` "碰巧"对齐，**无反馈校正**，解码抖动/慢帧会缓慢漂移。mpv §3：音频自由播放、视频追音频**实测**时钟（`ao_get_delay` + `delay` 桥接 + `adjust_sync` 吃 10%）。AudioQueue 等价实测 = `AudioQueueGetCurrentTime`。

**务实判断**：seek/loop 要的是 (A) 对齐重起、**不是** (B) 持续追时钟。先做 (A) 把功能跑通；**等实际观察到预览音画漂移成问题，再上 (B)**。且 WorkLabs 是合成器，输出侧（录制/推流）已用墙钟 epoch，(B) 主要改善**预览观感**和长片漂移，不影响录制正确性。

### 3.6 建议落地顺序

1. **时间基准可重建 + 帧间隔 clamp**（= 议题一 §1.2 那件事）—— seek/loop 共同地基，不做后面全狂闪。
2. **seek 流程**：命令通道 + `avformat_seek_file` + flush 六处（2 packet + 2 frame 队列 + 2 解码器）+ `baseTime` 归零。
3. **hr-seek 精确度**：丢弃 `< 目标 pts` 的帧。
4. **loop**：`EOF → seek(0)`，复用 2/3。
5.（观察到漂移再做）**视频追音频主时钟**（§3 + `AudioQueueGetCurrentTime`）。

第 1~4 步一条线、共用同一套"清零重建"代码；第 5 步独立、可后置。

---

## 4. 待斟酌的决策点（供后续拍板）

1. **是否先做"地基"再做功能？** §3.6 第 1 步（可重建基准 + 帧间隔 clamp）是 seek/loop 的前提，也顺带补完 P0 #3、消除 pts reset 崩坏。建议先做，但需确认排期。
2. **节流模型要不要整体换成"相对积分时钟"？** 还是只做最小的"baseTime 可重建 + clamp"？前者更彻底（对齐 mpv §2.5）、改动大；后者成本低、够支撑 seek/loop。倾向后者起步。
3. **渲染线程要不要顺手从 usleep 轮询换成 condvar？**（议题一 §1.3）与 seek 改造同在 render 线程，可一并做，省电更准；也可独立排期。
4. **A/V 同步做到哪一档？** 先只做 §3.5(A)「对齐重起」，(B)「视频追音频主时钟」后置，等漂移成问题再做——需确认是否接受。
5. **hr-seek 精确度是否要做？** 不做则进度条只能跳到关键帧（可能差几秒）；做则精确到拖动点、成本是"解码丢弃早于目标的帧"。
6. **loop 的 EOF 尾巴**：是否要等帧队列排空再回跳（接缝更干净），还是接受简单实现。

---

## 5. 关联文档

- [MPV_时间戳源码深挖.md](MPV_时间戳源码深挖.md) —— 本文所有"mpv §X"引用的出处（产生/异常/同步/重置，逐函数 + 行号）。
- [MPV_时间戳与队列设计调研.md](MPV_时间戳与队列设计调研.md) —— 取经清单 P0-P2 + 队列/限流/背压。
- [WLMediaSource视频读取_漏洞与mpv对照.md](../../WorkLabs设计/WLMediaSource视频读取_漏洞与mpv对照.md) —— 视频读取链路时间戳漏洞对照。
