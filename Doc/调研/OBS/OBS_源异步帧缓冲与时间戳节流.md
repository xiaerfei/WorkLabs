# OBS 源的异步帧缓冲与时间戳节流

> **性质**：OBS 源码级深挖调研 · 系列第 ② 篇（维度：源帧缓冲 / 源侧时间戳）。
> **调研对象**：obs-studio `32.1.2-94-gf61619ce3`，主文件 `libobs/obs-source.c`（约 6000 行）+ `obs-internal.h`。行号实读核对。
> **系列总览**：见 [OBS_架构骨架与WorkLabs模块映射](OBS_架构骨架与WorkLabs模块映射.md)（第 ① 篇）。本篇讲「单个源的帧如何缓冲、如何被 video 线程按系统时钟 tick 选帧/丢帧」——是和 WorkLabs 各源节流逻辑最直接对照的部分。上游驱动（video tick）见第 ③ 篇。

## 0. 主线一句话

```
源线程: obs_source_output_video(frame)        ← 源"投帧",随时、任意频率
            └─► cache_video / async_frames     ← 帧拷进 source 的异步缓冲队列(上限 30)
                                                  (源完全不关心"何时显示")
─────────────────────────────────────────────────────────────────────
graphics 线程(固定节拍): obs_graphics_thread_loop  ← 每 1/fps 一次 tick
   tick_sources(video_time)
     └─ obs_source_video_tick → async_tick(source)
            └─ get_closest_frame(source, sys_time)   ← 用系统时钟挑"现在该显示的那帧"
                 └─ ready_async_frame(...)            ← 推进虚拟时钟、丢过期帧
            source->cur_async_frame = 选中的帧
   render_displays / output_frames
     └─ obs_source_update_async_video → 上纹理 → 参与合成
```

**OBS 的时间戳哲学（与 mpv 截然不同）**：源帧自带 `timestamp`，但 OBS **不**用它去"精确调度某帧在某绝对时刻显示"。它让一个统一的 graphics 线程按**固定系统节拍**（`video_frame_interval_ns`）tick；每个 tick 用系统时钟在缓冲里挑**当前最该显示的那帧**、把更早的帧当作"已过期"直接丢弃。源 `timestamp` 只用于在缓冲内部维护**相对节奏**（帧间隔），而非绝对显示时刻。这是合成器（compositor）的做法：输出节拍由合成端的渲染帧率主宰，源帧只是被"采样"。

---

## 1. 视频帧投入：从 `obs_source_output_video` 到 async 缓冲

### 1.1 公开入口：拷出一份栈上副本

`obs_source_output_video` / `obs_source_output_video2` 只是薄封装，处理 range 归一化后转交内部函数。注意它把入参 `*frame` 拷成栈上的 `new_frame`——这是浅拷贝（data 指针仍指向调用方内存），真正的深拷贝发生在后面的 `cache_video`。

```c
// libobs/obs-source.c:3595
void obs_source_output_video(obs_source_t *source, const struct obs_source_frame *frame)
{
	if (destroying(source)) return;
	if (!frame) { obs_source_output_video_internal(source, NULL); return; }  // NULL = "停流"信号

	struct obs_source_frame new_frame = *frame;
	new_frame.full_range = format_is_yuv(frame->format) ? new_frame.full_range : true;
	obs_source_output_video_internal(source, &new_frame);
}
```

`obs_source_output_video2`（`:3610`）多了 `color_matrix`/`color_range`/`trc` 等字段拷贝，本质相同。

### 1.2 内部派发：`obs_source_output_video_internal`

```c
// libobs/obs-source.c:3563
static void obs_source_output_video_internal(obs_source_t *source, const struct obs_source_frame *frame)
{
	if (!obs_source_valid(source, "obs_source_output_video")) return;

	if (!frame) {                                  // 源停流：清空缓冲、复位时基
		pthread_mutex_lock(&source->async_mutex);
		source->async_active = false;
		source->last_frame_ts = 0;                 // ← 关键：last_frame_ts=0 触发下一帧"冷启动"
		free_async_cache(source);
		pthread_mutex_unlock(&source->async_mutex);
		return;
	}

	source_profiler_async_frame_received(source);
	struct obs_source_frame *output = cache_video(source, frame);   // ← 深拷贝进缓存池

	pthread_mutex_lock(&source->async_mutex);
	if (output) {
		if (os_atomic_dec_long(&output->refs) == 0) {  // 引用归零→无人持有→销毁
			obs_source_frame_destroy(output);
			output = NULL;
		} else {
			da_push_back(source->async_frames, &output);  // ← 入"待显示队列"
			source->async_active = true;
		}
	}
	pthread_mutex_unlock(&source->async_mutex);
}
```

