# OBS 合成 tick · 音频混音 · A/V 同步

> **性质**：OBS 源码级深挖调研 · 系列第 ③ 篇（维度：合成主循环 / 音频混音 / A/V 同步）。
> **调研对象**：obs-studio `32.1.2-94-gf61619ce3`，核心四文件 `libobs/obs-video.c`、`libobs/obs-audio.c`、`libobs/media-io/video-io.c`、`libobs/media-io/audio-io.c`，旁证 `obs-source.c`、`obs.c`。行号实读核对。
> **系列总览**：见 [OBS_架构骨架与WorkLabs模块映射](OBS_架构骨架与WorkLabs模块映射.md)（第 ① 篇）。源侧帧缓冲/选帧见 [第 ② 篇](OBS_源异步帧缓冲与时间戳节流.md)；编码/输出见 [第 ④ 篇](OBS_输出侧_编码_复用_录制推流.md)。

## 0. 全局结论（先给心智模型）

OBS 的 A/V 同步**不是**「视频追音频」或「音频追视频」的反馈调节，而是：

- **两条完全独立的线程**，各自带一个用 `os_gettime_ns()`（系统单调时钟）锚定的循环：
  - **graphics thread**（`obs_graphics_thread`）：每 `video_frame_interval_ns` 醒来一次，tick 所有源 → 合成渲染 → 把合成帧打上**那一刻的系统时间戳** → 推进 video output。
  - **audio thread**（`audio_thread`，在 audio-io 层）：每 `AUDIO_OUTPUT_FRAMES`(=1024) 个采样对应的时长醒来一次，调 `audio_callback` 把所有源在 `[prev_time, audio_time)` 这个**系统时间窗口**内的音频混进 mix。
- **对齐的本质 = 共享同一个系统单调时钟基准**。每个源进来的「设备时间戳/解码 PTS」在入口处被换算成系统时钟：`timing_adjust = os_time − 源自身 timestamp`，之后该源所有帧都 `+= timing_adjust` 落到统一时间轴上。视频和音频于是被钉在同一根「墙钟」上，自然对齐——而不需要任何一方去追另一方。
- 编码/输出端（video output 缓存 + audio output 缓存）只是「按时间分发的缓冲层」，真正的 interleave/muxing 在编码器线程里做（见第 ④ 篇）。

下面分四块讲透。

---

## 1. 合成主循环（graphics / video 线程）

### 1.1 线程入口与时钟锚定 — `obs_graphics_thread`

`obs-video.c:1161`：

```c
void *obs_graphics_thread(void *param)
{
	is_graphics_thread = true;
	const uint64_t interval = obs->video.video_frame_interval_ns;   // 固定帧间隔，见下
	obs->video.video_time = os_gettime_ns();                        // 用系统单调时钟做起点
	...
	struct obs_graphics_context context;
	context.interval  = interval;
	context.last_time = 0;
	...
#ifdef __APPLE__
	while (obs_graphics_thread_loop_autorelease(&context))   // macOS：每帧套一层 autoreleasepool
#else
	while (obs_graphics_thread_loop(&context))
#endif
		;
	...
}
```

- `interval = video_frame_interval_ns`，定义在 `obs.c:694`：
  ```c
  video->video_frame_interval_ns = util_mul_div64(1000000000ULL, ovi->fps_den, ovi->fps_num);
  ```
  即 `1e9 * fps_den/fps_num` 纳秒。60fps → 16 666 666 ns。**物理意义**：一个 video tick 应有的标称时长。
- `video_time` 是这条管线的「虚拟当前时刻」，初值取 `os_gettime_ns()`，之后每帧由 `video_sleep` 推进 `interval`（见 1.5）。它就是后面合成帧时间戳的来源。
- macOS 走 `..._autorelease` 包装版（每个 loop 包一层 `@autoreleasepool`，避免 ObjC 临时对象堆积）。

### 1.2 一帧的完整流程 — `obs_graphics_thread_loop`

`obs-video.c:1097`：

```c
bool obs_graphics_thread_loop(struct obs_graphics_context *context)
{
	uint64_t frame_start = os_gettime_ns();      // 测量这一帧实际耗时用
	uint64_t frame_time_ns;

	update_active_states();                        // 刷新各 mix 的 raw/gpu 激活状态

	gs_enter_context(obs->video.graphics);
	gs_begin_frame();
	gs_leave_context();

	/* (1) 推进所有源的时间 */
	context->last_time = tick_sources(obs->video.video_time, context->last_time);

	/* (2) 合成 + 下载像素 + 送 video output */
	output_frames();

	/* (3) 渲染所有预览窗口/display（与编码无关，仅 UI） */
	render_displays();

	execute_graphics_tasks();                      // 跨线程投递到 graphics 线程的任务

	frame_time_ns = os_gettime_ns() - frame_start;

	/* (4) sleep 到下一个 tick 时刻，并推进 video_time */
	video_sleep(&obs->video, &obs->video.video_time, context->interval);
	...
	return !stop_requested();
}
```

