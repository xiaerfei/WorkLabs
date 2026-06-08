# OBS 架构骨架与 WorkLabs 模块映射

> **性质**：OBS（libobs）源码级深挖调研 · 系列第 ① 篇（架构总览 / 系列入口）。
> **调研对象**：obs-studio `32.1.2-94-gf61619ce3`（`/Users/tvum4pro/Documents/github/obs-studio`，核心 `libobs/`）。
> **方法**：与 mpv 调研一致——并行 agent 源码级精读、行号实读核对。
> **为什么调研 OBS**：OBS 是 OBS-like 多源合成器，与 WorkLabs 项目逻辑**几乎一致**（mpv 是播放器，逻辑只部分相通）。这是比 mpv 更贴近 WorkLabs 的取经对象。
>
> **OBS 调研系列（四维度）**：
> 1. **本篇** — 架构骨架 · 核心数据结构 · 线程模型 · OBS↔WorkLabs 模块映射
> 2. [OBS_源异步帧缓冲与时间戳节流](OBS_源异步帧缓冲与时间戳节流.md) — 单个源的帧如何缓冲、按系统时钟 tick 选帧/丢帧
> 3. [OBS_合成tick_音频混音_AV同步](OBS_合成tick_音频混音_AV同步.md) — 合成主循环 · 音频混音 · 双管线共享系统时钟的 A/V 同步
> 4. [OBS_输出侧_编码_复用_录制推流](OBS_输出侧_编码_复用_录制推流.md) — 编码 pts · a/v interleave 对齐 · 录制/推流
>
> **与 mpv 调研的关系**：见 `Doc/调研/mpv/`。本系列各篇末尾的「OBS vs mpv」对比即两套范式的分水岭。

---

OBS 的整个 libobs 内核可以一句话概括：**一个全局单例 `obs`，挂着「图形/视频子系统 + 音频子系统 + 用户数据（sources/outputs/canvases…）」三大块，由一条固定帧率的 graphics 线程（系统单调时钟主导）周期性地 tick 所有源、渲染合成、把成片推给各 video output；另一条音频线程按固定时间窗口独立拉取并混音。** 这与播放器（mpv）的「音频主时钟 + 按 pts 调度」是根本相反的两套模型——这一点贯穿全文，最后专门对比。

---

## 1. 核心数据结构（`libobs/obs-internal.h`）

### 1.1 全局单例 `struct obs_core` —— 一切的根

`obs-internal.h:544-581`：

```c
struct obs_core {
    struct obs_module *first_module;           // 已加载插件模块链表
    obs_source_info_array_t source_types;       // 注册的源/滤镜/转场类型
    /* … output_types / encoder_types / service_types … */

    signal_handler_t *signals;                  // 全局信号
    proc_handler_t *procs;

    /* segmented into multiple sub-structures … */
    struct obs_core_video video;                // 图形+视频子系统（含所有 video mix）
    struct obs_core_audio audio;                // 音频子系统
    struct obs_core_data data;                  // 用户对象：sources/outputs/canvases/displays
    struct obs_core_hotkeys hotkeys;

    os_task_queue_t *destruction_task_thread;   // 异步析构队列
    obs_task_handler_t ui_task_handler;
};

extern struct obs_core *obs;   // obs-internal.h:581 —— 进程内唯一全局指针
```

`obs` 是一个 **全局裸指针**（不是参数传递），`obs_init()` 里 `obs = bzalloc(sizeof(struct obs_core))`（`obs.c:1225`）。整个 libobs 几乎所有函数都直接读写 `obs->...`。这是 OBS「单实例」的根本设计——一个进程一套合成器。

它把状态切成四个子结构，便于组织：`video`（图形+视频）、`audio`、`data`（用户对象）、`hotkeys`。

---

### 1.2 `struct obs_core_video` —— 图形子系统 + 视频线程时钟

`obs-internal.h:389-436`（节选关键字段）：

```c
struct obs_core_video {
    graphics_t *graphics;                  // 图形设备（Metal/D3D/GL）
    gs_effect_t *default_effect;           // 各种内置 effect/shader
    /* … 一大堆 effect … */

    uint64_t video_time;                   // ★ 当前帧的目标系统时间戳（单调时钟）
    uint64_t video_frame_interval_ns;      // ★ 每帧间隔 = 1e9 * fps_den / fps_num
    uint64_t video_half_frame_interval_ns;
    uint64_t video_avg_frame_time_ns;
    double   video_fps;
    pthread_t video_thread;                // ★ graphics/video 线程句柄
    uint32_t total_frames;
    uint32_t lagged_frames;                // 落后/丢帧统计
    bool     thread_initialized;

    pthread_mutex_t task_mutex;
    struct deque    tasks;                 // 投递到 video 线程执行的任务队列

    pthread_mutex_t mixes_mutex;
    DARRAY(struct obs_core_video_mix *) mixes;  // ★ 所有 video mix（每个 canvas 一个）
};
```

职责：持有图形设备与全部 shader，**持有 video 线程和它的时钟字段**（`video_time` / `video_frame_interval_ns`），并管理一个 `mixes` 数组——OBS 把「一块画布的合成」抽象成一个 `obs_core_video_mix`，可以有多个（主画布 + 多预览/投影画布），但 **它们共享同一条 video 线程和同一套 fps**（见 §3）。