要点：
- **`source->last_frame_ts = 0`** 是"冷启动哨兵"。停流或缓冲溢出时置 0，意味着"我丢失了时基连续性，下一帧到来时直接显示、并以它的 ts 重新锚定虚拟时钟"（见 `get_closest_frame` §2.5）。
- 有两套结构：`async_cache`（帧**内存池**，可复用的 `async_frame` 槽）和 `async_frames`（**待显示队列**，指向 cache 里 `used=true` 的帧）。投帧时帧先进 cache 拿到一块内存，深拷贝完成后再把指针 push 进 `async_frames`。

### 1.3 帧内存池：`cache_video` —— 复用、上限、格式变更清空

```c
// libobs/obs-source.c:3503
#define MAX_ASYNC_FRAMES 30
static inline struct obs_source_frame *cache_video(struct obs_source *source, const struct obs_source_frame *frame)
{
	struct obs_source_frame *new_frame = NULL;
	pthread_mutex_lock(&source->async_mutex);

	if (source->async_frames.num >= MAX_ASYNC_FRAMES) {   // ① 待显示队列已堆到 30 帧
		free_async_cache(source);                         //    整池清空(消费太慢,认定卡死)
		source->last_frame_ts = 0;                        //    复位时基,冷启动
		pthread_mutex_unlock(&source->async_mutex);
		return NULL;                                      //    丢弃本帧
	}

	if (async_texture_changed(source, frame)) {           // ② 分辨率/格式/range/trc 变了
		free_async_cache(source);                         //    旧池作废(尺寸不兼容,无法复用槽)
		source->async_cache_width  = frame->width;
		source->async_cache_height = frame->height;
	}
	... // 记录 async_cache_format/full_range/trc

	for (size_t i = 0; i < source->async_cache.num; i++) {  // ③ 找一个空闲槽复用
		struct async_frame *af = &source->async_cache.array[i];
		if (!af->used) { new_frame = af->frame; af->used = true; af->unused_count = 0; break; }
	}
	clean_cache(source);                                     // ④ 回收长期不用的槽

	if (!new_frame) {                                        // ⑤ 没空闲槽→新分配
		struct async_frame new_af;
		new_frame = obs_source_frame_create(format, frame->width, frame->height);
		new_af.frame = new_frame; new_af.used = true; new_af.unused_count = 0;
		new_frame->refs = 1;
		da_push_back(source->async_cache, &new_af);
	}

	os_atomic_inc_long(&new_frame->refs);
	pthread_mutex_unlock(&source->async_mutex);

	copy_frame_data(new_frame, frame);                      // ⑥ 真正的像素深拷贝(锁外做,降低持锁时间)
	return new_frame;
}
```

边界条件与物理意义：
- **`MAX_ASYNC_FRAMES = 30`**：待显示队列的硬上限。若合成端（tick）消费速度长期跟不上源投帧速度，队列会堆积；一旦达 30，整池清空 + 复位时基。语义是"宁可丢一批、重新对齐，也不无限堆内存"。这是缓冲背压的最后防线。
- **`async_texture_changed`**（`:3466`）：比较宽、高、`convert_type`（由 format/full_range/trc 决定）。任一变化即整池作废——因为内存槽是按固定尺寸/格式分配的，无法直接复用。源切分辨率会触发一次缓存重建。
- **`clean_cache`**（`:3490`）+ `MAX_UNUSED_FRAME_DURATION = 5`：一个 cache 槽连续 5 次 tick 没被用到就 `destroy` 并从池移除。这是内存的"软回收"，区别于 ① 的"硬清空"。
- **锁外深拷贝**（⑥）：`copy_frame_data` 是耗时操作，放在解锁之后做，缩短 `async_mutex` 持有时间，减少与 graphics 线程 `async_tick` 的争用。
- **引用计数**：每帧 `refs` 由投帧侧 +1、消费侧（`async_tick`/`get_frame`）增减；归零才真正销毁。这让"源线程投帧"与"graphics 线程消费"无锁竞争地共享同一帧内存。

