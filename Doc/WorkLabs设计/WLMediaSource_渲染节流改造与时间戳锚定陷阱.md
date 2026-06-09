# WLMediaSource 渲染节流改造 与 baseTime 时间戳锚定陷阱

> **性质**：实现决策记录 / 踩坑笔记（WorkLabs 自身代码，非外部调研）。
> **日期**：2026-06-08（同日两轮：先 condvar 化，再 pop-then-sleep + 队列纯化）。
> **涉及文件**：`WorkLabs/Source/MediaFile/WLMediaSource.m`（两条 render 线程 + `_baseTimeNs` + `wl_sleep_until_segment`）、`WorkLabs/Common/WLNodeQueue.h/.m`（本轮回归纯 FIFO）。
> **取经来源**：`Doc/调研/mpv/`（时间戳稳健 / 单调时钟）、`Doc/调研/OBS/`（系统时钟主导 / baseTime 共享即同步）。
> **范围**：本次只改 `WLMediaSource` **输出端**（pts 精确 + 源内 A/V 同步），不涉及下游 AudioQueue 延迟补偿、不涉及合成节拍。

---

## 0. 这次改了什么（一句话）

render 线程的节流经历了两步演进：

1. **`peek + usleep` 轮询**（墙钟 `CFAbsoluteTimeGetCurrent` + 相对 `usleep`）——旧实现，CPU 空转。
2. → 一度改成 **`peekBlocking + waitUntilDeadlineNs:` condvar 精确等待**（把「睡到 deadline、可被新帧/abort 提前唤醒」塞进队列、复用其 `_cond`）。
3. → **最终**：**`deQueue(阻塞) + 分段 nanosleep 睡到 deadline`**（pop-then-sleep）。第 2 步让队列懂了墙钟 deadline、职责不纯，且 `peek` 把队头裸指针漏到锁外有悬垂风险；第 3 步把节流彻底还给 render 线程，`WLNodeQueue` 回归纯 FIFO（见 §6.1）。

A/V 同步锚点 `baseTime` 则从「墙钟毫秒」改成「单调纳秒、有符号、CAS 锚定」——这一点三步不变。

本文档重点不是节流机制本身，而是其中一个**当前不触发、但 seek 实现时必然踩中**的时间戳锚定陷阱（§2~§4）——这是需要仔细研究的核心。

---

## 1. baseTime 锚定的模型

### 1.1 语义

`baseTime` 的物理含义是：**「源时间轴上 pts=0 的那一刻，对应到单调时钟上的哪个时刻」**。有了它，任意一帧的「应显示时刻（deadline）」就是：

```
deadline = baseTime + pts_ns          // (+ 可选的 a/v 微调 offset)
```

首帧用 CAS 锚定，使首帧立即出（`deadline == now`）：

```
baseTime = now − first_pts_ns          // 于是首帧 deadline = baseTime + first_pts_ns = now
```

video / audio 两条 render 线程**共享同一个 `baseTime`**（谁先出帧谁用 CAS 设、另一路读同一值）。因为两路 pts 同源（同一容器、同减 `startTime`），相同 pts 必算出相同 deadline → 同一时刻输出 → **这就是源内 A/V 同步**。

### 1.2 关键代码（最终版 · pop-then-sleep）

