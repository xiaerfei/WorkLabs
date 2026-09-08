# 媒体源 sleep / pacing 设计

> 日期：2026-09-09
> 基线：WorkOBS `dev`，`WLMediaSource` 已按本方案改造完成并编译通过、实测验收（305 秒零漂移 / 零丢帧 / 音频 1.000x）
> 对标：OBS `deps/media-playback/media-playback/media.c`（本机 `/Users/erfeixia/Documents/github/obs-studio`）
> 相关：`Doc/设计/重构/Audio.md` §4.5 / §6.1、`Doc/ToDo.md` A2、`Doc/调研/OBS/OBS_媒体源线程模型.md`
> 代码：`WorkOBS/OBSLabs/libwl/src/source/WLMediaSource.{hpp,cpp}`

---

## 0. 先讲个故事（理解全篇的地基）

地上有一条长线代表时间，上面每隔一段有一颗豆子：

```
时间线  0        16.7      21.3      33.3      42.7     50
        ●────────●─────────○─────────●─────────○────────●
        蓝+黄     蓝        黄        蓝        黄        蓝
```

- **蓝豆** = 视频帧（60fps，每 16.7 ms 一颗）
- **黄豆** = 音频帧（48k / 1024，每 21.3 ms 一颗）

你的任务：**走到哪颗豆就捡哪颗**，不挑颜色，谁在前面捡谁。

问题只有一个：**你怎么知道"什么时候该迈下一步"？**

### 笨办法：每次说"我再等 16.7 毫秒"

```
到豆 1 → 系鞋带 2ms → "再等 16.7ms"
到豆 2 → 系鞋带 3ms → "再等 16.7ms"     ← 又慢 3ms
到豆 3 → 系鞋带 1ms → "再等 16.7ms"     ← 又慢 1ms
```

每次都把"系鞋带的时间"白送出去 → **越走越慢**，电影越放越拖。

### 聪明办法：看手表，定"几点到"

```
现在 0ms    → 第 1 颗定在 16.7  → 睡 16.7ms
系鞋带 2ms  → 第 2 颗定在 33.3  → 只睡 14.7ms（自动扣掉磨蹭）
系鞋带 3ms  → 第 3 颗定在 50.0  → 只睡 13.7ms
```

**永远准时**，因为每次的目标是「上一颗豆的时间 + 间隔」，不是「现在 + 间隔」。

> **一句话记住：永远定"几点到"，不要定"等多久"。**
> 这就是 `next_ns += delta` 存在的唯一理由。

---

## 1. 为什么需要 sleep：解码远比播放快

`av_read_frame` + `avcodec_receive_frame` 的速度是**几十倍到上百倍实时**（尤其 VideoToolbox 硬解是异步的）。不节流的话，一秒钟就把整个文件解完，画面一闪而过。

所以主循环必须"按媒体的节奏等一等"。**pacing（节流）就是这件事。**

### 1.1 踩过的坑：不能有两个 pace

直觉做法是"视频自己 pace、音频自己 pace"，但两者在同一条**串行**主循环里，谁 sleep 谁就独占整条循环：

| 方案 | 后果（60fps + 48k/AAC） |
|---|---|
| **视频、音频各 pace 一次** | 每轮要同时满足视频 `k·16.67ms` 与音频 `k·21.33ms`，实际取 `max` → 整体节奏被**锁死成 46.875 fps**（= 48000/1024），**视频慢 22%**，且落后量 `k·4.67ms` 持续累积 |
| **只 pace 视频**（改造前的现状） | 音频不受控：每轮最多产 1 视频帧(16.7ms) + 1 音频帧(21.3ms) → 音频以 **1.28× 实时**堆积（每分钟多堆 ~17 秒），直到缓冲区溢出丢数据 |
| **只 pace 视频 + 水位 sleep** | 每 ~0.3s 触发一次 42.7ms 的 sleep ≈ **卡 2.6 个视频帧**，肉眼可见顿挫 |
| **✅ 单一放行线**（本方案 = OBS） | 只有一个 pace：按**合并事件序列**推进，视频帧与音频帧谁到点谁出场 |

### 1.2 合并事件序列

不挑颜色之后，豆子的顺序是**两路混排**：