---

### 1.3 `struct obs_core_video_mix` —— 一块画布的合成单元

`obs-internal.h:332-384`（节选）：

```c
struct obs_core_video_mix {
    struct obs_view *view;                 // ★ 这个 mix 渲染哪些源（channels[]）

    gs_texture_t *render_texture;          // 合成目标纹理
    gs_texture_t *output_texture;
    gs_texture_t *convert_textures[NUM_CHANNELS];  // GPU 色彩空间/格式转换
    enum gs_color_space render_space;

    struct deque vframe_info_buffer;       // ★ 待输出帧的时间戳队列（raw 路径）
    struct deque vframe_info_buffer_gpu;   // GPU 编码路径
    int cur_texture;
    volatile long raw_active;              // 是否有 raw（CPU 下载）消费者
    volatile long gpu_encoder_active;      // 是否有 GPU 编码消费者

    pthread_t gpu_encode_thread;          // 可选：GPU 编码独立线程
    DARRAY(obs_encoder_t *) gpu_encoders;

    video_t *video;                        // ★ media-io 的 video_output（下游 outputs 从这里取帧）
    struct obs_video_info ovi;             // 这块画布的分辨率/fps/格式

    bool gpu_conversion;
    float color_matrix[16];
    bool mix_audio;                        // 这个 view 的源是否参与音频混音
};
```

这是 WorkLabs 视角下最关键的对照点：**`obs_core_video_mix` ≈ WLVideoMix + WLCanvasModel 的合成产物**。它有自己的画布尺寸 `ovi`、自己的合成纹理 `render_texture`，把成片喂给 `video`（一个 `video_output`），下游的 `obs_output`（录制/推流）从这个 `video` 上拉帧（§4）。`view` 指向「渲染哪些源」。

---

### 1.4 `struct obs_core_audio` —— 音频子系统

`obs-internal.h:442-464`（节选）：

```c
struct obs_core_audio {
    audio_t *audio;                        // ★ media-io 的 audio_output（驱动 audio 线程）

    DARRAY(struct obs_source *) render_order;  // 本次 tick 的音频渲染顺序（拓扑）
    DARRAY(struct obs_source *) root_nodes;    // 顶层混音节点

    uint64_t buffered_ts;
    struct deque buffered_timestamps;      // ★ 时间窗口队列 [start_ts, end_ts]
    uint64_t buffering_wait_ticks;
    int total_buffering_ticks;
    int max_buffering_ticks;               // 最大缓冲深度（默认 45 tick）
    bool fixed_buffer;

    pthread_mutex_t monitoring_mutex;
    DARRAY(struct audio_monitor *) monitors;  // 音频监听（回放到本机扬声器）

    struct deque tasks;                    // 投递到 audio 线程的任务
};
```

注意：**`audio_t *audio` 自带线程**（在 media-io 的 `audio-io.c` 里，见 §3.2），`obs_core_audio` 本身不存线程句柄，只存「混音用的中间状态」。`render_order` / `root_nodes` 在每次 `audio_callback` 里重建。

---

### 1.5 `struct obs_context_data` —— 所有「对象」的公共基类

`obs-internal.h:625-652`：

```c
struct obs_context_data {
    char *name;
    const char *uuid;
    void *data;                            // ★ 具体实现的私有数据（插件 create() 返回）
    obs_data_t *settings;                  // 配置（可序列化）
    signal_handler_t *signals;             // 本对象信号
    proc_handler_t *procs;                 // 本对象 proc
    enum obs_obj_type type;                // SOURCE / OUTPUT / ENCODER / SERVICE …

    struct obs_weak_object *control;       // 弱引用控制块（引用计数）
    obs_destroy_cb destroy;

    DARRAY(obs_hotkey_id) hotkeys;
    /* … */

    pthread_mutex_t *mutex;
    struct obs_context_data *next;         // ★ 侵入式链表
    struct obs_context_data **prev_next;

    UT_hash_handle hh;                     // ★ 按 name 的 uthash
    UT_hash_handle hh_uuid;                // ★ 按 uuid 的 uthash
    bool private;
};
```

这是 OBS 的「类继承」手法：`obs_source` / `obs_output` / `obs_encoder` / `obs_service` / `obs_canvas` 的 **第一个成员都是 `struct obs_context_data context;`**（见 `obs_source` `:808`、`obs_output` `:1212`、`obs_canvas` `:722`）。于是任意对象指针都能安全 cast 成 `obs_context_data*`，统一处理 名字/uuid 哈希、信号、引用计数、链表。`data` 字段挂的是插件实现的私有结构。

---

### 1.6 `struct obs_source` —— 源（输入/滤镜/转场/场景统一体）

`obs-internal.h:807-1004`，是最大的结构。关键分区（节选）：