主线①一目了然：**tick 所有源 → output_frames（合成+下载+送输出）→ render 预览 → sleep 到点**。注意时序：`tick_sources` 用的是**本帧开头**的 `video_time`（上一轮 sleep 推进后的值），合成完成后才在末尾 `video_sleep` 推进到下一帧。

### 1.3 tick 所有源 — `tick_sources`（驱动每个源推进时间）

`obs-video.c:32`：

```c
static uint64_t tick_sources(uint64_t cur_time, uint64_t last_time)
{
	struct obs_core_data *data = &obs->data;
	uint64_t delta_time;
	float seconds;

	if (!last_time)
		last_time = cur_time - obs->video.video_frame_interval_ns;  // 首帧：假装上一帧在一个 interval 前

	delta_time = cur_time - last_time;                  // 距上次 tick 的真实纳秒差
	seconds = (float)((double)delta_time / 1000000000.0);  // 换成秒，传给各源

	/* 调全局 tick 回调（插件/前端注册的）*/
	pthread_mutex_lock(&data->draw_callbacks_mutex);
	for (size_t i = data->tick_callbacks.num; i > 0; i--) { ... callback->tick(callback->param, seconds); }
	pthread_mutex_unlock(&data->draw_callbacks_mutex);

	/* 快照当前所有源（加引用，避免 tick 期间被销毁）*/
	da_clear(data->sources_to_tick);
	pthread_mutex_lock(&data->sources_mutex);
	source = data->sources;
	while (source) {
		obs_source_t *s = obs_source_removed(source) ? NULL : obs_source_get_ref(source);
		if (s) da_push_back(data->sources_to_tick, &s);
		source = (struct obs_source *)source->context.hh_uuid.next;
	}
	pthread_mutex_unlock(&data->sources_mutex);

	/* 逐源调用其 video_tick(seconds) */
	for (size_t i = 0; i < data->sources_to_tick.num; i++) {
		obs_source_t *s = data->sources_to_tick.array[i];
		if (!obs_source_removed(s))
			obs_source_video_tick(s, seconds);    // ← 驱动 source async 帧推进的源头
		obs_source_release(s);
	}
	return cur_time;
}
```

逐点说明：
- **`seconds = (cur_time − last_time)/1e9`**：传给每个源的是**真实经过的时间**（不是固定的 1/fps）。如果上一帧卡了，`delta_time` 会偏大，源会按真实经过时长推进——这就是「丢帧后追时间」的根。
- **`last_time` 与 `cur_time` 解耦**：`cur_time` 是当前 `video_time`（标称推进），`last_time` 是上一次 tick 的 `video_time`。注意 `tick_sources` 返回 `cur_time`，被赋给 `context->last_time`——所以两次 tick 间的 `seconds` 用的是 **video_time 的差**（标称推进，每帧 1×interval），稳定平滑；而非墙钟抖动。
- `obs_source_video_tick` 内部对异步源（摄像头/媒体文件）会按 `seconds` 推进时间窗口、从 async 帧队列里挑出"到点"的帧。**这正是第 ② 篇里 source async tick 的上游驱动**：源不是自己有线程在 render，而是被 video 线程统一节拍 tick 出来。

### 1.4 合成 + 下载 + 送输出 — `output_frames` → `output_frame` → `output_video_data`

`output_frames`（`obs-video.c:916`）遍历所有 `obs_core_video_mix`（每个 mix = 一套输出分辨率/色彩空间组合），对每个有 `view` 的 mix 调 `output_frame`。

`output_frame`（`obs-video.c:868`）：

```c
static inline void output_frame(struct obs_core_video_mix *video)
{
	const bool raw_active = video->raw_was_active;   // 是否有 raw（CPU 下载）消费者
	const bool gpu_active = video->gpu_was_active;   // 是否有 GPU 编码消费者
	int cur_texture  = video->cur_texture;
	int prev_texture = cur_texture == 0 ? NUM_TEXTURES - 1 : cur_texture - 1;
	struct video_data frame;
	bool frame_ready = 0;
	memset(&frame, 0, sizeof(struct video_data));

	gs_enter_context(obs->video.graphics);
	render_video(video, raw_active, gpu_active, cur_texture);   // 真正的合成：背景+各源按 z 序绘制+色彩转换
	if (raw_active)
		frame_ready = download_frame(video, prev_texture, &frame);  // 把上一帧的 stage surface map 回 CPU
	gs_flush();
	gs_leave_context();

	if (raw_active && frame_ready) {
		struct obs_vframe_info vframe_info;
		deque_pop_front(&video->vframe_info_buffer, &vframe_info, sizeof(vframe_info));
		frame.timestamp = vframe_info.timestamp;                 // ★ 给合成帧打时间戳
		output_video_data(video, &frame, vframe_info.count);     // 送进 video output
	}

	if (++video->cur_texture == NUM_TEXTURES)
		video->cur_texture = 0;
}
```