```
60fps 视频：0 ── 16.7 ── 33.3 ── 50 ── 66.7 ── 83.3
48k   音频：0 ── 21.3 ── 42.7 ── 64 ── 85.3
合并后    ：0, 16.7(V), 21.3(A), 33.3(V), 42.7(A), 50(V), 64(A), 66.7(V), ...
```

事件密度 = 60 + 46.875 = **106.875 个/秒** → 平均每轮睡 **9.36 ms**（不是固定的 16.7！）。

**关键性质**：每轮只放行"到点"的帧，于是生产速率 = 合并序列的速率 = **1.0× 实时**。音频超产从根上消失，**不需要任何水位限速**。

---

## 2. 三个概念（贯穿全篇）

| 白话 | 代码 | 含义 |
|---|---|---|
| **你脚下踩着的位置** | `next_pts_ns_` | 放行线（媒体时基）。`pts ≤ 它` 的帧才可投放 |
| **往前看，最近的那颗豆** | `min_next_ns` | `min(视频就绪帧 pts, 音频就绪帧 pts)` |
| **要走多远** | `delta` | `min_next_ns − next_pts_ns_`，也就是**这一觉睡多久** |
| **那个位置是手表上的几点** | `next_ns_` | 放行线对应的**墙钟绝对时刻** |

```
       你脚下                前方的豆
          ↓                     ↓
时间线  0        16.7      21.3      33.3
        ●────────●─────────○─────────●
        已捡      蓝        黄        蓝
```

| 轮 | 你站在哪 `next_pts_ns_` | 前面最近的豆 `min_next_ns` | 要走多远 `delta` | 走到之后 |
|---|---|---|---|---|
| 1 | 0 | 16.7（蓝） | 16.7 | 站到 16.7 |
| 2 | 16.7 | 21.3（黄） | 4.6 | 站到 21.3 |
| 3 | 21.3 | 33.3（蓝） | 12.0 | 站到 33.3 |

**规律**：走到哪，`next_pts_ns_` 就变成哪；然后重新往前看，找新的 `min_next_ns`。

### 2.1 为什么一个用 `+=`、一个用 `=`？

```c
m->next_ns    += delta;        // 累加
m->next_pts_ns = min_next_ns;  // 赋值
```

**数学上完全等价**（`min_next_ns == next_pts_ns + delta`），只是说法不同：

- `next_pts_ns_` 用赋值更直观（它就是"下一颗豆的位置"）
- `next_ns_` 用累加是为了**强调"绝对时刻、不漂移"**——必须基于"上一次的目标"，绝不能基于"现在"

---

## 3. OBS 是怎么做的（源码级）

文件：`deps/media-playback/media-playback/media.c` / `media.h`

### 3.1 状态量

```c
// media.h:80-85
int64_t play_sys_ts;    // 本次播放起点的系统钟 os_gettime_ns()
int64_t next_pts_ns;    // ★ 放行线（媒体时基）
uint64_t next_ns;       // ★ 放行线对应的墙钟绝对时刻（sleep 睡到它）
int64_t start_ts;       // 本次播放的媒体起点
int64_t base_ts;        // 媒体时间轴累计平移量（seek/loop 时 +=）
bool    full_decode;    // true = 不 pace，全速解码（预加载/缓存用）
```

外加进程级零点：

```28:28:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
static int64_t base_sys_ts = 0;
```
```951:952:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
	if (!base_sys_ts)
		base_sys_ts = (int64_t)os_gettime_ns();
```

### 3.2 主循环：睡一次 → 各放一帧 → 补货 → 推进

```796:876:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
	for (;;) {
		...
		if (!is_active || pause) {
			if (os_sem_wait(m->sem) < 0)      // 暂停：挂信号量，不是 sleep
				return false;
			if (pause)
				reset_ts(m);
		} else {
			timeout = mp_media_sleep(m);          // ① 全循环唯一 sleep
		}
		...
		if (is_active && !timeout) {
			if (m->has_video) mp_media_next_video(m, false);   // ② 到点才放
			if (m->has_audio) mp_media_next_audio(m);           // ③ 到点才放
			if (!mp_media_prepare_frames(m)) return false;      // ④ 补货
			if (mp_media_eof(m)) continue;
			mp_media_calc_next_ns(m);                           // ⑤ 推进放行线
		}
	}
```