---

## 2. 时间戳节流（最核心）：`ready_async_frame` + `get_closest_frame` + `async_tick`

### 2.1 关键字段（`obs-internal.h:848-855`）

```c
// libobs/obs-internal.h:848
/* timing (if video is present, is based upon video) */
volatile bool     timing_set;          // 时基是否已建立
volatile uint64_t timing_adjust;       // 源 ts → 系统时钟的偏移量(音频/解耦时用)
uint64_t next_audio_ts_min;            // (音频)下一帧期望的最小 ts
uint64_t next_audio_sys_ts_min;        // (音频)折算到系统时钟后的下一帧最小 ts
uint64_t last_frame_ts;                // ★ "虚拟显示时钟":上次选中帧的(推进后)时间戳
uint64_t last_sys_timestamp;           // ★ 上次 tick 的系统时钟(obs->video.video_time)
```

含义辨析（这是理解全部节流逻辑的钥匙）：
- **帧的 `timestamp`**：源自己打的时间戳，单位纳秒，基准任意（可以是采集时的 `os_gettime_ns()`，也可以是文件 pts 转换值）。OBS **不假设**它和系统时钟同基准——只假设它内部**单调、间隔正确**。
- **`last_frame_ts`**：一个**虚拟时钟**，处在"源帧时间轴"上。每个 tick 它按系统时钟流逝量（`sys_offset`）向前推进，用来和队头帧的 `timestamp` 比较，判断"按源的节奏，现在该到这帧了吗"。
- **`last_sys_timestamp`**：上一次 tick 的系统时刻。本次 tick 的 `sys_time - last_sys_timestamp` 就是"两次 tick 之间真实流逝的纳秒数"（≈ 一个渲染帧间隔），用它去推进 `last_frame_ts`。

**核心技巧**：OBS 不直接比较 `frame.timestamp` 和 `sys_time`（它们不同基准、无法直接比）；而是让一个虚拟时钟 `last_frame_ts` 以**系统时钟的步幅**在**源时间轴**上行走，再拿它和帧 ts 比。等价于"把系统时钟的流速映射到源时间轴上"。

### 2.2 统一节拍来源：graphics 线程

```c
// libobs/obs-video.c:1097
bool obs_graphics_thread_loop(struct obs_graphics_context *context)
{
	...
	context->last_time = tick_sources(obs->video.video_time, context->last_time);  // 推进所有源
	...
	output_frames();        // 合成 + 输出/编码
	render_displays();      // 预览
	...
	video_sleep(&obs->video, &obs->video.video_time, context->interval);  // ★ 睡到下个节拍,并更新 video_time
	return !stop_requested();
}
```

`obs->video.video_time` 是**全局统一的系统时刻**，由 graphics 线程每帧推进；`interval = video_frame_interval_ns`（如 60fps → 16.67ms）。`tick_sources`（`obs-video.c:32`）遍历所有源调用 `obs_source_video_tick`。**所有源共享同一个 `sys_time`、同一个节拍**——这是 OBS 同步的根。（详见第 ③ 篇。）

### 2.3 `async_tick`：每节拍选一帧

```c
// libobs/obs-source.c:1328
static void async_tick(obs_source_t *source)
{
	uint64_t sys_time = obs->video.video_time;          // ★ 全局统一系统时刻
	pthread_mutex_lock(&source->async_mutex);

	if (deinterlacing_enabled(source)) {
		deinterlace_process_last_frame(source, sys_time);
	} else {
		if (source->cur_async_frame) {                  // 上个 tick 选的帧若还没被消费,先归还内存槽
			remove_async_frame(source, source->cur_async_frame);
			source->cur_async_frame = NULL;
		}
		source->cur_async_frame = get_closest_frame(source, sys_time);   // ★ 选出本 tick 该显示的帧
	}

	source->last_sys_timestamp = sys_time;              // ★ 记录本次系统时刻,供下次算 sys_offset
	...
	filter_frame(source, &source->cur_async_frame);     // 异步视频滤镜
	if (source->cur_async_frame)
		source->async_update_texture = set_async_texture_size(source, source->cur_async_frame);
	pthread_mutex_unlock(&source->async_mutex);
}
```

