# OBS 目录导航 · libobs 内核（对象模型与流水线中枢）

> 源码范围：`libobs/`（顶层 61 个 `.c`/`.h`/`.m`/`.hpp` + 2 个 `.in` 模板）、`libobs/callback/`（8）、`libobs/audio-monitoring/`（14）、`libobs/data/`（21 个 `.effect`）、`libobs/cmake/`、`libobs/pkgconfig/` ｜ 基于 obs-studio commit `f2db097`（2026-07-09）
> 不含 `libobs/graphics/`、`libobs/util/`、`libobs/media-io/`（另有分篇）
> 返回总索引：[README.md](README.md)

## 本篇速查

想找什么 → 去哪：

| 我想看… | 去这里 |
|---|---|
| 渲染节拍主循环（tick → 合成 → 下载帧 → 分发） | [`obs-video.c`](#obs-videoc) |
| 异步源帧缓冲 / 虚拟时钟选帧 / 丢帧 | [`obs-source.c`](#obs-sourcec)（`ready_async_frame` :4087） |
| 全局初始化、`obs->` 单例、通道 0~63 输出源 | [`obs.c`](#obsc) |
| 音频混音 + 缓冲水位自适应（ts 对齐） | [`obs-audio.c`](#全局生命周期与主循环libobs-顶层) |
| 编码器共享、多输出扇出、编码组同步启动 | [`obs-encoder.c`](#obs-encoderc) |
| 交错打包（音视频 packet 排序后交给 muxer） | [`obs-output.c`](#obs-outputc) |
| 场景 / 场景项变换矩阵 / group / 裁剪 | `obs-scene.c`、`obs-scene.h` |
| 插件注册（`obs_source_info` 等四张表） | `obs-module.c` |
| 属性面板（UI 无关的属性描述树） | `obs-properties.c` |
| JSON 化设置存取（`obs_data_t`） | `obs-data.c` |
| 信号 / 过程调用总线（`signal_handler_t`） | [`callback/`](#信号回调总线libobscallback) |
| macOS 平台层（模块路径、系统信息日志、热键、autorelease pool） | `obs-cocoa.m`（见[平台适配](#平台适配libobs-顶层--cmake)） |
| macOS 音频监听（AudioQueue 播放 + 设备枚举） | [`audio-monitoring/osx/`](#音频监听libobsaudio-monitoring) |
| 内置 shader（格式转换 / 缩放 / 去隔行） | [`data/`](#内置-effectshader-数据libobsdata) |
| H.264/HEVC/AV1 码流头部解析（SPS/PPS、关键帧判定） | [`码流语法解析`](#码流语法解析libobs-顶层) |
| 音量推子 / 电平表（真峰值、IEC 刻度） | `obs-audio-controls.c` |

---

## 一句话职责

`libobs` 顶层这堆文件就是 OBS 的**内核对象模型 + 两条流水线中枢**：一个全局单例 `obs`（`struct obs_core`）持有所有 source/output/encoder/service/canvas，一条**图形线程**按固定节拍 tick 全部源、把它们合成到画布纹理再下载/交给编码器，一条**音频回调线程**把所有源的 PCM 按时间戳对齐混成 6 路 mix。

下层它依赖 `graphics/`（`gs_*` 图形抽象）、`media-io/`（`video_t`/`audio_t` 帧分发与格式转换）、`util/`（容器/线程/平台）；上层它被 `plugins/*`（注册 source/output/encoder/service）和 `frontend/`（Qt UI）调用。**插件永远只 include `obs-module.h` + `obs.h`，不 include `obs-internal.h`** —— 这条边界是整个架构的关键。

## 全局生命周期与主循环　`libobs/` 顶层

**职责**：`obs_startup()` 建起全局单例、拉起图形线程与音频线程，之后一切都挂在这个单例上。视频侧是"节拍驱动（tick-driven）"而非"事件驱动"：图形线程每 `1/fps` 醒一次，不管源有没有来新帧都跑完整一轮 tick+render，源自己负责用虚拟时钟决定"这一拍显示哪帧"。这是 OBS 和"播放器式各源独立节流"的根本分野。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs.c` ⭐ | 3483 | 全局单例 `obs` 的创建/销毁、图形+音频子系统初始化、内置 effect 加载、通道 0~63 的 `obs_set_output_source`、场景/源的存档与载入（`obs_save_source`/`obs_load_sources`）、全局信号表、task 队列 |
| `obs.h` | 2698 | libobs 的**唯一公开 API 门面**（约 2700 行声明 + doc 注释），插件和前端只认这个头 |
| `obs.hpp` | 345 | C++ RAII 包装：`OBSSource`/`OBSSourceAutoRelease`/`OBSWeakSource` 等模板别名，`OBSRef`/`OBSSafeRef`/`OBSRefAutoRelease` 三种引用语义 |
| `obs-internal.h` ⭐ | 1535 | **内部结构体全集**：`obs_core`（:544）、`obs_core_video`（:389）、`obs_core_video_mix`（:332）、`obs_core_audio`（:442）、`obs_core_data`（:467）、`obs_source`（:807）、`obs_output`（:1211）、`obs_encoder`（:1362）、`obs_canvas`（:721）。想搞懂任何字段先来这里 |
| `obs-video.c` ⭐ | 1203 | 图形线程主循环：`obs_graphics_thread`（:1161）、`tick_sources`（:32）、`output_frames`（:916）、`render_displays`（:94）、GPU→CPU 帧下载与色彩转换、CFR 节拍与掉帧计数 |
| `obs-audio.c` | 728 | 音频主回调 `audio_callback`（:555）：递归收集音频源树（`push_audio_tree` :30）、按 `min_ts` 对齐、`mix_audio`（:90）累加到 6 路 mix、缓冲水位不足时**自动加大 buffering**（`add_audio_buffering` :361）、丢弃停流源 |
| `obs-view.c` | 194 | `obs_view_t` = "一组 64 个输出通道 + 可选的独立 video mix"。主视图之外，投影/多画布用它开新的 mix（`obs_view_add2` :150、`obs_view_render` :118） |
| `obs-display.c` | 311 | `obs_display_t` = 一个可绘制窗口/swap chain：`render_display`（:237）在图形线程里被 `render_displays()` 调用，走 draw callback 列表让前端画预览 |
| `obs-canvas.c` | 592 | **2025 年新增的多画布（multi-canvas）层**：`obs_canvas_t` 包住 view + video mix + 一批归属该画布的源，带引用计数/弱引用/存档（`obs_save_canvas` :237）。主画布名字/uuid 固定（`obs_create_main_canvas` :188） |
| `obs-defs.h` | 53 | 常量与错误码：`MAX_CHANNELS 64`、`OBS_ALIGN_*`、`MODULE_*`、`OBS_OUTPUT_*`（含 `OBS_OUTPUT_DISCONNECTED`）、`OBS_VIDEO_*` |

### ⭐ 重点文件展开

#### `obs.c`
- **做什么**：libobs 的"main"。`obs_startup`（:1320）→ `obs_init`（:1223）建 `struct obs_core` 单例、注册全局信号表（`obs_signals` :1080）、`obs_init_graphics`（:479）创建图形子系统并**编译全部内置 effect**（:507~549 依次加载 `default.effect`、`opaque.effect`、`solid.effect`、`repeat.effect`、`format_conversion.effect` 及三种缩放 effect）、`obs_init_video`（:691）建 mix 并起图形线程、`obs_init_audio`（:903）起音频子系统。此外它管**通道模型**（`obs_set_output_source(channel, source)` :1834，channel 0~63，前端把"当前场景"放 channel 0）、源/场景的 JSON 存档载入（`obs_save_source` :2437、`obs_load_sources` :2397）、tick callback 注册（:3021）、以及图形线程 task 队列（:3268 起的 "task stuff"）。
- **关键入口**：`obs_startup`（:1320）、`obs_shutdown`（:1379）、`obs_reset_video`（:1525）、`obs_reset_audio2`（:1601）、`obs_set_output_source`（:1834）、`obs_render_main_texture`（:2222）、`obs_get_signal_handler`（:2160）
- **看点**：三点值得抄。① **单例 + 通道**：不搞"pipeline 对象"，而是全局 64 个通道插源，画布合成就是"按通道号从下往上渲染"，比自己维护 z-order 数组简单得多。② **重置视频的代价**：`obs_reset_video` 只有在没有活跃 output 时才允许（返回 `OBS_VIDEO_CURRENTLY_ACTIVE`），因为它要重建整套纹理和 mix —— 想做"运行时改画布分辨率"的人先读这段。③ **内置 effect 是全局共享的**，存在 `obs->video.*_effect` 字段里，源渲染时按需 `obs_load_effect` 懒加载（见 `obs-source-deinterlace.c:270`）。

#### `obs-video.c`
- **做什么**：整个 OBS 的心跳。`obs_graphics_thread`（:1161）设定 `interval = video_frame_interval_ns`，然后死循环调 `obs_graphics_thread_loop`（:1097）。每一拍严格按这个顺序：
  1. `update_active_states()`（:1076）—— 采样"这一帧有没有 raw/gpu 消费者"，决定要不要真的合成
  2. `gs_begin_frame()`
  3. **`tick_sources`（:32）** —— 先跑 tick callback，再把 `obs->data.sources` 链表快照进 `sources_to_tick`（**先加引用再放锁**），逐个 `obs_source_video_tick(s, seconds)`
  4. **`output_frames`（:916）→ `output_frame`（:868）** —— 每个 video mix 走一遍：`render_video`（:539）合成 → `download_frame`（:583）从 stage surface 读回 → `output_video_data`（:777）推给 `media-io` 的 `video_t`
  5. **`render_displays`（:94）** —— 遍历 `obs->data.first_display` 链表画预览窗口（在 `obs-display.c:237`）
  6. `execute_graphics_tasks()`（:957） —— 跑排队进来的"必须在图形线程执行"的任务
  7. `video_sleep`（:805） —— `os_sleepto_ns` 睡到下一拍
- **关键入口**：`obs_graphics_thread`（:1161）、`obs_graphics_thread_loop`（:1097）、`tick_sources`（:32）、`output_frame`（:868）、`output_frames`（:916）、`render_displays`（:94）、`render_video`（:539）、`render_main_texture`（:172）、`render_output_texture`（:270）、`render_convert_texture`（:344）、`stage_output_texture`（:407）、`queue_frame`（:442）、`download_frame`（:583）、`video_sleep`（:805）
- **看点**：这是复刻 tick 合成必须逐行读的文件。① **三段纹理链**：main texture（原色域合成）→ output texture（缩放/色域）→ convert textures（GPU 做 RGB→NV12/I444 等平面转换），最后 `stage_output_texture` 拷到 CPU 可读的 stage surface，`NUM_TEXTURES` 轮转做流水线，**下载的是"上一帧"的 stage surface**（`prev_texture`）以避开 GPU 同步等待。② **掉帧不是丢时间戳，而是给同一帧打 count**：`video_sleep`（:805）里若 `os_sleepto_ns` 返回 false（说明这一拍超时了），就算出跨了几个 interval，`vframe_info.count = count`、`lagged_frames += count - 1`，并把 `{timestamp, count}` 压进 `vframe_info_buffer`；下载出帧时 `output_video_data(video, &frame, vframe_info.count)` 把同一帧**重复投递 count 次**，从而保持严格 CFR。这个"时间戳由节拍产生、内容可以重复"的做法，是 OBS 时间轴永不漂移的根本。③ **省电路径**：`can_reuse_mix_texture`（:136）在多 mix 分辨率相同时直接复用纹理；`render_video` 在既无 raw 也无 gpu 消费者时只画不下载。④ **平台差异**：macOS 走 `obs_graphics_thread_loop_autorelease`（在 `obs-cocoa.m:190`，套一层 `@autoreleasepool`），Windows 在循环里顺手 `PeekMessage` 抽消息泵。

## 源对象体系　`libobs/` 顶层

**职责**：`obs_source_t` 是 OBS 唯一的"内容单元" —— 输入源、滤镜、转场、场景**全都是** source，只是 `obs_source_type` 和 flag 不同。这套统一抽象让滤镜链、场景嵌套、转场都变成"source 指向 source"，代价是 `obs-source.c` 长到 6005 行。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-source.c` ⭐ | 6005 | 源的创建/销毁/强弱引用、**异步帧缓冲与虚拟时钟选帧**、滤镜链渲染、音频提交与重采样/延迟补偿、显示/激活引用计数、audio monitoring 接线、纹理上传 |
| `obs-source.h` | 572 | `obs_source_info`（:222）注册结构体 + `obs_source_type`（:33）+ 全部 `OBS_SOURCE_*` 能力 flag（:88~215，如 `OBS_SOURCE_ASYNC_VIDEO`、`OBS_SOURCE_CUSTOM_DRAW`、`OBS_SOURCE_COMPOSITE`、`OBS_SOURCE_SRGB`、`OBS_SOURCE_REQUIRES_CANVAS`） |
| `obs-scene.c` ⭐ | 4143 | 场景实现（本身注册成一个 source）：场景项增删/排序、变换矩阵与 bounding box、裁剪 crop、group（组=嵌套场景）、`private_settings`、拖拽命中测试所需的几何计算 |
| `obs-scene.h` | 116 | `obs_scene_item`（:24）与 `obs_scene` 的内部定义（含 `item_render` texrender、`crop`、`pos/scale/rot/align`、`absolute_coordinates`） |
| `obs-source-transition.c` | 1072 | 转场：`obs_transition_start`（:327）、双 child source（A/B）的矩阵重算（`recalculate_transition_matrix` :105）、`obs_transition_tick`（:197）、手动转场（torque/manual time）、scale type 与对齐 |
| `obs-source-deinterlace.c` | 480 | 去隔行：自己一套 `ready_deinterlace_frames`（:20）双帧取帧逻辑、`deinterlace_render`（:315）、按 mode 懒加载对应 `deinterlace_*.effect`（`get_effect` :270）、2x 模式的场序处理 |

### ⭐ 重点文件展开

#### `obs-source.c`
- **做什么**：源的一切。生命周期（`obs_source_create_internal` :436 → `obs_source_create` :520 / `obs_source_create_private` :525 / `obs_source_create_canvas` :530，销毁 `obs_source_destroy` :709、`obs_source_release` :853）；**异步视频帧的生产-消费**（下面单独说）；渲染（`obs_source_video_render` :2948 → 若有滤镜走 `obs_source_render_filters` :2666，否则 `render_video` :2906 → `obs_source_default_render` :2846）；滤镜链维护（`obs_source_filter_add` :3076，链表受 `filter_mutex` 保护）；滤镜实现辅助（`obs_source_process_filter_begin` :4345 / `..._end` :4467）；音频提交（`obs_source_output_audio` :4029 → `source_output_audio_data` :1572）与混音期渲染（`obs_source_audio_render` :5455）。
- **关键入口（异步帧这一串，复刻重点）**：
  - `obs_source_output_video`（:3595）/ `obs_source_output_video2`（:3610）→ `obs_source_output_video_internal`（:3563）
  - `cache_video`（:3505）—— 从 `async_cache` 里找可复用的 frame 槽，**超过 `MAX_ASYNC_FRAMES 30`（:3503）就整池清空**（`free_async_cache` :3475）
  - 帧压入 `source->async_frames`（:3588，DARRAY 当 FIFO）
  - 消费端：`obs_source_video_tick`（:1357）→ `async_tick`（:1328）→ `get_closest_frame`（:4175）→ **`ready_async_frame`（:4087）**
  - `obs_source_get_frame`（:4199）/ `obs_source_release_frame`（:4220）—— 对外借帧，原子引用计数
  - 互斥量：`async_mutex`（初始化在 :223/:240，**递归锁**）保护 `async_frames` + `async_cache` + `cur_async_frame`
  - 纹理侧：`set_async_texture_size`（:2106）、`obs_source_update_async_video`（:2514）
- **看点**：
  ① **虚拟时钟选帧**（`ready_async_frame` :4087）是全文件精华。它维护 `source->last_frame_ts`，每拍按**系统时间增量** `sys_offset` 推进它（:4124），然后 `while (last_frame_ts > next_frame->timestamp)` 往前吃帧；`< 2000000`（2ms）时提前 break 以**避免无意义的重复帧**（:4133）。unbuffered 模式（:4095）直接把队列砍到只剩最新一帧 —— 低延迟摄像头走这条。时间戳跳变由 `frame_out_of_bounds` / `MAX_TS_VAR` 兜底重锚。
  ② **帧池而非每帧 malloc**：`async_cache` 是"按尺寸/格式复用的帧槽池"，`refs` 原子计数，`remove_async_frame` 只在 refs 归零时才真销毁 —— 所以 `obs_source_release_frame` 必须传回原 source。
  ③ **锁的粒度**：`async_mutex` 和 `filter_mutex` 都是**递归锁**，因为滤镜链渲染会重入同一源；`tick_sources` 快照源链表时先 `obs_source_get_ref` 再放锁，避免 tick 期间源被销毁。
  ④ **滤镜是 source**：`obs_source_process_filter_begin/end` 让滤镜插件不用管 texrender 生命周期，`allow_direct` 打开时能省一次离屏渲染。

## 输出侧　`libobs/` 顶层

**职责**：编码器从 `video_t`/`audio_t` 拿裸帧、编成 `encoder_packet`；output 把多路 packet **交错排序（interleave）**后交给具体 muxer/推流实现。核心设计是**编码一次、扇出多个 output**（录制 + 推流共享同一 encoder），以及**可选的延迟推流缓冲**。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-output.c` ⭐ | 3340 | output 生命周期、`obs_output_start/stop`、raw 与 encoded 两条接入路径、**音视频 packet 交错排序**、暂停（pause）、断线重连、多轨（最多 6 音轨 / 10 视频轨）、service 绑定 |
| `obs-output.h` | 96 | `obs_output_info`（:41）+ `OBS_OUTPUT_*` flag（`VIDEO`/`AUDIO`/`ENCODED`/`SERVICE`/`MULTI_TRACK`/`CAN_PAUSE`）+ `MAX_OUTPUT_AUDIO_ENCODERS 6`、`MAX_OUTPUT_VIDEO_ENCODERS 10` |
| `obs-output-delay.c` | 209 | 延迟推流：packet 进 `delay_data` 队列（`push_packet` :46），到点才 `pop_packet`（:96）放行；`process_delay`（:132）是挂在 encoder 上的回调；支持"断流时保留缓冲"（`obs_output_delay_start` :141） |
| `obs-encoder.c` ⭐ | 2286 | encoder 生命周期、与 `video_t`/`audio_t` 的连接管理（`add_connection` :369 / `remove_connection` :413）、`do_encode`（:1456）、多 output 共享同一 encoder 的 packet 扇出（`send_packet` :1360）、音频缓冲对齐视频起点（`buffer_audio` :1690）、**encoder group**（多档同步启动） |
| `obs-encoder.h` | 365 | `obs_encoder_info`（:198）、`encoder_packet`（:100）、`encoder_frame`（:147）、`encoder_packet_time`（:65）、`obs_encoder_type`（:44） |
| `obs-video-gpu-encode.c` | 312 | GPU 直编路径：`gpu_encode_thread`（:24）拿共享纹理句柄直接喂编码器（Win 上 NVENC/AMF 免 GPU→CPU 回读）；`init_gpu_encoding`（:231）/ `free_gpu_encoding`（:287） |
| `obs-service.c` | 466 | service = "推流目标配置"（URL/key/协议/推荐码率）：创建销毁、`obs_service_initialize`（:271）把配置灌进 output、`obs_service_apply_encoder_settings`（:283）让平台强制码率上限 |
| `obs-service.h` | 115 | `obs_service_info`（:47）+ `obs_service_resolution`（:31） |

### ⭐ 重点文件展开

#### `obs-output.c`
- **做什么**：output 是"帧/包的终点"。两条接入路径：**raw** 路径（`default_raw_video_callback` :2328、`default_raw_audio_callback` :2381）直接把裸帧丢给插件（如 `obs-ffmpeg` 的 nvenc 之外的纯录制、虚拟摄像头）；**encoded** 路径（`default_encoded_callback` :2309）走 `interleave_packets`（:2222）先排序再发。启动流程：`obs_output_start`（:396）→ `can_begin_data_capture`（:1353）→ `obs_output_initialize_encoders`（:2638）→ `obs_output_begin_data_capture`（:2758）→ `hook_data_capture`（:2488）挂回调；停止走 `obs_output_stop`（:530）/ `obs_output_end_data_capture`（:2926）。此外管暂停（`obs_output_pause` :826，带 `pause_data` 时间戳补偿）和重连（`reconnect_thread` :2931、`output_reconnect` :2949、指数退避）。
- **关键入口**：`obs_output_create`（:196）、`obs_output_start`（:396）、`obs_output_stop`（:530）、`obs_output_pause`（:826）、`interleave_packets`（:2222）、`initialize_interleaved_packets`（:1998）、`get_interleaved_start_idx`（:1776）、`prune_interleaved_packets`（:1902）、`insert_interleaved_packet`（:2073）、`send_interleaved`（:1681）、`apply_interleaved_packet_offset`（:1442）、`obs_output_begin_data_capture`（:2758）
- **看点**：**interleave 这一套是 muxer 前必做的功课**。视频和音频编码器各自独立跑、起点不一致、延迟不同，直接喂 muxer 会时间戳倒退。OBS 的做法是：所有 packet 先插进一个按 dts 排序的数组（`insert_interleaved_packet` :2073），用 `initialize_interleaved_packets`（:1998）找到"音视频都齐了"的公共起点，`get_interleaved_start_idx`（:1776）定位第一个视频关键帧，`prune_interleaved_packets`（:1902）扔掉起点之前的碎包，`apply_interleaved_packet_offset`（:1442）把全部时间戳减去这个 epoch 归零，最后 `send_interleaved`（:1681）才往 muxer 送。**"延迟写 header 直到第一个关键帧" + "第一个视频关键帧作为共同零点"就是从这里来的**。另一个看点：`preserve_active`（:2483）区分"停止但保留 encoder"的场景，支持录制中途开推流。

#### `obs-encoder.c`
- **做什么**：把 encoder 做成**可被多个 output 共享的广播源**。`obs_encoder_initialize`（:727）真正调插件 `create`；`obs_encoder_start`（:836）内部走 `obs_encoder_start_internal`（:809）把 `{callback, param}` 加进 `encoder->callbacks` 数组 —— 第一个 start 时 `add_connection`（:369）向 `video_t`/`audio_t` 注册 `receive_video`（:1586）/`receive_audio`（:1837）；最后一个 stop 时 `remove_connection`（:413）摘掉。编码在 `do_encode`（:1456）里，出包后 `send_packet`（:1360）**逐个 callback 发一份**，每个 output 拿到的是独立可持有的 packet 实例。音频侧 `buffer_audio`（:1690）把 PCM 攒到 `start_from_buffer`（:1669）指定的视频起点才开始编，保证音视频从同一时刻起。
- **关键入口**：`obs_video_encoder_create`（:160）、`obs_encoder_initialize`（:727）、`obs_encoder_shutdown`（:766）、`obs_encoder_start`（:836）、`obs_encoder_stop`（:848）、`do_encode`（:1456）、`send_packet`（:1360）、`receive_video`（:1586）、`receive_audio`（:1837）、`buffer_audio`（:1690）、`obs_encoder_add_output`（:1868）
- **看点**：① **共享编码器的引用模型**：encoder 不知道谁在用它，只维护 callback 数组；"录制 + 推流只编一次"和"推流断了录制继续"就是这个数组增删的自然结果 —— 复刻时照抄这个结构比自己发明 fan-out 更省事。② **encoder group**（`obs_encoder_group`，`obs-internal.h:1342`）：多档同时推流时必须**同一帧起编**，group 会等 `num_encoders_started >= encoders.num` 才 `add_ready_encoder_group`（:406），真正的 `start_timestamp` 由图形线程在 `video_sleep`（`obs-video.c:826~846`）里统一写入 —— 起点由节拍决定，不由哪个编码器先就绪决定。③ **运行时重配**：`encoder_group_new_reconfigure_request`（:1539）+ `handle_encoder_group_reconfigure_request`（:1547）支持不断流改参数。

## 码流语法解析　`libobs/` 顶层

**职责**：muxer 和推流需要知道"这包是不是关键帧、SPS/PPS 在哪、要不要给 FLV 写 extradata"，但 libobs 不想为此依赖 FFmpeg 的 bitstream filter，于是自己手写了最小限度的 NAL/OBU 解析。**只解析到判定关键帧和提取参数集的程度**，不做完整语法树。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-nal.c` | 66 | NAL 起始码扫描（`{0,0,1}`），代码直接搬 FFmpeg 的实现（见文件头 :19 注释说明原因） |
| `obs-nal.h` | 37 | 同名实现的声明 |
| `obs-avc.c` | 321 | H.264：关键帧判定、SPS/PPS 提取、AnnexB↔AVCC 长度前缀互转、给 FLV 拼 `AVCDecoderConfigurationRecord` |
| `obs-avc.h` | 55 | 同名实现的声明 |
| `obs-hevc.c` | 202 | H.265 同上（多 VPS，`HEVCDecoderConfigurationRecord`） |
| `obs-hevc.h` | 81 | 同名实现的声明 + HEVC NAL 类型枚举 |
| `obs-av1.c` | 208 | AV1：OBU 遍历 + `leb128`（:9）变长整数解码 + sequence header 提取 |
| `obs-av1.h` | 47 | 同名实现的声明 |

## 插件与属性系统　`libobs/` 顶层

**职责**：三件事各自独立但常一起出现 —— ① 动态库加载 + 四张注册表（source/output/encoder/service）；② `obs_data_t`：一个 JSON 语义的属性字典，**带 default 层**，所有设置的存取都走它；③ `obs_properties_t`：一棵**与 UI 框架完全解耦**的属性描述树，前端（Qt）读它自动生成表单。这三层加起来就是 OBS 的插件契约。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-module.c` | 1195 | 模块加载：`obs_open_module`（:140）dlopen + 校验导出符号与 `LIBOBS_API_VER`、`obs_init_module`（:233）调 `obs_module_load`、模块搜索路径（`obs_add_module_path` :406）、`obs_load_all_modules2`（:578）、**四张注册表** `obs_register_source_s`（:956）/`_output_s`（:1061）/`_encoder_s`（:1126）/`_service_s`（:1168） |
| `obs-module.h` | 187 | 插件侧契约：`OBS_DECLARE_MODULE()`（:76）宏、必须导出的 `obs_module_load`（:101）/`obs_module_unload`（:104）/`obs_module_post_load`（:107）/`obs_module_set_locale`（:110）、本地化查表 `obs_module_get_string`（:145） |
| `obs-data.c` | 2181 | `obs_data_t` 实现：类型化 get/set、**default 与 autoselect 双影子值**、JSON 互转（`obs_data_create_from_json` :606、`obs_data_save_json_pretty_safe` :769 带临时文件+备份的原子写）、`obs_data_apply`（:1001）合并、数组、`vec2/3/4`/`quat`/`media_frames_per_second` 便捷存取 |
| `obs-data.h` | 314 | 同名实现的声明 |
| `obs-properties.c` | 1415 | 属性树：`obs_properties_create`（:207）、各类控件 `obs_properties_add_bool/int/float/text/path/list/color/button/font/editable_list/frame_rate/group`（:507~732）、`obs_property_set_modified_callback`（:792，改一项联动刷新别的项）、`obs_property_next`（:783）遍历 |
| `obs-properties.h` | 364 | 同名实现的声明 + `obs_property_type` 枚举 |
| `obs-missing-files.c` | 142 | "文件丢了"报告器：载入场景时源发现引用的文件不存在，就往 `obs_missing_files_t` 里塞一条，前端弹窗让用户重指路径，回调 `obs_missing_file_issue_callback`（:123）写回 |
| `obs-missing-files.h` | 53 | 同名实现的声明 |

## 音频控制　`libobs/` 顶层

**职责**：把"音量"这件事从 dB / 推子刻度 / 线性乘数三种表示之间来回换算，以及算电平表要的峰值。**不参与混音**（混音在 `obs-audio.c`），它只是挂在源信号上的观察者 + UI 数值转换层。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-audio-controls.c` | 878 | `obs_fader_t`（三种刻度：cubic :81、IEC :101、log :166 各自 def↔dB 互换）+ `obs_volmeter_t`（`get_true_peak` :320 用 SSE 做 4 倍过采样真峰值、`get_sample_peak` :366、`volmeter_process_magnitude` :462 算 RMS）；靠订阅源的 `volume`/`destroy` 信号与 `audio_data` 回调工作（:208~257、:492） |
| `obs-audio-controls.h` | 250 | 同名实现的声明 + `obs_fader_type` 枚举 |

## 热键与交互　`libobs/` 顶层

**职责**：一套**与窗口系统解耦的全局热键**框架。核心在跨平台的 `obs-hotkey.c`，各平台只需实现 4 个函数（`obs_hotkeys_platform_init/free/is_pressed` + 键码互转），键位表用 X-macro 一处定义、三处展开。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-hotkey.c` | 1397 | 热键注册（按宿主分五种：`_register_frontend`（:189）/`_encoder`（:201）/`_output`（:215）/`_service`（:229）/`_source`（:243））、组合键绑定与存档（`obs_hotkey_load` :522）、轮询线程与前后台按键判定、`obs_hotkey_inject_event`（:1096）让 UI 注入按键、pair 型热键（按一次开、按一次关） |
| `obs-hotkey.h` | 271 | 同名实现的声明 + `obs_key_combination_t` / `obs_hotkey_id` |
| `obs-hotkeys.h` | 653 | **纯 X-macro 键位表**：`OBS_HOTKEY(OBS_KEY_XXX)` 逐个列出所有按键（:17 起），被 enum 定义、名字映射、平台键码表三处 `#include` 展开 |
| `obs-hotkey-name-map.c` | 134 | 键名↔`obs_key_t` 的哈希表（`obs_key_to_name` :76、`obs_key_from_name` :106），配置文件里存的是名字不是键码 |
| `obs-interaction.h` | 56 | 纯定义：`obs_interaction_flags`（:22 修饰键与鼠标按钮位）、`obs_mouse_event`（:45）、`obs_key_event`（:51）—— 供浏览器源/游戏捕获这类"可交互源"接收鼠标键盘 |

## 信号 / 回调总线　`libobs/callback/`

**职责**：OBS 的**弱耦合事件系统**。所有"源被创建了""音量变了""推流断了"都是通过字符串声明的信号广播出去，接收方不需要头文件依赖。设计成三层：`calldata`（类型化参数包）→ `decl`（把 `"void source_volume(ptr source, in out float volume)"` 这种声明串解析成参数表）→ `signal`/`proc`（广播 / 单点调用）。前端和插件几乎全靠它互通。

| 文件 | 行数 | 功能 |
|---|---|---|
| `calldata.c` | 238 | 参数包实现：按名字存取 int/float/bool/ptr/string 的扁平缓冲区 |
| `calldata.h` | 195 | `calldata_t` 结构 + `call_param_type`（:34）+ `CALL_PARAM_IN/OUT`（:44）+ 一堆 `calldata_get_*`/`set_*` inline |
| `decl.c` | 231 | 声明串解析器：把 `"void func(int a, string b)"` 词法分析成 `decl_info` 参数表 |
| `decl.h` | 61 | `decl_param`（:10）/ `decl_info`（:24）定义 |
| `signal.c` | 391 | `signal_handler_t`：按名字注册信号、connect/disconnect 回调、`signal_handler_signal` 广播；另有**全局回调**（`global_signal_callback_t`）能监听该 handler 上的所有信号 |
| `signal.h` | 73 | 同名实现的声明（`signal_handler_add_array` :45 批量注册在此，`obs.c:1080` 的 `obs_signals[]` 就喂给它） |
| `proc.c` | 128 | `proc_handler_t`：按名字注册可调用过程，`proc_handler_call` 找不到就返回 false —— 相当于运行时的"可选接口" |
| `proc.h` | 52 | 同名实现的声明 |

> 复刻提示：这一小目录只有 1369 行，却是 OBS 解耦的关键。想让"源属性变化 → UI 刷新"不产生编译期依赖，抄 `signal.c` + `calldata.c` 两个文件就够了；`decl.c` 只是为了让信号声明可以写成人类可读的字符串，不想要可以用结构体常量替代。

## 音频监听　`libobs/audio-monitoring/`

**职责**：把某个源的音频**播放到本机扬声器**（OBS 里的 "Monitor" / "Monitor and Output"）。这是纯平台功能，四个后端各自实现同一组内部函数（`audio_monitor_create/reset/destroy`、`obs_enum_audio_monitoring_devices`、`obs_audio_monitoring_available`、`devices_match`），由 CMake 按平台选一个编进去（`libobs/cmake/os-macos.cmake:16~19` 选 osx）。

### `osx/` —— macOS 后端（读者主战场，逐文件写清）

| 文件 | 行数 | 功能 |
|---|---|---|
| `coreaudio-output.c` | 322 | **核心**。`struct audio_monitor`（:15）= `AudioQueueRef` + 3 个 `AudioQueueBufferRef` + `audio_resampler_t` + 两个 `deque`（空 buffer 池 / 待播数据）。`audio_monitor_init`（:145）建队列、`on_audio_playback`（:64）作为源音频回调把 PCM 重采样后入队、`buffer_audio`（:122）是 AudioQueue 的回调、`fill_buffer`（:33）攒够 `buffer_size` 才提交；`on_audio_pause`（:55）响应媒体源暂停清空缓冲 |
| `coreaudio-enum-devices.c` | 226 | 设备枚举：`obs_enum_audio_monitoring_devices`（:93）遍历 CoreAudio 设备（`enum_audio_devices` :65，默认不含输入设备）、`get_default_id`（:107）取系统默认输出、`devices_match`（:143）比较设备 id（含 "default" 的特殊处理）、`get_desktop_default_id`（:200）找 loopback |
| `coreaudio-monitoring-available.c` | 6 | 只有一行 `return true` —— macOS 恒支持监听 |
| `mac-helpers.h` | 13 | 一个 `success(stat, call)` 宏：`OSStatus != noErr` 时自动 `blog(LOG_WARNING, ...)` 带函数名，把 CoreAudio 的样板错误检查压成一行 |

> 注意：macOS 用的是 **AudioQueue**（`AudioToolbox`）而不是 AudioUnit 渲染回调，虽然文件顶部也 include 了 `AudioUnit.h`。这跟 WorkLabs 现在的 `WLAudioRenderer` 是同一路子 —— 可以直接对照 `coreaudio-output.c:33~143` 看 OBS 怎么处理"缓冲不够就不提交"和暂停清缓冲。

### 其余平台后端

| 文件 | 行数 | 功能 |
|---|---|---|
| `win32/wasapi-output.c` / `wasapi-output.h` | 463 / 22 | WASAPI 渲染客户端实现监听 |
| `win32/wasapi-enum-devices.c` | 174 | WASAPI 设备枚举 |
| `win32/wasapi-monitoring-available.c` | 6 | Win 上按系统版本判定是否可用 |
| `pulse/pulseaudio-output.c` | 528 | PulseAudio stream 播放 |
| `pulse/pulseaudio-wrapper.c` / `.h` | 389 / 212 | PulseAudio 主循环/上下文封装（Linux 各处共用） |
| `pulse/pulseaudio-enum-devices.c` | 31 | sink 枚举 |
| `pulse/pulseaudio-monitoring-available.c` | 6 | 恒 true |
| `null/null-audio-monitoring.c` | 35 | **空实现兜底**：`available` 返回 false，`audio_monitor_create` 返回 NULL。想看"这套接口最小面"是什么，读这 35 行最快 |

## 平台适配　`libobs/` 顶层 + `cmake/`

**职责**：libobs 的平台层只负责三件小事 —— ① 模块搜索路径与动态库后缀；② 启动时打印系统信息（CPU/内存/OS 版本，崩溃报告要用）；③ 全局热键的平台实现。**图形/音频/线程的平台差异不在这里**（在 `graphics/` 和 `util/`）。

> **关于 macOS**：任务描述里说"macOS 平台层不在 libobs 顶层" —— 实测**不成立**。macOS 平台层就是 `libobs/obs-cocoa.m`（844 行），和 `obs-windows.c`、`obs-nix.c` 平级，由 `libobs/cmake/os-macos.cmake:20` 编入并在 :31 单独加 `-fobjc-arc`。相关 macOS 文件的完整清单是：`libobs/obs-cocoa.m`、`libobs/audio-monitoring/osx/*`（4 个，见上节）、`libobs/cmake/os-macos.cmake`、`libobs/cmake/macos/entitlements.plist`，以及**不在本篇范围**的 `libobs/util/platform-cocoa.m` 与 `libobs/graphics/` 下的 Metal/OpenGL 后端。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-cocoa.m` ⭐（macOS 唯一平台层） | 844 | ① 模块路径：`get_module_extension`（:33，macOS 返回空串——插件是 `.plugin` bundle 不是裸动态库）、`add_default_module_paths`（:38，从 `[NSBundle mainBundle].builtInPlugInsURL` 拼出 `%module%.plugin/Contents/MacOS/` 与 `.../Resources/`）、`find_libobs_data_file`（:47，走 bundle resource）；② 系统信息日志：`log_system_info`（:152）汇总 CPU 名/频率/机型/核数/**Rosetta 仿真状态**（`log_emulation_status` :117）/可用内存/OS 与内核版本；③ **`obs_graphics_thread_autorelease`（:183）与 `obs_graphics_thread_loop_autorelease`（:190）—— 给图形线程每一拍套 `@autoreleasepool`**，被 `obs-video.c:1191` 在 `__APPLE__` 下调用；④ 全局热键：`CGEventTap`（`KeyboardEventProc` :519）+ `TISInputSource` 键盘布局监听（`InputMethodChangedProc` :555）+ `obs_hotkeys_platform_init`（:587，需要辅助功能权限）+ `obs_key_to_virtual_key`（:666）/`obs_key_from_virtual_key`（:675）/`obs_hotkeys_platform_is_pressed`（:686）+ 本地化键名（`obs_key_to_localized_string` :468） |
| `obs-windows.c` | 1245 | Windows 平台层：模块路径、超详细的系统信息日志（Windows 版本 :146、管理员状态 :163、**游戏模式/GPU 调度** :185、**杀毒软件枚举** :310、Lenovo Vantage 冲突检测 :121）、`get_virtual_key`（:371）大表 + 热键平台实现（:970~1096） |
| `obs-win-crash-handler.c` | 534 | Windows 崩溃处理：运行时 dlopen `dbghelp.dll`（:118）、走栈（`walk_stack` :294）、写带符号名的崩溃文本报告 + minidump。**Windows 专属，其他平台无对应物** |
| `obs-nix.c` | 499 | Linux/FreeBSD 平台层入口：模块路径、系统信息（CPU :131、内存 :253、内核 :277、发行版 :287、**Flatpak 扩展** :345、桌面会话 :386）、热键调度转发到 x11/wayland 后端（:422~482） |
| `obs-nix.h` | 42 | 同名实现的声明 |
| `obs-nix-x11.c` / `.h` | 1280 / 22 | X11 后端：xcb 键盘映射（`fill_keycodes` :734）、keysym↔`obs_key_t`（`get_keysym` :108）、`obs_nix_x11_log_info`（:34） |
| `obs-nix-wayland.c` / `.h` | 1630 / 24 | Wayland 后端：`wl_keyboard` + xkbcommon keymap（`load_keymap_data` :48、`rebuild_keymap_data` :69），比 X11 更长因为要自己跟 seat/keyboard 协议 |
| `obs-nix-platform.c` / `.h` | 45 / 53 | 极小的运行时开关：`obs_set_nix_platform`/`obs_get_nix_platform`（X11-EGL / X11-GLX / Wayland）+ 平台 display 指针存取，供 `graphics/` 取用 |
| `obs-config.h` | 52 | **API 版本号**：`LIBOBS_API_MAJOR_VER 32` / `MINOR 2` / `PATCH 0`（:30~44）+ `LIBOBS_API_VER` 打包宏 —— 模块加载时版本不匹配就拒载 |
| `obsversion.h` | 5 | 三个 extern 字符串：`OBS_VERSION`、`OBS_VERSION_CANONICAL`、`OBS_COMMIT` |
| `obsversion.c.in` | 5 | 上面三个字符串的 CMake 模板（构建时填 git 信息） |
| `obsconfig.h.in` | 13 | 构建期配置模板（安装前缀、数据/插件目录、可选功能开关） |
| `obs-ffmpeg-compat.h` | 13 | 一个 `LIBAVCODEC_VERSION_CHECK(a,b,c,d,e)` 宏，同时兼容 libav 与 FFmpeg 两套版本号规则 |

## 内置 effect（shader）数据　`libobs/data/`

**职责**：libobs 自己渲染流程要用的 HLSL-风格 `.effect` 文件（OBS 自研 effect 语法，由 `graphics/effect-parser.c` 解析后转译到 GLSL/HLSL/MSL）。安装后放在数据目录，运行时用 `obs_find_data_file()` 按文件名找。**这里没有本地化数据** —— `libobs/data/` 下只有 21 个 `.effect`，没有 `locale/` 子目录；libobs 自身的字符串本地化走 `obs_module_get_string`，locale 文件在各插件的 `data/locale/` 和前端目录里。

| 文件 | 行数 | 功能 |
|---|---|---|
| `format_conversion.effect` ⭐ | 1823 | 最大的一个：RGB↔NV12/I420/I444/P010/UYVY… 各种平面/打包格式互转 + BT.601/709/2020 色彩矩阵 + 有限/全范围。GPU 做格式转换全靠它（`obs-video.c:344 render_convert_texture` 用） |
| `default.effect` | 271 | 通用绘制：`Draw`/`DrawSrgbDecompress`/`DrawAlphaDivide`… 多个 technique，源默认渲染路径（`obs.c:507` 加载）；`default_rect.effect`（84）是 `GL_TEXTURE_RECTANGLE` 变体 |
| `color.effect` | 172 | **不是 technique，是被 `#include` 的公共 shader 头**：sRGB↔线性、色彩空间/矩阵辅助函数。被 `default.effect`、`format_conversion.effect`、`lanczos_scale.effect`、`deinterlace_base.effect` 以及多个插件 effect 引用 |
| `bicubic_scale.effect` | 236 | 双立方缩放（`obs.c:533`） |
| `lanczos_scale.effect` | 292 | Lanczos 缩放（`obs.c:537`） |
| `area.effect` | 250 | 面积平均缩放，降采样质量最好（`obs.c:541`） |
| `bilinear_lowres_scale.effect` | 123 | 低分辨率双线性缩放（`obs.c:545`） |
| `deinterlace_base.effect` | 325 | 去隔行公共实现（被下面 8 个 `#include`），含 yadif 等算法主体 |
| `deinterlace_{discard,blend,linear,yadif}{,_2x}.effect` | 各 21 | 8 个 21 行的薄壳：`#include "deinterlace_base.effect"` + 选一个 technique。由 `obs-source-deinterlace.c:270` 按 mode 懒加载 |
| `opaque.effect` | 159 | 强制 alpha=1 绘制（`obs.c:517`） |
| `solid.effect` | 80 | 纯色填充，画背景/边框用（`obs.c:521`） |
| `repeat.effect` | 36 | 平铺重复采样（`obs.c:525`） |
| `premultiplied_alpha.effect` | 38 | 预乘 alpha 还原（`obs.c:549`） |

## 构建脚本　`libobs/cmake/`、`libobs/pkgconfig/`

`libobs/CMakeLists.txt`（8301 字节）列出全部源文件与公开头，按平台 `include()` 对应的 `cmake/os-{macos,windows,linux,freebsd}.cmake` 追加平台专属源（macOS 那份就是加 `obs-cocoa.m` + `audio-monitoring/osx/*` 并给 ObjC 文件开 `-fobjc-arc`）；`cmake/obs-version.cmake` 从 git 生成 `obsversion.c`；`cmake/libobsConfig.cmake.in` 供下游 `find_package(libobs)`；`cmake/macos/entitlements.plist` 是 macOS 签名权限（热键要辅助功能、采集要屏幕录制）；`cmake/windows/obs-module.rc.in` 给插件 DLL 生成版本资源；`cmake/linux/libobs.pc.in` 与 `pkgconfig/libobs.pc.in` 是 pkg-config 描述。**这些都不含业务逻辑，只在"我加了个新文件为什么没编进去"时来看。**

---

## 阅读建议

1. **先读 `obs-internal.h`，但只读结构体定义**（`obs_core` :544 → `obs_core_video` :389 → `obs_core_video_mix` :332 → `obs_source` :807 → `obs_output` :1211 → `obs_encoder` :1362）。不理解这几个结构体的字段布局，读任何 `.c` 都是雾里看花。这一步值得花一小时。
2. **然后一口气读完 `obs-video.c`（1203 行，全读）**。它短、完整、没有分支迷宫，读完你就掌握了 OBS 的节拍模型：`obs_graphics_thread_loop`（:1097）是入口，`video_sleep`（:805）里的 `vframe_info.count` 是理解"掉帧不漂移"的钥匙。这是本篇性价比最高的一个文件。
3. **`obs-source.c` 不要顺读，按主题跳**。复刻异步源就只读三段：`cache_video`（:3505）+ `obs_source_output_video_internal`（:3563）是生产端；`async_tick`（:1328）+ `get_closest_frame`（:4175）+ `ready_async_frame`（:4087）是消费端；`obs_source_get_frame`（:4199）/`release_frame`（:4220）是对外借还。滤镜链和 audio 部分等真要做时再回来。
4. **输出侧先读 `obs-encoder.c` 的 `add_connection`（:369）/`send_packet`（:1360），再读 `obs-output.c` 的 interleave 六件套**（:1442、:1681、:1776、:1902、:1998、:2073）。这两块合起来回答"编一次怎么喂两个 muxer"和"packet 怎么排序才不让 muxer 报时间戳倒退"，正好对应 WorkLabs 的 `WLEncoder` + `WLRecorder`/`WLPusher`。
5. **`callback/` 全目录只 1369 行，建议整个读完**，尤其 `signal.c`。这是让"源变化 → UI 刷新"不产生编译期依赖的最小方案，直接能搬。
6. **可以直接跳过的**：`obs-scene.c`（4143 行，除非要做场景嵌套/group）、`obs-data.c`/`obs-properties.c`（是 UI 与配置的基础设施，用法看 `obs.h` 声明就够，不必读实现）、`obs-hotkey*`（做单机工具用不上全局热键框架）、`obs-windows.c`/`obs-win-crash-handler.c`/`obs-nix*`（非 macOS 平台）、`obs-avc/hevc/av1/nal`（等真的自己写 FLV muxer 时再来查）、`obs-source-transition.c` 与 `obs-source-deinterlace.c`（功能性特性，不影响架构理解）。
7. **macOS 开发者的必看清单**：`obs-cocoa.m:183~190`（autorelease pool 怎么套进图形线程主循环）和 `audio-monitoring/osx/coreaudio-output.c`（AudioQueue 播放的完整最小实现，322 行）。