> 顺序不能换：**睡 → 放 → 补货 → 算**。因为"算"需要"补货"拿到的新 pts。

### 3.3 sleep：睡到绝对时刻

```632:652:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
static inline bool mp_media_sleep(mp_media_t *m)
{
	bool timeout = false;

	if (!m->next_ns) {
		m->next_ns = os_gettime_ns();          // ★ 首轮/重锚：以现在为基准，不睡
	} else {
		const uint64_t t = os_gettime_ns();
		if (m->next_ns > t) {
			const uint64 delta_ms = (uint32_t)((m->next_ns - t + 500000) / 1000000);
			if (delta_ms > 0) {
				static const uint32_t timeout_ms = 200;
				timeout = delta_ms > timeout_ms;       // 落后 > 200ms → 标记
				os_sleep_ms(timeout ? timeout_ms : delta_ms);
			}
		}
	}

	return timeout;
}
```

- `+500000` = 纳秒→毫秒的**四舍五入**，宁可多睡 0.5ms 也别早醒忙等；
- 粒度是 `os_sleep_ms`（毫秒级），单轮有 ±1ms 量化误差，**但因为推进的是绝对时刻，不累积**；
- `200ms` 上限防"时间戳跳变导致睡死"；`timeout == true` 时**本轮一帧都不放**，分 200ms 一段追上来再放。

### 3.4 谁可以出场

```353:359:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
static inline bool mp_media_can_play_frame(mp_media_t *m, struct mp_decode *d)
{
	if (m->full_decode)
		return d->frame_ready;
	return d->frame_ready && (d->frame_pts <= m->next_pts_ns ||
				  (d->frame_pts - m->next_pts_ns > MAX_TS_VAR));   // 2s 跳变强放
}
```

**视频和音频各自独立判这一个条件**，互不等谁——同一轮可能只放视频、只放音频、或都放。

### 3.5 推进多少

```322:336:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
static inline int64_t mp_media_get_next_min_pts(mp_media_t *m)
{
	int64_t min_next_ns = 0x7FFFFFFFFFFFFFFFLL;

	if (m->has_video && m->v.frame_ready) {
		if (m->v.frame_pts < min_next_ns)
			min_next_ns = m->v.frame_pts;
	}
	if (m->has_audio && m->a.frame_ready) {
		if (m->a.frame_pts < min_next_ns)
			min_next_ns = m->a.frame_pts;
	}

	return min_next_ns;
}
```
```529:549:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
static void mp_media_calc_next_ns(mp_media_t *m)
{
	int64_t min_next_ns = mp_media_get_next_min_pts(m);
	int64_t delta = min_next_ns - m->next_pts_ns;

	if (m->seek_next_ts) {
		delta = 0;
		m->seek_next_ts = false;
	} else {
		if (delta < 0)
			delta = 0;
		if (delta > 3000000000)       // 3s 跳变保护
			delta = 0;
	}

	m->next_ns += delta;              // ★ 累加
	m->next_pts_ns = min_next_ns;     // ★ 赋值
}
```

> **关键性质**：`next_ns` 与 `next_pts_ns` 每次加同一个 `delta` → **差值恒定**。
> 所以"睡到 `next_ns`" 等价于 "睡到 `SysOf(next_pts_ns)`"。

### 3.6 补货：提前解一帧攥在手里（本方案成立的前提）

```204:216:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
static inline bool mp_media_ready_to_start(mp_media_t *m)
{
	if (m->has_audio && !m->a.eof && !m->a.frame_ready)
		return false;
	if (m->has_video && !m->v.eof && !m->v.frame_ready)
		return false;
	return true;
}

static inline bool mp_decode_frame(struct mp_decode *d)
{
	return d->frame_ready || mp_decode_next(d);
}
```
```278:308:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
bool mp_media_prepare_frames(mp_media_t *m)
{
	bool actively_seeking = m->seek_next_ts && m->pause;

	while (!mp_media_ready_to_start(m)) {
		if (!m->eof) {
			int ret = mp_media_next_packet(m);
			...
		}
		...
		if (m->has_video && !mp_decode_frame(&m->v))
			return false;
		if (m->has_audio && !mp_decode_frame(&m->a))
			return false;
	}
	...
}
```