```c
struct obs_source {
    struct obs_context_data context;       // 基类
    struct obs_source_info info;           // 类型回调表（create/video_render/audio_render/video_tick…）

    uint32_t flags;
    volatile long show_refs;               // 引用计数式 show/hide
    volatile long activate_refs;           // 引用计数式 activate/deactivate
    bool active, showing, enabled;

    /* timing —— ★ 异步源时间对齐的核心 */
    volatile bool     timing_set;
    volatile uint64_t timing_adjust;       // = 系统时钟 - 源 pts（把源 pts 拉到系统时钟）
    uint64_t last_frame_ts;                // 上一已渲染帧的 pts
    uint64_t last_sys_timestamp;           // 上一 tick 的系统时间

    /* audio */
    struct deque   audio_input_buf[MAX_AUDIO_CHANNELS];  // 重采样后的环形缓冲
    float         *audio_output_buf[MAX_AUDIO_MIXES][MAX_AUDIO_CHANNELS];
    audio_resampler_t *resampler;
    uint64_t       audio_ts;
    int64_t        sync_offset;            // 用户 a/v 同步偏移
    struct obs_source *next_audio_source;  // first_audio_source 链表

    /* async video（解码源走这条路，如媒体文件/摄像头）*/
    struct obs_source_frame *cur_async_frame;
    DARRAY(struct async_frame) async_cache;     // 帧池（复用）
    DARRAY(struct obs_source_frame *) async_frames;  // ★ 待渲染帧队列
    pthread_mutex_t async_mutex;
    uint64_t async_last_rendered_ts;

    /* filters */
    struct obs_source *filter_parent, *filter_target;
    DARRAY(struct obs_source *) filters;   // 滤镜链

    /* canvas this source belongs to (only used for scenes) */
    obs_weak_canvas_t *canvas;
};
```

一个 `obs_source` 可以是输入源、滤镜、转场或场景（`info.id` 决定）。对 WorkLabs 最相关的是 **async video 区**：解码出来的帧（摄像头/媒体文件）通过 `obs_source_output_video()` 推进 `async_frames` 队列，由 video 线程 tick 按系统时钟取出（§3.1）；`timing_adjust` 把源自己的 pts 平移到系统单调时钟域。

---

### 1.7 `struct obs_output` —— 输出（录制/推流）

`obs-internal.h:1211-1304`（节选）：

```c
struct obs_output {
    struct obs_context_data context;
    struct obs_output_info info;           // 回调表：start/stop/raw_video/raw_audio/encoded_packet

    bool received_video[MAX_OUTPUT_VIDEO_ENCODERS];
    bool received_audio;
    volatile bool data_active;

    pthread_mutex_t interleaved_mutex;
    DARRAY(struct encoder_packet) interleaved_packets;  // ★ a/v 交织排序缓冲

    volatile bool active, paused;
    video_t *video;                        // ★ 取帧来源（= 某个 mix 的 video_output）
    audio_t *audio;                        // ★ 取音频来源（= obs_core_audio.audio）
    obs_encoder_t *video_encoders[MAX_OUTPUT_VIDEO_ENCODERS];
    obs_encoder_t *audio_encoders[MAX_OUTPUT_AUDIO_ENCODERS];
    obs_service_t *service;                // 推流目标（RTMP 等）

    struct deque audio_buffer[MAX_AUDIO_MIXES][MAX_AV_PLANES];
    uint64_t audio_start_ts, video_start_ts;  // ★ a/v 对齐起点

    int64_t video_offsets[MAX_OUTPUT_VIDEO_ENCODERS];
    int64_t audio_offsets[MAX_OUTPUT_AUDIO_ENCODERS];
    /* reconnect / delay / caption … */
};
```

`obs_output` 持有 `video` / `audio` 两个指针——它从某个 `video_output`（即某个 mix 的成片流）和全局 `audio_output` 拉数据，经 encoder 编码后交织（`interleaved_packets`）再 mux。`video_start_ts` / `audio_start_ts` 是它做 a/v 对齐的锚点。这正是 WorkLabs `WLRecorder` 的对应物，但 OBS 把「编码器」和「输出/mux」拆成了 `obs_encoder` + `obs_output` 两层。

---

### 数据结构关系图

```
                              struct obs_core *obs   (全局单例, obs-internal.h:581)
                              ────────────────────────────────────────────────────
                                │              │              │
          ┌─────────────────────┘              │              └────────────────────┐
          ▼                                     ▼                                   ▼
  obs_core_video (video)              obs_core_audio (audio)               obs_core_data (data)
  ─────────────────────               ────────────────────                ───────────────────────
  graphics_t *graphics                audio_t *audio  ──(自带音频线程)      sources   (uthash by uuid)
  pthread_t  video_thread             render_order[]                       public_sources (by name)
  video_time / interval_ns            root_nodes[]                         canvases  (uthash)
  DARRAY mixes[]  ─────┐              buffered_timestamps (窗口)            first_audio_source ─┐
                       │                                                    first_output  ──┐  │
                       ▼                                                    main_canvas     │  │
              obs_core_video_mix (每个 canvas 一个)                                          │  │
              ──────────────────                                                            │  │
              obs_view *view ──► channels[MAX_CHANNELS] ─► obs_source ◄────────────────────┘  │
              render_texture / output_texture                  ▲   (顶层源, 通常是一个 scene)   │
              video_t *video  ◄──────────────────────┐         │                              │
              ovi (分辨率/fps/格式)                    │         └── obs_scene.first_item ──►    │
                                                      │              obs_scene_item.source ──► obs_source (子源)
              obs_output ──► video (从某 mix 取帧) ────┘                                         │
                       └──► audio (= obs_core_audio.audio) ◄──────────────────────────────────┘

  所有 obs_source / obs_output / obs_canvas / obs_encoder / obs_service
  第一个成员都是 struct obs_context_data context;  → 统一 名字/uuid 哈希 + 信号 + 引用计数 + 链表
```

