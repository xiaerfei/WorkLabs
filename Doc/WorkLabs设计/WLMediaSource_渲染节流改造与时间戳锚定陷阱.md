# WLMediaSource 渲染节流改造 与 baseTime 时间戳锚定陷阱

> **性质**：实现决策记录 / 踩坑笔记（WorkLabs 自身代码，非外部调研）。
> **日期**：2026-06-08
> **涉及文件**：`WorkLabs/Source/MediaFile/WLMediaSource.m`（两条 render 线程 + `_baseTimeNs`）、`WorkLabs/Common/WLNodeQueue.h/.m`（`peekBlocking` / `waitUntilDeadlineNs:`）。
> **取经来源**：`Doc/调研/mpv/`（condvar 精确等待 / 单调时钟）、`Doc/调研/OBS/`（系统时钟主导 / baseTime 共享即同步）。
> **范围**：本次只改 `WLMediaSource` **输出端**（pts 精确 + 源内 A/V 同步），不涉及下游 AudioQueue 延迟补偿、不涉及合成节拍。

---

## 0. 这次改了什么（一句话）

把两条 render 线程从 **`peek + usleep` 轮询**（墙钟 `CFAbsoluteTimeGetCurrent` + 相对 `usleep`）改成 **`peekBlocking + waitUntilDeadlineNs` 精确等待**（单调钟 + condvar），并把 A/V 同步锚点 `baseTime` 从「墙钟毫秒」改成「单调纳秒、有符号、CAS 锚定」。

本文档重点不是改造本身，而是其中一个**当前不触发、但 seek 实现时必然踩中**的时间戳锚定陷阱——这是需要仔细研究的核心。

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

### 1.2 关键代码（最终版）