**这就是"下一帧 pts 从哪来"的答案**：OBS 永远提前把两路各解一帧**攥在手里**（`frame_ready`），投放时才清标志：

```408:412:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
	if (!preload) {
		if (!mp_media_can_play_frame(m, d))
			return;

		d->frame_ready = false;      // ★ 放出去了，手里空了
```

### 3.7 时间戳：音视频用**逐字相同**的公式

```c
// media.c:477（video）
frame->timestamp = m->full_decode ? d->frame_pts
    : (m->base_ts + d->frame_pts - m->start_ts + m->play_sys_ts - base_sys_ts);

// media.c:388（audio）—— 完全相同的表达式
audio.timestamp  = m->full_decode ? d->frame_pts
    : m->base_ts + d->frame_pts - m->start_ts + m->play_sys_ts - base_sys_ts;
```

| 量 | 含义 | 何时变 |
|---|---|---|
| `base_ts` | 媒体轴累计平移 | seek / loop 时 `+=` |
| `start_ts` | 本次播放的媒体起点 | 起播 / reset |
| `play_sys_ts` | 本次播放起点的墙钟 | 起播 / reset / **暂停恢复** |
| `base_sys_ts` | 进程零点（首次 init 时） | 不变 |

seek 只平移媒体轴、不动墙钟：

```590:598:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
	int64_t next_ts = mp_media_get_base_pts(m);
	int64_t offset = next_ts - m->next_pts_ns;
	...
	m->eof = false;
	m->base_ts += next_ts;        // ★ 媒体轴平移
	m->seek_next_ts = false;
```

暂停恢复（`reset_ts`）也是音视频一起改同一个量：

```769:775:/Users/erfeixia/Documents/github/obs-studio/deps/media-playback/media-playback/media.c
static void reset_ts(mp_media_t *m)
{
	m->base_ts += mp_media_get_base_pts(m);
	m->play_sys_ts = (int64_t)os_gettime_ns();
	m->start_ts = m->next_pts_ns = mp_media_get_next_min_pts(m);
	m->next_ns = 0;
}
```

### 3.8 两个旁路（我们没搬）

| 旁路 | OBS 实现 | 用途 |
|---|---|---|
| 变速 | `audio.samples_per_sec = f->sample_rate * m->speed / 100;`（`:384`） | 倍速播放 |
| full_decode | `can_play_frame` 直接返回 `frame_ready`；`mp_media_init_internal` 里 `if (info->full_decode) return true;`（`:910`） | stinger 转场预加载 / 缓存，**不 pace** |

### 3.9 一个容易忽略的点：OBS 是**两级**时间归一

1. **media 层**：媒体 pts → 一条"相对轴"（含 `− base_sys_ts`），保证 a/v **相对**对齐；
2. **libobs 源入口**：`obs_source_output_audio/video` 再算 `timing_adjust = os_gettime_ns() − timestamp`（`obs-source.c:1454/1572`），把相对轴**拉回真正的系统钟**。

我们把两级**合并成一级**（`SysOf()` 直接产出系统钟），因为没有 OBS 那套全局源时基；壳层的 `timing_adjust_` 保留给麦克风这类"自带设备时钟、无媒体时间轴"的实时源。

---

## 4. 我们怎么做

### 4.1 与 OBS 的差异（有意为之）

| 项 | OBS | WorkOBS | 原因 |
|---|---|---|---|
| 进程零点 `base_sys_ts` | 有（时间戳相对进程启动） | **去掉** | 我们用 `CLOCK_MONOTONIC`，数值本就可控；少一个量少一处错 |
| `full_decode` | 有（预加载/缓存不 pace） | **不做** | 无 stinger/缓存需求 |
| 变速 `speed` | 有 | **不做** | 无倍速需求 |
| 暂停 | `os_sem_wait` | `pthread_cond_wait`（沿用现状） | 现状已能 signal 唤醒，更利于 stop 打断 |
| seek | 主循环内 `av_seek_frame` | 主循环内**仅 flush**（`av_seek_frame` 待 S1） | S1 是独立任务 |
| 节流方式 | 放行线 | **完全照搬** | — |