```objc
// 实例变量
_Atomic(int64_t) _baseTimeNs;   // 有符号！0 = 未锚定

// 单调时钟（CLOCK_UPTIME_RAW：单调、不受改系统时间/NTP 影响、休眠期间暂停）
static inline uint64_t wl_mono_now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// 分段睡眠：睡到单调 deadlineNs，单段 ≤capNs；rel<=0（已到/微负/过期）即返回 YES → 立即输出
static inline BOOL wl_sleep_until_segment(int64_t deadlineNs, int64_t capNs) {
    int64_t rel = deadlineNs - (int64_t)wl_mono_now_ns();
    if (rel <= 0) return YES;
    if (rel > capNs) rel = capNs;
    struct timespec ts = { (time_t)(rel / 1000000000LL), (long)(rel % 1000000000LL) };
    nanosleep(&ts, NULL);
    return NO;
}

// render 线程核心（pop-then-sleep）
WLNode *node = [self.videoFrameQueue deQueueWithBlock:YES];   // 取走 → 帧归本线程私有
if (!node) break;                                            // nil ⟺ abort（停止）
...
int64_t pts_ns = (int64_t)(normalized_pts * 1e9);            // 有符号
int64_t expected = 0;
atomic_compare_exchange_strong(&_baseTimeNs, &expected,
                               (int64_t)wl_mono_now_ns() - pts_ns);   // 首帧锚定
int64_t baseTime = atomic_load_explicit(&_baseTimeNs, memory_order_relaxed);
int64_t deadline = baseTime + pts_ns + (int64_t)(self.videoPtsOffset * 1e9);
deadline = wl_clamp_deadline(deadline);   // 坏 pts 兜底：离谱远的 deadline 钳到 now+1s（见 §4-b）

// 分段睡到 deadline，每段复查停止标志 → abort 最多延迟一段
while (self.isVideoRendering && !wl_sleep_until_segment(deadline, 20000000LL /* 20ms */)) { }
if (!self.isVideoRendering) { [node flush]; break; }         // 睡眠期间被叫停：丢帧退出
// → 输出
```

---

## 2. 陷阱本体：`pts_ns` 的取值范围会击穿朴素实现

`normalized_pts = wl_add_pts(node.pts, -startTime)`（已减容器 start_time）。直觉上它「从 0 开始、单调递增」，于是最初写成了 `uint64_t pts_ns`。但 `pts_ns` 实际有三种会出问题的取值：

### 坑 1：微负 `pts_ns`（边界帧）

容器 `start_time` 是「综合起始时间」，个别流的首帧 pts 可能**略小于** `start_time`（音视频起点本就可能不一致）。于是 `normalized_pts` 可能是 `-0.04` 这种微负值。

- **`uint64_t pts_ns = (uint64_t)(-0.04 * 1e9)`** → 负 double 转 uint64 = **巨大值**（约 1.8e19）→ 一切计算崩坏。

### 坑 2：大正 `pts_ns`（seek 后段）—— 最隐蔽

未来做 seek 时，seek 后的首帧 `normalized_pts` 可能很大（如 seek 到 1 小时 = `pts_ns ≈ 3.6e12`）。而 `wl_mono_now_ns()`（`CLOCK_UPTIME_RAW`）是**自开机的纳秒**——如果机器刚开机不久（`now` 较小），就有：

```
now − pts_ns = 6e10 − 3.6e12 = 负值
```

- 朴素写法 `(uint64_t)((int64_t)now − pts_ns)` → 负值转 uint64 = **下溢成巨大值** → `baseTime` 错乱 → `deadline` 巨大 → **render 线程永远等不到 → 卡死**。

> 这是本文档的核心。它**当前从头播放不触发**（首帧 `pts_ns≈0`，`now−0=now>0`），所以平时跑没问题；但 **seek 一旦落到「媒体内时间 > 本次开机时长」的位置就必然触发**。属于"代码看着没事、上线 seek 就崩"的典型隐患。

### 坑 3：倒退帧 → `deadline` 为负

若某帧 pts 比锚定帧还早（pts 倒退、或早于锚点的帧），`deadline = baseTime + pts_ns` 可能算出**负值**。这个负值若被当成「绝对睡眠刻度」喂进等待函数，会变成「睡到天荒地老」。

---

## 3. 解法：全链路 int64 + baseTime 有符号存储（而非 `if` 特判）

### 3.1 为什么不用 `if (pts_ns < 0)` 特判

特判要穷举所有出问题的 case（微负、大正、倒退、组合…），容易漏。**改用有符号运算，让负值/越界值自然参与计算且结果数学正确**，是更稳的做法——这与 mpv「时间戳稳健」的精神一致（见 `Doc/调研/mpv/MPV_时间戳源码深挖.md` §2）。

### 3.2 三处改动