`async_tick` 由 `obs_source_video_tick`（`:1357`）在 `OBS_SOURCE_ASYNC` 标志下调用。每个 tick：归还上帧 → `get_closest_frame` 选新帧 → 更新 `last_sys_timestamp`。**它只"选帧"，不上纹理**（上纹理在 render 阶段，见 §3）。

### 2.4 `ready_async_frame`：判断"该不该出队头帧"（逐行）

```c
// libobs/obs-source.c:4087
static bool ready_async_frame(obs_source_t *source, uint64_t sys_time)
{
	struct obs_source_frame *next_frame = source->async_frames.array[0];   // 队头
	struct obs_source_frame *frame = NULL;
	uint64_t sys_offset = sys_time - source->last_sys_timestamp;           // ① 本次 tick 真实流逝
	uint64_t frame_time = next_frame->timestamp;
	uint64_t frame_offset = 0;

	if (source->async_unbuffered) {                    // ② 无缓冲模式:只留最新帧,其余全丢
		while (source->async_frames.num > 1) {
			da_erase(source->async_frames, 0);
			remove_async_frame(source, next_frame);
			next_frame = source->async_frames.array[0];
		}
		source->last_frame_ts = next_frame->timestamp;
		return true;
	}

	/* account for timestamp invalidation */
	if (frame_out_of_bounds(source, frame_time)) {     // ③ 时间戳跳变/回绕检测
		source->last_frame_ts = next_frame->timestamp; //    直接把虚拟时钟跳到该帧,认定它 ready
		return true;
	} else {
		frame_offset = frame_time - source->last_frame_ts;
		source->last_frame_ts += sys_offset;           // ④ ★ 虚拟时钟按系统流逝量推进
	}

	while (source->last_frame_ts > next_frame->timestamp) {   // ⑤ 虚拟时钟已越过队头帧 ts → 该帧到点/过期
		/* 减少不必要的重复帧,平滑到帧边界:差<2ms 就停,不再继续丢 */
		if (frame && (source->last_frame_ts - next_frame->timestamp) < 2000000)  // 2,000,000 ns = 2ms
			break;

		if (frame)
			da_erase(source->async_frames, 0);     // 丢弃已过期帧(出队)
		remove_async_frame(source, frame);             // 归还内存槽

		if (source->async_frames.num == 1)             // 只剩一帧→就用它
			return true;

		frame = next_frame;
		next_frame = source->async_frames.array[1];    // 看下一帧

		/* 帧间 ts 突然暴涨(>2s)→认定跳变,重锚虚拟时钟 */
		if ((next_frame->timestamp - frame_time) > MAX_TS_VAR)   // MAX_TS_VAR = 2,000,000,000 ns = 2s
			source->last_frame_ts = next_frame->timestamp - frame_offset;

		frame_time = next_frame->timestamp;
		frame_offset = frame_time - source->last_frame_ts;
	}

	return frame != NULL;          // frame!=NULL 表示"至少有一帧到点了,可以出队"
}
```

逐段物理意义：
- **① `sys_offset`**：两次 tick 之间真实流逝的纳秒。这是把系统时钟"灌入"源时间轴的步长。
- **④ `last_frame_ts += sys_offset`**：虚拟时钟以系统时钟的真实速度前进。若渲染掉帧（某次 tick 间隔变长），`sys_offset` 变大，虚拟时钟跳得多，自然会跳过更多源帧——**自动追帧**。
- **⑤ `while (last_frame_ts > next_frame->timestamp)`**：虚拟时钟已经"走过"队头帧的时间戳，说明这帧的显示时刻已到或已过。循环不断出队过期帧，直到找到"虚拟时钟还没越过"的帧（即未来帧），或只剩一帧。
- **2ms (`2000000`) 平滑阈值**：当已经选出一帧（`frame != NULL`），且虚拟时钟仅比队头帧超前不到 2ms，就**停止继续丢帧**。物理意义：避免在帧边界附近为了"绝对精确"而多丢一帧造成顿挫，宁可显示一帧"早 2ms 以内"的帧，让帧率平滑。这是 OBS 在"精确"与"平滑"间的折中。
- **返回值语义**：返回 `true` 仅代表"有帧到点、队头帧可出队"；返回 `false` 代表"队头帧还在未来，本 tick 不出新帧（沿用上帧/不更新）"。