---

## 2. 全局上下文与初始化生命周期（`libobs/obs.c`）

「一个 OBS 实例」分三步搭起来，调用方（如 obs-studio 前端）依次调用 `obs_startup` → `obs_reset_video` → `obs_reset_audio`。

### 2.1 `obs_startup` → `obs_init`：建对象、不建线程

`obs.c:1320` 的 `obs_startup` 仅做 COM 初始化和调 `obs_init`（`obs.c:1223`）：

```c
static bool obs_init(const char *locale, ...) {
    obs = bzalloc(sizeof(struct obs_core));      // :1225  分配全局单例
    /* 初始化各 mutex */
    obs->name_store = store ? store : profiler_name_store_create();

    if (!obs_init_data())       return false;     // :1242  哈希表/链表/mutex
    if (!obs_init_handlers())   return false;     // :1244  全局 signals/procs
    if (!obs_init_hotkeys())    return false;     // :1246

    /* Create persistent main canvas. */
    obs->data.main_canvas = obs_create_main_canvas();   // :1250 ★ 主画布常驻
    obs->destruction_task_thread = os_task_queue_create();  // :1254

    obs_register_source(&scene_info);             // :1261  注册内置「场景」源类型
    obs_register_source(&group_info);             // :1262
    obs_register_source(&audio_line_info);        // :1263
    add_default_module_paths();
    return true;
}
```

此阶段 **还没有图形设备，也没有 video/audio 线程**。只是把全局结构、哈希表、信号系统、主画布（mix 尚未分配视频）和内置源类型立起来。

### 2.2 `obs_reset_video` → `obs_init_graphics` + `obs_init_video`：建图形设备 + 启动 video 线程

`obs.c:1525` 的 `obs_reset_video`：

```c
int obs_reset_video(struct obs_video_info *ovi) {
    if (obs_video_active()) return OBS_VIDEO_CURRENTLY_ACTIVE;  // 运行中禁止改
    stop_video();                       // :1537  停旧线程
    obs_free_canvas_mixes();
    obs_free_video();

    ovi->output_width  &= 0xFFFFFFFC;   // 对齐
    ovi->output_height &= 0xFFFFFFFE;

    if (!obs->video.graphics) {
        int errorcode = obs_init_graphics(ovi);   // :1546 ★ 创建图形设备 + 编译 shader
        ...
    }
    return obs_init_video(ovi);          // :1594 ★
}
```

`obs_init_graphics`（`obs.c:479`）`gs_create()` 建图形设备（macOS 下是 Metal），然后 `gs_effect_create_from_file` 把 `default.effect` / `format_conversion.effect` / `bicubic_scale.effect` 等一堆内置 shader 编译进 `obs_core_video`。

`obs_init_video`（`obs.c:691`）是 **video 时钟与线程的诞生地**：

```c
static int obs_init_video(struct obs_video_info *ovi) {
    struct obs_core_video *video = &obs->video;
    video->video_frame_interval_ns      = util_mul_div64(1000000000ULL, ovi->fps_den, ovi->fps_num);  // :694 ★ 帧间隔
    video->video_half_frame_interval_ns = util_mul_div64( 500000000ULL, ovi->fps_den, ovi->fps_num);  // :695

    /* 给主画布建 mix（video_output_open 在内部） */
    if (!obs_canvas_reset_video_internal(obs->data.main_canvas, ovi))  // :705
        return OBS_VIDEO_FAIL;
    if (!restore_canvases()) return OBS_VIDEO_FAIL;   // :708 其余画布

#ifdef __APPLE__
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);  // :715 高优先级
    errorcode = pthread_create(&video->video_thread, &attr,
                               obs_graphics_thread_autorelease, obs);     // :716 ★ 启动 video 线程
#else
    errorcode = pthread_create(&video->video_thread, NULL, obs_graphics_thread, obs);  // :718
#endif
    video->thread_initialized = true;
    return OBS_VIDEO_SUCCESS;
}
```

每个画布的 mix 通过 `obs_init_video_mix`（`obs.c:605`）创建，里面 `video_output_open(&video->video, &vi)`（`obs.c:632`）开出 media-io 的 `video_output`——这是下游 outputs 取帧的端口。**注意 `obs.c:614-622`**：辅助画布会强制沿用主画布的 fps，因为 **所有 mix 共用同一条 video 线程的节拍**。

### 2.3 `obs_reset_audio` → `obs_init_audio`：开音频输出（自带线程）

`obs.c:1645 obs_reset_audio` → `:1601 obs_reset_audio2`：组装 `audio_output_info`（采样率、声道、`AUDIO_FORMAT_FLOAT_PLANAR`、`.input_callback = audio_callback`），算出 `max_buffering_ticks`（默认 45），调 `obs_init_audio`（`obs.c:903`）：