1. **`pts_ns` 用 `int64_t`**：负 double 转 int64 得到真实负数（如 `-4e7`），不再下溢成巨值。
2. **`_baseTimeNs` 用 `_Atomic(int64_t)`**：`baseTime` 的物理含义是「pts=0 对应的单调时刻」；当 pts 不从 0 起、开机时间又短时，这个时刻**逻辑上可能在开机之前（数学负值）**。uint64 存不下才是病根，int64 存得下。
3. **`deadline` 全程 int64**：`deadline = baseTime + pts_ns + offset` 恒等于「now 级别的值」：
   ```
   deadline = (anchor_now − anchor_pts) + pts_n = anchor_now + (pts_n − anchor_pts)
   ```
   无论 `baseTime` 正负、`pts_ns` 大小，结果都正确。

### 3.3 负 / 过期 `deadline` 如何被安全吸收

pop-then-sleep 下 deadline 全程 int64，直接传进 `wl_sleep_until_segment(deadline, cap)`。helper 内 `rel = deadline − now`：

- `rel <= 0`（坑 3 的负 deadline、微负 pts、过期帧）→ 立即返回 `YES` → while 循环不进入 → **立即输出**，根本不调用 `nanosleep`。
- `rel > 0` → 睡 `min(rel, cap)`。

不再需要旧版「`(uint64_t)deadline` 只在 else 分支才安全」那套论证——int64 deadline 自带符号，负值/过期在 `rel<=0` 处被自然吸收。这正是 pop-then-sleep 比「condvar 等绝对 deadline」更干净的一点：等待原语只认「还要睡多久（相对、有符号判零）」，不认「绝对 deadline 是不是合法 uint64」。

---

## 4. 安全性推演（逐情况）

设 `now = wl_mono_now_ns()`（自开机纳秒，量级 1e13~1e14），`offset = 0`。

| 情况 | `pts_ns` | CAS `candidate = now − pts_ns` | `baseTime` | `deadline = baseTime + pts_ns` | 行为（`rel = deadline − now`） |
|---|---|---|---|---|---|
| **从头播放·首帧** | ≈ 0 | `now` | `now` | `now` | `rel≈0` → 立即出 ✓ |
| **边界微负·首帧** | −4e7（−40ms） | `now + 4e7`（正） | `now+4e7` | `now+4e7−4e7 = now` | `rel≈0` → 立即出 ✓ |
| **seek 后段·首帧** | 3.6e12（1h，> now） | `now − 3.6e12`（**负，int64 存得下**） | 逻辑负 | `(负) + 3.6e12 = now` | `rel≈0` → 立即出 ✓（不再下溢） |
| **非首帧·正常** | > anchor_pts | （CAS 失败，沿用） | 已锚定 | `anchor_now + (pts_n−anchor_pts)` > now | `rel>0` → 睡到 deadline ✓ |
| **倒退帧** | < anchor_pts | （CAS 失败，沿用） | 已锚定 | < now（可能负） | `rel<0` → 立即出 ✓（负值被 helper 吸收） |

**关键洞察**：`deadline` 永远 = `anchor_now + (当前帧pts − 锚定帧pts)`，它只依赖「当前帧相对锚定帧的 pts 差」，与 `baseTime` 的绝对正负无关。这就是为什么有符号运算能一招通吃所有情况。

---

## 4-b. 第二类陷阱：deadline 无穷大 / 有限巨值 → render 挂死

§2~§4 的三坑都靠「int64 有符号运算」解决（负值/越界值参与计算结果仍正确）。但还有一类坑 int64 救不了——**deadline 本身是无穷大或离谱巨值**，会让分段睡眠的外层 `while` 空转、等一个永远到不了的时刻。

> 注意：`wl_sleep_until_segment` 内 `if (rel > capNs) rel = capNs` 已把单次 `nanosleep` 钳在 20ms，所以**不是 nanosleep 睡无穷**；危险是外层 `while(running && !sleep_segment(...))` 反复「睡 20ms→醒→rel 仍巨大→再睡」，**几亿次空转 ≈ render 线程卡死几年**，后续帧全堵在队列、画面冻结。abort 能在 20ms 内跳出，但正常播放时这一帧就把线程钉死了。