### 2.5 `get_closest_frame`：实际出队 + 冷启动

```c
// libobs/obs-source.c:4175
static inline struct obs_source_frame *get_closest_frame(obs_source_t *source, uint64_t sys_time)
{
	if (!source->async_frames.num)               // 缓冲空→没帧可选
		return NULL;

	if (!source->last_frame_ts ||                // ★ 冷启动:虚拟时钟未建立(=0)→直接出队头帧
	    ready_async_frame(source, sys_time)) {   //    或:有帧到点
		struct obs_source_frame *frame = source->async_frames.array[0];
		da_erase(source->async_frames, 0);       // 出队

		if (!source->last_frame_ts)              // 冷启动:用这帧的 ts 锚定虚拟时钟
			source->last_frame_ts = frame->timestamp;

		return frame;
	}
	return NULL;                                 // 队头帧还在未来,本 tick 不出帧
}
```

- **`!source->last_frame_ts`（冷启动）**：源刚开始投帧、或刚经历过停流/缓冲溢出（`last_frame_ts` 被置 0）。此时不做时间戳判断，**第一帧立即显示**，并用它的 ts 作为虚拟时钟起点。这就是"重新对齐"的入口。
- 它"挑最接近当前系统时刻的帧"是通过 `ready_async_frame` 内部的循环丢帧实现的——丢完所有过期帧后，队头就是"当前最该显示的那帧"。

### 2.6 时间戳跳变/回绕处理

OBS **有**类似 mpv clamp/reset 的机制，但更粗放（合成器只需"别乱"，不需要逐帧精确）：

```c
// libobs/obs-internal.h:1059
#define MAX_TS_VAR 2000000000ULL    // 2 秒:最大允许时间戳方差

// libobs/obs-internal.h:1062
static inline bool frame_out_of_bounds(const obs_source_t *source, uint64_t ts)
{
	if (ts < source->last_frame_ts)
		return ((source->last_frame_ts - ts) > MAX_TS_VAR);   // 回绕/倒退超过 2s
	else
		return ((ts - source->last_frame_ts) > MAX_TS_VAR);   // 暴涨超过 2s
}
```

两道防线：
1. **`frame_out_of_bounds`（`ready_async_frame` ③）**：队头帧 ts 与虚拟时钟差超过 **±2 秒** → 认定时间戳不连续（源 seek、回绕、断流重连等）→ 把虚拟时钟**强行跳到该帧 ts**、立即显示，不再尝试按节奏对齐。
2. **循环内的 `> MAX_TS_VAR`（④处）**：丢帧过程中发现相邻两帧 ts 突跳超 2s → 用 `next_frame->timestamp - frame_offset` 重锚虚拟时钟，保持帧间隔连续。

阈值 **2 秒（`MAX_TS_VAR`）** 的物理意义：正常帧间隔在毫秒量级，2s 的跨度远超任何合理抖动，只可能是 seek/回绕/重连。超过即"放弃对齐、硬复位"。这与 mpv 用更小的容差（`5s`/`1e4s` 两档，见 mpv 调研 §2.1）做逐帧 clamp 不同——OBS 只关心"不要因为一个野值卡死缓冲"。

---

## 3. async tick → 上屏：tick（选帧）与 render（上纹理）分离

OBS 把"选帧"和"上纹理"刻意拆在两个阶段，对应 graphics 线程循环里的 `tick_sources` 与 `render_displays`/`output_frames` 两段：

```c
// libobs/obs-source.c:2906  (render_video, 在渲染阶段调用)
if (source->info.type == OBS_SOURCE_TYPE_INPUT &&
    (source->info.output_flags & OBS_SOURCE_ASYNC) != 0 && !source->rendering_filter) {
	...
	obs_source_update_async_video(source);   // ① 把 tick 选中的帧上传成 GPU 纹理
}
...
else
	obs_source_render_async_video(source);   // ② 用该纹理画到合成画布
```

