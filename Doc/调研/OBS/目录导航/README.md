# OBS Studio 源码目录导航 · 总索引

> 源码：`/Users/tvum4pro/Documents/github/obs-studio` ｜ 基于 commit `f2db097`（2026-07-09）
> 全仓约 **1900 个源文件、49 万行代码**（其中第三方 vendored 依赖 8 万行，OBS 自有约 41 万行）

这套文档的用途是**把 OBS 源码当地图用**：想学某个机制、想找某个功能实现在哪，先在这里定位到目录和文件，
再点进分篇看那一层的逐文件说明。不是 API 手册，也不是逐行讲解——判断标准是「扫一眼就知道跟我要找的事有没有关系」。

---

## 顶层目录地图

| 目录 | 文件数 | 代码行 | 是什么 |
|---|---|---|---|
| `libobs/` | 240 | 8.8 万 | **内核**。对象模型（源/场景/输出/编码器/服务）+ 渲染与音频节拍主循环 + 图形抽象层 + 基础设施库。整个 OBS 的地基 |
| `plugins/` | 687 | 19 万 | **全部功能实现**。所有采集源、滤镜、转场、编码器、复用/推流、浏览器源、WebSocket 远控都是插件。代码量最大的一块 |
| `frontend/` | 414 | 8.7 万 | **Qt6 桌面界面**。主窗口、预览控件、设置面板、场景/源列表、混音条、投影仪、各类向导 |
| `shared/` | 89 | 2.2 万 | **跨模块共享代码**。其中 `media-playback/` 是媒体文件播放内核（`mp_media_*`），价值最高 |
| `deps/` | 387 | 8 万 | vendored 第三方库（blake2 / glad / json11 / libcaption / libdshowcapture / w32-pthreads），基本不用看 |
| `libobs-metal/` | 35 | 8.4 千 | **Metal 图形后端（全 Swift 写的）**，macOS 用 |
| `libobs-opengl/` | 24 | 8.9 千 | OpenGL 图形后端，含 macOS 的 `gl-cocoa.m` |
| `libobs-d3d11/` | 14 | 7.2 千 | Direct3D 11 图形后端，Windows 用 |
| `libobs-winrt/` | 4 | 711 | Windows.Graphics.Capture 封装 |
| `test/` | 16 | 1.5 千 | 测试与**最小插件示例**（写自己的源/滤镜时可照抄的骨架）。注意 cmocka 单测与 `test/osx`、`test/win` 在当前构建图里不可达，根 CMakeLists 只 `add_subdirectory(test/test-input)` |
| `docs/` | 44 | — | Sphinx 官方 API 文档源码（在线版 https://obsproject.com/docs） |
| `cmake/` `build-aux/` | — | — | 构建体系：依赖查找、平台配置、打包（`build_macos/` 不是源码目录，是 `macos` 预设的输出目录，被 gitignore，可随时删） |

> 文件数的统计口径是源文件（`.c/.cpp/.h/.hpp/.m/.mm/.swift/.metal/.effect/.ui/.rst`），
> 不含 CMake、JSON、图标、本地化 `.ini` 等——所以某些插件的"总文件数"会比这里的数字大。

一句话概括三层关系：**`libobs` 定规矩（对象模型 + 节拍），`plugins` 干活（每个具体功能一个插件），`frontend` 摆界面（Qt 调 libobs 的公开 API）**。
三者互不侵入——插件只 include `libobs/obs-module.h` 那一套公开头文件，frontend 只用 `obs.h` + `frontend/api/obs-frontend-api.h`。

---

## 分篇索引