### 来源

1. **inf / NaN 穿透校验**：坏 `time_base`（den=0 → `av_q2d` 给 inf）或异常时间戳产生 inf/NaN。`wl_pts_is_valid` 旧版只判 `!= WL_NOPTS_VALUE`，而 `NaN != 任何值` 恒为真 → 放行 → `(int64_t)(NaN*1e9)` 是 **UB**，deadline 成 ±inf 的截断巨值。这是字面意义的「无穷大」。
2. **有限但离谱**：损坏流给个 pts=5 万秒，`normalized_pts` 合法、有限，deadline 落在几小时后 → while 空转挂死。

### 两道防线

1. **上游 `isfinite`（挡 inf/NaN）**：`wl_pts_is_valid` 加 `&& isfinite(pts)`，inf/NaN 帧在归一化校验处即被当无效帧丢弃（`[node flush]; continue;`），到不了 deadline 计算。
2. **下游 `wl_clamp_deadline`（挡有限巨值）**：算出 deadline 后钳到 `now + WL_MAX_FRAME_WAIT_NS`（1s）。正常帧间隔几十 ms，1s 纯兜底——seek 后段首帧靠 CAS 锚定 `deadline≈now`（rel≈0）不受影响；只有「已锚定后某帧相对锚点 >1s」才触发，那本就是异常 / 大 gap。钳制选择「最多等 1s 后强制输出」而非丢帧：不丢内容、保证不挂死。

> 极端 int64 溢出（pts > ~292 年，`pts_ns` 接近 `INT64_MAX` 使 `baseTime+pts_ns` 回绕）不专门防——媒体不可能；且即便发生，回绕成负 deadline 会走 `rel<=0` 立即输出，仍不挂死。

---

## 5. 残留风险与边界说明

1. **哨兵 `0` 误判**：`_baseTimeNs == 0` 表示「未锚定」。若某帧 `candidate = now − pts_ns` **恰好等于 0**（即 `now == pts_ns` 到纳秒精确），会被误判为未锚定、下一帧重设。实际需要「开机时长恰等于媒体 pts 到纳秒」，不可能发生；即便发生，下一帧 `now` 已变、`candidate≠0`，自愈，无害。若要绝对严谨可改用独立的 `bool _baseTimeSet` 标志，但当前不必。

2. **大正 `pts_ns` 现在"不崩"但行为待 seek 时定义**：int64 让它不再下溢卡死（首帧 `deadline=now` 立即出）。但 seek 的完整正确行为（清空队列、`_baseTimeNs=0` 重锚、丢弃早于目标 pts 的帧做精确 seek）属于 seek 功能本身，见 `Doc/调研/mpv/MPV时间戳_讨论纪要与功能规划.md`。本次只保证「不崩」。

3. **stop/abort 延迟一段**：分段睡眠每段 ≤20ms，stop 信号最坏延迟一段才被复查到（一帧级，无感）。换来的是不必引入「可被提前唤醒的等待原语」（见 §6.3）。

4. **本次未处理（按范围）**：下游 AudioQueue 缓冲延迟（最终"听到 vs 看到"的偏移）、音频实测主时钟（`AudioQueueGetCurrentTime`）。`WLMediaSource` 的契约仅是「输出端 pts 精确 + 同 pts 同时刻输出」。

---

## 6. 顺带记录：这次 render 改造的其它关键决策