```c
static bool obs_init_audio(struct audio_output_info *ai) {
    /* … */
    errorcode = audio_output_open(&audio->audio, ai);   // :925 ★ 开音频输出 → 内部启动 audio 线程
    ...
}
```

`audio_output_open` 在 `media-io/audio-io.c` 里 `pthread_create(..., audio_thread, out)`（`audio-io.c:376`），**音频线程在此刻诞生**，并把上面那个 `audio_callback` 作为 `input_cb`。

### 初始化调用链总览

```
前端
 └─ obs_startup(locale, cfg, store)                 obs.c:1320
     └─ obs_init()                                  obs.c:1223
         ├─ obs_init_data()      哈希表/链表/mutex     obs.c:966
         ├─ obs_init_handlers()  全局 signals/procs   obs.c:1121
         ├─ obs_init_hotkeys()
         ├─ obs_create_main_canvas()  主画布常驻        obs.c:1250
         └─ obs_register_source(scene/group/audio_line)
 └─ obs_reset_video(ovi)                            obs.c:1525
     ├─ obs_init_graphics(ovi)   建图形设备+shader     obs.c:479   ← Metal/D3D/GL
     └─ obs_init_video(ovi)                          obs.c:691
         ├─ video_frame_interval_ns = 1e9*den/num    obs.c:694   ← 固定节拍来源
         ├─ obs_canvas_reset_video_internal(main)    → obs_init_video_mix → video_output_open
         └─ pthread_create(video_thread,
                           obs_graphics_thread)       obs.c:716/718  ← ★ video 线程启动
 └─ obs_reset_audio(oai)                            obs.c:1645
     └─ obs_init_audio(ai)                           obs.c:903
         └─ audio_output_open() → pthread_create(audio_thread)   audio-io.c:376  ← ★ audio 线程启动
```

---

## 3. 线程模型（关键）

OBS 的核心是 **两条独立、各自按系统单调时钟（`os_gettime_ns`）固定节拍的线程**：video 线程（固定 fps tick）和 audio 线程（固定时间窗口）。它们都是 **「时间到了就跑一拍」**，而不是「等数据来了才跑」。

### 3.1 video / graphics 线程 —— 固定帧率 tick（`obs-video.c`）

线程入口 `obs_graphics_thread`（`obs-video.c:1161`）：

```c
void *obs_graphics_thread(void *param) {
    is_graphics_thread = true;
    const uint64_t interval = obs->video.video_frame_interval_ns;   // :1170 ★ 固定帧间隔
    obs->video.video_time = os_gettime_ns();                        // :1172 ★ 以系统单调时钟为起点
    os_set_thread_name("libobs: graphics thread");
    /* … context.interval = interval … */
    while (obs_graphics_thread_loop_autorelease(&context))          // :1191 (macOS)
        ;
}
```

每一拍 `obs_graphics_thread_loop`（`obs-video.c:1097`）：

```c
bool obs_graphics_thread_loop(struct obs_graphics_context *context) {
    uint64_t frame_start = os_gettime_ns();                 // :1099

    update_active_states();                                 // :1102 刷新各 mix 是否有消费者
    gs_begin_frame();

    /* ① tick：用系统时钟推进所有源 */
    context->last_time = tick_sources(obs->video.video_time, context->last_time);  // :1112

    /* ② render + 把成片喂给每个 mix 的 video_output */
    output_frames();                                        // :1125
    /* ③ 渲染所有屏幕预览 display/swapchain */
    render_displays();                                      // :1129
    execute_graphics_tasks();                               // :1133  投递任务

    /* ④ 睡到下一拍（决定节拍的地方）*/
    video_sleep(&obs->video, &obs->video.video_time, context->interval);  // :1142
    return !stop_requested();
}
```

**节拍由 `video_sleep`（`obs-video.c:805`）决定：**

```c
static inline void video_sleep(struct obs_core_video *video, uint64_t *p_time, uint64_t interval_ns) {
    uint64_t cur_time = *p_time;
    uint64_t t = cur_time + interval_ns;         // 下一帧目标系统时间
    int count;
    if (os_sleepto_ns(t)) {                      // ★ 睡到绝对时间点 t（系统单调时钟）
        *p_time = t;  count = 1;
    } else {                                     // 睡过头（卡顿）→ 算补几帧
        const uint64_t udiff = os_gettime_ns() - cur_time;
        ...
        count = (int)(clamped_diff / interval_ns);  // 一次补 count 帧
        *p_time = cur_time + interval_ns * count;
    }
    video->total_frames  += count;
    video->lagged_frames += count - 1;           // 落后帧统计
    /* 把 {timestamp=cur_time, count} 推入各 mix 的 vframe_info_buffer，供 output 用 */
}
```

关键点：
- **时钟是 `os_gettime_ns()`（系统单调时钟），不是任何媒体的 pts。** `video_time` 严格按 `interval_ns` 步进；`os_sleepto_ns(t)` 睡到下一帧的绝对时间点。
- **`interval_ns` 来自 `obs_init_video`（`obs.c:694`）的 `1e9 * fps_den / fps_num`**——即录制/合成的目标 fps。卡顿时 `count>1` 一次补多帧（输出层会把这帧重复 `count` 次，保持 CFR）。
- **每拍做四件事**：tick 源 → 渲染合成 → 渲染预览 → 输出。