| 篇 | 覆盖范围 | 什么时候看 |
|---|---|---|
| [01 libobs 内核](01_libobs核心.md) | `libobs/` 顶层 60 个 `.c/.h` + `callback/` + `audio-monitoring/` + `data/` | **最重要的一篇**。想懂源生命周期、场景图、节拍主循环、输出/编码器抽象 |
| [02 libobs/graphics](02_libobs_graphics.md) | `libobs/graphics/`（41 文件） | 想懂图形抽象层 `gs_*`、`.effect` 着色器语言、数学库 |
| [03 libobs/util + media-io](03_libobs_util_media-io.md) | `libobs/util/`（64）+ `libobs/media-io/`（19） | 想找现成轮子（容器/平台抽象/剖析器），或想懂帧总线 `video_output_*`、重采样、格式转换 |
| [04 编码 / 输出 / 服务](04_plugins_编码_输出_服务.md) | `obs-ffmpeg` `obs-outputs` `mac-videotoolbox` `obs-x264` `rtmp-services` 等 | 做录制、推流、编码器接入 |
| [05 源 / 滤镜 / 转场](05_plugins_源_滤镜_转场.md) | `obs-filters`（59）`obs-transitions` `image-source` `obs-text` 等 | 写滤镜或转场；也是「同步源 vs 异步源」的最佳对照 |
| [06 平台采集](06_plugins_平台采集.md) | `mac-*`（摄像头/屏幕/Syphon/虚拟摄像头）、`win-*`、`linux-*` | 做摄像头、屏幕、系统音频采集 |
| [07 硬件 / 浏览器 / 远控 / 工具](07_plugins_硬件_浏览器_远控_工具.md) | `decklink`（113）`aja` `obs-browser` `obs-websocket`（79）`frontend-tools` | 接采集卡、嵌网页、做远程控制 |
| [08 frontend（Qt 界面）](08_frontend_Qt界面.md) | `frontend/` 全部（414 文件） | 做界面；尤其想看预览控件怎么跟 `obs_display` 对接 |
| [09 图形后端](09_图形后端_metal_opengl_d3d11.md) | `libobs-metal` `libobs-opengl` `libobs-d3d11` `libobs-winrt` | 在 macOS 上做 Metal 合成；想懂抽象层怎么绑定后端 |
| [10 shared / deps / 构建 / 测试](10_shared_deps_构建_测试_文档.md) | `shared/`（含 **media-playback**）、`deps/`、`test/`、构建体系、`docs/` | **复刻媒体播放必看**（pts 节流、seek、循环都在这）；也讲怎么在 macOS 上编译 OBS |

---

## 全局速查：我想看 X → 去哪

**内核机制**

| 想看什么 | 去哪 |
|---|---|
| 渲染节拍主循环（一拍里都干了什么） | `libobs/obs-video.c:1161` `obs_graphics_thread` → `:1097` 循环体 → `:32` `tick_sources` → `:94` `render_displays` → `:868` `output_frame` |
| 源怎么提交一帧视频 | `libobs/obs-source.c:3595` `obs_source_output_video` |
| 异步帧缓冲怎么挑帧（fps 不匹配怎么吸收） | `libobs/obs-source.c:4087` `ready_async_frame`，调用点 `:4180` |
| 帧的 owned/borrow 引用契约 | `libobs/obs-source.c:4199` `obs_source_get_frame` / `:4220` `obs_source_release_frame` |
| 多路音频怎么混、时间戳怎么对齐 | `libobs/obs-audio.c:90` `mix_audio`、`:223` `discard_audio`、`:361` `add_audio_buffering` |
| 场景图、源变换（位置/缩放/裁剪/对齐） | `libobs/obs-scene.c`（4143 行，最大的单文件之一） |
| 输出（录制/推流）的通用状态机 | `libobs/obs-output.c` |
| 编码器抽象、一次编码喂多路输出 | `libobs/obs-encoder.c` |
| 插件怎么被加载、`obs_source_info` 怎么注册 | `libobs/obs-module.c`、`libobs/obs-source.h` |
| 属性面板的数据模型（插件声明 UI 的方式） | `libobs/obs-properties.c`，界面渲染在 `shared/properties-view/` |
| 信号/回调总线 | `libobs/callback/` |
| macOS 平台层 | `libobs/obs-cocoa.m`、`libobs/util/platform-cocoa.m`、`libobs/util/apple/`、`libobs/audio-monitoring/osx/` |

**具体功能实现**

| 想看什么 | 去哪 |
|---|---|
| 媒体文件播放（解码线程、pts 节流、seek、循环） | `shared/media-playback/` ← 不在 plugins 里，容易找不到 |
| 媒体源插件外壳（把上面那个包成一个源） | `plugins/obs-ffmpeg/obs-ffmpeg-source.c` |
| macOS 硬件编码 `h264_videotoolbox` | `plugins/mac-videotoolbox/` |
| mp4 录制复用 | `plugins/obs-ffmpeg/obs-ffmpeg-mux.c` + 独立子进程 `ffmpeg-mux/` |
| RTMP 推流与拥塞丢帧策略 | `plugins/obs-outputs/rtmp-stream.c`、`flv-mux.c` |
| 摄像头采集（macOS） | `plugins/mac-avcapture/` |
| 屏幕/窗口采集（macOS，ScreenCaptureKit） | `plugins/mac-capture/` |
| 系统音频采集（macOS） | `plugins/mac-capture/` 的音频部分 |
| 虚拟摄像头（macOS） | `plugins/mac-virtualcam/` |
| 内置滤镜（色键/裁剪/降噪/压缩器…） | `plugins/obs-filters/` |
| 转场 | `plugins/obs-transitions/` |
| 图片源（同步源的典型代表） | `plugins/image-source/` |
| 浏览器源（CEF） | `plugins/obs-browser/` |
| WebSocket 远程控制协议 | `plugins/obs-websocket/` |