### 3.1 `obs_source_update_async_video`：取帧 + 上纹理

```c
// libobs/obs-source.c:2514
static void obs_source_update_async_video(obs_source_t *source)
{
	if (!source->async_rendered) {
		source->async_rendered = true;

		struct obs_source_frame *frame = obs_source_get_frame(source);   // 取 async_tick 选好的 cur_async_frame
		if (frame) {
			check_to_swap_bgrx_bgra(source, frame);

			if (!source->async_decoupled || !source->async_unbuffered) {
				source->timing_adjust = obs->video.video_time - frame->timestamp;  // 记录源↔系统偏移(供音频同步)
				source->timing_set = true;
			}
			if (source->async_update_texture) {
				update_async_textures(source, frame, source->async_textures, source->async_texrender);  // ★ 上 GPU 纹理
				source->async_update_texture = false;
			}
			source->async_last_rendered_ts = frame->timestamp;
			obs_source_release_frame(source, frame);   // 用完归还内存槽
		}
	}
}
```

> 注意 `timing_adjust = obs->video.video_time - frame->timestamp`：视频在上屏时也把"源 ts → 系统时钟"的偏移记下来，供音频侧做 A/V 同步（第 ③ 篇）。

### 3.2 `obs_source_get_frame`：消费侧取帧（线程安全交接）

```c
// libobs/obs-source.c:4199
struct obs_source_frame *obs_source_get_frame(obs_source_t *source)
{
	struct obs_source_frame *frame = NULL;
	pthread_mutex_lock(&source->async_mutex);
	frame = source->cur_async_frame;       // ★ tick 阶段选好的帧
	source->cur_async_frame = NULL;        // 交接所有权给渲染端
	if (frame) os_atomic_inc_long(&frame->refs);
	pthread_mutex_unlock(&source->async_mutex);
	return frame;
}
```

**为什么 tick / render 分离**：
- `async_tick` 在 `tick_sources` 阶段跑（CPU、可在任意上下文），只做缓冲管理和选帧——不碰 GPU。
- 上纹理（`update_async_textures`）和绘制必须在 graphics context 内（render 阶段）。
- 这样**选帧逻辑与 GPU 状态解耦**：一个源可能被画到多个 display/output（预览 + 编码），但**一个 tick 只选一次帧、只上一次纹理**（`async_rendered` 标志保证），多个渲染目标复用同一纹理。`async_rendered` 在下个 tick 复位，保证每节拍最多更新一次纹理。

---

## 4. 音频侧缓冲与时间戳

音频走**完全独立**的路径与时间戳逻辑（视频走 `async_frames`/虚拟时钟，音频走 `audio_input_buf` deque/`timing_adjust`）。两者不共用节流逻辑，但通过 `timing_adjust` 间接关联做 A/V 同步。

### 4.1 入口

```c
// libobs/obs-source.c:4029
void obs_source_output_audio(obs_source_t *source, const struct obs_source_audio *audio_in)
{
	...
	process_audio(source, &audio);                       // 重采样到输出格式
	output = filter_async_audio(source, &source->audio_data);   // 异步音频滤镜
	if (output) {
		struct audio_data data;  ... // 取 data/frames/timestamp
		pthread_mutex_lock(&source->audio_mutex);
		source_output_audio_data(source, &data);         // ★ 核心:时间戳处理 + 入缓冲
		pthread_mutex_unlock(&source->audio_mutex);
	}
}
```

### 4.2 `source_output_audio_data`：音频时间戳的全部哲学