**`tick_sources`（`obs-video.c:32`）** 遍历 `obs->data.sources` 链表，对每个源调 `obs_source_video_tick(s, seconds)`，`seconds` 是 **两拍之间的系统时间差**。异步源在 tick 里用这个系统时间差从 `async_frames` 队列取「该显示哪一帧」——见 `ready_async_frame`（`obs-source.c:4087`）：

```c
static bool ready_async_frame(obs_source_t *source, uint64_t sys_time) {
    uint64_t sys_offset = sys_time - source->last_sys_timestamp;   // :4091 系统时钟走了多少
    ...
    frame_offset = frame_time - source->last_frame_ts;
    source->last_frame_ts += sys_offset;                           // :4124 ★ 用系统时钟推进“当前播放位置”
    while (source->last_frame_ts > next_frame->timestamp) {        // :4127 丢弃所有已过期的帧
        ...
    }
}
```

**这就是 OBS 处理「解码源 pts」的方式：不按源 pts 调度，而是把系统时钟的步进量加到 `last_frame_ts` 上，然后丢掉所有 pts 已落后于它的帧。** 源的快慢完全由系统时钟节拍裁决——源跟不上就丢帧/重复帧，绝不会让源拖慢全局节拍。（这部分在系列第 ② 篇详解。）

`output_frames`（`obs-video.c:916`）遍历 `obs->video.mixes` 调 `output_frame`，最终 `output_video_data`（`obs-video.c:777`）把合成纹理 `video_output_lock_frame` 写进该 mix 的 `video`，下游 outputs 即可取到。（合成与输出细节见第 ③ 篇。）

### 3.2 audio 线程 —— 固定时间窗口（`media-io/audio-io.c` 驱动 → `obs-audio.c` 回调）

audio 线程入口 `audio_thread`（`audio-io.c:205`）：

```c
static void *audio_thread(void *param) {
    struct audio_output *audio = param;
    size_t   rate       = audio->info.samples_per_sec;
    uint64_t samples    = 0;
    uint64_t start_time = os_gettime_ns();      // :215 ★ 以系统单调时钟为起点
    uint64_t prev_time  = start_time;

    while (os_event_try(audio->stop_event) == EAGAIN) {
        samples += AUDIO_OUTPUT_FRAMES;                                  // :224 每拍固定 N 帧
        uint64_t audio_time = start_time + audio_frames_to_ns(rate, samples);  // :225 下一窗口结束时间
        os_sleepto_ns_fast(audio_time);                                 // :227 ★ 睡到该时间点
        input_and_output(audio, audio_time, prev_time);                 // :231 处理 [prev_time, audio_time)
        prev_time = audio_time;
    }
}
```

`input_and_output`（`audio-io.c:160`）清空混音缓冲后调 `audio->input_cb(...)`——也就是 OBS 注册的 `audio_callback`（`obs-audio.c:555`）。（混音细节见第 ③ 篇。）

关键点：
- **时钟同样是 `os_gettime_ns()`，固定每拍 `AUDIO_OUTPUT_FRAMES` 个采样**（`audio-io.c:224`），`os_sleepto_ns_fast` 睡到下一窗口边界。两条线程时钟基准相同（系统单调时钟），但 **各自独立步进、互不阻塞**。
- audio 工作在 **时间窗口 `[start_ts, end_ts)`** 上，把所有源的音频对齐到这个窗口混音。源时间戳回退时用 `add_audio_buffering` 动态加缓冲（默认上限 45 tick），而不是让音频跟着某个源跑。

### 线程模型示意

```
        系统单调时钟 os_gettime_ns()  (两条线程共用同一基准，但各自独立步进)
        ════════════════════════════════════════════════════════════════════

  ┌─ video / graphics 线程 ───────────────────────────────┐   ┌─ audio 线程 ─────────────────────────┐
  │  obs_graphics_thread  (obs-video.c:1161)               │   │  audio_thread (audio-io.c:205)        │
  │  起点 video_time = os_gettime_ns()                      │   │  起点 start_time = os_gettime_ns()     │
  │  节拍 interval_ns = 1e9*fps_den/fps_num   (固定 fps)    │   │  节拍 = N samples (AUDIO_OUTPUT_FRAMES)│
  │                                                        │   │                                       │
  │  每拍 loop (obs-video.c:1097):                          │   │  每拍 (audio-io.c:223):               │
  │   ① tick_sources()  系统时钟推进所有源, 丢/补帧          │   │   os_sleepto_ns_fast(audio_time)      │
  │   ② output_frames() 合成 → 各 mix 的 video_output       │   │   input_and_output() →                │
  │   ③ render_displays() 屏幕预览                          │   │     audio_callback() (obs-audio.c:555)│
  │   ④ video_sleep(): os_sleepto_ns(video_time+interval)  │   │       窗口[start,end) 内逐源渲染+混音   │
  │      卡顿→count>1 补帧 (lagged_frames++)                │   │       源回退→动态加缓冲(≤45 tick)      │
  └────────────────────────────────────────────────────────┘   └───────────────────────────────────────┘
            │  成片帧 (video_t)                                            │  混好的音频 (audio_t)
            └──────────────┬───────────────────────────────────────────────┘
                           ▼
                 obs_output (录制/推流): 各 encoder 编码 → interleaved_packets 交织 → mux
```