**界面与图形**

| 想看什么 | 去哪 |
|---|---|
| 主窗口（新版已拆成 25 个文件） | `frontend/widgets/OBSBasic.cpp` + `OBSBasic_*.cpp`（`_Streaming` `_Recording` `_Scenes` `_Preview` …按功能分片） |
| 预览控件（拖拽/缩放源） | `frontend/widgets/OBSBasicPreview.cpp` |
| Qt 窗口怎么变成 `obs_display` | `frontend/widgets/OBSQTDisplay.cpp` |
| 给插件用的 frontend API | `frontend/api/obs-frontend-api.h` |
| 图形抽象层（`gs_*` 调用如何转发到后端） | `libobs/graphics/graphics.c`、绑定机制在 `graphics-imports.c` |
| `.effect` 着色器语言的解析器 | `libobs/graphics/effect-parser.c`（1972 行） |
| Metal 后端 / CVPixelBuffer → MTLTexture | `libobs-metal/`（Swift），特别是纹理与 `CVPixelFormat+Extensions.swift` |

---

## OBS 的五条主干（读源码的推荐切入顺序）

想快速建立整体直觉，按这五条主干走一遍比乱翻目录高效得多。

1. **启动与对象模型** — `obs.c`（3483 行）建起全局核心：图形子系统、视频/音频输出总线、源列表、模块加载。
   把 `obs_startup` → `obs_reset_video` → `obs_load_all_modules` 这条线读完，就知道 OBS 的「地基」长什么样。

2. **一帧的生命** — 源提交帧（`obs_source_output_video`）→ 进异步帧缓冲 → 节拍线程按时挑帧（`ready_async_frame`）
   → 合成（`render_displays` / `output_frame`）→ 下载回内存 → 走 `video_output_*` 帧总线分发给编码器。
   **这条线是 OBS 的心脏**，也是任何 OBS-like 项目最先要抄对的东西。

3. **一个插件是怎么接进来的** — 从 `test/test-input/` 的最小示例开始，看 `obs_source_info` 结构体的每个回调何时被调，
   再回到 `libobs/obs-module.c` 看加载流程。看完就能写自己的源和滤镜了。

4. **音频侧** — 音频不跟视频共用节拍：源把 PCM 交给 `obs_source_output_audio`，
   `obs-audio.c` 按时间戳窗口把多路对齐、混音、必要时动态加缓冲（`add_audio_buffering`）。
   音视频同步就是在这里靠时间戳而不是靠等待达成的。

5. **输出侧** — `obs-encoder.c` 一次编码 → 多路输出复用（这是 OBS 能「边录边播」而不双倍编码开销的关键）
   → `plugins/obs-ffmpeg`（mp4）和 `plugins/obs-outputs`（rtmp）各自复用同一份编码包。

---

## 与 WorkOBS / libwl 的对应关系

正在复刻的 `WorkOBS/OBSLabs/libwl/` 与 OBS 的对照（便于「我这块要抄哪个文件」）：

| libwl | OBS 对应 | 已复刻到什么程度 |
|---|---|---|
| `core/WLCore` | `libobs/obs.c` + `obs-internal.h` | 全局核心 + 源列表 + 一把锁，已有 startup/shutdown 幂等 |
| `source/WLSource` + `WLSourceProtocol` | `libobs/obs-source.c` + `obs-source.h` 的 `obs_source_info` | 已复刻壳+协议三元结构、异步帧缓冲、drop-oldest、追赶挑帧、`get_frame` owned 契约 |
| `graphics/WLGraphics` | `libobs/obs-video.c` 的 `obs_graphics_thread` | 已复刻节拍骨架（绝对时刻 sleep + 补帧计数）+ per-source push；**尚无真合成**（对应 `render_displays`/`output_frame` 是 M3） |
| `source/WLMediaSource` + `WLDecoder` | `shared/media-playback/`（不是 `plugins/obs-ffmpeg`！） | 视频解码 + pts 绝对基准节流已复刻；**音频、pause、seek、loop 待做**（M1 收尾） |
| `WLTime` | `libobs/util/platform.h` 的时钟函数 | 已复刻单调钟 |
| 待建：编码器 + 复用 | `libobs/obs-encoder.c` + `plugins/obs-ffmpeg/obs-ffmpeg-mux.c` | M2 |
| 待建：Metal 合成 | `libobs/graphics/` + `libobs-metal/` | M3 |
| 待建：混音 | `libobs/obs-audio.c` | M4 |
| 待建：推流 | `plugins/obs-outputs/` | M5 |