### 4.2 状态量

```cpp
// WLMediaSource.hpp
AVFrame *v_frame_;  int64_t v_pts_;  bool v_ready_;  bool v_drained_;   // 手里攥着的视频帧
AVFrame *a_frame_;  int64_t a_pts_;  bool a_ready_;  bool a_drained_;   // 手里攥着的音频帧
bool     read_eof_;        // av_read_frame 已 EOF

int64_t next_pts_ns_;      // 放行线（媒体时基）
int64_t next_ns_;          // 它对应的墙钟绝对时刻；0 = 需要重新锚定
int64_t start_ts_ns_;      // 本次播放的媒体起点
int64_t base_ts_ns_;       // 媒体轴平移量（seek/loop 时 +=）
int64_t play_sys_ts_ns_;   // 本次播放起点的墙钟
```

### 4.3 主循环五步

```292:368:WorkOBS/OBSLabs/libwl/src/source/WLMediaSource.cpp
```

| 步 | 代码位置 | 做什么 |
|---|---|---|
| 1 | `ThreadLoop` 顶部 | 控制：pause 挂起；**恢复后 `next_ns_ = 0` 重锚** |
| 2 | `ThreadLoop` | seek：flush + 丢手里帧 + 重锚（标志位模式） |
| 3 | `ThreadLoop` | 起播/重锚：`PrepareFrames()` 拿首帧 pts → `ResetTs()`（**不睡**） |
| 4 | `ThreadLoop` | **全循环唯一 sleep**：睡到 `next_ns_`；落后 >200ms 分段追、本轮不放帧 |
| 5 | `ThreadLoop` | 到点才放 → `PrepareFrames()` 补货 → `AdvancePts()` 推进 |

```
       ┌──────────────────────────────────────────────┐
       ▼                                              │
  ① 睡到 next_ns_                                     │
       │                                              │
  ② 放帧（到点的才放）← 放的是「上一轮取的」帧           │
       │                                              │
  ③ 取下一帧 PrepareFrames（两路各攥一帧）              │
       │                                              │
  ④ 算 delta、next_ns_ += delta                       │
       └──────────────────────────────────────────────┘
```

**顺序不能换**：不先取帧就不知道下一帧 pts，算不出 delta，就不知道睡多久。

### 4.4 关键函数逐个讲

**① 往前看在哪颗豆**

```147:152:WorkOBS/OBSLabs/libwl/src/source/WLMediaSource.cpp
int64_t WLMediaSource::MinReadyPts() const {
    int64_t min_pts = INT64_MAX;
    if (v_ready_ && v_pts_ < min_pts) min_pts = v_pts_;
    if (a_ready_ && a_pts_ < min_pts) min_pts = a_pts_;
    return min_pts;
}
```

**② 到点判定**

```155:158:WorkOBS/OBSLabs/libwl/src/source/WLMediaSource.cpp
bool WLMediaSource::CanPlay(int64_t pts_ns) const {
    return pts_ns <= next_pts_ns_ ||
           (pts_ns - next_pts_ns_ > WL_MAX_TS_VAR_NS);   // 跳变 > 2s 强放，防卡死
}
```

**③ 重锚（起播 / 暂停恢复 / seek）**

```164:169:WorkOBS/OBSLabs/libwl/src/source/WLMediaSource.cpp
void WLMediaSource::ResetTs() {
    play_sys_ts_ns_ = WLTime::NowNs();
    start_ts_ns_    = MinReadyPts();      // 本次播放的媒体起点
    next_pts_ns_    = start_ts_ns_;
    next_ns_        = play_sys_ts_ns_;    // 本轮不睡，立即放首帧
}
```

**④ 推进放行线**

```172:182:WorkOBS/OBSLabs/libwl/src/source/WLMediaSource.cpp
void WLMediaSource::AdvancePts() {
    int64_t min_next = MinReadyPts();
    if (min_next == INT64_MAX) return;    // 两路都排空，不再推进

    int64_t delta = min_next - next_pts_ns_;
    if (delta < 0)                delta = 0;                 // 单调保护
    if (delta > WL_MAX_TS_JUMP_NS) delta = 0;                // 3s 跳变：本轮不推进

    next_ns_    += delta;        // ★ 累加：绝对时刻，误差不累积
    next_pts_ns_ = min_next;     // ★ 赋值：走到那颗豆
}
```