关键点：
- **`render_video`**（`obs-video.c:539`）：`render_main_texture`（清屏 + 跑 draw 回调把背景和所有源按 z 序画进主纹理）→ `render_output_texture` + 色彩空间/格式转换（生成编码所需的 NV12/I420 等）。这是 OBS 的"WLVideoMix"等价物，但全在 GPU 上完成。
- **N-buffer 延迟下载**：注意 `download_frame` 用的是 **`prev_texture`**，不是当前帧。OBS 用 `NUM_TEXTURES` 个 stage surface 轮转——这一帧渲染进 `cur_texture`，下载的是上一帧的 `prev_texture`。这是异步 GPU→CPU 回读的标准做法：先发起拷贝，下一帧再 map，避免 stall。代价是合成帧到达编码器有 1 帧固定延迟。
- **时间戳从哪来 = `vframe_info.timestamp`**：它**不是**这里取 `os_gettime_ns()`，而是从 `vframe_info_buffer` 队列里弹出来的——这个队列由 `video_sleep` 在**上一帧**填入（见 1.5），值就是当时的 `video_time`（系统单调时钟推进值）。**所以合成帧的时间戳 = 触发该帧的那个 tick 的系统时钟时刻**。这是 A/V 同步对齐的视频侧锚点。

`output_video_data`（`obs-video.c:777`）：

```c
static inline void output_video_data(struct obs_core_video_mix *video, struct video_data *input_frame, int count)
{
	const struct video_output_info *info = video_output_get_info(video->video);
	struct video_frame output_frame;

	bool locked = video_output_lock_frame(video->video, &output_frame, count, input_frame->timestamp);  // ★ 把 ts 交给 video-io
	if (locked) {
		if (video->gpu_conversion)
			set_gpu_converted_data(&output_frame, input_frame, info);  // GPU 已转好格式 → 平面 memcpy
		else
			copy_rgbx_frame(&output_frame, input_frame, info);          // CPU 转换路径
		video_output_unlock_frame(video->video);
	}
}
```

它把刚下载的像素拷进 video-io 的环形缓存，并把 `input_frame->timestamp` 一路传给 `video_output_lock_frame`（见第 4 节）。`count` 是这一 tick 代表的帧数（卡顿时 >1，用于补帧）。

### 1.5 节拍与丢帧补偿 — `video_sleep`

`obs-video.c:805`：

```c
static inline void video_sleep(struct obs_core_video *video, uint64_t *p_time, uint64_t interval_ns)
{
	struct obs_vframe_info vframe_info;
	uint64_t cur_time = *p_time;
	uint64_t t = cur_time + interval_ns;       // 目标：当前 video_time + 一个帧间隔
	int count;

	if (os_sleepto_ns(t)) {                     // 睡到绝对时刻 t；返回 true=确实睡了（没超时）
		*p_time = t;                            // 正常：video_time 平滑 +interval
		count = 1;
	} else {                                     // 返回 false：t 已是过去 → 这帧晚了/丢帧了
		const uint64_t udiff = os_gettime_ns() - cur_time;
		int64_t diff; memcpy(&diff, &udiff, sizeof(diff));
		const uint64_t clamped_diff = (diff > (int64_t)interval_ns) ? (uint64_t)diff : interval_ns;
		count = (int)(clamped_diff / interval_ns);   // 落后了几个完整 interval
		*p_time = cur_time + interval_ns * count;     // 一次性把 video_time 跳到该到的位置
	}

	video->total_frames  += count;
	video->lagged_frames += count - 1;          // count-1 即本轮"补"出来的滞后帧

	vframe_info.timestamp = cur_time;           // ★ 本帧时间戳 = 进入 sleep 时的 video_time
	vframe_info.count     = count;

	/* 把 (timestamp,count) 推给各 mix 的 vframe_info_buffer，供下一轮 output_frame 弹出使用 */
	pthread_mutex_lock(&obs->video.mixes_mutex);
	for (...) {
		if (raw_active) deque_push_back(&video->vframe_info_buffer, &vframe_info, sizeof(vframe_info));
		if (gpu_active) deque_push_back(&video->vframe_info_buffer_gpu, &vframe_info, sizeof(vframe_info));
	}
	pthread_mutex_unlock(&obs->video.mixes_mutex);
	/* ... 还顺带处理 encoder_group 的 start_timestamp ... */
}
```

这是整个节拍的核心，逐层拆：
- **`os_sleepto_ns(t)` 睡到「绝对时刻」而非「睡固定时长」**：目标永远是 `cur_time + interval` 这个**绝对**系统时刻。即使本帧合成花了 5ms，下一个目标仍是上一目标 + interval，**误差不累积**（不会 drift）。这是固定步长仿真时钟的标准写法。
- **丢帧补偿（`else` 分支）**：如果到了 `os_sleepto_ns` 时 `t` 已经是过去（说明本帧渲染超过了一个 interval），它不会"装作只过了一帧"，而是算出实际落后了 `count = diff/interval` 个间隔，把 `video_time` **一次性跳** `count*interval`。同时 `vframe_info.count = count` 标记"这一帧顶 count 帧"。下游 `video_output_lock_frame` 收到 `count>1` 时会把同一帧在编码端复制 `count` 份（VFR/复帧），保证输出帧率名义上不掉、时间轴连续。`lagged_frames += count-1` 就是统计意义上的"卡掉的帧"。
- **`vframe_info.timestamp = cur_time`**：注意此刻 `cur_time` 还是**进入本函数时的旧 video_time**（即触发本帧 tick 的时刻），它被存进队列，下一轮 `output_frame` 弹出来当作合成帧的 timestamp。所以「时间戳 ↔ 帧」是滞后一拍配对的，但配的永远是那一帧对应的系统时钟时刻。