```c
// libobs/obs-source.c:1572
static void source_output_audio_data(obs_source_t *source, const struct audio_data *data)
{
	... uint64_t os_time = os_gettime_ns(); ...

	/* "直接时间戳"探测:若 ts 本来就接近系统时钟(<2s),认为它直接是系统基准 */
	if (uint64_diff(in.timestamp, os_time) < MAX_TS_VAR) {       // MAX_TS_VAR = 2s
		source->timing_adjust = 0;                              // 无需偏移
		source->timing_set = true;
		using_direct_ts = true;
	}

	if (!source->timing_set) {
		reset_audio_timing(source, in.timestamp, os_time);      // 首帧:建立 timing_adjust = os_time - ts
	} else if (source->next_audio_ts_min != 0) {
		diff = uint64_diff(source->next_audio_ts_min, in.timestamp);

		if (diff > MAX_TS_VAR && !using_direct_ts)              // ① 跳变>2s → 复位音频时基+清空缓冲
			handle_ts_jump(source, source->next_audio_ts_min, in.timestamp, diff, os_time);
		else if (diff < TS_SMOOTHING_THRESHOLD) {              // ② 抖动<70ms → 平滑:强制贴到期望 ts
			if (source->async_unbuffered && source->async_decoupled)
				source->timing_adjust = os_time - in.timestamp;
			in.timestamp = source->next_audio_ts_min;          // ★ 抹平小抖动,保证连续
		} else {
			... // 70ms~2s:既不平滑也不复位,只记日志(罕见中等抖动)
		}
	}

	source->next_audio_ts_min = in.timestamp + conv_frames_to_time(sample_rate, in.frames);  // 期望下帧 ts
	in.timestamp += source->timing_adjust;                     // ★ 折算到系统时钟

	... // next_audio_sys_ts_min 二次校验,sync_offset(用户 A/V 偏移)叠加

	if (push_back && source->audio_ts)
		source_output_audio_push_back(source, &in);            // 连续→直接追加到 deque 尾
	else
		source_output_audio_place(source, &in);                // 不连续→按 ts 算偏移精确放置
}
```

```c
// libobs/obs-source.c:1452
#define TS_SMOOTHING_THRESHOLD 70000000ULL   // 70ms

// libobs/obs-source.c:1454
static inline void reset_audio_timing(obs_source_t *source, uint64_t timestamp, uint64_t os_time)
{
	source->timing_set = true;
	source->timing_adjust = os_time - timestamp;   // ★ 把"源 ts 基准"映射到"系统时钟基准"的偏移
}

// libobs/obs-source.c:1472
static void handle_ts_jump(obs_source_t *source, uint64_t expected, uint64_t ts, uint64_t diff, uint64_t os_time)
{
	blog(LOG_DEBUG, "Timestamp ... jumped by '%llu' ...", diff, ...);
	pthread_mutex_lock(&source->audio_buf_mutex);
	reset_audio_timing(source, ts, os_time);    // 重建偏移
	reset_audio_data(source, os_time);          // ★ 清空音频缓冲,强制重新同步
	pthread_mutex_unlock(&source->audio_buf_mutex);
}
```

音频时间戳处理要点（与视频对照）：
- **`timing_adjust`**：音频版的"源 ts → 系统时钟"偏移。`reset_audio_timing` 计算 `os_time - timestamp`；之后每帧 `in.timestamp += timing_adjust` 折算到系统时基。视频侧也在 `update_async_video`（`:2524`）里设过同一个 `timing_adjust`——这是 A/V 共享的同步桥。
- **三档阈值**（音频比视频精细，因为音频缓冲是按 ts 精确摆放的 PCM，错位会"咔哒"响）：
  - **< 70ms (`TS_SMOOTHING_THRESHOLD`)**：小抖动 → `in.timestamp = next_audio_ts_min` **直接抹平**，强制连续，避免 deque 里出现 gap/overlap。
  - **70ms ~ 2s**：中等异常，只记日志，原样放置（按真实 ts 摆，可能留 gap，由后续混音处理）。
  - **> 2s (`MAX_TS_VAR`)**：判定跳变 → `handle_ts_jump` **复位时基 + 清空缓冲**，硬重同步。这正对应视频侧的 `frame_out_of_bounds` 复位。
- **`using_direct_ts`**：若源直接用系统时钟打 ts（采集设备常见），`timing_adjust=0`，跳过偏移折算。
- **缓冲结构**：`audio_input_buf[MAX_AUDIO_CHANNELS]` 是 per‑channel 的 `deque`（环形缓冲）。`push_back`（`:1539`）连续追加；`place`（`:1508`）按 `get_buf_placement(ts - audio_ts)` 算字节偏移精确摆放——音频是**按时间戳定位写入缓冲**，而非视频那样"按节拍选帧丢帧"。`MAX_BUF_SIZE`（`1000 * AUDIO_OUTPUT_FRAMES * sizeof(float)`）是缓冲上限，超了直接丢，防止内存爆。