**⑤ 补货（提前攥一帧）**

```229:258:WorkOBS/OBSLabs/libwl/src/source/WLMediaSource.cpp
```

要点：
- 循环直到"不需要帧的那一路之外，其余每路手里都攥着一帧"；
- **先收后读**：`TryReceiveX()` 失败才 `Read()`（B 帧延迟，codec 内可能缓存多帧）；
- `ReceiveX` 返回 `WL_FRAME_EOF` 才置 `drained_`（`EAGAIN` 不算）；
- 单路文件（纯音频/纯视频）：另一路立刻 `drained_`，逻辑不用特判。

**⑥ 投放**

```260:271:WorkOBS/OBSLabs/libwl/src/source/WLMediaSource.cpp
```

硬解帧零拷贝：`v_frame_->data[3]` 就是 `CVPixelBufferRef`，壳内部 retain，`av_frame_free` 后仍有效。

### 4.5 第一帧：sleep 0

```
t = 0（起播）
  取帧：V0(pts=0)  A0(pts=0)
  ResetTs：play_sys=0ms, start_ts=0, next_pts=0, next_ns=0ms
  睡  ：next_ns(0) > now(0.002)? 否 → 不调 SleepToNs        ← sleep 0
  放  ：V0 ✓   A0 ✓
  取  ：V1(40ms)  A1(23.2ms)
  算  ：min = 23.2 → delta = 23.2 → next_ns = 23.2ms
```

**为什么不睡**：没有"上一次的目标"可累加；首帧的投放时刻就定义为时间原点 `play_sys_ts_ns_`。

同一个 `next_ns_ = 0` 还用在两处：**暂停恢复**（墙钟在暂停期间照走，旧放行线作废）、**seek**。

### 4.6 时间戳：音视频同一个函数

```cpp
int64_t SysOf(int64_t pts_ns) const {
    return base_ts_ns_ + pts_ns - start_ts_ns_ + play_sys_ts_ns_;
}
```

- 音视频过**同一个** `SysOf()` → 差值恒为 0，天然对齐；
- `base_ts_ns_`：只在 seek / loop 时 `+= 目标 pts`（媒体轴平移，不动 `play_sys_ts_ns_`）；
- 目前视频仍传媒体 pts 给 `source_->OutputVideo()`（壳的 `GetFrame` 自己锚定，契约不变）；`SysOf()` 留给 A4 的音频输出使用。

---

## 5. 完整走一遍（真实素材：25fps + 44.1k/1024）

| 轮 | 手里攥着 | 睡到 | 醒来放谁 | 补货 | delta | 新 next_ns_ |
|---|---|---|---|---|---|---|
| 1 | V0(0) A0(0) | 0（不睡） | V0 ✓ A0 ✓ | V1(40) A1(23.2) | 23.2 | 23.2 |
| 2 | V1(40) A1(23.2) | 23.2 | A1 ✓（V1 未到点） | V2(80) | 16.8 | 40.0 |
| 3 | V2(80) A1已放 | 40.0 | V1 ✓ | A2(46.4) | 6.4 | 46.4 |
| 4 | V2(80) A2(46.4) | 46.4 | A2 ✓ | V3(120) | 33.6 | 80.0 |
| 5 | V3(120) | 80.0 | V2 ✓ | A3(69.6) | — | — |

**平均每轮 sleep** = 1 / (25 + 43.07) = **14.7 ms**（不是 40ms，也不是 23.2ms）。

---

## 6. 关键参数

| 参数 | 值 | 位置 | 说明 |
|---|---|---|---|
| `WL_LAG_LIMIT_NS` | 200 ms | `WLMediaSource.cpp` | 落后上限：单次最多睡 200ms，超过则本轮不放帧（OBS `timeout_ms` 同值） |
| `WL_MAX_TS_JUMP_NS` | 3 s | 同上 | 放行线单次推进上限，超过视为跳变（OBS `media.c:543` 同值） |
| `WL_MAX_TS_VAR_NS` | 2 s | 同上 | 强放阈值：`pts − next_pts_ns_ > 2s` 的帧强制放行（OBS `MAX_TS_VAR`） |
| `WL_STATS_INTERVAL_NS` | 5 s | 同上 | 诊断日志周期 |
| `WL_MEDIA_PACE_STATS` | 1 | 同上 | 诊断开关，验收后置 0 |