> 小结主线①：**sleep 到绝对 tick 时刻（不 drift）→ 把该时刻系统时间戳入队 → 下一轮 tick 所有源按真实 seconds 推进 → render_video 合成 → download 上一帧 → output_video_data 打上队列里的系统时间戳 → 送 video output。卡顿时用 count 一次性跳时间并复帧补偿。**

---

## 2. 音频混音（audio 线程）

### 2.1 audio 线程如何被驱动 — `audio_thread`（media-io/audio-io.c）

audio 不在 graphics 线程里，而在 audio-io 层有自己的线程。`audio-io.c:205`：

```c
static void *audio_thread(void *param)
{
	struct audio_output *audio = param;
	size_t   rate       = audio->info.samples_per_sec;
	uint64_t samples    = 0;
	uint64_t start_time = os_gettime_ns();   // ★ 与 video 同源的系统单调时钟
	uint64_t prev_time  = start_time;

	while (os_event_try(audio->stop_event) == EAGAIN) {
		samples += AUDIO_OUTPUT_FRAMES;                              // 每轮固定推进 1024 采样
		uint64_t audio_time = start_time + audio_frames_to_ns(rate, samples);  // 该批采样应对应的系统时刻

		os_sleepto_ns_fast(audio_time);                              // 睡到绝对时刻（同 video 的不 drift 策略）

		input_and_output(audio, audio_time, prev_time);             // 处理 [prev_time, audio_time) 这个窗口
		prev_time = audio_time;
	}
	...
}
```

- **节拍 = `AUDIO_OUTPUT_FRAMES`(1024) 采样的时长**：48kHz 下一轮 ≈ 21.33ms。`audio_time = start_time + (samples 总数换成 ns)`，同样是**绝对时刻、不累积漂移**，和 video 用同一个 `os_gettime_ns()` 基准——这是 A/V 共享时钟的物理实现。
- 每轮处理的是一个**时间窗口 `[prev_time, audio_time)`**，宽度恰好一批 1024 采样。窗口边界都是系统时钟值。

`input_and_output`（`audio-io.c:160`）清空各 mix 缓冲后，把窗口边界传给注册的 `input_cb`：

```c
success = audio->input_cb(audio->input_param, prev_time, audio_time, &new_ts, active_mixes, data);
```

而 `input_cb` 就是 `audio_callback`——在 `obs.c:1630` 注册：`ai.input_callback = audio_callback;`。所以 **audio-io 层负责"按固定时间窗口节拍调用"，libobs 的 `audio_callback` 负责"在这个窗口里把所有源混出来"**。混完后 `do_audio_output` 把结果发给下游（编码器/监听）。

### 2.2 遍历源 + 渲染 + 混音 — `audio_callback`（obs-audio.c:555）

签名收到窗口 `[start_ts_in, end_ts_in)`：

```c
bool audio_callback(void *param, uint64_t start_ts_in, uint64_t end_ts_in, uint64_t *out_ts, uint32_t mixers,
		    struct audio_output_data *mixes)
{
	struct ts_info ts = {start_ts_in, end_ts_in};   // 本次要混的系统时间窗口
	size_t sample_rate = audio_output_get_sample_rate(audio->audio);
	size_t channels    = audio_output_get_channels(audio->audio);
	uint64_t min_ts;

	/* 把本窗口压入 buffered_timestamps，再 peek 出队头作为实际处理窗口
	   （存在音频缓冲时，处理的可能是更早的窗口）*/
	deque_push_back(&audio->buffered_timestamps, &ts, sizeof(ts));
	deque_peek_front(&audio->buffered_timestamps, &ts, sizeof(ts));
	min_ts = ts.start;
	...
```

整个函数四步走：

**(a) 建渲染顺序**（`obs-audio.c:583-625`）：遍历所有 video mix 的 view channels（场景里激活的源）+ `first_audio_source` 链表（全局音频源如麦克风），用 `obs_source_enum_active_tree` 展开嵌套场景，把所有要出声的源收进 `render_order`，顶层源收进 `root_nodes`（只有 root 才会被混进 mix，子源音频已被父场景汇总）。

**(b) 渲染每个源的音频**（`obs-audio.c:629`）：