```objc
// 实例变量
_Atomic(int64_t) _baseTimeNs;   // 有符号！0 = 未锚定

// 单调时钟（CLOCK_UPTIME_RAW：单调、不受改系统时间/NTP 影响、休眠期间暂停）
static inline uint64_t wl_mono_now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// render 线程核心节流
int64_t pts_ns = (int64_t)(normalized_pts * 1e9);   // 有符号

int64_t expected = 0;
atomic_compare_exchange_strong(&_baseTimeNs, &expected,
                               (int64_t)wl_mono_now_ns() - pts_ns);   // 首帧锚定
int64_t baseTime = atomic_load_explicit(&_baseTimeNs, memory_order_relaxed);

int64_t deadline = baseTime + pts_ns + (int64_t)(self.videoPtsOffset * 1e9);
if ((int64_t)wl_mono_now_ns() >= deadline) {
    // 到点/已过 → 立即出帧
} else {
    [self.videoFrameQueue waitUntilDeadlineNs:(uint64_t)deadline];   // 睡到点 / 被新帧·abort 唤醒
}
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

若某帧 pts 比锚定帧还早（pts 倒退、或早于锚点的帧），`deadline = baseTime + pts_ns` 可能算出**负值**。这个负值若被 `(uint64_t)deadline` 传进等待函数，会变成「睡到天荒地老」。

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

### 3.3 `(uint64_t)deadline` 何时安全

`waitUntilDeadlineNs:(uint64_t)deadline` **只在 else 分支调用**，而 else 的前提是 `(int64_t)now < deadline`，即 `deadline > now > 0`。所以传进去的 `deadline` 必为正，`(uint64_t)` 转换安全。**坑 3 的负 deadline 走的是"立即出帧"分支，永远不会传进等待函数。**

---

## 4. 安全性推演（逐情况）

设 `now = wl_mono_now_ns()`（自开机纳秒，量级 1e13~1e14），`offset = 0`。

| 情况 | `pts_ns` | CAS `candidate = now − pts_ns` | `baseTime` | `deadline = baseTime + pts_ns` | 行为 |
|---|---|---|---|---|---|
| **从头播放·首帧** | ≈ 0 | `now` | `now` | `now` | 立即出 ✓ |
| **边界微负·首帧** | −4e7（−40ms） | `now + 4e7`（正） | `now+4e7` | `now+4e7−4e7 = now` | 立即出 ✓ |
| **seek 后段·首帧** | 3.6e12（1h，> now） | `now − 3.6e12`（**负，int64 存得下**） | 逻辑负 | `(负) + 3.6e12 = now` | 立即出 ✓（不再下溢） |
| **非首帧·正常** | > anchor_pts | （CAS 失败，沿用） | 已锚定 | `anchor_now + (pts_n−anchor_pts)` > now | 等到 deadline ✓ |
| **倒退帧** | < anchor_pts | （CAS 失败，沿用） | 已锚定 | < now（可能负） | `now ≥ deadline` → **立即出**，负 deadline 不传入等待 ✓ |

**关键洞察**：`deadline` 永远 = `anchor_now + (当前帧pts − 锚定帧pts)`，它只依赖「当前帧相对锚定帧的 pts 差」，与 `baseTime` 的绝对正负无关。这就是为什么有符号运算能一招通吃所有情况。

---

## 5. 残留风险与边界说明

1. **哨兵 `0` 误判**：`_baseTimeNs == 0` 表示「未锚定」。若某帧 `candidate = now − pts_ns` **恰好等于 0**（即 `now == pts_ns` 到纳秒精确），会被误判为未锚定、下一帧重设。实际需要「开机时长恰等于媒体 pts 到纳秒」，不可能发生；即便发生，下一帧 `now` 已变、`candidate≠0`，自愈，无害。若要绝对严谨可改用独立的 `bool _baseTimeSet` 标志，但当前不必。

2. **大正 `pts_ns` 现在"不崩"但行为待 seek 时定义**：int64 让它不再下溢卡死（首帧 `deadline=now` 立即出）。但 seek 的完整正确行为（清空队列、`_baseTimeNs=0` 重锚、丢弃早于目标 pts 的帧做精确 seek）属于 seek 功能本身，见 `Doc/调研/mpv/MPV时间戳_讨论纪要与功能规划.md`。本次只保证「不崩」。

3. **本次未处理（按范围）**：下游 AudioQueue 缓冲延迟（最终"听到 vs 看到"的偏移）、音频实测主时钟（`AudioQueueGetCurrentTime`）。`WLMediaSource` 的契约仅是「输出端 pts 精确 + 同 pts 同时刻输出」。

---

## 6. 顺带记录：这次 render 改造的其它关键决策

1. **单调钟选 `CLOCK_UPTIME_RAW`**：单调、不受 NTP/改系统时间影响（墙钟 `CFAbsoluteTimeGetCurrent` 会被 NTP step/slew、改时间、休眠唤醒污染，详见对话记录），且**休眠期间暂停**——合盖唤醒后不会因为"日历时间过了很久"而瞬间冲一批帧。

2. **等待用 `pthread_cond_timedwait_relative_np` 而非绝对 deadline + condattr**：macOS 的 pthread **不支持** `pthread_condattr_setclock(CLOCK_MONOTONIC)`（mpv 在 Linux 上的做法）。Darwin 原生的 `pthread_cond_timedwait_relative_np` 用相对超时、内部走单调钟，正是 macOS 上"睡到单调时刻、不受改时间影响"的正确姿势。`WLNodeQueue.deQueueWithTimeout:` 也一并从 `CLOCK_REALTIME` 改成它。

3. **`peekBlocking` 无丢失唤醒**：空队列时在锁内 `while(!head && !abort) cond_wait`，「检查队头 + 进入等待」原子完成，避免「peek 到空 → 还没进 wait → enQueue signal 丢失 → 死等」的经典竞态。而「有队头、等 deadline」那条 race 无害——新帧加在队尾不改变队头，被 enQueue signal 唤醒只是假唤醒，重判后继续等到 deadline。

4. **停止协议复用现有 abort**：decode 线程结束时 `[frameQueue abort]`（broadcast）会唤醒阻塞在 `peekBlocking`/`waitUntilDeadlineNs` 的 render 线程，使其 `while(isRendering)` 判退出。无需额外停止机制。

5. **`videoPtsOffset/audioPtsOffset` 默认 30ms → 0**：原来两个对称 30ms 是统一延后（对 a/v 相对关系无影响），与"精确"诉求矛盾，改为 0（精确到点）；保留为秒级 a/v 微调旋钮供未来用。

---

## 7. 关键位置速查

- `WLMediaSource.m`：`wl_mono_now_ns()`（单调钟）、`_baseTimeNs`（`_Atomic(int64_t)` 锚点）、`videoRenderThread`/`audioRenderThread`（CAS 锚定 + deadline 节流）。
- `WLNodeQueue.m`：`peekBlocking`（空队列阻塞等）、`waitUntilDeadlineNs:`（`relative_np` 睡到单调 deadline）、`deQueueWithTimeout:`（已改 `relative_np`）。
- 关联：`Doc/调研/mpv/`（时间戳稳健 / condvar）、`Doc/调研/OBS/`（baseTime 共享即同步）、`Doc/调研/mpv/MPV时间戳_讨论纪要与功能规划.md`（seek/loop 规划，本陷阱是 seek 的前置）。