---

## 7. 验证结果（实测 305 秒）

```
[media pace] wall=5.02s media=5.04s v=126 a=217 audio=1.004x late avg=2.47ms max=7.7ms
...
[media pace] wall=305.68s media=305.69s v=7643 a=13165 audio=1.000x late avg=2.42ms max=7.6ms
```

| 指标 | 实测 | 判据 |
|---|---|---|
| `audio` 倍率 | 全程 1.000~1.004x | ✅ 旧方案 1.28x，**超产根治** |
| `media` vs `wall` | 差值恒定 +10~20ms，5 分钟无趋势 | ✅ **零漂移** |
| 视频帧数 | 7643 / 305.68s = **25.00 fps**（素材 25fps） | ✅ 零丢帧 |
| 音频帧数 | 13165 / 305.68s = **43.07/s** = 44100/1024 | ✅ 零丢帧 |
| `late` | avg 0.8~2.5ms，偶发 max 21.9ms | ✅ macOS nanosleep 过睡量，**不累积** |

> `late` 出现 0.8ms / 2.5ms 两档，是 macOS 定时器合并/省电策略导致（系统忙时精度高），与代码无关。因为睡的是绝对时刻，过睡会被下一轮自动扣掉。

---

## 8. FAQ（讨论中真实卡住过的点）

**Q1：`next_pts_ns` 怎么知道？**
不用"算"，它是**上一轮留下的**（走到哪站哪）；只有第一轮需要现取一次 `MinReadyPts()`。它的源头是文件 pts → FFmpeg → `WLDecoder::ReceiveXxx()` 给的 `out_pts_ns`（已是纳秒）。

**Q2：下一帧还没从 FFmpeg 取出来，怎么知道它的 pts？**
不知道——所以**必须提前解一帧攥在手里**（`PrepareFrames` + `v_frame_/a_frame_`）。"下一帧"不是未来的帧，是已解好未投放的帧。

**Q3：为什么一个 `+=` 一个 `=`？**
数学等价（同一个 delta）。`next_ns_` 用 `+=` 是为了强调"基于上次目标、不漂移"。

**Q4：第一帧睡多久？**
0。没有上次目标可累加，只能把"现在"定义为原点。

**Q5：音频会不会拖慢视频？**
不会。音频不单独 sleep，只由放行线决定"到点才投"；视频帧 k 的投放时刻 ≈ `SysOf(k·40ms)`，与"只给视频 pace"完全一致。

**Q6：解码耗时会不会造成漂移？**
不会。解码发生在"放帧之后、算 delta 之前"，而 delta 是**累加到旧目标**上，所以耗时只是让本轮少睡（甚至不睡），不进入下一轮的目标。

**Q7：落后太多怎么办？**
`now` 已超过 `next_ns_` → `SleepToNs` 返回 false → 不睡直接放帧自动追赶；若落后 > 200ms，分 200ms 一段追，且**本轮不放帧**（防止一次性倾泻）。

**Q8：`late` 长期很大要紧吗？**
只要 `late` 明显小于平均事件间隔（14.7ms），就只是"少睡一点"，不丢帧不漂移。若长期 > 间隔，才需要：① 给解码线程设 `QOS_CLASS_USER_INTERACTIVE`；② `WLTime::SleepToNs` 从 `nanosleep` 换成 `mach_wait_until`（`WLTime.hpp` 已留口子）。

---

## 9. 后续

- **A3/A4**：`ReleaseAudio()` 里已留接入点（`WLResampler` → `source_->OutputAudio(...)`），主循环不用再动。
- **S1 seek**：主循环 seek 分支补 `av_seek_frame`，其余重锚逻辑已在位。
- **P2 暂停恢复**：`resumed → next_ns_ = 0 → ResetTs()` 已实现，音视频同一个量一起改。
- 验收后把 `WL_MEDIA_PACE_STATS` 置 0。