```c
for (size_t i = 0; i < audio->render_order.num; i++) {
	obs_source_t *source = audio->render_order.array[i];
	obs_source_audio_render(source, mixers, channels, sample_rate, audio_size);  // 把源 [audio_ts, +1024) 的采样取/算进 source->audio_output_buf

	/* 若源时间倒退且已无法再缓冲 → 丢弃部分/全部音频以止损 */
	if (audio_buffering_maxed(audio) && source->audio_ts != 0 && source->audio_ts < ts.start) {
		...
		bool rerender = ignore_audio(source, channels, sample_rate, ts.start);  // 丢掉滞后采样，尝试重新对齐
		if (rerender)
			obs_source_audio_render(source, mixers, channels, sample_rate, audio_size);
	}
}
```

`obs_source_audio_render`（在 obs-source.c）会按 `source->audio_ts` 和音量包络把源缓存里的 PCM 写进 `source->audio_output_buf[mix][ch]`。

**(c) 算最小时间戳 + 决定是否加缓冲**（`obs-audio.c:662-676`）：

```c
const char *buffering_name = calc_min_ts(data, sample_rate, &min_ts);   // 找所有源里最早的 audio_ts
...
if (audio->fixed_buffer) {
	if (!audio_buffering_maxed(audio)) set_fixed_audio_buffering(audio, sample_rate, &ts);
} else if (min_ts < ts.start) {                  // 有源的数据比当前窗口还早 → 还没追上
	add_audio_buffering(audio, sample_rate, &ts, min_ts, buffering_name);  // 整体加缓冲、回退窗口
}
```

**物理意义**：若某源（网络/高延迟设备）最早可用采样 `min_ts` 还落在窗口起点之前，说明它"来晚了"，OBS 不丢它，而是**整条音频管线后退 `ts`、增加缓冲 ticks**，给慢源争取时间——这是 OBS 处理音频抖动的方式（动态缓冲，最高 `max_buffering_ticks`）。

**(d) 真正混音**（`obs-audio.c:680-694`）：

```c
if (!audio->buffering_wait_ticks) {        // 只有不在"等缓冲填满"状态才真混
	for (size_t i = 0; i < audio->root_nodes.num; i++) {
		obs_source_t *source = audio->root_nodes.array[i];
		if (source->audio_pending) continue;
		pthread_mutex_lock(&source->audio_buf_mutex);
		if (source->audio_output_buf[0][0] && source->audio_ts)
			mix_audio(mixes, source, channels, sample_rate, &ts);   // ★ 按时间戳叠加进各 mix
		pthread_mutex_unlock(&source->audio_buf_mutex);
	}
}
```

最后 **(e) discard + 出队**（`obs-audio.c:696-728`）：对每个 audio source 调 `discard_audio` 丢掉本窗口已混掉的采样，`deque_pop_front(buffered_timestamps)`，`*out_ts = ts.start`（告诉 audio-io 这批输出的时间戳），若仍在等缓冲则 `buffering_wait_ticks--` 并 `return false`（本轮不输出，让上层跳过 `do_audio_output`）。

### 2.3 按时间戳放到正确偏移 — `mix_audio`（obs-audio.c:90）

```c
static inline void mix_audio(struct audio_output_data *mixes, obs_source_t *source, size_t channels,
			     size_t sample_rate, struct ts_info *ts)
{
	size_t total_floats = AUDIO_OUTPUT_FRAMES;   // 1024
	size_t start_point  = 0;

	if (source->audio_ts < ts->start || ts->end <= source->audio_ts)   // 源数据完全落在窗口外 → 不混
		return;

	if (source->audio_ts != ts->start) {                                // 源数据从窗口中段才开始
		start_point = convert_time_to_frames(sample_rate, source->audio_ts - ts->start);  // ★ 时间差→采样偏移
		if (start_point == AUDIO_OUTPUT_FRAMES) return;
		total_floats -= start_point;
	}

	for (size_t mix_idx = 0; mix_idx < MAX_AUDIO_MIXES; mix_idx++) {
		for (size_t ch = 0; ch < channels; ch++) {
			register float *mix = mixes[mix_idx].data[ch];
			register float *aud = source->audio_output_buf[mix_idx][ch];
			register float *end;
			mix += start_point;                 // ★ 落到 mix 缓冲中该源对应的时间偏移处
			end  = aud + total_floats;
			while (aud < end)
				*(mix++) += *(aud++);            // 浮点累加 = 混音
		}
	}
}
```

- **核心 = `start_point = (source->audio_ts − ts->start) 换算成采样数`**：源的当前时间戳与窗口起点的差，转成在 1024 样本缓冲里的偏移。源音频不是无脑写到缓冲头部，而是**按其时间戳对齐到正确的样本位置**，然后逐样本浮点累加进各 mix。多个源、多个 mixer（`MAX_AUDIO_MIXES`，OBS 支持 6 条独立音轨）就这样在统一时间网格上叠加。
- 这就是"按时间戳把源音频放到输出缓冲的正确偏移"——OBS 的音频混音本质是**时间对齐的浮点求和**，没有重采样到主时钟的反馈（重采样只在 audio-io 的 `resample_audio_output` 做格式/采样率适配，不做同步追赶）。

