# OBS 目录导航 · shared / deps / 构建 / 测试 / 官方文档

> 源码范围：`shared/`（14 个子目录，120 个文件，其中 `.c/.h/.cpp/.hpp/.i/.in` 共 93 个）、`deps/`（6 个 vendored 库，533 个文件——其中 481 个属于 `w32-pthreads` 与 `libdshowcapture` 两个 Windows-only 大库）、`test/`（21 个）、`cmake/`（74 个）、`build-aux/`、`docs/`（54 个）、顶层杂项 ｜ 基于 obs-studio commit `f2db097`（2026-07-09）
> 返回总索引：[README.md](README.md)

## 本篇速查

想找什么 → 去哪：

| 我想看… | 去这里 |
|---|---|
| **媒体文件播放内核**（拆包/解码/节流/输出 一条线程搞定） | [`shared/media-playback/media-playback/media.c`](#mediac) |
| **pts 节流**：怎么用绝对基准睡到下一帧 | `media.c:598`（`mp_media_sleep`）+ `media.c:498`（`mp_media_calc_next_ns`） |
| **seek**：`av_seek_frame` + 解码器 flush + 丢旧帧 | `media.c:520`（`seek_to`）+ `decode.c:413`（`mp_decode_flush`） |
| **loop / EOF**：时间线怎么摊平、baseTime 要不要重锚 | `media.c:619`（`mp_media_eof`）→ `media.c:551`（`mp_media_reset`，`base_ts += next_ts` 在 :563） |
| **输出时间戳公式**（源侧 pts → OBS 系统时间轴） | `media.c:366`（音频）、`media.c:453`（视频） |
| 解码器封装、硬件加速优先级（含 VideoToolbox） | [`shared/media-playback/media-playback/decode.c`](#decodec)（`hw_priority` 在 :23） |
| "整文件预解码进内存再播"的另一套实现 | [`shared/media-playback/media-playback/cache.c`](#cachec) |
| 谁在用这套播放内核 | `plugins/obs-ffmpeg/obs-ffmpeg-source.c:25`（include）、`:314`（`media_playback_create`） |
| Lua / Python 脚本宿主（脚本能调 libobs 全部 API 的原理） | [`shared/obs-scripting/`](#sharedobs-scripting脚本宿主) |
| 属性面板通用控件（`obs_properties_t` → Qt 控件的翻译器） | [`shared/properties-view/properties-view.cpp`](#properties-viewcpp) |
| 推流连接的 IPv4/IPv6 双栈竞速（Happy Eyeballs） | `shared/happy-eyeballs/happy-eyeballs.c`（RFC **6555**，见下文更正） |
| 写自己的源 / 滤镜时可照抄的最小插件骨架 | [`test/test-input/`](#test-input最小插件示例) |
| 音视频同步自检的测试源（黑白闪 + 音调） | `test/test-input/sync-pair-vid.c`、`sync-pair-aud.c` |
| macOS 上从零编译 OBS 的实际命令 | [构建体系 → macOS 从零编译](#macos-从零编译实测命令) |
| `cmake/` 各文件干什么、`build_macos/` 是什么 | [构建体系](#构建体系cmake--build-aux--cmakepresetsjson) |
| 官方 API 文档的 .rst 在哪、在线地址 | [docs/](#docssphinx官方文档源码) |

标记约定：
- ⭐ = 架构关键或代码量大，有展开小节。
- 🔧 = **可以直接抄进自己内核的轮子**（无 OBS 依赖 / 依赖极浅）。

---

## 一句话职责

`shared/` 是 **libobs 与插件之间的"公共中间层"**：一堆各自独立的小静态库/INTERFACE 库，libobs 本身不依赖它们，
但多个插件（或插件 + 前端）都要用，于是抽出来放这儿。每个子目录一个 CMake target，名字都叫 `OBS::xxx`。
其中 `media-playback` 是分量最重的一个——**它就是 OBS 播放媒体文件的全部内核**，`obs-ffmpeg` 的"媒体源"只是它的一层薄壳。

`deps/` 是**真正的第三方 vendored 代码**（原样引入 + 一个 OBS 自己写的 `CMakeLists.txt` 当胶水），
`test/` 是示例插件 + 两个手写 harness + 4 个 cmocka 单测，
`cmake/` + `build-aux/` + `CMakePresets.json` 是整套构建/打包/格式化脚本，
`docs/` 是 https://obsproject.com/docs 那份 API 手册的 Sphinx 源码。

---

## shared/media-playback/　`shared/media-playback/media-playback/`

**职责**：一个自成一体的 FFmpeg 媒体播放器内核（`mp_media_*`），ISC 许可（`LICENSE.media-playback`，比 OBS 主体的 GPLv2 宽松，说明作者有意让它可被单独取用）。
输入是一个路径/URL + 一组回调，输出是**已经打好 OBS 时间轴时间戳**的 `struct obs_source_frame` / `struct obs_source_audio`。
CMake 里它是 `INTERFACE` 库（`CMakeLists.txt:5`），也就是**源码直接编进使用者**，不产出独立二进制；只有 `plugins/obs-ffmpeg` 用它。

对外只有 `media-playback.h` 一个头文件（65 行），内部分两条实现：
**流式播放**（`media.c`，边读边解边播）和**整文件预解码**（`cache.c`，全部解进内存再按索引播），
由 `media-playback.c:32` 一行决定走哪条：`is_local_file && full_decode` 才走 cache（给 stinger 转场那种要求"零延迟、可反复重播"的场景）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `media.c` ⭐ | 1052 | **流式播放主体**：一条 `mp_media_thread` 干完拆包→解码→节流→回调全部活；pts 节流、seek、loop/EOF、时间戳换算、swscale 兜底、非本地流的 interrupt 回调都在这 |
| `media.h` | 126 | `struct mp_media` 全部字段（:41）——**读这 66 行就能看懂整套状态机**：时间基四件套 `play_sys_ts/next_pts_ns/next_ns/start_ts/base_ts`（:80-84）、命令标志位 `preload_frame/stopping/looping/active/reset/kill`（:91-96）、`pause/reset_ts/seek/seek_next_ts/seek_pos`（:101-105） |
| `decode.c` ⭐ | 421 | **单流解码器封装** `mp_decode_*`：硬件加速探测与创建、`avcodec_receive/send` 循环、pts 与 duration 推算（含 `best_effort_timestamp` 缺失时的兜底）、倍速换算、flush |
| `decode.h` | 81 | `struct mp_decode`（:41）：一个流一份——解码器上下文 + `hw_ctx`/`hw_format`、三个 `AVFrame`（`in_frame`/`sw_frame`/`hw_frame`，:53-56）、`frame_pts`/`next_pts`/`last_duration`、`struct deque packets`（:67，包队列直接用 libobs 的 `deque`） |
| `cache.c` ⭐ | 701 | **整文件预解码播放**：先用 `media.c` 全速解完整个文件塞进两个 `DARRAY`，再按数组下标 + 同一套节流逻辑回放。seek 变成"二分…其实是线性扫描数组"（:143） |
| `cache.h` | 97 | `struct mp_cache`（:25）：与 `mp_media` 平行的一套状态，多了 `video_frames`/`audio_segments` 两个 DARRAY（:54-55）和 `cur_v_idx/next_v_idx/next_v_ts` 这组游标（:57-62） |
| `media-playback.c` | 176 | **门面（facade）**：`struct media_playback` 只有一个 `bool is_cached` + 一个 union（:21-27），每个 API 都是"if cached → mp_cache_xxx else → mp_media_xxx"的二选一转发 |
| `media-playback.h` | 65 | 唯一对外头文件：三个回调 typedef（:24-26）、`struct mp_media_info`（:28，创建参数全集：路径/格式名/ffmpeg_options/buffering/speed/force_range/hardware_decoding/is_local_file/request_preload/full_decode）、15 个 `media_playback_*` 函数 |
| `closest-format.h` 🔧 | 117 | 纯查表：把 FFmpeg 输出的任意 `AVPixelFormat` 映射到"OBS 支持的最接近格式"。**9/10/12/14/16-bit 的各种 420 统统折成 `AV_PIX_FMT_YUV420P10LE`（:83），而原生 `P010LE` 保持不动（:104-105）**，不认识的一律 `BGRA`（:116）。有了这张表就能只在真正需要时才起 swscale（`media.c:296-303` 只在 `closest_format(fmt) != fmt` 时才建 scaler） |
| `CMakeLists.txt` | 24 | `add_library(media-playback INTERFACE)`，链 avcodec/avdevice/avutil/avformat |
| `LICENSE.media-playback` | 18 | ISC 许可全文 |

### ⭐ 重点文件展开

#### `media.c`

- **做什么**：一条线程完成"读包 → 解码 → 按 pts 睡 → 回调输出"。它**不是**播放器常见的多线程流水线，而是**单线程串行**——这是本文件最大的设计取舍，下面单独讲。
- **关键入口**：`mp_media_init`（:875，填字段 + 起线程）、`mp_media_thread`（:740，真身）、`mp_media_prepare_frames`（:264，"两路都有帧待发"的填充器）、`mp_media_next_video`/`mp_media_next_audio`（:375/:346，输出）、`mp_media_sleep`（:598）、`mp_media_calc_next_ns`（:498）、`seek_to`（:520）、`mp_media_reset`（:551）、`mp_media_eof`（:619）、`reset_ts`（:724）、`init_avformat`（:661）、`mp_media_free`（:927）。
- **看点**：见下面「复刻要点」四节，全部落在这个文件里。

#### `decode.c`

- **做什么**：把"一个 AVStream → 一个随时可取的当前帧"这件事封成 `struct mp_decode`。视频、音频各一份（`m->v` / `m->a`），互不知情。
- **关键入口**：`mp_decode_init`（:134）、`mp_open_codec`（:68）、`init_hw_decoder`（:45）、`mp_decode_push_packet`（:246）、`mp_decode_next`（:323）、`decode_packet`（:267）、`mp_decode_flush`（:413）、`get_estimated_duration`（:251）。
- **看点**：
  ① **硬件加速是"按优先级表逐个试"**：`hw_priority[]`（:23-26）顺序是 CUDA → D3D11VA → DXVA2 → VAAPI → VDPAU → QSV → **VIDEOTOOLBOX** → NONE。注意 VideoToolbox 排在倒数第二——在 mac 上前面几个 `av_hwdevice_ctx_create` 都会失败，自然落到 VT。判定分两步：`has_hw_type`（:28）先用 `avcodec_get_hw_config` 查这个 codec 支不支持该 device type（并顺手记下 `hw_format`），再 `av_hwdevice_ctx_create` 真建设备（:52），成功才 `d->hw = true`（:64）。
  ② **硬件帧下载有个"格式不符就直接放行"的分支**：`decode_packet:301-317`——如果解出来的 `hw_frame->format != hw_format`，说明 FFmpeg 其实给了软帧，直接 `d->frame = d->hw_frame` 返回；否则 `av_hwframe_transfer_data` 下载到 `sw_frame`，**并且必须补一次 `av_frame_copy_props`（:311）**，因为 transfer 只搬像素不搬 pts/色彩属性。这个坑很值得记。
  ③ **`avcodec_receive_frame` 在 `avcodec_send_packet` 之前先试一次**（:272 在 :280 之前）——先把上一次可能囤在解码器里的帧掏出来，掏不到（EAGAIN）才喂新包。省掉一个"帧队列"。
  ④ **pts 三级兜底**（:386-408）：`best_effort_timestamp` 有值就 rescale 到纳秒（:392）；没有就用上一帧算出的 `next_pts`（:390）。duration 也是三级：帧自带 `duration` → 音频按 `nb_samples/sample_rate` 算、视频用"本帧 pts − 上帧 pts" → 再退到 `last_duration` → 最后退到 `time_base`（`get_estimated_duration`:251-264）。**`next_pts = frame_pts + duration`（:407）是整套节流的输入**。
  ⑤ **倍速在解码层就换算掉**（:401-404）：`frame_pts` 和 `duration` 同时按 `speed/100` 缩放，所以上层节流代码完全不用知道有倍速这回事（音频还要在 `media.c:362` 把 `samples_per_sec` 也乘上 speed）。
  ⑥ **VP8/VP9 带 alpha 要强制换解码器**（:154-162）：检测流 metadata 里 `alpha_mode == "1"` 就改用 `libvpx`/`libvpx-vp9`（原生解码器不出 alpha 平面）。
  ⑦ `thread_count = 0`（让 FFmpeg 自选线程数）对几种图片类 codec 例外（:88-90，PNG/TIFF/JPEG2000/MPEG4/WEBP 保持单线程）。

#### `cache.c`

- **做什么**：`media.c` 的"离线全解"孪生兄弟。启动时先把整个文件解成两个数组（视频帧逐帧 `obs_source_frame_init` + `obs_source_frame_copy` 深拷贝，音频段 `bmalloc` 一块连续内存再按 plane 切），之后播放就是数组游标前进。
- **关键入口**：`mp_cache_init`（:535，把 `info` 改写成 `full_decode=true` + 自己的 fill 回调后交给 `mp_media_init`）、`mp_cache_decode`（:113，全解循环）、`fill_video`/`fill_audio`（:468/:483）、`mp_cache_thread`（:368）、`mp_cache_next_video`/`_next_audio`（:234/:268）、`seek_to`（:143）、`mp_cache_reset`（:293）、`mp_cache_sleep`（:72）、`mp_cache_calc_next_ns`（:346）。
- **看点**：
  ① **它复用 `media.c` 的私有函数**——`cache.c:24-29` 用 `extern` 直接声明了 6 个 `mp_media_*` 内部函数（`mp_media_init2`/`prepare_frames`/`eof`/`next_video`/`next_audio`/`reset`）。这就是为什么 `media.c` 里那些函数没写 `static`。全解循环（:122-130）就是"手动跑 `media.c` 的主循环，但不睡"。
  ② **`m->full_decode = true`（:118）是一个开关，让 `media.c` 里的时间戳逻辑退化**：看 `media.c:366` 和 `:453`——`full_decode` 时 timestamp 直接等于 `d->frame_pts`（源侧相对时间），不做系统时间轴映射。因为映射要留到回放时（`cache.c:246`/`:283`）才做。这是同一份代码服务两种时基的干净做法。
  ③ **解完就把解码器整个释放**（`mp_cache_decode:139` 调 `mp_media_free`）——内存里只留裸帧，FFmpeg 上下文全部还给系统。
  ④ **seek 退化成线性扫描**（:156-162 / :174-180）：从头遍历 `video_frames` 找第一个 `timestamp >= pos`。长视频会慢，但 cache 模式本来只给短转场素材用。
  ⑤ 节流逻辑（`mp_cache_sleep`:72、`mp_cache_calc_next_ns`:346）和 `media.c` 那两个**逐行相同**——是复制粘贴，不是抽公共函数。想抄的话抄一份就行。

### 复刻要点（线程 / pts 节流 / seek / loop）

> 这四节是本篇的核心，全部行号已核对。

#### 1. 线程模型：**只有一条线程**

| 项 | 位置 | 说明 |
|---|---|---|
| 线程数 | `media.c:866` | 整个 `mp_media` **只 `pthread_create` 一次**。线程名 `"mp_media_thread"`（:742）。cache 模式另有一条 `"mp_cache_thread"`（`cache.c:526`/`:370`），但同一时刻也只有一条 |
| 线程干什么 | `media.c:740-833` | 一个 `for(;;)`：① 取 `active`/`pause` → ② 不活跃就 `os_sem_wait` 阻塞、活跃就 `mp_media_sleep` 睡到下一帧（:761-768）→ ③ 加锁一次性把所有命令标志读出并清零（:770-786）→ ④ 依次处理 kill/reset/seek/reset_time/pause（:788-808）→ ⑤ 输出当前帧 `mp_media_next_video` + `mp_media_next_audio`（:818-821）→ ⑥ `mp_media_prepare_frames` 补下一帧（:823）→ ⑦ `mp_media_eof` 判尾（:825）→ ⑧ `mp_media_calc_next_ns` 算下次醒来时刻（:828） |
| "拆包"在哪 | `media.c:167` `mp_media_next_packet` | 被 `mp_media_prepare_frames`（:264）调用，**在同一条线程里同步 `av_read_frame`**。读到的包按 stream index 分给 `m->v` 或 `m->a` 的 `deque`（`decode.c:246`），不属于这两条流的包直接扔回池子（:189） |
| "解码"在哪 | `media.c:290-293` | 还是同一条线程：`mp_decode_frame(&m->v)` / `(&m->a)`。**循环条件是 `!mp_media_ready_to_start(m)`（:268，:195 定义）——两路都有 `frame_ready` 或已 eof 才停**，所以每一轮必然把音视频各准备好一帧 |
| 怎么退出 | `media.c:915` `mp_kill_thread` | 置 `m->kill = true` → `os_sem_post` 把可能在等信号量的线程叫醒 → `pthread_join`。线程侧在 :788 看到 `kill` 就 `break` |
| 网络流怎么打断阻塞的 IO | `media.c:642` `interrupt_callback` | 非本地文件才装（:691-692）。**20ms 才真正取一次锁**（:648，靠 `interrupt_poll_ts` 节流），返回 `kill \|\| stopping`。这是让 `av_read_frame` 能被中断的标准手法 |
| 暂停 | `media.c:966` `mp_media_play_pause` | 置 `pause` + `reset_ts = !pause`，然后 post 信号量。线程侧 :761 判断 `pause` 就去 `os_sem_wait` 挂住；**恢复时先 `reset_ts(m)`（:765 / :802-805）重锚时间轴**，否则暂停那段真实时间会被当成"落后"，恢复瞬间猛追帧 |

**与你现在 `WLMediaSource` 五线程（parse / v-decode / a-decode / v-render / a-render）的对比**：
OBS 用一条线程换来"零队列间同步问题"——没有帧队列的加锁、没有 seek 时"哪个队列里还有旧帧"的清理竞态（`mp_decode_flush` 一调，`deque` 和解码器缓冲一起清干净，没有第二个持有者）。
代价是**任何一路的解码抖动会直接推迟另一路的输出**，且拆包与解码不能重叠。OBS 能接受这个代价，是因为它下游还有 libobs 的异步帧缓冲（`obs-source.c` 那套 async frame 队列）在兜底。

#### 2. pts 节流：绝对基准 + 增量累加

核心是两个变量：`m->next_ns`（**下一帧应该在墙上时钟的哪一刻输出**，单位 ns，`os_gettime_ns` 时基）和 `m->next_pts_ns`（当前已输出到的源侧 pts）。

```
mp_media_calc_next_ns（media.c:498）
    min_next_ns = min(v.frame_pts, a.frame_pts)      // :500，取两路里更早的那个
    delta       = min_next_ns - m->next_pts_ns        // :501，本帧到下帧的源侧间隔
    m->next_ns    += delta                            // :516  ← 累加到墙上时钟目标
    m->next_pts_ns = min_next_ns                      // :517

mp_media_sleep（media.c:598）
    若 next_ns == 0：            next_ns = os_gettime_ns()   // :603，第一次，锚定
    否则 t = os_gettime_ns()；若 next_ns > t：
        delta_ms = (next_ns - t + 500000) / 1000000          // :607，四舍五入到 ms
        os_sleep_ms(min(delta_ms, 200))                      // :611
        返回 timeout = (delta_ms > 200)                      // :610
```

要点：

1. **是"基准 + 累加增量"，不是"每帧 sleep 一个帧间隔"**。因为 `next_ns` 从来不被"当前时间"重写（只在 `reset_ts` 里清零重锚），累加的 delta 之和恰好等于 `当前pts − 起始pts`，所以数学上等价于 `base_wall + (pts - first_pts)`——**解码慢了不会累积漂移，下一帧的目标时刻不变，自然会少睡或不睡追回来**。这正是你要复刻的那条。
2. **两个夹紧（clamp）会打破上面的等价性**，`media.c:507-513`：`delta < 0` 置 0（时间戳倒退，B 帧乱序或流异常）、`delta > 3000000000`（3 秒）置 0（时间戳大跳）。Debug 构建里 `delta >= 0` 是个 `assert`（:508）。也就是说 OBS 明确选择了"遇到坏时间戳就放弃对齐、立刻出帧"。
3. **睡眠上限 200ms + timeout 标志**（:609-611）：一次最多睡 200ms，超了就返回 `timeout=true`。线程侧拿到 `timeout` 会**跳过这一轮的输出与推进**（:817 的 `if (is_active && !timeout)`），下一轮重新算。这样"下一帧在 5 秒后"（比如慢速流、或 seek 到远处）也能每 200ms 回到循环顶部去响应 kill/seek/pause 命令——**用睡眠分片换命令响应延迟**，比用条件变量 + 超时等待简单得多。
4. **输出时间戳是另一套公式**，别和节流混在一起。`media.c:453`（视频）/ `:366`（音频）：
   ```
   frame->timestamp = m->base_ts + d->frame_pts - m->start_ts + m->play_sys_ts - base_sys_ts;
   ```
   - `base_sys_ts`（:28，文件级 static）：**进程内第一个 `mp_media` 创建时的 `os_gettime_ns()`**（:904-905），全局共享，让所有媒体源的时间戳同处一个原点。
   - `m->play_sys_ts`：本次播放开始的墙上时刻（`mp_media_reset:579/585`）。
   - `m->start_ts`：本次播放第一帧的源侧 pts（:580/:584）。
   - `m->base_ts`：**已经播完的时长累加值**——loop 的关键，见第 4 节。
   - 于是 `frame_pts - start_ts` 是"本轮播了多久"，加 `base_ts` 是"总共播了多久"，加 `play_sys_ts - base_sys_ts` 平移到 OBS 全局时间轴。
5. **`mp_media_can_play_frame`（:339）是"这一帧该不该现在出"的闸门**：`frame_pts <= next_pts_ns` 才出；但如果 `frame_pts - next_pts_ns > MAX_TS_VAR`（2 秒，:337）也放行——**时间戳差太多就认定它坏了，宁可出画面也不要卡住**。音视频各自过这个闸门（`:352` / `:385`），所以某一路时间戳跳变不会拖死另一路。

#### 3. seek：`av_seek_frame` + flush + 用 `seek_next_ts` 吞掉这一次的时间推进

```
mp_media_seek（media.c:1042）           // 外部线程调
    m->seek = true; m->seek_pos = pos * 1000;   // :1047，入参是 ms → 转成 µs(AV_TIME_BASE)
    os_sem_post(m->sem)                          // :1051，把可能挂住的线程叫醒

线程侧（media.c:796-800）
    m->seek_next_ts = true;                      // :797  ← 标记"下一次算 delta 时别算"
    seek_to(m, seek_pos);                        // :798
    continue;                                    // :799  ← 本轮不输出帧

seek_to（media.c:520）
    seek_flags = (fmt->duration == AV_NOPTS_VALUE) ? AVSEEK_FLAG_FRAME
                                                   : AVSEEK_FLAG_BACKWARD   // :526-529
    seek_target = BACKWARD ? av_rescale_q(pos, AV_TIME_BASE_Q, stream[0]->time_base)
                           : pos                                            // :531-533
    if (is_local_file) av_seek_frame(m->fmt, 0, seek_target, seek_flags)     // :536
    if (has_video && is_local_file) {
        mp_decode_flush(&m->v);                                             // :543
        if (seek_next_ts && pause && v_preload_cb && prepare_frames(m))
            mp_media_next_video(m, true);       // :545 ← 暂停中拖进度条：立刻出一帧预览
    }
    if (has_audio && is_local_file) mp_decode_flush(&m->a);                  // :548
```

要点：

1. **旧帧不是"丢弃"而是"根本不存在"**——`mp_decode_flush`（`decode.c:413`）三件事：`avcodec_flush_buffers` 清解码器内部缓冲、`mp_decode_clear_packets` 清 `deque` 里未解的包（并把 `packet_pending` 的那个 unref）、把 `frame_pts`/`next_pts`/`frame_ready`/`eof` 全部归零。因为只有一条线程持有这些帧，flush 完就不可能有"在飞的旧帧"。**你那套 epoch 世代号方案是为多线程流水线准备的；单线程模型下不需要世代号。**
2. **`AVSEEK_FLAG_BACKWARD` 时才 rescale 时间基**（:531）。注意它 rescale 用的是 `m->fmt->streams[0]->time_base`，而 `av_seek_frame` 传的 stream index 也是 `0`（:536）——**硬编码用第 0 条流做 seek 基准**，不是视频流。这是个简化（多数文件第 0 条就是视频），复刻时留意。
3. **`seek_next_ts` 是"这一次别推进时间轴"的一次性标志**：`mp_media_calc_next_ns:503-505` 看到它就把 `delta` 强制为 0 并清标志。否则 seek 后的第一帧 pts 与 seek 前差了几十秒，`next_ns` 会被推到很远的未来（或被 3 秒 clamp 打成 0），画面就卡住或乱跳。
4. **只有本地文件才 seek**（:535/:542/:547 三处都判 `is_local_file`）——网络流一律不 seek。
5. **暂停中 seek 要单独出一帧**（:544-546）：走 `v_preload_cb`/`v_seek_cb` 而不是正常的 `v_cb`，这样进度条拖动时画面跟着变但播放状态不变。看 `mp_media_next_video:487-495` 的 `preload` 分支：`seek_next_ts && v_seek_cb` → `v_seek_cb`；否则 `!request_preload` → `v_preload_cb`。**你实现的"松手才 seek + 抑制回显"对应的就是这条路径的上层策略。**
6. 非本地流 + 还没拿到关键帧时会**直接丢非关键帧**（`mp_media_next_video:480-485`，`got_first_keyframe`），避免开头一堆花屏。

#### 4. loop 与 EOF：时间线摊平，`base_ts` 累加，**play_sys_ts 不重锚**

```
mp_media_eof（media.c:619）
    eof = (无视频 或 v.frame_ready==false) && (无音频 或 a.frame_ready==false)   // :621-623
    若 eof：
        加锁读 looping；若不 looping 则 active=false, stopping=true            // :628-634
        mp_media_reset(m);                                                     // :636
    返回 eof   // 线程侧 :825 拿到 true 就 continue（跳过 calc_next_ns）

mp_media_reset（media.c:551）
    next_ts = mp_media_get_base_pts(m)      // :556，= max(v.next_pts, a.next_pts)：本轮播到哪
    offset  = next_ts - m->next_pts_ns      // :557，本轮"已算进 next_ns"与"实际播到"的差
    m->eof = false;
    m->base_ts += next_ts;                  // :563  ★ 时间线摊平的全部秘密
    m->seek_next_ts = false;                // :564
    seek_to(m, start_time);                 // :566，回到 fmt->start_time
    prepare_frames(m);                      // :574
    if (active) {                           // :577  ← loop 走这条
        if (!m->play_sys_ts) m->play_sys_ts = os_gettime_ns();   // :578-579（只在没有时才设）
        m->start_ts = m->next_pts_ns = mp_media_get_next_min_pts(m);  // :580
        if (m->next_ns) m->next_ns += offset;                    // :581-582
    } else {                                // :583  ← 首次启动 / stop 后重启走这条
        m->start_ts = m->next_pts_ns = mp_media_get_next_min_pts(m);  // :584
        m->play_sys_ts = os_gettime_ns();                        // :585  ← 这里才重锚
        m->next_ns = 0;                                          // :586
    }
    m->pause = false;                       // :589
```

要点：

1. **`base_ts += next_ts`（:563）就是"时间线摊平"**：每播完一轮，把这一轮的总时长累进 `base_ts`。于是输出公式 `base_ts + frame_pts - start_ts + ...` 里，第二轮的 pts 虽然又从 0 开始，加上 `base_ts` 后依然单调递增。**下游（libobs 的 async frame 队列、编码器）看到的是一条永不回退的时间线。**
2. **loop 时 `play_sys_ts` 明确不重锚**（:578 的 `if (!m->play_sys_ts)` 守卫）——只有在 `active == false`（首次启动或 stop→play）才 `play_sys_ts = os_gettime_ns()`（:585）。这一条和你在 WorkLabs 里踩出来的结论完全一致：**loop 重锚 baseTime 会在循环点插入一个"真实耗时"的空洞**。
3. **`next_ns += offset`（:581-582）是个细节补正**：`offset = 本轮实际播到的 pts − 已经累进 next_ns 的 pts`。因为 `calc_next_ns` 累加的是"帧 pts 之差"，而最后一帧还有一个 duration 没被累加进去（`next_pts = frame_pts + duration`）。不补这一下，循环点会短掉最后一帧的显示时长。
4. **EOF 的判定是"两路都没有 ready 的帧"**，不是"读到 AVERROR_EOF"。`m->eof`（文件已读完）与 `d->eof`（解码器已排空）是两个不同的标志：`mp_media_prepare_frames:271-276` 读到 `AVERROR_EOF` 时只置 `m->eof = true`，然后 `mp_decode_next`（`decode.c:337-339`）会给解码器喂空包做 drain，把囤着的帧全掏出来，掏干了才 `d->eof = true`（`decode.c:353-355`）→ 于是 `frame_ready` 恒为 false → `mp_media_eof` 才判 true。**先摊平、后清空、再判尾，顺序不能乱。**
5. **不 loop 时的 stop 通知走一个"延迟到下次 reset"的路径**：`mp_media_eof` 置 `stopping = true`（:632），`mp_media_reset` 在 :569 把它读出来并清零，最后 :593-594 才调 `m->stop_cb`。也就是说 `stop_cb` 一定在"状态已经复位到起点"之后才通知上层——上层收到回调时可以直接重播。
6. `mp_media_get_base_pts`（:324）取 `max(v.next_pts, a.next_pts)`，`mp_media_get_next_min_pts`（:308）取 `min(v.frame_pts, a.frame_pts)`。**一个用 max（要覆盖最长的那路）、一个用 min（要先出最早的那帧）**，别搞反。
7. 对外的"当前播放位置"是 `mp_media_get_current_time`（:1001）：`mp_media_get_base_pts(m) * speed / 100000000LL`——ns → ms 再乘倍速。

---

## shared/obs-scripting/　脚本宿主

**职责**：把 libobs 的 C API 暴露给 Lua（LuaJIT）和 Python 3，让用户写 `.lua` / `.py` 脚本就能操作源、场景、信号、热键、定时器，甚至**用脚本注册一个新的源类型**。
编成一个独立的共享库 `obs-scripting`（`CMakeLists.txt:12`），使用者只有 `plugins/frontend-tools/scripts.cpp`（就是 OBS 里"工具 → 脚本"那个面板）。
绑定层不是手写的：`obslua.i` / `obspython.i` 是 **SWIG** 接口文件，构建时由 SWIG 从 libobs 的头文件自动生成整套绑定（`cmake/lua.cmake` / `cmake/python.cmake`）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-scripting.c` | 471 | 语言无关的门面：`obs_scripting_load`（:132，按编译期宏决定初始化 Lua/Python 哪几个）、`obs_script_create`（:245，按扩展名分派）、`obs_script_reload`（:395）、以及**延迟调用队列**——`defer_call_post`（:116）+ `defer_thread`（:93）：脚本回调里若要做"注销自己"这类危险操作，先入队，由独立线程稍后执行，避免在回调栈里销毁自己 |
| `obs-scripting.h` | 67 | 唯一对外头文件：`enum obs_script_lang`（:34）、`obs_scripting_load/unload`、`obs_script_*` 全套、`obs_scripting_python_runtime_linked` 等 Python 运行时探测 |
| `obs-scripting-internal.h` | 46 | `struct obs_script`（:24，公共基类：lang/loaded/settings/path/file/desc）+ `script_log` 与 `script_error/warn/info/debug` 宏 |
| `obs-scripting-callback.h` | 97 | **回调生命周期的公共骨架**：`struct script_callback`（:28，侵入式双向链表 `next` + `p_prev_next`，加一个 `volatile bool removed` 原子标志）、`add_script_callback`（:44）/`remove_script_callback`。所有 Lua/Python 回调（信号、定时器、热键、tick）都以它为头部再拼语言相关字段——**"C 侧不能立刻释放脚本对象"这个问题的通用解法，值得看** |
| `obs-scripting-logging.c` | 67 | 把脚本的 print/error 统一打上 `[Lua: foo.lua]` 前缀（:29）后交给可替换的 `scripting_log_handler_t`；Python 侧还在启动脚本里把 `sys.stdout/stderr` 重定向到它（`obs-scripting-python.c:31` 那段内嵌 Python 代码） |
| `obs-scripting-lua.c` ⭐大 | 1378 | LuaJIT 宿主主体：`load_lua_script`（:79，预置 `package.preload` 清理 + `require "obslua"` + 注入 `script_path()`）、定时器（`timer_add`:308 / `timer_remove`:278 / `timer_call`:289，一个全局 `timer_mutex`:248）、`script_tick` 钩子（:201）、tick/渲染回调增删（:363/:393/:409）、信号连接（:477/:550）、热键注册（:717）、源枚举（:579/:601/:626）。**注意大量操作走 `defer_call_post`**（如 :322 定时器初始化、:661 热键注销） |
| `obs-scripting-lua.h` | 238 | `struct obs_lua_script`、`struct lua_obs_callback`、`call_func_` / `ls_get_libobs_obj_` / `ls_push_libobs_obj_` 等宿主内部 API 声明 |
| `obs-scripting-lua-source.c` | 725 | **用 Lua 表定义一个 `obs_source_info` 并注册**：`struct obs_lua_source`（:119）保存每个回调在 Lua 注册表里的索引，然后一整套 C 侧 shim（`obs_lua_source_create`:179、`get_width`:256、`get_properties`:331、`update`:358、`video_tick`:399、`video_render`:422、`save`:445…）逐个转调 Lua 函数。`get_table_string_`（:25）等取表助手用 `cstrcache_get` 让字符串指针永久有效 |
| `obs-scripting-lua-frontend.c` | 335 | 只在 `ENABLE_FRONTEND` 时编译：把 `obs-frontend-api`（场景切换、录制/推流控制、事件回调）也绑给 Lua（`get_scene_names`:16、`get_scenes`:34…） |
| `obs-scripting-python.c` ⭐大 | 1769 | Python 3 宿主主体，与 Lua 版一一对应（`timer_add`:440、`timer_remove`:403、tick 回调 :506/:483、信号 :595/:652/:690…）。开头那段内嵌 `startup_script`（:16-31）把 stdout/stderr 接到 OBS 日志并设 `PYTHONUNBUFFERED` |
| `obs-scripting-python.h` | 219 | 同上的内部声明（`struct obs_python_script`、`libobs_to_py_`/`py_to_libobs_` 等） |
| `obs-scripting-python-import.c` | 210 | **只在 Windows/macOS 编译**：不链接 libpython，而是运行时 `dlopen` 它——`import_python`（:44）按 `PY_MAJOR/MINOR_VERSION_MAX`（:41-42，上限 3.12）从高到低逐个次版本试探（:87-88）。**macOS 的路径模板是 `Python.framework/Versions/%s/lib/libpython%s.dylib`（:38）**。这样 OBS 二进制不绑死某个 Python 版本 |
| `obs-scripting-python-import.h` | 279 | 一长串 `Py_*` 函数指针声明 + `#define Py_xxx import_xxx` 的重定向（靠 `NO_REDEFS` 控制），是"运行时链接"那套宏体操 |
| `obs-scripting-python-frontend.c` | 450 | Python 版的 frontend-api 绑定 |
| `cstrcache.cpp` / `cstrcache.h` | 29 / 13 | 极小工具：一个进程级 `unordered_map<string,string>`，`cstrcache_get`（:14）把任意 C 串**驻留（intern）成永久有效指针**。用途：脚本随时可能被 GC 的字符串要交给 libobs 长期持有（如源的 `id`/`name`），必须先驻留。🔧 思路可抄 |
| `obs-scripting-config.h.in` | 29 | 构建期配置（脚本目录、Python 版本等）模板 |
| `obslua/obslua.i` | 111 | Lua 绑定的 SWIG 接口：`%include` 一堆 libobs 头（:1-15 的 `%{...%}` 里）、把 `blog` 包一层变参安全版（:26-32）、清掉 `EXPORT`/`OBS_DEPRECATED` 等宏 |
| `obspython/obspython.i` | 139 | Python 版同上，额外处理 `SWIG_PYTHON_INITIALIZE_THREADS`（:20-26，Python≥3.7 + SWIG<4.1 的兼容）和 `%feature("python:annotations")` |
| `cmake/lua.cmake` | 40 | `ENABLE_SCRIPTING_LUA` 开关、`find_package(Luajit)`、用 `swig -lua -external-runtime` 生成 `swigluarun.h`（:13）、给 Clang 关掉 `-Werror=shorten-64-to-32`（:31-35） |
| `cmake/python.cmake` | 54 | 同上；**版本上限按平台不同**：Windows `3.8...<3.11`、macOS `3.8...<3.12`、Linux 只要 `3.8+`（:6-12）。macOS/Windows 走 `-py3-stable-abi` 且链接选项加 `-undefined dynamic_lookup`（:51） |
| `cmake/cstrcache.cmake` | 5 | 把 `cstrcache.cpp` 做成 `OBS::cstrcache` 目标 |
| `cmake/windows/obs-module.rc.in` | — | Windows 资源模板 |

---

## shared/properties-view/　属性面板通用控件

**职责**：把 libobs 的 `obs_properties_t`（数据驱动的属性描述）**自动翻译成一整页 Qt 控件**，并把用户改动写回 `obs_data_t`。
所有"源/滤镜/输出/编码器的设置对话框"都是它渲染的——OBS 前端（`OBSBasicProperties`/`OBSBasicFilters`/`OBSBasicSettings`）和三个插件（`aja-output-ui`、`decklink-output-ui`、`frontend-tools`）共用同一个类。
这是"**插件只声明属性、UI 完全由框架生成**"这条设计的落地点，也是你若要做属性面板的直接参考。

| 文件 | 行数 | 功能 |
|---|---|---|
| `properties-view.cpp` ⭐ | 2423 | 见下方展开 |
| `properties-view.hpp` | 204 | 两个类：`WidgetInfo`（:21，一个控件 ↔ 一个 `obs_property_t` 的绑定 + 各类型的 `XxxChanged` 槽 + 可编辑列表的 8 个按钮槽）、`OBSPropertiesView`（:84，继承 `VScrollArea`；`AddCheckbox`/`AddText`/`AddPath`/`AddInt`/`AddFloat`/`AddList`/`AddEditableList`/`AddButton`/`AddColor`/`AddFont`/`AddFrameRate`/`AddGroup` 一族私有方法在 :110-124） |
| `properties-view.moc.hpp` | 63 | 单独拆出来给 moc 处理的部分：`media_frames_per_second` 的 `==`/`!=`（:18-29，**交叉相乘比较分数，避免除法和舍入**）、`frame_rate_range_t` 类型别名、`OBSFrameRatePropertyWidget`（:34，帧率控件的全部子控件字段） |
| `double-slider.cpp` / `.hpp` | 29 / 21 | `DoubleSlider`：Qt 的 `QSlider` 只支持 int，这个包一层做浮点映射（内部按 `granularity` 缩放） |
| `spinbox-ignorewheel.cpp` / `.hpp` | 15 / 15 | `SpinBoxIgnoreScroll`：屏蔽滚轮改值。**因为属性面板是可滚动的长页面，鼠标滚过一个 spinbox 时不应该悄悄改数值**——一个很实际的 UX 修补 |

### ⭐ 重点文件展开

#### `properties-view.cpp`

- **做什么**：`RefreshProperties`（:112）遍历 `obs_properties_first/next`，对每个 property 调 `AddProperty`（:1526）按 `obs_property_get_type` 分派到对应的 `AddXxx`，把生成的控件塞进 `QFormLayout`，同时 new 一个 `WidgetInfo` 存进 `children`（`std::vector<std::unique_ptr<WidgetInfo>>`）负责信号连接。用户改动 → `WidgetInfo::ControlChanged`（:2040）→ 按类型调 `BoolChanged`/`IntChanged`/…（:1761 起）写回 `obs_data_t` → 触发上层 `callback`。
- **关键入口**：`ReloadProperties`（:91）、`RefreshProperties`（:112）、`AddProperty`（:1526）、`AddList`（:626）、`AddEditableList`（:725）、`AddFrameRate`（:1388）、`AddGroup`（:1489）、`CreateFrameRateWidget`（:1205）、`WidgetInfo::ControlChanged`（:2040）、`EditableItemDialog`（:2143）。
- **看点**：
  ① **滚动位置的保存/恢复**（`GetScrollPos`:180 / `SetScrollPos`:165）——属性刷新会重建整个页面，不记住滚动位置的话每次改一个选项视图就跳回顶部。同理还记住了 `lastFocused` 控件名（:101）。
  ② **`deferUpdate` 机制**：某些属性（文本框）不该每敲一个字符就调用插件的 `update`，于是用 `QTimer` 攒一下（`WidgetInfo::update_timer`，`properties-view.hpp:30`；析构时强制 `timeout` 落盘，:60-64）。
  ③ **帧率控件是本文件最复杂的一块**（:944-1486，约 540 行）：支持"简单模式（预置常见帧率）"与"有理数模式（分子/分母）"两套 UI 切换（`QStackedWidget`），还要把设备报上来的多个帧率**区间**（`frame_rate_ranges_t`）匹配到预置项上（`matches_range`:944 / `matches_ranges`:958）。若你以后要做"摄像头帧率选择"，这段是现成答案。
  ④ **`obs_property_modified` 的回调会导致属性集合结构变化**，所以 `RefreshProperties` 必须能被任意重入地整页重建——这解释了为什么控件全部用 `unique_ptr` 容器持有而不是 Qt 父子树自动管理。

---

## shared/qt/　Qt 公共控件

**职责**：前端与带 UI 的插件共用的 Qt 小工具。分两类：几个独立小控件（各自一个 CMake target），和 `idian/` 这一整套自制设计系统控件。

| 文件 | 行数 | 功能 |
|---|---|---|
| `wrappers/qt-wrappers.cpp` | 387 | **最常用的一个**：`OBSMessageBox`（`qt-wrappers.hpp:43`，统一样式的问/信息/警告/严重四个弹窗）、`QT_UTF8`/`QT_TO_UTF8` 宏（hpp:31-32）、`OBSScene`/`OBSSource` 的 `QDataStream` 序列化 + `Q_DECLARE_METATYPE`（hpp:59-68，让 libobs 对象能塞进 Qt 的拖放/model）、`CreateQThread`（hpp:70）、`ExecuteFuncSafeBlock`（hpp:72，跨线程阻塞执行）、`WaitConnection()`（hpp:82，**已在主线程就 Direct、否则 BlockingQueued**，一个很省心的 inline）、`SelectDirectory`/`SaveFile`/`OpenFile(s)`（hpp:94-97）、`TruncateLabel`（hpp:99）、`setClasses`（hpp:92，QSS class 切换） |
| `wrappers/qt-wrappers.hpp` | 101 | 同名实现的声明（上面已按行号点出） |
| `icon-label/IconLabel.cpp` / `.hpp` | 31 / 46 | `IconLabel`：`QLabel` 的子类，暴露 `Q_PROPERTY(QIcon icon)` + `iconSize`。头注释（hpp:23-28）写明动机：**让 QSS 的 `qproperty-icon` 能直接作用在 label 上**，省掉"先把 icon 导成固定尺寸 PNG 再设 qproperty-pixmap"的两步 |
| `plain-text-edit/plain-text-edit.cpp` / `.hpp` | 15 / 10 | `OBSPlainTextEdit`：`QPlainTextEdit` + 默认等宽字体（构造参数 `monospace = true`）。日志/脚本输出框用 |
| `slider-ignorewheel/slider-ignorewheel.cpp` / `.hpp` | 49 / 33 | `SliderIgnoreScroll`（屏蔽滚轮）与 `SliderIgnoreClick`（屏蔽"点击槽体直接跳值"，只允许拖动滑块）。音量推子用后者——防误触把音量拉满 |
| `vertical-scroll-area/vertical-scroll-area.cpp` / `.hpp` | 11 / 18 | `VScrollArea`：只竖向滚动的 `QScrollArea`（构造里就关掉水平滚动条，hpp:13），`resizeEvent` 里同步内部 widget 宽度。`OBSPropertiesView` 就继承它 |

### `qt/idian/`　自制设计系统（"Yami" UI）

`Idian.hpp:20-22` 的注释自嘲式点题："Idian - A family of custom widgets for OBS implementing the 'Yami' UI design. (OBS Idian, get it?)"。
全部在 `namespace idian`，用于 OBS 新版设置界面。前端里有一个专门的 `feature-idian-playground.cmake` 用来单独预览这些控件。

| 文件 | 行数 | 功能 |
|---|---|---|
| `widgets/Row.cpp` + `include/Idian/Row.hpp` | 391 + 183 | **核心布局单元**：`GenericRow`（Row.hpp:38，`QFrame` + 悬停属性 + 状态样式过滤器）→ `Row`（Row.hpp:55，一行 = 标题 + 描述 + 一个或多个控件）。"设置页每一行"的抽象 |
| `widgets/Group.cpp` + `include/Idian/Group.hpp` | 126 + 71 | `Group`：带标题/描述的一组 Row，可整组折叠或用 ToggleSwitch 启停（`Group.hpp:31`） |
| `widgets/PropertiesList.cpp` + `include/Idian/PropertiesList.hpp` | 88 + 57 | `PropertiesList`：Row 的容器（维护 `first`/`last` 指针以便给首尾行加不同圆角），外加一个纯装饰的 `PropertiesListSpacer`（PropertiesList.hpp:49） |
| `components/ToggleSwitch.cpp` + `include/Idian/ToggleSwitch.hpp` | 257 + 113 | 手绘的 iOS 风开关：`QAbstractButton` + `QPropertyAnimation` 动画滑块（ToggleSwitch.hpp:36-42 一串 `Q_PROPERTY` 让颜色全部可 QSS 化），并实现了 `QAccessibleWidget` 无障碍支持 |
| `components/ComboBox.cpp` + `.hpp` | 69 + 46 | 样式化 combo（含屏蔽滚轮） |
| `components/SpinBox.cpp` / `DoubleSpinBox.cpp` / `CheckBox.cpp` + 对应 hpp | 46/49/27 + 42/42/33 | 同族的样式化基础控件 |
| `include/Idian/Utils.cpp` / `Utils.hpp` | 59 / 124 | `class Utils`：QSS class 增删（带正则校验 `classNameIsValid`，Utils.hpp:29）、`repolish()`/`polishChildren()`（Utils.hpp:42-49，**改了 class 后强制 Qt 重算样式**——纯 QSS 主题化必备的脏活） |
| `include/Idian/StateEventFilter.cpp` / `.hpp` | 116 / 41 | `StateEventFilter`：一个装在控件上的事件过滤器，把 hover/focus/checked 等状态映射成 QSS 属性，让整套控件不写 `paintEvent` 也能有状态样式 |
| `include/Idian/Idian.hpp` | 31 | 汇总 include（只有 8 行 `#include`） |

---

## shared/　其余小目录

| 目录 / 文件 | 行数 | 是什么、谁用它 |
|---|---|---|
| `happy-eyeballs/happy-eyeballs.c` + `.h` 🔧 | 739 + 184 | **IPv4/IPv6 双栈并发连接**。头注释（`happy-eyeballs.h:2`）自称实现 **RFC 6555**（不是 RFC 8305——8305 是把 6555 扩展到含 DNS 解析的后续标准；OBS 这份只做 TCP 连接竞速，注释里明确写了 "currently only works for TCP"）。做法：`build_addr_list`（:188）把 getaddrinfo 结果按"系统偏好的协议族优先"排序，`launch_worker`（:404）为每个地址起一条 `happy_connect_worker`（:330）并发 connect，**谁先成功谁赢，其余关掉**；`coalesce_errors`（:265）在全失败时合并错误信息。API 是非阻塞的：`happy_eyeballs_connect`（:523）发起 → `happy_eyeballs_try`（:584）轮询 / `happy_eyeballs_timedwait`（:604）等 → `get_socket_fd`（:704）取胜出的 socket。**唯一使用者是 `plugins/obs-outputs/librtmp/rtmp.c`**——即 RTMP 推流的连接阶段。版权归 Twitch Interactive（2023），MIT。你若要做"推流首帧更快"或"IPv6 环境下不卡 20 秒"，这文件可以整体拿走 |
| `bpm/bpm.c` + `bpm.h` + `bpm-internal.h` | 598 + 25 + 105 | **Broadcast Performance Metrics**：把编码/输出的性能指标（渲染帧数、丢帧数、编码耗时…）打包成 **H.264/HEVC SEI NALU 塞进码流**，让服务端能看到主播侧的性能。三种 SEI（时间戳/会话指标/分辨率档指标，各有一个 16 字节 UUID，`bpm-internal.h:34-40`）。注册方式是 `obs_output_add_packet_callback(bpm_inject)`（`bpm.h` 头注释写明），入口 `bpm_inject`（:560）、渲染三个 SEI 的 `bpm_ts_sei_render`（:137）/`bpm_sm_sei_render`（:203）/`bpm_erm_sei_render`（:249）。依赖 `deps/libcaption` 的 `mpeg.h` 做 SEI 封装。使用者：`frontend/utility/MultitrackVideoOutput.cpp`、`plugins/obs-outputs/mp4-output.c` |
| `file-updater/file-updater/file-updater.c` + `.h` | 541 + 22 | **带缓存与版本比对的文件下载器**：从一个 URL 拉 JSON 清单，逐个文件比对本地缓存版本，只下载更新的，全程在独立线程（`update_thread`:435）。`update_info_create`（:455）走"清单 + 多文件"模式，`update_info_create_single`（:522）只下一个文件。使用者：`plugins/rtmp-services`（更新推流服务列表 + 各家 ingest 节点）、`plugins/win-capture`（更新游戏兼容性列表） |
| `opts-parser/opts-parser.c` + `.h` 🔧 | 81 + 27 | 极简 `"key=value key2=value2"` 解析器：`obs_parse_options`（:25）返回 `struct obs_options`（`.h:14`），额外把**无法解析的词单独收集到 `ignored_words`**（好报错："这几个选项我不认识"）。使用者极多：`obs-x264`、`obs-ffmpeg`（video-encoders / vaapi / AMF）、`obs-nvenc`、`mp4-output`——就是编码器设置里那个"自定义参数"输入框背后的东西 |
| `ipc-util/ipc-util/pipe.h` + `pipe-windows.c/.h` + `pipe-posix.c/.h` | 53 + 271/43 + 17/21 | 跨进程命名管道（server 收、client 发）。**POSIX 版基本是空壳（`pipe-posix.c` 只有 17 行）**——这套只在 Windows 上真用：`plugins/win-capture/graphics-hook` 注入到游戏进程后靠它把日志/状态回传给 OBS |
| `obs-hook-config/graphics-hook-info.h` + `graphics-hook-ver.h` + `hook-helpers.h` | 141 + 23 + 50 | Windows 游戏捕获 hook 的**共享内存协议定义**（`struct hook_info`）与版本号，以及一组 Win32 命名事件/互斥体助手（`hook-helpers.h:10-52` 全是 `CreateEventW`/`OpenMutexW` inline）。注入 DLL 与 OBS 主进程共用同一份头。使用者：`plugins/win-capture/graphics-hook`、`get-graphics-offsets` |
| `obs-inject-library/inject-library.c` + `.h` | 134 + 15 | Windows DLL 注入：`inject_library_obf`（`.h:9`）走 `CreateRemoteThread`，`inject_library_safe_obf`（`.h:15`）走 `SetWindowsHookEx`。**所有 Win32 API 名都以混淆字符串传入**（防反作弊把 OBS 误判为外挂）。mac 无关 |
| `obs-shared-memory-queue/shared-memory-queue.c` + `.h` | 218 + 33 | Windows 虚拟摄像头的**共享内存三格帧队列**：`struct queue_header`（:12，`volatile` 读写下标 + 状态机 `SHARED_QUEUE_STATE_*`）+ 三个帧槽（`video_queue_create`:41）。注意 `plugins/win-dshow/` 下有一份**同名副本**在实际编译，这份是给 virtualcam-module 用的共享源 |
| `obs-tiny-nv12-scale/tiny-nv12-scale.c` + `.h` | 200 + 33 | 极简 NV12 缩放 + 转 I420/YUY2（`enum target_format`，`.h:10`）。文件头注释很实在（:4-7）："TODO: optimize this stuff later, or replace with something better. it's kind of garbage."——最近邻，无 SIMD。虚拟摄像头输出用 |
| `obs-d3d8-api/d3d8.h` + `d3d8types.h` + `d3d8caps.h` | 1279 + 1690 + 364 | **纯 Direct3D 8 头文件**（微软早已不在 SDK 里提供）。为了让游戏捕获能 hook 老游戏的 D3D8 调用而 vendored 进来。3333 行里一行 OBS 代码都没有。mac 无关 |
| `shared/.clang-format` | — | `shared/` 目录下的格式化配置（与仓库根不同） |

---

## deps/　vendored 第三方库

**规则**：这些目录是原样引入的上游代码，OBS 的改动基本只有"加一个自己写的 `CMakeLists.txt` 把它做成 `OBS::xxx` 目标"。**不逐文件看，看一段话就够。**

| 库 | 规模 | 是什么 / 许可 / OBS 用它干什么 / OBS 的胶水 |
|---|---|---|
| `blake2` | 6 个文件（`blake2b-ref.c` 参考实现） | BLAKE2b 哈希。许可三选一：**CC0 / OpenSSL License / Apache-2.0**（`LICENSE.blake2:1-2`）。OBS 用它算文件校验和——只有 **Windows 自动更新器**（`frontend/updater/`）和 macOS 更新/"新功能"弹窗那几个 feature 模块链接它（`frontend/cmake/os-windows.cmake`、`feature-macos-update.cmake`、`feature-whatsnew.cmake`）。OBS 的胶水只有 `CMakeLists.txt`——但里面多做了一件事：Windows 上额外编一个 `blake2_static` 目标并强制 `MultiThreaded` CRT（:14-21），因为更新器是独立 exe 不能依赖动态 CRT |
| `glad` | 8 个文件 | **OpenGL 函数加载器**（glad 是代码生成器，这里放的是生成结果，含 `glad.c` / `glad_wgl.c` / `glad_egl.c`）。生成的 glad 代码按其生成器约定为公有领域/MIT 式，仓库内未单独放 LICENSE 文件。OBS 用它给 `libobs-opengl` 加载 GL 函数指针；另外 `linux-capture`、`linux-pipewire`、`obs-nvenc` 也链它。胶水：`CMakeLists.txt` 里把 EGL/WGL 两份源码用 `$<TARGET_EXISTS:OpenGL::EGL>` / `$<PLATFORM_ID:Windows>` 条件化（:9-20）。**macOS 上 OBS 已改用 `libobs-metal`，这个只在 Linux/Windows 路径上真正生效** |
| `json11` | 4 个文件 | Dropbox 的极简 C++11 JSON 库（`LICENSE.txt:1`，MIT）。**只有前端用**（`frontend/CMakeLists.txt`）。OBS 自己的 libobs 侧用的是 jansson（外部依赖）不是这个——所以仓库里同时存在两套 JSON。胶水：`CMakeLists.txt:10-16` 给新版 Clang 关掉 `-Wno-unqualified-std-cast-call` |
| `libcaption` | 27 个文件（`src/` 13 个 .c + `caption/` 11 个 .h） | Twitch 的**闭路字幕（closed caption）库**，MIT（`LICENSE.txt:1-3`），版本 v0.8（`README.md:2`）。实现 EIA-608 / CEA-708 的编解码，以及**把 708 数据包成 H.264 SEI NALU** 的工具函数（`src/mpeg.c`）。使用者三处：`libobs`（`obs_output_output_caption_text` 那条路）、`plugins/decklink`（从 SDI 抽取字幕）、`shared/bpm`（借它的 SEI 封装塞性能指标）。`add_library(caption STATIC EXCLUDE_FROM_ALL)`。注意 `src/eia608_from_utf8.re2c` 是 re2c 源、`.c` 是生成结果——**不要手改 `.c`** |
| `libdshowcapture` | 448 个文件（含两层 git submodule 残留） | OBS 官方自己维护的 **DirectShow 采集封装库**，LGPL-2.1（`src/COPYING`）。Windows 摄像头/采集卡的全部脏活（`src/source/dshow-enum.cpp` 设备枚举、`dshow-formats.cpp` 格式协商、`capture-filter.cpp` 自制 filter…）。里面还嵌了一个 **Elgato 的 `capture-device-support`** 子模块（`src/external/capture-device-support/`，含 `Library/mac/EGAVHIDImplementation.cpp`——但 OBS 的 CMake 只在 win-dshow 里用，mac 路径不编译）。使用者：`plugins/win-dshow`。胶水：顶层 `CMakeLists.txt` 做成 `INTERFACE` 库把源码列进去（因为它自带的构建系统与 OBS 不兼容）。**mac 开发整目录跳过** |
| `w32-pthreads` | 约 240 个文件 | **pthreads-win32**（POSIX 线程 Windows 移植，LGPL-2.1，`COPYING.LIB`）。让 `libobs/util/threading-posix.*` 那套 pthread 代码在 Windows 上也能编。做成 `SHARED EXCLUDE_FROM_ALL`（`CMakeLists.txt:3`）并且**只编 `pthread.c` 一个源文件**（:6-9，上游的 `pthread.c` 会 `#include` 其余全部 .c——所以那两百多个 `pthread_*.c` 是被间接编进去的）。几乎每个 Windows 插件都链它。mac 完全无关 |

**一句话结论**：mac 上做开发时，`deps/` 里真正相关的只有 `libcaption`（如果你要做字幕）和 `json11`/`blake2`（前端周边）；`glad` 半相关；`w32-pthreads`、`libdshowcapture`、`obs-d3d8-api` 三者共约 3800 个文件全是 Windows 包袱。

---

## test/　测试与示例

**先说一个重要发现**：根 `CMakeLists.txt:33` 只 `add_subdirectory(test/test-input)`，**并没有 `add_subdirectory(test)`**。
而 `test/CMakeLists.txt` 里的 `BUILD_TESTS`（:1）和 `ENABLE_UNIT_TESTS`（:13）两个变量**在整个仓库里再无第二处引用**（grep 全库只命中这一个文件）。
也就是说：`test/cmocka/`、`test/osx/`、`test/win/` 在当前构建图里**不可达**——它们是历史遗留的手动 harness，要跑得自己 `cmake -S test`。`test/test-input/` 是唯一被主构建看到的，且默认关闭（`ENABLE_TEST_INPUT` 默认 `OFF`，`test-input/CMakeLists.txt:3`）。

### `test-input/`　最小插件示例

**这是写自己的源/滤镜时可以照抄的骨架**——一个完整但极小的 OBS 插件：一个模块入口 + 7 个源。整个目录不到 900 行。

| 文件 | 行数 | 功能 |
|---|---|---|
| `test-input.c` ⭐ | 23 | **模块骨架，整份就 23 行**：`OBS_DECLARE_MODULE()`（:3）、`extern` 声明 7 个 `struct obs_source_info`（:5-11）、`obs_module_load` 里逐个 `obs_register_source`（:13-22）。你的插件入口长这样就够了 |
| `test-random.c` ⭐ | 107 | **最小异步视频源**：一条自建线程每 250ms 填一张 20×20 随机像素图并 `obs_source_output_video`。见下方展开 |
| `test-sinewave.c` | 110 | **最小异步音频源**：`sinewave_thread`（:23）每 10ms（`os_sleepto_ns(last_time += 10000000)`，:32）生成 480 个采样的中央 C 正弦波（`rate = 261.63/48000.0`，:15）并 `obs_source_output_audio`。做音频源看这个 |
| `test-filter.c` | 71 | **最小视频滤镜**：`filter_create`（:28）里 `obs_enter_graphics()` → `obs_module_file("test.effect")` 取数据文件 → `gs_effect_create_from_file` → `obs_leave_graphics()`。**"滤镜要在 graphics 上下文里创建/销毁 GPU 资源"这个约束的最短示范** |
| `sync-async-source.c` | 142 | **音视频同步自检源**：一条线程同时产出画面与音调，两者时间戳严格对应。用来验证 libobs 的 async 帧缓冲有没有把音视频对齐弄错 |
| `sync-audio-buffering.c` | 193 | 同上，但**故意让音频缓冲量变化**：7 个音阶（`aud_rates[]`:16-24，A→D#）配 7 级灰度（`vid_colors[]`:29-37），一眼能看出"第几个音配第几个灰度"错位了没有。`buffer_audio` 标志控制是否走缓冲路径 |
| `sync-pair-vid.c` + `sync-pair-aud.c` | 133 + 134 | **两个独立源组成的同步测试对**：视频源黑白交替闪（`starting_time` 是 `sync-pair-vid.c:14` 定义的全局，音频源用 `extern` 取它，`sync-pair-aud.c:24`），音频源只在"奇数秒"发声（`whitelist_time`:26-33）。于是**画面变白的那一秒应该有声、变黑那一秒应该静音**——肉眼+耳朵就能查跨源同步 |
| `data/test.effect` | 37 | 给 `test-filter.c` 用的最小 effect 文件 |
| `data/draw.effect` | 35 | 最小绘制 effect |
| `CMakeLists.txt` | 28 | `ENABLE_TEST_INPUT`（默认 OFF）、`add_library(test-input MODULE)`、只链 `OBS::libobs`、`FOLDER "Tests and Examples"` + `PREFIX ""` |

### 其余（当前不参与主构建）

| 文件 | 行数 | 功能 |
|---|---|---|
| `osx/test.mm` | 186 | **macOS 手写 harness**：不用 Qt，直接 Cocoa 开一个 800×600 `NSWindow`，`obs_startup` → `obs_reset_video`（OpenGL）→ 建一个 `random` 源和一个 scene → `obs_display_create` 挂到 window。开头那个 `OBSUniqueHandle` 模板（:19-27）是用 `std::unique_ptr` 包 libobs 句柄的小技巧。**想在 mac 上跑一个"最小 libobs 宿主"看这个** |
| `osx/CMakeLists.txt` | 18 | 同上的构建定义 |
| `win/test.cpp` | 234 | Windows 版同上（Win32 窗口 + D3D） |
| `win/CMakeLists.txt` | 11 | 同上 |
| `cmocka/test_serializer.c` | 36 | cmocka 单测：`array_output_serializer_init` + 三个 `s_w8` + 校验字节与 `serializer_get_pos` |
| `cmocka/test_darray.c` | 31 | `DARRAY` 的 push_back / num / 内容校验 |
| `cmocka/test_bitstream.c` | 36 | `bitstream_reader`：按 8/1/3/4 位混合读、`r8`/`r16`，**并验证越过 len 后返回 0**（:26） |
| `cmocka/test_os_path.c` | 53 | `os_get_path_extension` 的一堆边界用例（:32-41，`"./\\"`、`"/\\."`、空串…） |
| `cmocka/CMakeLists.txt` | 30 | 四个 `add_executable` + `add_test`，需要 `find_package(CMocka)` |
| `CMakeLists.txt` | 15 | 上面提到的、当前不可达的调度文件 |

---

## 构建体系（`cmake/` + `build-aux/` + `CMakePresets.json`）

### 顶层入口

| 文件 | 行数 | 角色 |
|---|---|---|
| `CMakeLists.txt` | 37 | **极薄**：`include(cmake/common/bootstrap.cmake)`（:3，这一行就把版本号、OS 判定、模块路径全部准备好）→ `project(obs-studio VERSION ${OBS_VERSION_CANONICAL})`（:5）→ `include(compilerconfig/defaults/helpers)`（:14-16，**注意这三个名字会按 OS 解析到 `cmake/macos/` 或 `cmake/windows/` 或 `cmake/linux/` 下的同名文件**）→ 三个 option（`ENABLE_FRONTEND`/`ENABLE_SCRIPTING`/`ENABLE_HEVC`，:18-20）→ 按平台 `add_subdirectory` 各渲染后端 → `plugins` → `test/test-input` → `frontend` → `message_configuration()` |
| `CMakePresets.json` | 233 | 见下方预设清单 |

### `cmake/common/`　平台无关的公共模块

| 文件 | 行数 | 角色 |
|---|---|---|
| `bootstrap.cmake` | 82 | **一切的起点**：设置 `CMAKE_MAP_IMPORTED_CONFIG_*`（:7-13，让 RelWithDebInfo 能回落到 Release 的预编译依赖）、然后 include `versionconfig` / `buildnumber` / `osconfig` / `policies` / `ccache` |
| `osconfig.cmake` | 20 | 按 `CMAKE_HOST_SYSTEM_NAME` 设 `OS_WINDOWS`/`OS_MACOS`/`OS_LINUX` 并把对应的 `cmake/<os>/` 追加到 `CMAKE_MODULE_PATH`（三个 OS 分支各一行 `list(APPEND CMAKE_MODULE_PATH ...)`：Windows :8、**macOS :13**、Linux/BSD :17）——这就是 `include(defaults)` 能解析到平台版的原因 |
| `versionconfig.cmake` | 79 | 用 `git describe --always --tags --dirty=-modified`（:11-12）推导版本号，失败则用默认值；产出 `OBS_VERSION` / `OBS_VERSION_CANONICAL` |
| `buildnumber.cmake` | 26 | 维护 `cmake/.CMakeBuildNumber` 这个纯数字文件，每次配置递增，喂给 macOS 的 `CURRENT_PROJECT_VERSION` |
| `buildspec_common.cmake` | 200 | **预编译依赖的下载与校验**：`_check_deps_version`（:6）先看 `CMAKE_PREFIX_PATH` 下有没有 `share/obs-deps/VERSION`，没有就按 `CMakePresets.json` 的 `vendor` 段（版本号 + SHA256）去 GitHub Releases 下 tarball 并解压 |
| `compiler_common.cmake` | 125 | **C17 + C++17**（:9-12）、一大串通用警告开关、`OBS_COMPILE_DEPRECATION_AS_WARNING` option（:5） |
| `helpers_common.cmake` | 506 | 本目录最大：`message_configuration`（:6，配置结束时打印 feature summary）、`target_enable_feature`/`target_disable_feature`（各处 `return()` 时用它标记"这个功能没编"）、以及一堆目标属性/安装辅助函数 |
| `cpackconfig_common.cmake` | 14 | CPack 公共变量（包名、vendor、SHA256 校验） |
| `ccache.cmake` | 25 | 自动发现 ccache 并挂到 `CMAKE_<LANG>_COMPILER_LAUNCHER` |
| `policies.cmake` | 3 | 目前只有 `include_guard`——CMake 策略清空后留下的空壳 |

### `cmake/macos/`　macOS 专属（**5 个 `.cmake` + 3 个打包资源，你要看的就这些**）

| 文件 | 行数 | 角色 |
|---|---|---|
| `compilerconfig.cmake` | 108 | **第 9-11 行硬性要求：`if(NOT XCODE) message(FATAL_ERROR "Building OBS Studio on macOS requires Xcode generator.")`**——mac 上不能用 Ninja/Makefile 生成器。:12 `enable_language(Swift)`（前端有 Swift 代码）。另有 `ENABLE_COMPILER_TRACE` option（:5，clang `-ftime-trace`） |
| `defaults.cmake` | 51 | 签名默认值（无团队则 ad-hoc 身份 `"-"`，:6-13）；include `xcode` + `buildspec`；**给 SWIG 设 `SWIG_LIB` 环境变量**（:22-27，因为 obs-deps 里的 swig 是可重定位的）；RPATH 全套（:31-38，安装后为 `@executable_path/../Frameworks`）；**`CMAKE_IGNORE_PREFIX_PATH` 屏蔽 `/opt/homebrew` 和 `/usr/local`**（:40）——防止 Homebrew 里的库污染构建，这条很关键 |
| `xcode.cmake` | 165 | 集中设置 `CMAKE_XCODE_ATTRIBUTE_*`：项目版本号、`DYLIB_COMPATIBILITY_VERSION`、部署目标、以及生成 scheme（:5） |
| `helpers.cmake` | 464 | macOS 打包主体：`set_target_xcode_properties`（:8）、bundle 组装、插件安装到 `.app/Contents/PlugIns`、`codesign`/`notarize` 相关 |
| `buildspec.cmake` | 30 | `_check_dependencies_macos`（:7）：架构固定 `universal`，下载 `prebuilt` + `qt6` + `cef` 三个 tarball 到 `.deps/`，**解压后 `xattr -r -d com.apple.quarantine`**（:23-26，不然 Gatekeeper 会拦下来） |
| `resources/AppIcon.icns` / `background.tiff` / `package.applescript` | — | 应用图标、DMG 背景图、DMG 布局脚本（被 `defaults.cmake:47-51` configure 到构建目录） |

`cmake/linux/`（8 个）与 `cmake/windows/`（8 个）是对应的平台实现，`cmake/finders/`（32 个 `FindXxx.cmake`）是各种可选依赖的查找模块（`FindFFmpeg`、`FindLuajit`、`FindLibsrt`、`FindSIMDe`、`FindUthash`…），`cmake/bundle/windows/` 是 Windows 打包资源。

### `build-aux/`　格式化脚本 + Flatpak + Steam

`README.md` 自己列清了（:3-11）：格式化脚本、Flatpak manifest、Steam 打包文件。

| 文件 | 角色 |
|---|---|
| `.run-format.zsh` | **一个脚本三个身份**：`run-clang-format`、`run-gersemi`、`run-swift-format` 都是指向它的**符号链接**（`ls -la` 可见），脚本按 `$0` 决定跑哪个格式化器。要求 zsh ≥ 5.2（:19-22）。clang-format 版本必须精确匹配，OBS 提供了自己的 Homebrew formula |
| `.functions/` | 8 个 zsh 自动加载函数（`log_info`/`log_error`/`log_group`/`set_loglevel`…），日志输出的公共实现 |
| `com.obsproject.Studio.json` | **Flatpak manifest**（Linux 打包）：runtime `org.freedesktop.Platform` 25.08（:3-4）、权限清单 `finish-args`（:7-21，wayland/pulseaudio/pipewire/网络…）、插件扩展点 `com.obsproject.Studio.Plugin`（:23-31） |
| `format-manifest.py` | 格式化上面那个 JSON（`python3 build-aux/format-manifest.py com.obsproject.Studio.json`） |
| `steam/obs_build.vdf` / `obs_playtest_build.vdf` / `scripts_macos/launch.sh` / `scripts_windows/*.bat` | Steam 发布用的构建描述与安装脚本 |

### `build_macos/`　**不是源码目录**

`build_macos/` 是被忽略的构建产物（`git check-ignore -v build_macos` 命中 `.gitignore:2` 的 `/*` 全量排除规则），里面只有 `CMakeCache.txt`、`CMakeFiles/`、`.cmake/api/` 这些生成物。
原因：`CMakePresets.json` 的 `macos` 预设把 `binaryDir` 设成 `${sourceDir}/build_macos`——**它是 macOS 预设的默认构建输出目录**，出现在你的工作副本里只是因为有人在这台机器上配置过一次（且当前那两个 `error-*.json` 说明配置失败过）。可以随时整个删掉。

### `CMakePresets.json` 预设清单

版本 8。两类预设：

**configurePresets（10 个，2 个隐藏）**

| 名字 | 说明 |
|---|---|
| `environmentVars`（hidden） | 只干一件事：把 `TWITCH_CLIENTID`/`RESTREAM_*`/`YOUTUBE_*` 等 OAuth 密钥从**进程环境变量**（`$penv{}`）搬进 cache 变量 |
| `dependencies`（hidden） | **预编译依赖的清单**：`vendor.obsproject.com/obs-studio.dependencies` 下写明 `prebuilt`(obs-deps) / `qt6` / `cef` 的版本（本 commit 为 `2026-06-25`，CEF `6533`）、baseUrl、以及每个平台切片的 **SHA256**；`tools.sparkle` 2.9.2（macOS 自动更新框架） |
| `macos` | **macOS 默认**：`generator: Xcode`、`binaryDir: ${sourceDir}/build_macos`、`CMAKE_OSX_DEPLOYMENT_TARGET=12.0`、签名三件套从 `CODESIGN_IDENT`/`CODESIGN_TEAM`/`PROVISIONING_PROFILE` 环境变量取、虚拟摄像头三个 UUID、Sparkle appcast URL/公钥、`ENABLE_BROWSER=true`。**condition 限定 `hostSystemName == Darwin`**。单架构（描述里写明 "single architecture only"） |
| `macos-ci` | 继承 `macos`，额外 `CMAKE_COMPILE_WARNING_AS_ERROR=true` + 开 Xcode 编译缓存 + 打开 dev/deprecated 警告 |
| `ubuntu` / `ubuntu-ci` | Ninja 生成器 |
| `windows-x64` / `windows-ci-x64` / `windows-arm64` / `windows-ci-arm64` | `Visual Studio 18 2026` 生成器 |

**buildPresets（2 个）**：只有 `windows-x64`、`windows-arm64`。**macOS 没有 build preset**——因为 mac 走 Xcode，构建用 `xcodebuild`（见下）。

### macOS 从零编译（实测命令）

以下全部从仓库文件查证，不是我编的：

**前置**（`.github/scripts/utils.zsh/check_macos`）：macOS ≥ 12.0（:7-12）、Homebrew（:15-19），然后按 `.github/scripts/.Brewfile` 装 4 个工具：
```bash
brew install cmake git jq xcbeautify
```
（Xcode 本体是硬要求，因为 `cmake/macos/compilerconfig.cmake:9-11` 强制 Xcode 生成器。）

**配置**（依赖会自动下载到 `.deps/`，无需手动准备）：
```bash
cd /path/to/obs-studio
cmake --preset macos
# → 生成 build_macos/obs-studio.xcodeproj
```

**构建**——CI 用的就是这条（`.github/scripts/.build.zsh:152-160`，默认 config 为 `RelWithDebInfo`，见 :56）：
```bash
xcodebuild ONLY_ACTIVE_ARCH=NO \
  -project build_macos/obs-studio.xcodeproj \
  -target obs-studio \
  -destination "generic/platform=macOS,name=Any Mac" \
  -configuration RelWithDebInfo \
  -parallelizeTargets -hideShellScriptEnvironment \
  build
```
（CI 里执行 `xcodebuild` 前已 `pushd ${project_root}`，且它用的 `-project obs-studio.xcodeproj` 是相对 binaryDir 的；本地最省事的等价写法是 `cmake --build build_macos --config RelWithDebInfo`，或者直接打开 `build_macos/obs-studio.xcodeproj` 按 ⌘B。）

**指定架构**（CI 传的是 `-DCMAKE_OSX_ARCHITECTURES`，`.build.zsh:121-124`）：
```bash
cmake --preset macos -DCMAKE_OSX_ARCHITECTURES=arm64
```

**要编测试源插件**就再加 `-DENABLE_TEST_INPUT=ON`（`test/test-input/CMakeLists.txt:3`）。

**注意**：`cmake --build --preset macos` **不存在**（macOS 没有 buildPreset）；`README.rst:35` 把官方安装说明指向 Wiki（https://github.com/obsproject/obs-studio/wiki/Install-Instructions），仓库里没有本地版编译文档。

---

## docs/　Sphinx 官方文档源码

**在线地址**：https://obsproject.com/docs （`README.rst:38-39`、`:58-59` 两处写明"Developer/API documentation"就是这个地址）。

构建方式：`docs/sphinx/` 下 `make html`（`Makefile` 是 sphinx-quickstart 生成的极简版，:17-20 把所有目标转发给 `sphinx-build -M`）。依赖只两个（`requirements.txt`）：`sphinx>=1.3`、`sphinx_rtd_theme>=0.5.2`。
`conf.py:34-42` 开的扩展：autodoc / coverage / viewcode / napoleon / rtd_theme / autosectionlabel / extlinks；`primary_domain = 'c'`（:53）——**整份文档是手写的 C domain 指令，不是从头文件自动抽取的**，所以改了 API 记得手动同步 .rst。

组织结构（`index.rst` 的两个 toctree）：

**Core Concepts（先读这五篇）**

| .rst | 行数 | 对应哪块 |
|---|---|---|
| `backend-design.rst` | 194 | libobs 整体架构：源/输出/编码器/服务四类对象、视频与音频两条管线怎么走。**全仓库最该先读的一篇** |
| `plugins.rst` | 571 | 写插件：模块加载、`obs_source_info`/`obs_output_info`/`obs_encoder_info` 各字段含义 |
| `frontends.rst` | 252 | 写前端：怎么用 libobs 从零搭一个宿主程序 |
| `graphics.rst` | 365 | 图形子系统与 effect 语法 |
| `scripting.rst` | 336 | Lua/Python 脚本 API（对应本篇的 `shared/obs-scripting/`） |

**API Reference（按目录一一对应）**

| .rst | 行数 | 对应源码 |
|---|---|---|
| `reference-core.rst` | 954 | `libobs/obs.h` 全局 API（`obs_startup`/`obs_reset_video`/`obs_get_video` 等） |
| `reference-core-objects.rst` | 13 | 只是把下面几篇聚合的目录页 |
| `reference-sources.rst` | 2001 | `libobs/obs-source.h`（**最大的一篇**） |
| `reference-scenes.rst` | 772 | `libobs/obs-scene.h` |
| `reference-outputs.rst` | 1041 | `libobs/obs-output.h` |
| `reference-encoders.rst` | 620 | `libobs/obs-encoder.h` |
| `reference-services.rst` | 376 | `libobs/obs-service.h` |
| `reference-properties.rst` | 846 | `libobs/obs-properties.h`（**本篇 `properties-view` 渲染的就是它**） |
| `reference-settings.rst` | 349 | `libobs/obs-data.h` |
| `reference-canvases.rst` | 302 | 多画布 API（较新） |
| `reference-modules.rst` | 382 | `libobs/obs-module.h` |
| `reference-frontend-api.rst` | 987 | `frontend/api/obs-frontend-api.h` |
| `reference-libobs-callback.rst` | 305 | `libobs/callback/`（signal/proc/calldata） |
| `reference-libobs-graphics*.rst` | 17 + 11 篇 | `libobs/graphics/`：`-graphics`(1695) 是主篇，其余按数学类型分（`vec2`/`vec3`/`vec4`/`quat`/`matrix4`/`axisang`/`math`）+ `effects`(409) + `image-file`(71) |
| `reference-libobs-media-io.rst` | 527 | `libobs/media-io/`（对应本系列 03 篇） |
| `reference-libobs-util*.rst` | 18 + 11 篇 | `libobs/util/`：`platform`(507) / `dstr`(513) / `config-file`(389) / `darray`(334) / `profiler`(327) / `serializers`(224) / `threading`(217) / `deque`(160) / `source-profiler`(91) / `base`(76) / `bmem`(62) / `text-lookup`(58) |

`_static/css/custom.css` 是主题微调；`_build/`、`_templates/`、`_static/` 里各有一个 `.gitignore` 占位。
**注意 `docs/` 完全不参与 CMake 构建**——它是独立的文档工程。

---

## 顶层杂项

| 文件 | 行数 | 内容 |
|---|---|---|
| `README.rst` | 79 | 项目简介 + 全部官方链接（官网 / Wiki / 论坛 / **构建说明 Wiki** / **API 文档 https://obsproject.com/docs** / 捐赠 / issue tracker）+ 贡献指引 + 末尾 PVS-Studio 静态分析致谢 |
| `CODESTYLE.md` | 425 | **代码风格规范**：制表符缩进、K&R 大括号、命名（`snake_case` for C、`CamelCase` for C++ 类）、注释、以及"提交前跑 `build-aux/run-clang-format`"。你若要向 OBS 提 PR 必读；即使不提 PR，第 1 节的命名与文件组织约定值得参考 |
| `CONTRIBUTING.md` | 123 | 贡献流程：commit message 格式（`<模块>: <一句话>`，OBS 这条规矩很严）、分支策略、PR 要求 |
| `COPYING` | 339 | **GNU GPL v2 全文**（OBS 主体许可） |
| `COMMITMENT` | 46 | **GPL Cooperation Commitment**：承诺在起诉 GPL 违规前给 30/60 天补救期（Red Hat 等公司发起的那份声明） |
| `AUTHORS` | 2894 | 贡献者名单（一行一人） |
| `COC.rst` | 153 | 行为准则（Contributor Covenant 变体） |
| `SECURITY.md` | 70 | 安全漏洞报告流程与支持版本策略 |
| `INSTALL` | 1 | **只有一行**，指向 Wiki 的 Install-Instructions |
| `additional_install_files/` | 13 个空目录 | `exec32/exec64/libs32/libs64/data/misc` 及其 `d`/`r` 变体——Windows 打包时"往安装包里额外塞文件"的挂载点，仓库里是空的 |
| `.clang-format` / `.gersemirc` / `.swift-format` / `.editorconfig` | — | 三种语言的格式化配置 + 编辑器配置。`shared/` 和 `deps/*` 下还各有自己的 `.clang-format` 覆盖 |
| `.git-blame-ignore-revs` | — | 大规模格式化提交的哈希列表，`git blame --ignore-revs-file` 用它跳过噪声 |
| `.gitmodules` | — | submodule 声明（`deps/libdshowcapture` 那条链） |
| `.cirrus.yml` | — | Cirrus CI 配置（FreeBSD 构建） |
| `.github/` | — | GitHub Actions：`scripts/.build.zsh`（三平台构建脚本，macOS 段在 :118-175）、`scripts/utils.zsh/`（辅助函数）、`scripts/.Brewfile`（mac 前置工具） |

---

## 阅读建议

1. **本篇只有一块是"必须逐行读"的：`shared/media-playback/`**（`media.c` 1052 + `decode.c` 421 = 1473 行）。
   顺序建议：先读 `media.h:41-106`（66 行的 `struct mp_media`，读完就有全局地图）→ `media.c:740-833`（主循环 94 行）→ `media.c:498-617`（节流三函数）→ `media.c:520-596`（seek + reset）→ 最后 `decode.c` 全文。
   **一个下午能读完，而它覆盖了你待办清单里的音频通路、暂停、seek、循环四项。**
2. **对照你现有实现时，重点关注三处认知差**：
   ① OBS 是**单线程**（拆包+解码+节流+输出全在一条线程），靠"每轮必备好两路各一帧"（`mp_media_ready_to_start`:195）保证音视频同步，seek 时因此不需要 epoch 世代号；
   ② 节流是**绝对基准累加**（`next_ns += delta`）而不是每帧 sleep 帧间隔，且**睡眠切成 200ms 片**（:609-611）来换命令响应速度；
   ③ loop 时 **`base_ts` 累加 + `play_sys_ts` 绝不重锚**（:563 与 :578 的守卫），且要补 `next_ns += offset`（:581）把最后一帧的 duration 算进去——这一条是你之前踩出来但 OBS 用两行代码解决的。
3. **`closest-format.h`（117 行）建议直接拿走**：一张纯 switch 表，把 FFmpeg 可能吐出的任何像素格式折成你的渲染器支持的少数几种。你现在 P010/10-bit 那套试错（记忆里的"10-bit HEVC 被当 BGRA 绑定"）本质上就是缺这张表。`opts-parser.c`（81 行）也可以直接抄，编码器自定义参数输入框迟早要做。
4. **`test/test-input/` 建议现在就扫一遍**（整个目录不到 900 行）：`test-input.c` 23 行是模块骨架，`test-random.c` 是最小异步视频源，`test-sinewave.c` 是最小音频源，`test-filter.c` 是最小滤镜（尤其看它 `obs_enter_graphics()` 的位置）。`sync-pair-vid.c` + `sync-pair-aud.c` 那个"白屏有声/黑屏静音"的自检法子可以直接搬到 WorkLabs 上验证你的音视频同步。
5. **`properties-view.cpp` 只读设计不抄代码**（2423 行，且强绑 Qt）。要抄的是那条思路：**插件只声明 `obs_properties_t`，UI 由框架统一生成**。你现在的设置页是手写 AppKit 控件，等源类型变多后这条会救命。真要动手前先读 `docs/sphinx/reference-properties.rst`（846 行）看属性系统的表达能力边界。
6. **`shared/happy-eyeballs/`（739 行）单独标记一下**：等你做网络拉流源（`WLNetWorkSource`）或者发现 IPv6 环境下推流要卡十几秒时再回来读，它是可以整体移植的 MIT 代码。
7. **可以完全跳过的**：`deps/w32-pthreads`、`deps/libdshowcapture`、`shared/obs-d3d8-api`、`shared/obs-hook-config`、`shared/obs-inject-library`、`shared/obs-shared-memory-queue`、`shared/obs-tiny-nv12-scale`、`shared/ipc-util`、`test/win/`（合计约 4000 个文件，全是 Windows 游戏捕获/虚拟摄像头/DirectShow 包袱）；`shared/obs-scripting/`（3300+ 行，除非你打算做脚本扩展）；`shared/qt/`（你不用 Qt）；`build-aux/steam/` 与 Flatpak manifest。
8. **构建体系只需记住四行**：`cmake --preset macos` → 出 `build_macos/obs-studio.xcodeproj` → `⌘B` 或 `cmake --build build_macos --config RelWithDebInfo`；mac 上**必须 Xcode 生成器**（`cmake/macos/compilerconfig.cmake:9-11` 直接 FATAL_ERROR）；依赖不用手装，`cmake/macos/buildspec.cmake` 会按 `CMakePresets.json` 里的 SHA256 自动下载到 `.deps/` 并去掉 quarantine 属性；`build_macos/` 是被 gitignore 的构建产物目录，随时可删。