按 `WorkOBS/Doc/ToDo.md` 的任务编号开工时，对应该读的 OBS 代码：
**A 系列（音频）** → `shared/media-playback/` 的音频解码路径 + `libobs/obs-source.c` 的 `obs_source_output_audio`；
**P/S/L（暂停/seek/循环）** → 全在 `shared/media-playback/`。

### 本轮扫描挖出的、会影响实现决策的几条

按优先级排，细节和行号在对应分篇里：

1. **OBS 的媒体播放是单线程的**（`media.c:866` 唯一一个 `pthread_create`，拆包/解码/节流/输出全在一个 `for(;;)` 里串行）。
   直接后果：**seek 不需要 epoch 世代号**——没有第二个帧持有者，`mp_decode_flush` 一调就干净。
   epoch 是为多线程流水线付的税；WorkOBS 若走单线程串行，这笔税可以省。详见 [10 篇](10_shared_deps_构建_测试_文档.md)。
2. **"可中断 sleep" 的最简解法是睡眠分片**：`mp_media_sleep` 一次最多睡 200ms，超时就跳过本轮输出。
   不用条件变量、不用 pipe 自唤醒，纯靠拆短长睡来换 stop/seek/pause 的响应速度。
3. **loop 的时间线摊平除了 `base_ts += next_ts`，还要 `next_ns += offset`**——把最后一帧没被累加的 duration 补回去，
   否则循环点会短掉一帧的显示时长。这是只有读源码才会发现的细节。
4. **macOS 上图形线程每一拍要单独套 `@autoreleasepool`**：OBS 为此专门把那一拍挪进 `obs-cocoa.m:190`
   导出 `obs_graphics_thread_loop_autorelease`，由 `obs-video.c:1191` 在 `__APPLE__` 下调用。
   不这么做，Metal/CoreVideo 对象会攒到线程退出才释放。详见 [01 篇](01_libobs核心.md)。
5. **OBS 的 Metal 后端不支持多平面 IOSurface**（`plane` 硬编码 0，格式表无任何 YUV），且 **macOS 默认仍跑 OpenGL**
   （`frontend/OBSApp.cpp:308` 注释：等 Metal 达到生产质量再切）。当参考架构可以，当"生产验证过的成熟设计"要打折。详见 [09 篇](09_图形后端_metal_opengl_d3d11.md)。
6. **CFR 靠"帧带 count 重复投递"而不是丢时间戳**：`video_sleep` 掉拍时把 `{timestamp, count}` 入队，
   出帧时同一帧投 count 次、`lagged_frames += count-1` 只作统计。时间戳由节拍产生，内容可以重复。
7. **重采样必须补时间戳偏移**：`swr_get_delay()` 取纳秒级内部延迟，调用方做 `timestamp -= offset`
   （`audio-resampler-ffmpeg.c:194` → `audio-io.c:101`）。漏了会慢慢跑偏。详见 [03 篇](03_libobs_util_media-io.md)。
8. **帧总线的扇出在编码之前**：`video_output_*` 一份合成帧 → N 个下游，每个自带 scaler 和 `frame_rate_divisor` 分频，
   所以能"录 1080p60 + 推 720p30"。WorkLabs 现在是编码之后才扇出给 recorder/pusher，能力上是两回事。

---

## 其它

- 同目录下的其它文档是**专题深挖**（线程模型、异步帧缓冲、tick 与混音、输出侧、macOS 全景等），
  这套「目录导航」是它们的**索引层**：先在这里定位，再去专题文档看细节。
- 文档基于 commit `f2db097`（2026-07-09）。OBS 主干在动，行号可能漂移——找不到时用函数名 grep，不要迷信行号。
- 行数与文件数都是 `wc -l` / `find` 实测值，不是估算。