### 2.4 丢弃已混/过期音频 — `discard_audio`（obs-audio.c:223）

```c
static inline void discard_audio(struct obs_core_audio *audio, obs_source_t *source, size_t channels,
				 size_t sample_rate, struct ts_info *ts)
{
	size_t total_floats = AUDIO_OUTPUT_FRAMES;
	...
	if (source->info.audio_render) { source->audio_ts = 0; return; }   // 合成型源（如场景）无缓冲可丢

	if (ts->end <= source->audio_ts)        // 源时间戳还在窗口之后 → 没东西可丢
		return;

	if (source->audio_ts < (ts->start - 1)) {     // 源严重滞后（早于窗口）
		if (source->audio_pending && ... && discard_if_stopped(source, channels)) return;
		return;                                    // 留给 ignore_audio/缓冲逻辑处理
	}

	if (source->audio_ts != ts->start && source->audio_ts != (ts->start - 1)) {
		size_t start_point = convert_time_to_frames(sample_rate, source->audio_ts - ts->start);
		if (start_point == AUDIO_OUTPUT_FRAMES) return;
		total_floats -= start_point;               // 只丢窗口内已经消费的那部分
	}

	size = total_floats * sizeof(float);
	if (source->audio_input_buf[0].size < size) {  // 数据还没凑齐 → 标记停止/挂起，ts 跳到窗口尾
		if (discard_if_stopped(source, channels)) return;
		source->audio_ts = ts->end;
		return;
	}

	for (size_t ch = 0; ch < channels; ch++)
		deque_pop_front(&source->audio_input_buf[ch], NULL, size);  // ★ 真正丢弃已混采样
	source->last_audio_input_buf_size = 0;
	source->pending_stop = false;
	source->audio_ts = ts->end;            // ★ 推进源时间戳到窗口尾，准备下一窗口
}
```

逻辑：本窗口 `[ts->start, ts->end)` 已经混过了，把源缓冲里对应这段时间的采样 `deque_pop_front` 丢掉，并把 `source->audio_ts` 推进到 `ts->end`。`(ts->start - 1)` 的 ±1ns 容差是为了吸收纳秒↔采样换算的舍入误差。这样下一窗口 `mix_audio` 时 `source->audio_ts` 正好等于新窗口的 `ts->start`，对齐继续。

### 2.5 音频时间戳如何对齐到系统时钟（与视频共基准）

源进来时（`obs-source.c:1572` `source_output_audio_data`，详见第 ② 篇 §4）做时间戳归一：

```c
uint64_t os_time = os_gettime_ns();          // 系统单调时钟
...
in.timestamp += source->timing_adjust;       // ★ 把源自身 PTS 平移到系统时钟轴
```

而 `timing_adjust` 在 `reset_audio_timing`（`obs-source.c:1454`）里设定：

```c
static inline void reset_audio_timing(obs_source_t *source, uint64_t timestamp, uint64_t os_time)
{
	source->timing_set    = true;
	source->timing_adjust = os_time - timestamp;   // 系统时刻 − 源时间戳 = 偏移量
}
```

**这就是 A/V 同步的音频侧锚点**：源第一帧到达时记下 `os_time − 源timestamp`，此后该源所有音频帧 `+= timing_adjust`，于是 `source->audio_ts` 全部活在系统单调时钟轴上——与 `audio_callback` 的窗口 `[ts->start, ts->end)`（也来自系统时钟）同基准。

---

## 3. A/V 同步模型（重点）

### 3.1 OBS 的同步本质：两条管线共享系统单调时钟、各自按真实时间推进

把视频侧和音频侧的锚点并排看：

| | 视频侧 | 音频侧 |
|---|---|---|
| 线程 | `obs_graphics_thread` (obs-video.c) | `audio_thread` (audio-io.c) |
| 时钟起点 | `obs->video.video_time = os_gettime_ns()` (1172) | `start_time = os_gettime_ns()` (215) |
| 节拍 | 睡到 `video_time + interval` 绝对时刻 (809) | 睡到 `start_time + samples→ns` 绝对时刻 (225) |
| 帧/批时间戳 | `vframe_info.timestamp = cur_time`(=video_time) (827) | 窗口 `[prev_time, audio_time)` (231) |
| 源时间戳归一 | `timing_adjust = video_time − frame->timestamp` (obs-source.c:2524) | `timing_adjust = os_time − timestamp` (obs-source.c:1457) |

两条线**都用 `os_gettime_ns()`**作为唯一真理时钟，且都用"睡到绝对时刻 → 误差不累积"的方式推进。每个源进来无论自带什么 PTS（摄像头硬件时戳、文件解码 PTS），都在入口处被 `+= timing_adjust` 钉到这根系统时钟轴上。于是：

- 视频合成帧的 timestamp = 触发它的 tick 的系统时刻；
- 音频混音批的 timestamp = 它覆盖的系统时间窗口；
- 两者天然落在同一刻度上，**不需要任何一方做"追赶/拉伸"**。