> 还有若干次要线程：GPU 编码线程（`obs_core_video_mix.gpu_encode_thread`）、热键线程、析构线程（`destruction_task_thread`）、各源/输出自己的解码/网络线程。但 **合成与时基的主导只有 video + audio 两条**。

---

## 4. 源 / 场景 / 输出的挂接关系

**源注册进全局**：`obs_source_create` 调 `obs_context_data_init` 后，通过 `obs_context_data_insert_uuid`（`obs.c:2760`）/ `insert_name`（`obs.c:2729`）把自己插进 `obs->data.sources`（uuid 哈希）和 `public_sources`（name 哈希）。video 线程的 `tick_sources` 正是遍历 `obs->data.sources`（`obs-video.c:65-71`）。

**场景 = 源的容器**（`obs-scene.c` / `obs-scene.h`）：`obs_scene` 本身 `info.id == "scene"`，是一个特殊的 `obs_source`（`obs_scene.source` 反指回去，`obs-scene.h:100`）。它持有 `first_item` 链表（`obs-scene.h:115`），每个 `obs_scene_item`（`obs-scene.h:30`）有：
- `source`（`:42`）——这个 item 显示哪个源；
- `pos / scale / rot / crop / bounds / box_transform`（`:55-80`）——**变换/裁剪/层级信息**，正是 WorkLabs 画布里每个流的 `layout rect + z-order`；
- `prev / next`（`:95-96`）——链表顺序即 **z-order（底→顶）**。

场景被渲染时遍历 `first_item`，按变换把每个子源画到画布纹理上——这就是 OBS 的「合成」。

**源连到画布/渲染**：通过 `obs_view`（`obs-internal.h:278`）的 `channels[MAX_CHANNELS]`。前端调 `obs_set_output_source(channel, scene)`（`obs.c:1834`）→ `obs_canvas_set_channel` → 把场景源放进主画布 view 的某个 channel。video 线程渲染该 mix 时 `obs_view_render(video->view)`（`obs-video.c:202`）遍历 channels 渲染顶层源（通常 channel 0 是当前场景），递归画出场景里所有 item。

**输出连到 video/audio**：`obs_output_create` 默认 `output->video = obs_get_video(); output->audio = obs_get_audio();`（`obs-output.c:232-233`）。其中 `obs_get_video()` 返回 **主画布 mix 的 `video`**（`obs.c:1824-1826`：`obs->data.main_canvas->mix->video`），`obs_get_audio()` 返回 `obs->audio.audio`（`obs.c:1819-1821`）。输出启动时若是 raw 输出，`start_raw_video(output->video, ..., default_raw_video_callback, output)`（`obs-output.c:2520`）在那个 `video_output` 上注册回调，video 线程每拍 `output_video_data` 写帧就会回调到 output（`obs-output.c:2328`）。编码输出则走 encoder→`interleaved_packets`→mux（第 ④ 篇）。

```
obs_set_output_source(0, scene)            obs_output_create()
        │                                          │ video = obs_get_video() = main_canvas->mix->video
        ▼                                          │ audio = obs_get_audio() = obs->audio.audio
 main_canvas.view.channels[0] = scene             ▼
        │                              obs_output_start → start_raw_video(video,…)/encoder
        ▼                                          ▲ 每拍取帧
 video线程 tick → obs_view_render(view)             │
        │  遍历 scene.first_item                    │
        ▼  按 transform/z-order 合成               │
 mix.render_texture → output_video_data → mix.video ─┘
```

---

## 5. OBS vs 播放器（mpv）：根本架构差异

| 维度 | **OBS（合成器）** | **mpv / 一般播放器** |
|---|---|---|
| 角色 | 实时合成器/广播器：把 N 个源混成 1 路定 fps 成片 | 播放器：把 1 个文件解出 1 路画面+声音 |
| **主时钟** | **系统单调时钟 `os_gettime_ns()`**，video 线程按 `interval_ns` 固定步进 | **音频时钟（audio PTS）为主**，视频追音频 |
| 谁主导节拍 | **video 线程的固定 fps tick** 拉动一切 | 媒体的 **pts** 拉动一切（数据到了才推进） |
| 解码源 pts 的处理 | 不按 pts 调度：tick 用系统时钟步进 `last_frame_ts`，**过期帧直接丢、缺帧重复**（`ready_async_frame`，源跟不上≠拖慢全局） | 严格按 pts 排程渲染，**等到 pts 时刻才出帧**；音视频对齐到音频主钟 |
| 卡顿/落后 | `video_sleep` 一次补 `count` 帧、记 `lagged_frames`，**输出 CFR 不变** | 丢帧或音画不同步，但播放速度跟随媒体 |
| 音频 | audio 线程按固定时间窗口 `[start,end)` 主动拉所有源混音，源回退→动态加缓冲 | 音频驱动整体进度，视频被动跟随 |
| 时基方向 | **时钟 → 源**（系统时钟决定该取哪帧） | **源 → 时钟**（媒体 pts 决定何时出帧） |