**视频 vs 音频时间戳处理对比**：

| 维度 | 视频 | 音频 |
|---|---|---|
| 缓冲 | `async_frames`（指针队列，上限 30 帧） | `audio_input_buf` per‑channel deque（上限 `MAX_BUF_SIZE`） |
| 节流方式 | tick 拉取 + 丢过期帧（采样） | 按 ts 精确摆放 PCM 进环形缓冲（不丢，由混音器拉） |
| 跳变阈值 | `MAX_TS_VAR = 2s`（`frame_out_of_bounds`） | `MAX_TS_VAR = 2s` + `TS_SMOOTHING_THRESHOLD = 70ms` 三档 |
| 跳变处理 | 复位虚拟时钟、立即显示 | `handle_ts_jump`：复位时基 + 清空缓冲 |
| 时基锚定 | `last_frame_ts`（虚拟时钟） | `timing_adjust`（系统时钟偏移） |

---

## 5. 对 WorkLabs 的启示

WorkLabs 当前每个源（`WLMediaSource`）是**独立 render 线程**，按 `baseTime + pts` 做**绝对锚定节流** + `usleep` 轮询等到该帧的显示时刻才推送。这是 **mpv 式"每帧精确调度显示时刻"**的思路，源自己决定何时上屏。

OBS 是另一套范式——**统一 video tick 拉取**：
1. **源只管投帧进缓冲**（`obs_source_output_video` → `async_frames`），完全不关心何时显示、不睡眠、不轮询。源线程职责极简。
2. **合成端用一个全局节拍线程**（graphics thread，`obs->video.video_time` + `video_sleep`）统一驱动所有源 tick；每 tick 用同一个系统时刻 `sys_time` 在每个源的缓冲里**挑当前最该显示的那帧、丢弃过期帧**。
3. 时间戳只用来在缓冲内部维护**相对节奏**（`last_frame_ts` 虚拟时钟按 `sys_offset` 推进），不用来调度绝对显示时刻。
4. 跳变用粗放的 `±2s`（`MAX_TS_VAR`）做硬复位，不追求逐帧精确。

对 WorkLabs 的可借鉴点：
- **若要做多源合成**，OBS 范式更优：把"显示节拍"从各源 render 线程收归到**单一合成 tick**，源只投帧进 per‑source 缓冲。这样所有源天然对齐到同一节拍（合成的渲染帧率），免去各源 `usleep` 各自为政导致的**跨源不同步**和**线程数膨胀**（OBS 一个 graphics 线程驱动 N 个源 vs WorkLabs N 个 render 线程）。
- **背压防线**：引入 `MAX_ASYNC_FRAMES`(30) 式的队列上限 + 溢出整池清空复位，避免某源解码快/合成慢时无限堆帧。
- **冷启动哨兵**（`last_frame_ts = 0`）：seek/重连后第一帧立即显示并重锚时钟，避免 `baseTime + pts` 锚定在 seek 后产生长时间黑屏或快进。（正好呼应 WorkLabs 计划做的 seek/loop——见 `Doc/调研/mpv/MPV时间戳_讨论纪要与功能规划.md`。）
- **跳变容差**：WorkLabs 若沿用绝对锚定，至少应加 `frame_out_of_bounds` 式的 ±N 秒跳变检测来 reset `baseTime`，否则文件 pts 不连续（B 帧/seek/拼接）会让节流线程长时间错误等待或狂刷。
- **音视频分治**：视频可丢帧（采样），音频不可丢、按 ts 摆进环形缓冲并用 `< 70ms` 小抖动抹平——WorkLabs 后续接 AAC 录制/多轨混音时，音频时间戳应独立于视频处理，用类似 `TS_SMOOTHING_THRESHOLD` 的小阈值平滑、大阈值复位。

理解要点收束：**OBS 不调度"显示时刻"，它调度"节拍"，每拍采样一次缓冲。** 源是被动的帧生产者，合成端是主动的、按固定系统节拍拉取的消费者——这正是 compositor 区别于 player 的本质。