播放/录制端要做的只是把带着系统时间戳的视频帧和音频批，按时间戳交织（interleave）写进容器——这步在编码器线程做（见第 ④ 篇）。

### 3.2 与 mpv「音频主时钟、视频追音频」的明确对比

| 维度 | OBS（合成器） | mpv（播放器） |
|---|---|---|
| **谁是主时钟** | **没有主从**。系统单调时钟 `os_gettime_ns()` 是唯一外部基准，video/audio 两条线平等地各自对齐到它 | **音频是主时钟**（audio PTS 由声卡播放进度反推），视频是从 |
| **同步机制** | 两条独立线程各自"睡到绝对系统时刻"，源帧入口 `+= timing_adjust` 归一到系统钟。被动对齐，无反馈环 | 视频帧主动计算"该不该现在显示"：比较 video PTS 与 audio clock，**早了多睡、晚了丢帧/快进**——闭环反馈调节 |
| **时间从哪来** | 墙钟驱动：现在几点 → 现在该出哪一帧/哪批采样（live，时间一直向前） | 媒体 PTS 驱动：文件里这帧标的是第几秒 → 等音频放到那一秒再显示（可暂停、可 seek） |
| **慢源/抖动** | 整条音频管线动态加缓冲（`add_audio_buffering`），或 `ignore_audio`/丢帧止损；时间不会停 | 通过调节视频显示时机吸收，音频连续优先；可缓冲整段 |
| **本质差异** | "**实时合成**"：时间是外生的、单向流逝的真实时间，所有源都要追上墙钟 | "**回放**"：时间是内生的、由音频播放进度定义，视频伺服音频 |

一句话：**mpv 是"视频追音频"的伺服系统；OBS 是"音视频各自追墙钟"的双管线时基系统。** mpv 关心"这帧标的时间到了没"，OBS 关心"现在真实时间到了，该合成/混出哪一帧"。

---

## 4. video-io / audio-io 管线（"缓冲 + 按时间分发"层）

这一层是 libobs 合成逻辑与编码器/消费者之间的解耦缓冲。

### 4.1 video-io：环形帧缓存 + 按时间戳记账

**写入端**（合成线程调用）—`video_output_lock_frame`（`video-io.c:509`）：

```c
bool video_output_lock_frame(video_t *video, struct video_frame *frame, int count, uint64_t timestamp)
{
	...
	video = get_root(video);
	pthread_mutex_lock(&video->data_mutex);

	if (video->available_frames == 0) {                       // 缓存满 → 消费者跟不上
		video->cache[video->last_added].count   += count;     // 把帧数累加到队尾帧上（编码端复帧）
		video->cache[video->last_added].skipped += count;
		locked = false;                                        // 本帧不单独入队
	} else {
		if (video->available_frames != video->info.cache_size) {
			if (++video->last_added == video->info.cache_size) video->last_added = 0;
		}
		cfi = &video->cache[video->last_added];
		cfi->frame.timestamp = timestamp;                     // ★ 合成帧的系统时间戳存进缓存槽
		cfi->count   = count;                                 // 这帧顶 count 帧（来自 video_sleep 的补偿）
		cfi->skipped = 0;
		memcpy(frame, &cfi->frame, sizeof(*frame));           // 把目标缓冲地址回传给调用方去填像素
		locked = true;
	}
	pthread_mutex_unlock(&video->data_mutex);
	return locked;
}
```

`video_output_unlock_frame`（`video-io.c:547`）：`available_frames--` 并 `os_sem_post(update_semaphore)` 唤醒消费线程。

**读出端**—独立的 `video_thread`（`video-io.c:190`）等信号量，调 `video_output_cur_frame`（`video-io.c:126`）：

```c
frame_info = &video->cache[video->first_added];
for (...inputs...) {                                  // 每个 input = 一个编码器/消费者，可有 frame_rate_divisor 降帧
	struct video_data frame = frame_info->frame;
	uint32_t skip = input->frame_rate_divisor_counter++;
	if (input->frame_rate_divisor_counter == input->frame_rate_divisor) input->frame_rate_divisor_counter = 0;
	if (skip) continue;
	if (scale_video_output(input, &frame)) input->callback(input->param, &frame);  // 把帧推给编码器
}
...
frame_info->frame.timestamp += video->frame_time;     // ★ 关键：时间戳按帧间隔自增
complete = --frame_info->count == 0;                  // count 份全消费完才出队
if (complete) { first_added++; available_frames++; }
else if (skipped) { --frame_info->skipped; skipped_frames++; }
```

要点：
- **`frame_time`**（`video-io.c:251` `out->frame_time = 1e9*fps_den/fps_num`）= 标称帧间隔。每消费一次，槽内时间戳 `+= frame_time`。所以当 `count>1`（卡顿补帧）时，同一像素被消费 `count` 次，但每次时间戳递增一个 frame_time——**复出来的帧带着规整递增的时间戳**，编码端拿到的是连续 CFR 时间轴。这是 OBS 把"墙钟 VFR 触发"转成"编码端规整时间戳"的地方。
- video-io 是 `cache_size` 个槽的环形缓存：合成端快了就填、消费端（编码）慢了 `available_frames` 归零，触发上面 `count += count` 的累加复帧。**这层的角色 = 吸收合成与编码之间的速率差 + 维护规整时间戳。**