一句话：**OBS 是「系统时钟主导、固定 fps、video 线程 tick 主动拉所有源」的推送式合成器；mpv 是「音频主时钟、按 pts 调度、数据驱动」的拉取式播放器。** 这决定了 OBS 永远输出稳定 CFR（适合录制/直播），代价是源跟不上就丢帧；而播放器优先保证媒体完整重放，代价是节奏随媒体波动。

---

## 6. OBS ↔ WorkLabs 模块对照建议

| OBS 结构 / 机制 | WorkLabs 对应 | 说明 / 建议 |
|---|---|---|
| `struct obs_core`（全局单例 + video/audio/data 三分） | **`WLStreamsManager`** | WL 的编排器即「轻量 obs_core」：持有源、画布、输出、音频渲染。OBS 把 video/audio/data 切成子结构，WL 可参考这种「编排器只持引用、状态下沉到子模块」的分层。 |
| `obs_core_video` + `obs_graphics_thread`（固定 fps tick） | **WL 目前缺失的「固定节拍 video 线程」** | WL 现在是源各自 push（`WLMediaSource` 自带 render 线程按 `baseTime+pts` 节流）。若要对齐 OBS 的稳定 CFR 录制，可引入一条 `os_gettime_ns`/`mach_absolute_time` 驱动的合成 tick 线程，由它统一拉各源最新帧。 |
| `obs_core_video_mix`（`render_texture` + `ovi` + `video`） | **`WLVideoMix` + `WLCanvasModel`** | `WLVideoMix` ≈ mix 的合成（Core Image/Metal 合成到 pooled CVPixelBuffer），`WLCanvasModel` ≈ `ovi`（画布尺寸/格式）+ 布局来源。OBS 把「画布配置」和「合成纹理」放在同一个 mix 里，WL 拆成了两个，关系清晰。 |
| `obs_view.channels[]` + `obs_scene` / `obs_scene_item`（pos/scale/crop/z-order 链表） | **`WLCanvasModel` 的 `streamOrder` + per-stream layout rects** | OBS 的 scene_item 链表顺序 = z-order，item 的 transform = WL 的 layout rect。WL 的 `streamOrder`（底→顶）正对应 `first_item` 链表序。`obs_sceneitem_crop` 对应 WL 计划中的 crop 滤镜。 |
| `obs_source`（统一输入/滤镜/转场/场景，async video 区） | **各 `Source`（`WLCameraSource` / `WLMediaSource`）** | OBS 用一个结构统一所有源类型 + `info` 回调表；WL 用 `WLSourceProtocol` + 多个类。OBS 的 `async_frames` 队列 + `timing_adjust`/`last_frame_ts` ≈ WL `WLMediaSource` 的帧队列 + `baseTime`。OBS 的「系统时钟推进 + 丢过期帧」逻辑（`ready_async_frame`）是 WL 改造 CFR 时的直接参考。 |
| `obs_core_audio` + `audio_thread` + `audio_callback`（时间窗口混音） | **`WLAudioRenderer`（现状）/ 规划中的 `WLAudioMixer`** | WL 当前是单路媒体音频直接回放（AudioQueue）。OBS 的「audio 线程按固定窗口主动拉所有源、对齐到窗口、动态缓冲」正是 WL 要做 **多轨混音** 时的目标架构：一条音频 tick 线程 + 每源环形缓冲 + 按窗口混音。 |
| `obs_output`（`video`/`audio` 指针 + encoder + `interleaved_packets` 交织 mux） | **`WLRecorder`** | OBS 把「编码器(`obs_encoder`)」与「输出/mux(`obs_output`)」拆两层并做 a/v 交织（`video_start_ts`/`audio_start_ts` 对齐）。WL 的 `WLRecorder` 目前是 video-only 单体；要加 AAC + a/v 同步 mux 时，可借鉴 OBS 的 `interleaved_packets` 交织 + start_ts 对齐策略（第 ④ 篇）。RTMP 推流对应 OBS 的 `obs_service`。 |
| `obs_context_data`（name/uuid 哈希 + 信号 + 引用计数基类） | WL 的 protocol/delegate 解耦 | OBS 用「公共基类 + cast」做统一对象管理；WL 用 ObjC 协议 + 弱引用 delegate 达到类似解耦。WL 若对象数量增长，可考虑统一的注册表（按 name/uuid 查找）。 |

**对 WorkLabs 最有借鉴价值的三点**：
1. **固定节拍 tick 线程**：把「源各自 push」改为「合成线程按系统时钟固定 fps 主动拉各源最新帧」，是获得稳定 CFR 录制、且让某个源卡顿不拖垮全局的关键（OBS `obs_graphics_thread` + `video_sleep` + `ready_async_frame`）。
2. **音频时间窗口混音**：做多轨音频时，用一条独立 audio tick 线程按固定窗口拉所有源混音 + 动态缓冲（OBS `audio_thread` + `audio_callback`），而非让某一路音频主导。
3. **video/audio 两条线程时基分离**：合成与音频各跑各的固定节拍、都以系统单调时钟为基准、互不阻塞，录制时在 output 层用 start_ts 做 a/v 对齐——这是 OBS 与播放器最本质的结构差异，也是 WL 从「播放器式 `WLMediaSource` 节流」走向「合成器式时基」时需要的范式转变。