1. **把节流移出队列、`WLNodeQueue` 回归纯 FIFO（本轮核心重构）**：第 2 步实现曾把 `peekBlocking` + `waitUntilDeadlineNs:` 加进队列——让队列懂了 `CLOCK_UPTIME_RAW`、纳秒 deadline，本质是数据结构混进了播放器时基，**职责不纯**；且 `peek` 把队头裸指针漏到锁外返回，解锁后该 node 的 `frame` 随时可能被 `flush` 释放（靠"单消费者"口头约定保命，非结构保证）；peek-then-pop 还是两次加锁的非原子操作。改成 **pop-then-sleep**（先 `deQueue` 取走、帧归 render 私有、再纯 `nanosleep` 睡到 deadline）后，队列只剩 `enQueue`/`deQueueWithBlock:`/`deQueueWithTimeout:`/`flush`/`abort`，删掉了 `peekBlocking`/`waitUntilDeadlineNs:`/`peek`/`requeueFront:`/`enQueueNonBlocking:`/`count` 及 public `head`/`tail`（均**零外部引用**），封装闭合、职责单一。

2. **单调钟选 `CLOCK_UPTIME_RAW`**：单调、不受 NTP/改系统时间影响（墙钟 `CFAbsoluteTimeGetCurrent` 会被 NTP step/slew、改时间、休眠唤醒污染，详见对话记录），且**休眠期间暂停**——合盖唤醒后不会因为"日历时间过了很久"而瞬间冲一批帧。

3. **节流睡眠用分段 `nanosleep`（(c) 配 (a) 方案）**：`nanosleep` 是相对睡眠，时长随 `CLOCK_UPTIME_RAW` 同步推进，时基与 `wl_mono_now_ns` 一致。单段 ≤20ms、每段复查 `isXxxRendering` → stop/abort 最多延迟一段。为什么不用 condvar「睡到绝对 deadline + 被入队提前唤醒」？因为**帧已经取在手里**，render 不再需要「新帧入队就提前醒」的语义——那正是第 2 步把等待塞进队列的唯一理由。帧在手 → 只需「睡固定时长」→ `nanosleep` 足矣，无需 condvar，也就无需队列参与节流。

4. **停止协议复用 abort**：decode 线程结束时 `[frameQueue abort]`（broadcast）唤醒阻塞在 `deQueueWithBlock:YES` 的 render 线程 → 返回 nil → `break`（**阻塞出队返回 nil ⟺ abort，语义唯一**，比 `continue` 依赖标志可见性更稳）；若 render 正在分段睡眠，则靠每段复查 `isXxxRendering=NO` 退出并 `[node flush]` 丢弃手持帧。两条退出路径都无需额外停止机制。

5. **`videoPtsOffset/audioPtsOffset` 默认 30ms → 0**：原来两个对称 30ms 是统一延后（对 a/v 相对关系无影响），与"精确"诉求矛盾，改为 0（精确到点）；保留为秒级 a/v 微调旋钮供未来用。

6. **`deQueueWithTimeout:` 一并从 `CLOCK_REALTIME` 改 `relative_np`**：decode 线程取 packet 用的带超时出队，旧版基于 `CLOCK_REALTIME`（改系统时间会漂），改成 `pthread_cond_timedwait_relative_np`（单调），与全局时基统一。

---

## 7. 关键位置速查

- `WLMediaSource.m`：`wl_mono_now_ns()`（单调钟）、`wl_sleep_until_segment()`（分段睡眠）、`wl_clamp_deadline()` + `WL_MAX_FRAME_WAIT_NS`（巨值 deadline 兜底，§4-b）、`wl_pts_is_valid()`（`+ isfinite` 挡 inf/NaN，§4-b）、`_baseTimeNs`（`_Atomic(int64_t)` 锚点）、`videoRenderThread`/`audioRenderThread`（pop-then-sleep：阻塞出队 → CAS 锚定 → clamp → 分段睡到 deadline → 输出）。
- `WLNodeQueue.h/.m`：本轮回归**纯 FIFO**——`enQueue` / `deQueueWithBlock:`（阻塞，nil ⟺ abort）/ `deQueueWithTimeout:`（`relative_np`）/ `flush` / `abort`，不再有任何节流/时基相关方法。
- 关联：`Doc/调研/mpv/`（时间戳稳健 / 单调钟）、`Doc/调研/OBS/`（baseTime 共享即同步）、`Doc/调研/mpv/MPV时间戳_讨论纪要与功能规划.md`（seek/loop 规划，本陷阱是 seek 的前置）。