### 4.2 audio-io：按固定时间窗口回调 + ts 推进

audio-io 的 `audio_thread`（已在 2.1 详述）才是音频侧的"按时间分发"引擎：每 1024 采样推进 `audio_time`（绝对系统时刻），调 `input_and_output` → `input_cb`(=`audio_callback`) 处理 `[prev_time, audio_time)` 窗口 → `do_audio_output`（`audio-io.c:107`）把 `audio_callback` 回填的 `new_ts`（=该批起始系统时间戳）和 1024 帧发给每个注册的音频消费者（编码器/监听）。

- video-io 是**被合成线程 push 唤醒**的（信号量），自己不持时钟；
- audio-io 是**自己持时钟主动 pull**的（`os_sleepto_ns_fast` 到点就调回调）。

两者都把"系统时间戳"作为帧/批的身份标识带给下游，下游 mux 时按时间戳交织即可对齐——闭环回到第 3 节的同步本质。

---

## 5. 对 WorkLabs 的启示

把 OBS 的模型映射回 WorkLabs（各源独立 render 线程节流 + `WLVideoMix` 合成 + `WLRecorder` 墙钟 epoch）：

1. **节拍模型的根本差异**。WorkLabs 现在是"每个源自带 render 线程，按 `baseTime + pts` 自行节流后把帧推进 `WLVideoMix`"——是**多个独立生产者各自定时**。OBS 是**单一 graphics 线程统一 tick**：一个 `os_sleepto_ns` 到点 → `tick_sources` 拉动所有源推进 → 合成一帧。OBS 这种"拉模型 + 统一节拍"的好处是合成帧率稳定、所有源在同一时刻被采样、不会出现源 A、源 B 各自抖动叠加。WorkLabs 若想要稳定输出帧率，可考虑引入一个"合成时钟线程"按固定 interval 触发 `WLVideoMix`，各源只维护"当前最新帧"，由合成线程在 tick 时刻取样（OBS 的 `obs_source_get_frame` 思路）。

2. **`os_sleepto_ns` 的"睡到绝对时刻"是关键技巧**。WorkLabs 录制用墙钟 epoch 打时间戳是对的方向；但要确保节拍用的是"睡到 `epoch + n*interval` 的绝对时刻"而非"sleep(固定时长)"，否则合成耗时会累积成 drift。OBS 的 `video_sleep` + 丢帧补偿（`count`/`lagged_frames`）值得照搬：卡顿时一次性跳时间 + 复帧，而不是默默落后。

3. **A/V 同步先统一时钟基准，再各自推进**。WorkLabs 录制是墙钟 epoch，这与 OBS 同源（系统单调时钟）。要补齐"录制带音频"时，关键是把**每个源的音频 PTS 用 `timing_adjust = wallclock − 源PTS` 归一到同一墙钟轴**（正是 OBS 的 `reset_audio_timing`/`source_output_audio_data` 做法），然后视频帧和音频包都带墙钟时间戳交给 muxer interleave。**不要让视频追音频或音频追视频**——对合成/录制场景，OBS 的"双管线共享墙钟"比 mpv 的"视频伺服音频"更合适，因为 WorkLabs 也是 live 合成而非回放。

4. **混音 = 时间对齐的浮点累加 + 动态缓冲**。将来做多源音频混合时，`mix_audio` 的范式可直接借鉴：按 `(源ts − 窗口start)` 换算采样偏移，把各源 PCM 叠加进固定大小（如 1024 帧）的 mix 缓冲；对慢源/抖动用"整体加缓冲"而非丢帧（`add_audio_buffering`）。配合一个固定 1024 样本窗口的音频线程（对应 `audio_thread`），与视频线程共用 `mach_absolute_time`/`os_gettime` 同一基准。

5. **生产/消费解耦缓冲层有价值**。OBS 的 video-io 环形缓存把"合成节拍"与"编码节拍"解耦，并负责把 VFR 触发整理成规整递增时间戳交给编码器。WorkLabs 的 `WLRecorder` 直接吃 `WLVideoMix` 的输出帧；若编码偶发变慢，建议在两者间加一层小环形缓存 + "编码跟不上就复用/复帧并递增时间戳"的策略，避免合成线程被编码阻塞或时间轴出现空洞。

**核心收获**：OBS 把"现在几点 → 该出哪一帧"作为唯一驱动，video/audio 两条线各自睡到系统钟的绝对刻度、源入口统一归一时间戳，从而无反馈地天然对齐；这与 mpv「视频追音频」的伺服闭环是两种世界观。WorkLabs 作为 live 合成器，方向应靠拢 OBS：统一节拍合成 + 共享墙钟基准 + 卡顿用复帧/缓冲补偿，而非让任一路去追另一路。
