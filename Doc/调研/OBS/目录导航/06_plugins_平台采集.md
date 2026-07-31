# OBS 目录导航 · plugins 平台采集（摄像头 / 屏幕 / 系统音频 / 虚拟摄像头）

> 源码范围：`plugins/mac-avcapture`、`plugins/mac-capture`、`plugins/mac-syphon`、`plugins/mac-virtualcam`、
> `plugins/win-capture`、`plugins/win-dshow`、`plugins/win-wasapi`、`plugins/linux-capture`、`plugins/linux-v4l2`、
> `plugins/linux-pipewire`、`plugins/linux-pulseaudio`、`plugins/linux-alsa`、`plugins/linux-jack`、`plugins/oss-audio`、
> `plugins/sndio` ｜ 源文件 165 个（`.c/.h/.cpp/.hpp/.m/.mm/.swift`，不计 `data/locale/`，也不计各插件目录之外的
> vendored 依赖如 `deps/libdshowcapture`） ｜ 基于 obs-studio commit `f2db097`（2026-07-09）
> 返回总索引：[README.md](README.md)

## 本篇速查

想找什么 → 去哪：

| 我想看… | 去这里 |
|---|---|
| macOS 摄像头怎么用 AVFoundation 拿帧、格式协商在哪 | [`OBSAVCapture.m`](#obsavcapturem) |
| "旧管线直接吐帧" vs "IOSurface 直通纹理"两条路的取舍 | [`OBSAVCapture.m`](#obsavcapturem)、[`plugin-main.m`](#mac-avcapture) |
| macOS 屏幕/窗口/应用三种采集模式分别在哪个文件 | [`mac-sck-video-capture.m`](#mac-sck-video-capturem) |
| ScreenCaptureKit（新）跟旧 CGDisplayStream/CGWindowListCreateImage（旧）是什么关系 | [mac-capture/ 分组说明](#mac-capture) |
| macOS 系统音频/麦克风走的是什么 API，设备变更怎么处理 | [`mac-audio.c`](#mac-audioc) |
| macOS 虚拟摄像头"两半结构"（OBS 插件侧 + 系统侧）怎么分工 | [mac-virtualcam/ 分组说明](#mac-virtualcam) |
| Windows 窗口捕获注入去哪个文件 | [win-capture/ 分组说明](#win-capture) |
| Windows 屏幕捕获两套实现（Desktop Duplication vs 老 GDI）怎么切换 | [win-capture/ 分组说明](#win-capture) |
| Linux X11 vs Wayland 采集怎么分流 | [linux-capture/ 分组说明](#linux-capture)、[linux-pipewire/ 分组说明](#linux-pipewire) |
| Linux 有哪几种音频后端（PulseAudio/ALSA/JACK/OSS/sndio） | [Linux 音频分组](#linux-pulseaudio) |

---

## 一句话职责

这一篇覆盖 OBS 里**跟操作系统打交道最深**的一批插件：摄像头/麦克风采集、屏幕与窗口捕获、系统音频回环、虚拟摄像头输出。
它们都通过 `obs_source_info`（采集类）或 `obs_output_info`（虚拟摄像头输出类）接入 `libobs`，但内部实现清一色是各平台私有
API（AVFoundation/ScreenCaptureKit/CoreAudio、DXGI/WGC/DirectShow/WASAPI、V4L2/PipeWire/X11/PulseAudio……），
彼此之间没有共享代码——这也是为什么它们被拆成十几个平台专属插件目录，而不是一个跨平台源文件。三大平台有个共同套路反复出现：
**同一个功能有新旧两套实现，`obs_module_load` 里按系统版本/渲染后端运行时二选一注册**（macOS：SCK vs legacy；
Windows：Desktop Duplication vs GDI；Linux：X11 vs Wayland-PipeWire）——读这一篇时留意这个模式，比记住每个 API 细节更重要。

---

## macOS

macOS 上的采集源分四类，各自一个插件目录：**摄像头/麦克风一体的 AVFoundation 采集**（`mac-avcapture/`）、
**屏幕/窗口/应用画面 + 系统音频回环**（`mac-capture/`，新旧两套 API 并存）、**图形共享协议 Syphon**（`mac-syphon/`，
接收其他跑在同一台 Mac 上的图形 App 直接共享的纹理）、**虚拟摄像头输出**（`mac-virtualcam/`，把 OBS 合成结果伪装成一个
系统摄像头设备，供 Zoom/腾讯会议等第三方 App 选用）。下面四组是本篇重点，逐文件展开。

### mac-avcapture　`plugins/mac-avcapture/`

**职责**：基于 **AVFoundation**（`AVCaptureSession` + `AVCaptureVideoDataOutput`/`AVCaptureAudioDataOutput`）的摄像头
（含内建麦克风）采集源。**没有 Swift 文件**——整个目录纯 ObjC（`.m`），题目里提到的"Swift 与 ObjC 混编"实际发生在
`mac-virtualcam/`（下文），这里先澄清一下避免误解。

模块里同时存在**新旧两代实现**，各自独立注册、`.id` 不同、互不冲突：

- `legacy/av-capture.mm`（C++/ObjC++ 混写）——旧实现，`.id = "av_capture_input"`（:2134），`obs_module_load`
  （:2123）注册时把 v1 标 `OBS_SOURCE_CAP_OBSOLETE | OBS_SOURCE_DEPRECATED`、v2 标 `OBS_SOURCE_DEPRECATED`
  （:2134-2153）——**两个版本都已标记废弃**，只是为了老工程文件还能打开、不炸源，新建摄像头源不会再选到它。
- `OBSAVCapture.m` + `plugin-main.m` + `plugin-properties.m` 等——当前实现，见下方展开。

| 文件 | 行数 | 功能 |
|---|---|---|
| `OBSAVCapture.m` ⭐ | 1523 | AVCaptureSession 生命周期、设备切换、格式协商、帧回调，见下方展开 |
| `OBSAVCapture.h` | 390 | 上面的公开声明（`OBSAVCaptureInfo`/颜色空间等类型别名定义在此） |
| `plugin-main.m` | 325 | 模块入口，注册**两个** `obs_source_info`（普通异步源 + "fast path" 直通纹理源），见下方展开 |
| `plugin-main.h` | 119 | 上面的公开声明（`OBSAVCaptureInfo` C 结构体、错误码枚举等） |
| `plugin-properties.m` | 330 | 属性面板：设备/分辨率/帧率/预设下拉框的构建与联动回调 |
| `plugin-properties.h` | 81 | 上面的公开声明 |
| `AVCaptureDeviceFormat+OBSListable.m` | 163 | 给系统类 `AVCaptureDeviceFormat` 加分类，算出"这个格式在属性列表里怎么排序、怎么显示成一行文字" |
| `AVCaptureDeviceFormat+OBSListable.h` | 26 | 上面的公开声明（分类属性：像素带宽/宽高比/位深/描述字符串） |
| `OBSAVCapturePresetInfo.m` | 25 | 存一份 `AVCaptureSessionPreset` 对应的格式+帧率，供切回预设模式时还原 |
| `OBSAVCapturePresetInfo.h` | 24 | 上面的公开声明 |
| `legacy/av-capture.mm` | 2155 | 旧实现（C++/ObjC++），已全员标记 `OBS_SOURCE_DEPRECATED`，见上方说明 |
| `legacy/left-right.hpp` / `legacy/scope-guard.hpp` | 66 / 63 | 旧实现私有的两个通用 C++ 工具头：无锁读写切换（left-right pattern）+ RAII 作用域退出清理，仅 `av-capture.mm` 使用 |

#### `OBSAVCapture.m`
- **做什么**：整个文件按 `#pragma mark` 分四块。① **Capture Session Handling**（:108 起）——`createSession`
  （:110）建 `AVCaptureSession` + 加设备输入/输出，`switchCaptureDevice`（:193）换设备，`configureSession`
  （:415，**格式协商在这里**）根据用户在属性面板选的分辨率/帧率/像素格式，遍历 `device.formats` 找匹配的
  `AVCaptureDeviceFormat` 并锁定 `activeFormat`/`activeVideoMinFrameDuration`；找不到精确匹配的帧率时会自动
  降级到设备支持的最近帧率（:500-518）。`configureSessionWithPreset`（:354）是另一条路——用户选"使用预设"
  （`AVCaptureSessionPreset`）而不是手选格式时走这条，`updateSessionwithError`（:565）是 `update` 回调的主体，
  决定这次改设置要重建 session 还是仅重配格式。② **AVCapture Delegate Methods**（:1222 起）——
  `captureOutput:didOutputSampleBuffer:fromConnection:`（:1231）是真正拿帧的地方，音视频都从这一个代理方法进来，
  按 `mediaType` 分流处理。
- **关键入口**：`configureSession:`（:415，格式协商）、`captureOutput:didOutputSampleBuffer:fromConnection:`
  （:1231，取帧）、`switchCaptureDevice:withError:`（:193）。
- **看点**：`captureOutput:didOutputSampleBuffer:` 内部按 `_isFastPath` 布尔值（:1259）分两条完全不同的路——
  这是本文件最值得读的地方，见下方"两条取帧路径"的说明。音频侧（:1419 起）比较直白：从 `CMSampleBufferRef`
  里取出 `AudioBufferList`，包成 `obs_source_audio` 用 `obs_source_output_audio` 扔给核心，采样格式/声道数/
  采样率全部从系统给的 `AudioStreamBasicDescription` 现读现填，不写死任何格式假设。

**两条取帧路径（fast path vs 普通路径）**：`plugin-main.m` 的 `obs_module_load`（:287）一次注册两个源：

- `.id = "macos-avcapture"`（:290）——`OBS_SOURCE_ASYNC_VIDEO`，标准异步源。`captureOutput:` 里 `_isFastPath == false`
  分支（:1309）把 `CVPixelBufferRef` 的每个 plane 地址/行距抄进 `obs_source_frame`，`obs_source_output_video`
  （:1410）交给核心走异步帧队列——CPU 侧多一次指针整理，但兼容性最好（任何像素格式、任何下游都能接）。
- `.id = "macos-avcapture-fast"`（:305）——`OBS_SOURCE_VIDEO | OBS_SOURCE_CUSTOM_DRAW`，**自己接管渲染**。
  `captureOutput:` 的 `_isFastPath == true` 分支（:1259）只做一件事：从 `CVPixelBufferRef` 里拿 `IOSurfaceRef`
  （:1273 `CVPixelBufferGetIOSurface`）存起来，**不碰任何像素数据**；真正的纹理导入发生在 `plugin-main.m` 的
  `av_fast_capture_tick`（:145），每帧一次 `gs_texture_create_from_iosurface`（:177）把 IOSurface 直接包装成
  GPU 纹理，`av_fast_capture_render`（:188）画一次——**零拷贝**，代价是只能吃 `BGRA`/`ARGB2101010LEPacked`
  两种像素格式（:1260-1261 的判断），不满足就报错退回让用户切成普通源。这一组"CPU 拷贝兜底 vs IOSurface 直通零拷贝"
  的双轨设计，在下面 `mac-sck-video-capture.m` 里会再看到一次几乎一样的写法。

---

### mac-capture　`plugins/mac-capture/`

**职责**：屏幕/窗口/应用画面捕获 + 系统音频回环，这个目录里**新旧两套 API 并存**，`plugin-main.c`
（:1-35，只有 35 行）是切换枢纽：

```c
if (is_screen_capture_available()) {                 // macOS 12.5+ 才有 ScreenCaptureKit
    obs_register_source(&sck_video_capture_info);     // 新：屏幕/窗口/应用，三合一
    if (__builtin_available(macOS 13.0, *)) {          // SCK 的系统音频回环要到 13.0 才开放
        display_capture_info.output_flags |= OBS_SOURCE_DEPRECATED;   // 旧的三个源打上"已废弃"
        window_capture_info.output_flags  |= OBS_SOURCE_DEPRECATED;
        coreaudio_output_capture_info.output_flags |= OBS_SOURCE_DEPRECATED;
        obs_register_source(&sck_audio_capture_info);  // 新：纯系统音频（不要画面时用这个更省资源）
    }
}
obs_register_source(&display_capture_info);   // 旧：CGDisplayStream 逐显示器截屏，永远注册（macOS 12.5 以下兜底）
obs_register_source(&window_capture_info);    // 旧：CGWindowListCreateImage 轮询截图，同上
obs_register_source(&coreaudio_input_capture_info);   // 麦克风/线路输入，跟 SCK 无关，永远注册
obs_register_source(&coreaudio_output_capture_info);  // 旧系统音频回环方案（借助 Soundflower 类虚拟声卡）
```

也就是说：**六个 `obs_source_info` 永远/条件注册，`.id` 互不相同**（`screen_capture`/`sck_audio_capture`/
`display_capture`/`window_capture`/`coreaudio_input_capture`/`coreaudio_output_capture`），旧的三个只是在新 API
可用时被标个"已废弃"角标，属性面板仍然能选到（兼容旧工程），只是不再是默认推荐项。

**三种采集模式在哪个文件**：display/window/application 三种模式**全部塞在同一个文件** `mac-sck-video-capture.m`
里，靠 `capture_type`（枚举 `ScreenCaptureStreamType`，定义于 `mac-sck-common.h`）在一堆 `switch` 分支里选择走哪条
逻辑，不是三个独立文件——见下方展开。

**系统音频走的是什么 API**：两条路完全不同——`coreaudio_input_capture`/`coreaudio_output_capture`
（`mac-audio.c`）走的是传统 **CoreAudio + AudioUnit**（`kAudioUnitSubType_HALOutput`，见下方展开）；
`sck_audio_capture`（`mac-sck-audio-capture.m`）走的是 **ScreenCaptureKit** 的 `SCStreamConfiguration
setCapturesAudio:YES`（`mac-sck-video-capture.m:217`），跟画面共用同一条 `SCStream`，是系统级"应用/桌面声音"
回环，不需要像旧方案那样依赖 Soundflower/BlackHole 之类的虚拟声卡驱动。

| 文件 | 行数 | 功能 |
|---|---|---|
| `mac-audio.c` ⭐ | 1058 | CoreAudio/AudioUnit 麦克风与系统音频回环，设备热插拔处理，见下方展开 |
| `mac-sck-video-capture.m` ⭐ | 712 | ScreenCaptureKit 画面采集：显示器/窗口/应用三合一，见下方展开 |
| `mac-display-capture.m` | 684 | 旧显示器采集：`CGDisplayStream`，逐帧回调；支持裁剪到某个窗口区域（`CROP_TO_WINDOW`） |
| `mac-sck-common.m` | 352 | SCK 共享层：`ScreenCaptureDelegate`（`SCStreamOutput`/`SCStreamDelegate` 实现）+ 内容列表构建 + 音视频帧分发，被视频/音频两个 SCK 源共用 |
| `mac-sck-audio-capture.m` | 316 | ScreenCaptureKit 纯系统音频源（不采画面），复用 `mac-sck-common.m` 的 `SCStream` 建立逻辑，只是不加视频 output |
| `window-utils.m` | 280 | Cocoa 窗口枚举/查找/跟踪的共享工具（`enumerate_cocoa_windows`/`find_window`/`init_window`），被 `mac-window-capture.m`、`mac-display-capture.m`（裁剪到窗口）、`mac-sck-video-capture.m`（窗口列表）共用 |
| `mac-window-capture.m` | 223 | 旧窗口采集：独立 `capture_thread`（:74）里轮询调用 `CGWindowListCreateImage`（:37，Apple 已标记该 API 未来会移除），截图式而非推流式 |
| `audio-device-enum.c` | 139 | CoreAudio 设备枚举 + 一个很直白的 hack：`device_is_input`（:10）靠**名字里包不包含 "soundflower/wavtap/blackhole/…"** 这类虚拟声卡关键词，把它们强行归类为"输出"设备（因为 macOS 系统 API 本身不区分谁是"系统声音虚拟外放"） |
| `mac-sck-common.h` | 83 | 上面几个 SCK 源共享的 `struct screen_capture`、`ScreenCaptureStreamType`/`ScreenCaptureAudioStreamType` 枚举 |
| `window-utils.h` | 38 | 上面的公开声明（`struct cocoa_window` 定义在此） |
| `audio-device-enum.h` | 36 | 上面的公开声明 |
| `plugin-main.c` | 35 | 模块入口，新旧 API 运行时二选一注册，见上方"职责"说明 |

#### `mac-sck-video-capture.m`
- **做什么**：`init_screen_stream`（:74）是核心——`switch (sc->capture_type)`（:103）按三种模式分别构造
  `SCContentFilter`：`ScreenCaptureDisplayStream`（:104）用 `initWithDisplay:excludingApplications:...`（可选
  排除 OBS 自身窗口避免自采自）；`ScreenCaptureWindowStream`（:137）用
  `initWithDesktopIndependentWindow:`（单窗口，macOS 14.2+ 还能带上子窗口）；`ScreenCaptureApplicationStream`
  （:164）用 `initWithDisplay:includingApplications:exceptingWindows:`（某个 App 的全部窗口，14.2+ 还能含菜单栏）。
  三种模式共用同一份 `SCStreamConfiguration`：像素格式固定成 10-bit `'l10r'`（:212-214），队列深度 8
  （:201），是否采集系统音频看系统版本（:216-227，macOS 13 以下这个字段不存在，`ScreenCaptureWindowStream`
  之外的模式直接判失败返回）。构造完 `SCStream` 后 `addStreamOutput:` 两次（:235/:246，视频一次、音频一次），
  `startCaptureWithCompletionHandler:`（:259）异步启动、用 `os_event` 等它跑完再返回结果。拿到帧之后跟
  `OBSAVCapture` 一样是 IOSurface 直通：`sck_video_capture_tick`（:320）里 `gs_texture_create_from_iosurface`
  （:343）把最新一帧的 IOSurface 包成纹理，`sck_video_capture_render`（:352）画。
- **关键入口**：`init_screen_stream`（:74）、`sck_video_capture_create`（:275）、`sck_video_capture_tick`
  （:320）、`sck_video_capture_render`（:352）。`struct obs_source_info sck_video_capture_info`（:691）
  `.id = "screen_capture"`（:692）。
- **看点**：三种"采集范围"只是构造 `SCContentFilter` 时传的参数不同，`SCStream` 本身、代理回调
  （`mac-sck-common.m` 的 `ScreenCaptureDelegate`）、取帧方式完全共用——这是 ScreenCaptureKit 相对于老 API
  的一大简化：老方案里显示器截屏（`CGDisplayStream`）和窗口截屏（`CGWindowListCreateImage`）是两条毫无关系的
  代码路径（分别在 `mac-display-capture.m`/`mac-window-capture.m` 里），新方案统一成"一个 `SCStream` +
  一个内容过滤器参数"。跟 `OBSAVCapture.m` 一样走 IOSurface 直通零拷贝，同一个套路在 macOS 采集类源里反复出现，
  值得当成"macOS 上高性能视频源"的标准写法记住。

#### `mac-audio.c`
- **做什么**：`coreaudio_init_unit`（:626）用 `AudioComponentDescription{kAudioUnitType_Output,
  kAudioUnitSubType_HALOutput}`（:628-629）拿到一个 HAL Output Audio Unit（这是 CoreAudio 里跟硬件设备直接对接
  的标准子类型），`coreaudio_init_hooks`（:517）挂三个属性监听：`kAudioDevicePropertyDeviceIsAlive`（设备被拔掉）、
  `PROPERTY_FORMATS`（即 `kAudioStreamPropertyAvailablePhysicalFormats`，格式变了）、以及只在"跟随系统默认设备"
  模式下才加的 `kAudioHardwarePropertyDefaultInputDevice`（系统默认设备被用户切换）——全部指向同一个回调
  `notification_callback`（:484）。这个回调不做原地恢复，而是 `coreaudio_stop` + `coreaudio_uninit` 直接拆干净，
  再 `coreaudio_begin_reconnect`（:469）另起一个 `reconnect_thread`（:453）**轮询重试**（`os_event_timedwait`
  超时重试 `coreaudio_init`，默认设备变更给 300ms 冷却、设备拔出给 2000ms），直到新设备就绪或用户换源。
- **关键入口**：`coreaudio_init_unit`（:626）、`coreaudio_init_hooks`（:517）、`notification_callback`（:484）、
  `coreaudio_begin_reconnect`（:469）。`coreaudio_input_capture_info`（:1034，`.id = "coreaudio_input_capture"`
  :1035）、`coreaudio_output_capture_info`（:1047，`.id = "coreaudio_output_capture"` :1048）。
- **看点**：这是"设备可能随时消失，采集源不能跟着崩"这类问题的标准解法——**不试图优雅恢复，而是整体拆除再重建**，
  用一个独立线程做退避重试，主线程/音频线程完全不用关心重连细节。这个思路在 Windows 那边的
  `win-wasapi/wasapi-notify.cpp`（`IMMNotificationClient`）几乎是逐行对应的翻版，只是 API 换成了 WASAPI；
  对比读这两个文件能看清"设备变更监听"这件事在不同平台 API 下的共同骨架。另外 `coreaudio_output_capture_info`
  这种"系统音频回环"在没有 ScreenCaptureKit 之前完全靠用户自装虚拟声卡（Soundflower/BlackHole 等）冒充成一个
  "麦克风"，`audio-device-enum.c:10` 那个按名字字符串猜测设备类型的 hack 就是这段历史的遗留证据。

---

### mac-syphon　`plugins/mac-syphon/`

**职责**：接入 **Syphon**——macOS 上一个进程间 GPU 纹理共享协议/框架（第三方图形 App，如 VJ 软件、游戏引擎，
可以把渲染结果直接"广播"成一个 Syphon server，其他 App 当 client 订阅）。跟屏幕/摄像头采集完全不是一回事：
不经过任何系统采集 API，是**两个跑在同一台 Mac 上的图形进程之间直接共享 IOSurface**，延迟和拷贝开销都最低。

| 文件 | 行数 | 功能 |
|---|---|---|
| `syphon.m` | 749 | 源实现主体：发现 Syphon server、订阅、`newFrameImage` 拿 `IOSurfaceRef`（:138）直接建纹理，`.id = "syphon-input"`（:735） |
| `SyphonOBSClient.m` | 18 | 对 Syphon 官方 `SyphonClient` 的极薄包装，加了点 OBS 需要的回调转发 |
| `plugin-main.c` | 16 | 模块入口 |
| `SyphonOBSClient.h` | 11 | 上面的公开声明 |

与前面几个源一样，`syphon.m` 拿到的也是 `IOSurfaceRef`（:138 `newFrameImage`），同样走"IOSurface 直接建 GPU 纹理"
这条零拷贝路径——到这里 macOS 视频源里出现的第三次同款设计。

---

### mac-virtualcam　`plugins/mac-virtualcam/`

**职责**：把 OBS 的合成输出伪装成一个系统摄像头设备，供 Zoom/腾讯会议/浏览器等任何走标准摄像头 API 的第三方 App
选用。这是本篇里**结构最复杂**的目录：一份代码分裂成三个独立可执行/可加载体，彼此靠不同的系统机制通信。目录按用途分三份：

```
src/
├─ obs-plugin/      OBS 里加载的标准 obs_output 插件（本体），运行在 OBS 进程内
├─ dal-plugin/      旧："CoreMediaIO DAL" 插件（.plugin 包），会被安装进系统目录，运行在【每一个】调用 CoreMediaIO 的进程里
└─ camera-extension/ 新：Swift 写的 "Camera Extension"（系统扩展），运行在独立的系统托管进程里
```

**两半结构怎么分工，取决于系统版本**——枢纽在 `src/obs-plugin/plugin-main.mm` 的 `cmio_extension_supported()`
（:18，判断 `macOS 13.0` 以上）：

- **macOS 13 以下（旧：DAL 插件路）**：`obs-plugin` 侧的 `OBSDALMachServer`（`.mm`，`sendPixelBuffer:`
  :117）通过 **Mach 端口消息**（`NSPort`/`NSPortMessage`，非原始 `mach_msg`）把每一帧 `CVPixelBufferRef` 发给
  连接上来的客户端；`dal-plugin`（`.plugin` 包，装进 `/Library/CoreMediaIO/Plug-Ins/DAL`，`install_dal_plugin`
  :169）是一段 **CoreMediaIO Hardware Plug-In**——`OBSDALPlugInMain.mm` 里的 `PlugInMain`（:26）是 CoreMediaIO
  框架规定的 C 导出入口，任何一个调用 CoreMediaIO 枚举摄像头的进程（包括 Zoom 自己）都会把这个 `.plugin`
  加载进**自己的进程空间**；`OBSDALMachClient`（`connectToServer` :61、`handlePortMessage:` :84）在那个客户进程
  里连回 `obs-plugin`，收到帧后交给 `OBSDALStream`（`queuePixelBuffer:` :305）塞进一个 `CMSimpleQueueRef`
  （`copyBufferQueueWithAlteredProc:` :210）——这个队列就是 CoreMediaIO 规定的"设备往外吐帧"的标准机制，
  客户 App 从这个队列里取帧，跟取真实摄像头帧没有区别。
- **macOS 13 及以上（新：Camera Extension 路）**：不再需要 OBS 自造的 Mach IPC。`virtualcam_output_start`
  （:285）直接用 **CoreMediaIO 设备 API** 找到系统里由 Camera Extension 注册的那个虚拟摄像头设备
  （按 UUID 匹配），`CMIOStreamCopyBufferQueue`（:431）拿到**系统托管**的那条帧队列，`virtualcam_output_raw_video`
  （:470）把 OBS 的 `video_data` 拷进 `CVPixelBufferPool` 出来的 `CVPixelBufferRef`，包成 `CMSampleBufferRef`
  直接 `CMSimpleQueueEnqueue`（:541）进这条系统队列——**帧的传输完全交给操作系统**，OBS 不用再自己维护一套
  Mach 协议。`camera-extension/`（Swift）那一侧只需要在 `OBSCameraProviderSource`（:12，实现协议
  `CMIOExtensionProviderSource`）里把设备/流"注册"给系统，`OBSCameraStreamSource.startStream()`（:78）/
  `stopStream()`（:86）只是开关状态——真正的帧数据是系统直接把 `obs-plugin` 写进队列的样本转发给消费者，
  extension 进程本身不用手工转发一帧。

**Swift 与 ObjC(++) 怎么混编**：三个子目录里只有 `camera-extension/` 是纯 Swift（`main.swift` 是可执行入口，
`import CoreMediaIO` 直接用系统框架，不需要额外桥接头，因为 `CMIOExtensionProviderSource` 这套协议本身就是
Swift/ObjC 双语言桥接过的系统 API）；`obs-plugin/` 和 `dal-plugin/` 是 ObjC++（`.mm`），之所以不是纯 ObjC，
是因为要跟 `libobs` 的 C/C++ 头文件（`obs-module.h`）直接混用。三者是**三个独立编译产物**（分别打进 OBS 插件包、
系统 DAL 目录、系统扩展 bundle），不是同一个 target 里的源码级混编——真正跨语言调用发生在**进程边界**上
（Mach 端口 / CoreMediaIO 系统队列），不是函数调用层面的桥接。

| 文件 | 行数 | 功能 |
|---|---|---|
| `src/obs-plugin/plugin-main.mm` ⭐ | 567 | OBS 侧 `obs_output_info` 主体：两种系统版本分流、DAL 插件的安装/卸载，见下方展开 |
| `src/dal-plugin/OBSDALStream.mm` | 537 | 旧路：`CMIOStream` 对象——响应 CoreMediaIO 的属性查询、把收到的帧塞进标准帧队列 |
| `src/dal-plugin/OBSDALPlugInInterface.mm` | 370 | 旧路：`IUnknown`/`CMIOHardwarePlugInInterface` 的 C 函数表实现（供 `PlugInMain` 返回） |
| `src/camera-extension/OBSCameraDeviceSource.swift` | 308 | 新路：`CMIOExtensionDeviceSource`，向系统描述这个虚拟设备的属性（分辨率/帧率等） |
| `src/dal-plugin/OBSDALObjectStore.mm` | 279 | 旧路：CMIO 对象的属性存取通用基类（`Device`/`Stream`/`PlugIn` 都继承它） |
| `src/dal-plugin/OBSDALDevice.mm` | 272 | 旧路：`CMIODevice` 对象——对外呈现成一个"摄像头设备" |
| `src/dal-plugin/OBSDALPlugIn.mm` | 232 | 旧路：`CMIOHardwarePlugIn` 对象——插件生命周期、创建/持有 Device |
| `src/obs-plugin/OBSDALMachServer.mm` | 167 | 旧路：Mach IPC 服务端，`run`（:37）监听连接、`sendPixelBuffer:`（:117）广播帧 |
| `src/dal-plugin/OBSDALMachClient.mm` | 156 | 旧路：Mach IPC 客户端，跑在每个消费者进程里连回 `obs-plugin` |
| `src/camera-extension/OBSCameraStreamSink.swift` | 111 | 新路：`CMIOExtensionStreamSource` 的"接收端"变体（用于双向流场景，如系统允许往虚拟摄像头写入） |
| `src/camera-extension/OBSCameraStreamSource.swift` | 92 | 新路：`CMIOExtensionStreamSource`，`startStream`/`stopStream`（:78/:86）开关，帧转发由系统队列完成 |
| `src/dal-plugin/OBSDALObjectStore.h` | 62 | 上面的公开声明 |
| `src/dal-plugin/OBSDALDevice.h` | 34 | 上面的公开声明 |
| `src/camera-extension/OBSCameraProviderSource.swift` | 61 | 新路：`CMIOExtensionProviderSource`（:12），整个 Camera Extension 的顶层入口对象 |
| `src/dal-plugin/OBSDALPlugIn.h` | 48 | 上面的公开声明 |
| `src/dal-plugin/OBSDALStream.h` | 45 | 上面的公开声明 |
| `src/dal-plugin/Logging.h` | 39 | 旧路统一日志宏 |
| `src/dal-plugin/OBSDALPlugInMain.mm` | 35 | 旧路：`PlugInMain`（:26）导出入口，CoreMediaIO 规定的插件加载协议 |
| `dal-plugin/OBSDALMachClient.h`（33）/ `dal-plugin/OBSDALPlugInInterface.h`（23）/ `dal-plugin/CMSampleBufferUtils.mm`（26）/ `dal-plugin/CMSampleBufferUtils.h`（11）/ `dal-plugin/Defines.h`（21）/ `obs-plugin/OBSDALMachServer.h`（29）/ `obs-plugin/Defines.h`（22） | 11~33 | 均为对应 `.mm` 的声明，或 CMSampleBuffer 时间戳换算等极短工具函数，不逐一展开 |
| `src/camera-extension/main.swift` | 32 | 新路：extension 进程可执行入口，从 Info.plist 读设备/流 UUID 后启动 `OBSCameraProviderSource` |
| `src/common/MachProtocol.h` | 17 | 旧路 Mach 协议共享定义：服务名 `com.obsproject.obs-mac-virtualcam.server`、消息 ID 枚举（Connect/Frame/Stop） |

#### `src/obs-plugin/plugin-main.mm`
- **做什么**：`obs_output_info virtualcam_output_info`（:551，`.id = "virtualcam_output"` :552）就是普通的
  `obs_output`——`virtualcam_output_start`（:285）里先判断 `cmio_extension_supported()`（:18），Camera Extension
  路走系统 `OSSystemExtensionRequest` API 激活/安装扩展（:125 起的 `install_cmio_system_extension`），DAL 路
  走 `install_dal_plugin`（:169，本质是 `cp -R` 把 `.plugin` 包拷进 `/Library/CoreMediaIO/Plug-Ins/DAL`，
  需要用户授权）。`virtualcam_output_raw_video`（:470）是每帧的入口，逻辑见上方"两半结构"说明。
- **关键入口**：`virtualcam_output_start`（:285）、`virtualcam_output_stop`（:454）、`virtualcam_output_raw_video`
  （:470）、`cmio_extension_supported`（:18）。
- **看点**：这个文件把"新系统机制上线后，OBS 怎么从自建 IPC 平滑过渡到系统托管机制、同时不砍掉旧系统兼容性"这件事
  写得很直白——同一个 `obs_output`，`start`/`stop`/送帧三个回调内部各自一个 `if (cmio_extension_supported())`
  分支，两条路径通过同一组回调签名对外暴露，调用方（`libobs`）完全不需要关心底层差异。这跟 `mac-capture/plugin-main.c`
  "新旧 API 按系统版本二选一注册"是同一种思路在"输出"侧的应用。

---

## Windows

Windows 上的采集分三大类，各一个插件目录：**屏幕/窗口/游戏画面捕获**（`win-capture/`，规模最大，含独立的
DLL 注入 + 图形 API Hook 子系统）、**摄像头 + 虚拟摄像头**（`win-dshow/`，基于 DirectShow，虚拟摄像头是一个
独立注册的系统级 DirectShow Filter DLL）、**系统音频/麦克风**（`win-wasapi/`，基于 WASAPI）。

### win-capture　`plugins/win-capture/`

**职责**：显示器画面、指定窗口画面、指定游戏/程序画面三种捕获，后者复杂度最高——需要把一个 hook DLL
**注入进目标进程**，劫持它调用 D3D/OpenGL/Vulkan 的 Present 函数来截取渲染结果，这是本组里逻辑量最大的部分。

**想看窗口捕获注入去哪几个文件**：不是"注入"这一个动作单独一个文件，而是一整条子系统：
`game-capture.c`（2339 行，主控逻辑，决定要不要注入、往哪个进程注入）→ `inject-helper/inject-helper.c`
（真正执行注入动作的独立小程序，被 `game-capture.c` `CreateProcess` 出来跑）→ `graphics-hook/*`
（被注入进目标进程、常驻在里面劫持 Present 调用的 hook 本体，按图形 API 分成
`d3d8/9/10/11/12-capture.cpp`、`dxgi-capture.cpp`、`gl-capture.c`、`vulkan-capture.c` 六个变体 + 公共壳
`graphics-hook.c`）→ `get-graphics-offsets/*`（一个独立小工具，运行时创建各种设备类型探测 vtable 偏移，
因为 Present 等函数在 vtable 里的具体偏移量随驱动/系统版本变化，不能硬编码）。

**屏幕捕获的两套实现怎么切换**：跟 macOS 一样是运行时二选一，枢纽在 `plugin-main.c` 的 `obs_module_load`：

```c
if (win8_or_above && graphics_uses_d3d11)
    obs_register_source(&duplicator_capture_info);  // Windows 8+ 且用 D3D11 渲染：Desktop Duplication API
else
    obs_register_source(&monitor_capture_info);      // 否则：老式 GDI BitBlt 截屏
```

两者共用同一个 `.id = "monitor_capture"`（`duplicator-monitor-capture.c:852`、`monitor-capture.c:221`），
永远只会有一个被注册，属性面板上看不出区别，是完全不同的两份实现。窗口捕获（`window-capture.c`）本身也支持
两条底层路径（老 `dc-capture.c` 系 BitBlt/`PrintWindow`，和 Windows 10 1903+ 的 Windows Graphics Capture
`winrt-capture`，定义在 `libobs-winrt/`，本篇范围外）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `game-capture.c` | 2339 | 游戏/程序画面捕获主控：决定注入时机、管理共享内存与注入进程的握手协议，本组最大文件 |
| `graphics-hook/vulkan-capture.c` + `.h` | 2103 + 875 | Vulkan `vkQueuePresentKHR` hook + 共享纹理导出，本组着色器/Hook 代码里最长的一对 |
| `graphics-hook/graphics-hook.c` + `.h` | 907 + 263 | 注入进目标进程后的公共外壳：初始化、按目标进程用的图形 API 分发到对应 hook 模块 |
| `graphics-hook/gl-capture.c` | 881 | OpenGL `wglSwapBuffers` hook |
| `duplicator-monitor-capture.c` | 867 | 显示器捕获（新）：DXGI Desktop Duplication API，`.id = "monitor_capture"`（:852） |
| `graphics-hook/d3d9-capture.cpp` | 866 | Direct3D 9 hook（`Present`/`Reset` 等） |
| `window-capture.c` | 844 | 窗口捕获源：老 BitBlt 路径 + 新 WinRT WGC 路径二选一，`.id = "window_capture"`（:827） |
| `graphics-hook/d3d12-capture.cpp` | 441 | Direct3D 12 hook（`ExecuteCommandLists`/`Present`），现代游戏最常用的路径之一 |
| `graphics-hook/d3d8-capture.cpp` | 396 | Direct3D 8 hook（老游戏兼容） |
| `graphics-hook/d3d10-capture.cpp` | 370 | Direct3D 10 hook |
| `get-graphics-offsets/d3d9-offsets.cpp` | 355 | 独立小工具进程：创建一个真实 D3D9 设备，反查其 vtable 里 `Present` 等函数的字节偏移 |
| `graphics-hook/dxgi-capture.cpp` | 353 | DXGI 层的 `IDXGISwapChain::Present`/`Present1` hook，D3D10/11/12 共用这一层再往下分发 |
| `graphics-hook/d3d11-capture.cpp` | 328 | Direct3D 11 hook（最常见的现代游戏图形 API 之一） |
| `game-capture-file-init.c` | 321 | 把 hook DLL 相关文件（32/64 位）从插件数据目录复制/校验到本地可执行目录 |
| `cursor-capture.c` | 257 | 鼠标指针位图捕获（GDI `GetIconInfo`），窗口/显示器捕获共用 |
| `dc-capture.c` | 242 | 老式 GDI `BitBlt`/`PrintWindow` 截图 + 纹理上传，窗口/显示器捕获（老路径）共用 |
| `monitor-capture.c` | 235 | 显示器捕获（旧）：GDI `BitBlt`，`.id = "monitor_capture"`（:221），Windows 7 或非 D3D11 后端兜底 |
| `nt-stuff.c` | 233 | 用 `winternl.h` 未公开 NT API 查目标进程线程状态（判断游戏是否卡死/挂起），辅助注入时机判断 |
| `load-graphics-offsets.c` | 224 | 读取/缓存 `get-graphics-offsets` 探测出的 vtable 偏移（写成 config 文件） |
| `compat-helpers.c` | 190 | 读一份 JSON 兼容性名单（已知有问题的游戏/程序按 exe/窗口标题/类名匹配），做针对性变通 |
| `graphics-hook/d3d9-patches.hpp` | 184 | D3D9 特定驱动 bug 的运行时二进制补丁 |
| `plugin-main.c` | 161 | 模块入口，屏幕捕获新旧实现二选一注册，见上方"职责"说明 |
| `graphics-hook/gl-decs.h` | 144 | OpenGL 函数指针声明表（不静态链接 `opengl32.lib`，运行时自己找） |
| `audio-helpers.c` | 125 | 游戏捕获伴随的"同时捕获这个进程的音频"，与 WASAPI 应用回环联动 |
| `inject-helper/inject-helper.c` | 122 | 独立小程序：真正执行 DLL 注入动作（被 `game-capture.c` 拉起） |
| `get-graphics-offsets/dxgi-offsets.cpp` | 116 | 同上，探测 DXGI 层偏移 |
| `get-graphics-offsets/d3d8-offsets.cpp` | 86 | 同上，探测 D3D8 偏移 |
| `app-helpers.c` | 82 | 判断目标进程是否为 UWP/AppContainer 应用（`is_app`），这类进程注入方式不同 |
| `get-graphics-offsets/get-graphics-offsets.c` | 54 | 上面几个 offsets 探测文件的公共 `main` 入口 |
| `graphics-hook/dxgi-helpers.hpp` | 52 | DXGI 相关小工具（格式转换等） |
| `get-graphics-offsets/ddraw-offsets.cpp` | 1 | 只有一行 `/* TODO */`——DirectDraw 偏移探测从未实现，文件是个占位符 |
| 其余头文件（`dc-capture.h`（34）/`cursor-capture.h`（28）/`app-helpers.h`（10）/`audio-helpers.h`（27）/`compat-helpers.h`（17）/`compat-format-ver.h`（3）/`nt-stuff.h`（7）/`get-graphics-offsets/get-graphics-offsets.h`（33）） | 3~34 | 均为对应 `.c` 的声明，不逐一展开 |

---

### win-dshow　`plugins/win-dshow/`

**职责**：摄像头/采集卡输入（基于 **DirectShow**，依赖 vendored 的 `deps/libdshowcapture`，不在本篇统计范围内）
+ 虚拟摄像头输出。虚拟摄像头是**独立的系统级 DirectShow Filter**（`virtualcam-module/`，编译成单独一个 DLL 并
注册进系统，供任何走 DirectShow 采集协议的第三方 App 选用），跟 OBS 主程序之间用共享内存队列通信——概念上和
macOS 那套"OBS 进程 → IPC → 消费者进程里加载的一小段代码"完全对应，只是这里 IPC 换成了**命名共享内存环形队列**
而不是 Mach 端口。

| 文件 | 行数 | 功能 |
|---|---|---|
| `win-dshow.cpp` | 2094 | 摄像头采集源主体：包 `libdshowcapture`，设备/格式枚举与协商，`.id = "dshow_input"`（:2081） |
| `ffmpeg-decode.c` | 414 | 用 FFmpeg 软解某些 DirectShow 设备直接吐的压缩格式（如 MJPEG/H264 摄像头） |
| `virtualcam-module/virtualcam-filter.cpp` | 361 | 虚拟摄像头 DirectShow Filter 本体：作为一个视频采集 Pin，向消费 App 提供 NV12 帧 |
| `win-dshow-encoder.cpp` | 360 | 少数带硬件 H264 编码器的采集卡，包成 `obs_encoder` 使用 |
| `virtualcam-module/virtualcam-module.cpp` | 285 | Filter DLL 的 `IClassFactory`/COM 注册样板代码 |
| `shared-memory-queue.c` | 218 | OBS 侧：把每帧画面写进命名共享内存环形队列（`OBSVirtualCamVideo`） |
| `tiny-nv12-scale.c` | 200 | 极简最近邻缩放（滤镜侧不追求画质，只保证虚拟摄像头输出分辨率匹配） |
| `virtualcam-module/placeholder.cpp` | 155 | OBS 未运行时的占位测试卡图案，避免消费 App 看到摄像头"打开失败" |
| `virtualcam.c` | 121 | OBS 侧 `obs_output`：把渲染帧交给 `shared-memory-queue.c` |
| `encode-dstr.hpp` | 76 | 字符串编码转换小工具（宽字符/多字节互转） |
| `dshow-plugin.cpp` | 54 | 模块入口，注册摄像头源 + 编码器 |
| `virtualcam-module/sleepto.c` | 50 | 高精度定时器辅助（虚拟摄像头按固定帧率吐帧用） |
| `ffmpeg-decode.h` / `tiny-nv12-scale.h` / `shared-memory-queue.h` / `virtualcam-module/virtualcam-filter.hpp` / `virtualcam-module/sleepto.h` | 14~72 | 对应实现的公开声明 |

---

### win-wasapi　`plugins/win-wasapi/`

**职责**：麦克风/线路输入、桌面音频回环、**按进程的应用音频回环**（Windows 10+ Process Loopback，跟 macOS
ScreenCaptureKit 的应用级音频采集是同一个思路）三种音频源，全部基于 **WASAPI**。

| 文件 | 行数 | 功能 |
|---|---|---|
| `win-wasapi.cpp` | 1648 | 三种音频源的完整实现：`RegisterWASAPIInput`（:1596）、`RegisterWASAPIDeviceOutput`（:1614，桌面音频）、`RegisterWASAPIProcessOutput`（:1632，按进程回环） |
| `wasapi-notify.cpp` | 109 | `IMMNotificationClient` 实现——默认设备变更回调，与 `mac-capture/mac-audio.c` 的 `AudioObjectAddPropertyListener` 是同一个问题在 WASAPI 下的对应写法 |
| `enum-wasapi.cpp` | 97 | 音频设备枚举、取设备友好名称 |
| `plugin-main.cpp` | 76 | 模块入口 |
| `enum-wasapi.hpp` / `wasapi-notify.hpp` | 41 / 31 | 对应实现的公开声明 |

---

## Linux

Linux/BSD 的采集按"图形协议"和"音频后端"两条线拆分。图形侧分两代：**X11 专属**（`linux-capture/`，靠 XShm/
XComposite 扩展，只在 `obs_get_nix_platform() == OBS_NIX_PLATFORM_X11_EGL` 时注册）和 **Wayland 时代的统一方案**
（`linux-pipewire/`，通过 `xdg-desktop-portal` 向用户要授权、实际数据走 PipeWire，同时覆盖屏幕/窗口/摄像头）。
摄像头另有一条独立的 **V4L2** 路径（`linux-v4l2/`，`/dev/videoN` 设备文件，X11/Wayland 通用，因为 V4L2 是内核
接口不是显示服务器接口）。音频侧因为 Linux/BSD 生态碎片化，一次性给了五套后端可选：`linux-pulseaudio/`
（主流桌面 Linux 默认）、`linux-alsa/`（更底层，PulseAudio 之下的那一层）、`linux-jack/`（专业音频路由场景）、
`oss-audio/`（部分 BSD）、`sndio/`（OpenBSD 默认音频框架）。

### linux-capture　`plugins/linux-capture/`

**职责**：纯 X11 方案。`linux-capture.c`（模块入口，:31-42）只在 `OBS_NIX_PLATFORM_X11_EGL` 平台下才注册任何源——
Wayland 会话下这个插件等于自我禁用，交给 `linux-pipewire/` 处理。

| 文件 | 行数 | 功能 |
|---|---|---|
| `xcomposite-input.c` + `.h` | 985 + 4 | 窗口捕获：X Composite 扩展把窗口内容重定向到离屏 pixmap，再用 GLX texture-from-pixmap 直接拿 GPU 纹理（零拷贝）；`.h` 只有 `xcomposite_load`/`_unload` 两个声明 |
| `xshm-input.c` | 609 | 显示器/根窗口捕获：X SHM 扩展共享内存截图，注册 `xshm_input`/`xshm_input_v2` 两个版本（:577/:595） |
| `xhelpers.c` + `.h` | 326 + 146 | X11 错误处理/窗口属性读取等共享工具，被上面两个文件共用 |
| `xcursor-xcb.c` + `.h` | 147 + 83 | 鼠标指针叠加，走 XCB（比 Xlib 更细粒度的 X11 客户端库） |
| `linux-capture.c` | 48 | 模块入口，X11 平台判断见上方"职责"说明 |

---

### linux-v4l2　`plugins/linux-v4l2/`

**职责**：V4L2（Video4Linux2）摄像头采集 + 一个 v4l2loopback 风格的虚拟摄像头输出，都是直接 `ioctl` 内核设备节点，
不依赖任何图形/显示服务器协议。

| 文件 | 行数 | 功能 |
|---|---|---|
| `v4l2-input.c` | 1109 | 摄像头采集主体：设备打开、格式协商（`VIDIOC_S_FMT`）、`mmap` 缓冲区取帧循环 |
| `v4l2-helpers.h` | 327 | 大量 inline 的 ioctl 封装（格式/分辨率/帧率枚举） |
| `v4l2-output.c` | 325 | 虚拟摄像头输出：把画面写进 `/dev/videoN`（需要 `v4l2loopback` 内核模块），`.id = "virtualcam_output"`（:317） |
| `v4l2-helpers.c` | 315 | 上面头文件里非 inline 部分的实现 |
| `v4l2-udev.c` + `.h` | 203 + 47 | 用 udev 监听设备热插拔，触发属性面板刷新设备列表 |
| `v4l2-controls.c` + `.h` | 151 + 39 | 把 V4L2 标准控制项（亮度/曝光/对焦等）映射成 OBS 属性面板的滑块/开关 |
| `v4l2-decoder.c` + `.h` | 132 + 68 | 设备只给压缩格式（如 MJPEG）时的软解 |
| `linux-v4l2.c` | 42 | 模块入口，`.id = "v4l2_input"`（`v4l2-input.c:1099`） |

---

### linux-pipewire　`plugins/linux-pipewire/`

**职责**：Wayland 会话下屏幕/窗口/摄像头采集的统一方案——不直接碰任何图形接口，而是通过 **xdg-desktop-portal**
（一个 D-Bus 服务）向合成器申请授权，拿到一个 PipeWire 节点 ID 后用 **PipeWire** 拉流。模块入口
`linux-pipewire.c`（68 行）逻辑很直白：

```c
pw_init(NULL, NULL);
#if PW_CHECK_VERSION(0, 3, 60)
camera_portal_load();      // PipeWire 版本够新才有摄像头 portal 支持
#endif
screencast_portal_load();   // 屏幕/窗口/应用画面 portal，一直加载
```

| 文件 | 行数 | 功能 |
|---|---|---|
| `pipewire.c` + `.h` | 1471 + 63 | PipeWire 流的公共核心：连接、协商 buffer 格式、拉取帧，被屏幕采集和摄像头采集共用 |
| `camera-portal.c` + `.h` | 1352 + 24 | 摄像头：走 `org.freedesktop.portal.Camera`，`.id = "pipewire-camera-source"`（:1331） |
| `v4l2-input.c` 对照见上 | — | （摄像头在 Wayland 下也可以直接走 v4l2-input，camera-portal 是"经过合成器授权"的另一条路，两者并存供用户选） |
| `screencast-portal.c` + `.h` | 760 + 24 | 屏幕/窗口：走 `org.freedesktop.portal.ScreenCast`，一次注册 3 个源——桌面（:693）、窗口（:715）、旧版桌面+窗口合一（:737） |
| `portal.c` + `.h` | 190 + 34 | D-Bus 与 portal 交互的公共封装（发请求、等响应），被 screencast/camera 两个 portal 共用 |
| `formats.c` + `.h` | 120 + 38 | PipeWire/DRM 像素格式 ↔ OBS `video_format` 的映射表 |
| `linux-pipewire.c` | 68 | 模块入口，见上方"职责"说明 |

---

### linux-pulseaudio / linux-alsa / linux-jack / oss-audio / sndio

五套 Linux/BSD 音频后端，各自一个独立源，用户根据发行版/系统实际装了什么来选（PulseAudio 是主流桌面 Linux 的
事实标准，ALSA 是它下面那层更底层的接口，JACK 面向专业音频路由场景，OSS/sndio 分别是部分 BSD 系统的默认方案）。
彼此互不依赖，代码规模都不大。

| 目录/文件 | 行数 | 功能 |
|---|---|---|
| `linux-pulseaudio/pulse-input.c` | 601 | PulseAudio 输入源：`pa_stream` 回调取 PCM |
| `linux-pulseaudio/pulse-wrapper.c` + `.h` | 260 + 149 | PulseAudio 主循环/上下文连接的公共封装 |
| `linux-pulseaudio/linux-pulseaudio.c` | 34 | 模块入口 |
| `linux-alsa/alsa-input.c` | 641 | ALSA PCM 采集，注释里写明参考自 `pulse-input.c` 的结构 |
| `linux-alsa/linux-alsa.c` | 32 | 模块入口 |
| `linux-jack/jack-input.c` | 155 | JACK 客户端注册端口、回调取样本 |
| `linux-jack/jack-wrapper.c` + `.h` | 166 + 51 | JACK 库动态加载封装（同样是"库不存在就优雅跳过"的模式） |
| `linux-jack/linux-jack.c` | 32 | 模块入口 |
| `oss-audio/oss-input.c` | 693 | OSS（Open Sound System）`/dev/dsp` 读取，本组单文件最大（手写 ioctl 较多） |
| `oss-audio/oss-audio.c` | 33 | 模块入口 |
| `sndio/sndio-input.c` + `.h` | 392 + 18 | OpenBSD sndio 库采集 |
| `sndio/sndio.c` | 32 | 模块入口 |

---

## 阅读建议

1. macOS 优先读 `mac-avcapture/OBSAVCapture.m:1231`（`captureOutput:didOutputSampleBuffer:`）和
   `mac-capture/mac-sck-video-capture.m:74`（`init_screen_stream`）这两个函数——把"IOSurface 直通纹理"和
   "SCContentFilter 按类型构造"这两个模式吃透，`mac-syphon/syphon.m` 的取帧方式立刻就能看懂，因为是同一套零拷贝思路。
2. 三大平台各有一处"新旧实现运行时二选一"的枢纽函数，建议对照读一遍：`mac-capture/plugin-main.c:19`、
   `win-capture/plugin-main.c:141`（Desktop Duplication vs GDI）、`linux-capture/linux-capture.c:33`
   （X11 平台判断）——搞懂这个模式后，再看任何一个"为什么有 v1/v2"或"为什么同一个 id 有两份实现"都会更快。
3. `mac-capture/mac-audio.c:484`（`notification_callback`）和 `win-wasapi/wasapi-notify.cpp` 的
   `IMMNotificationClient` 建议对照读——"设备被拔出/切换时怎么办"这个问题，CoreAudio 和 WASAPI 给的答案骨架几乎一样
   （监听 + 整体拆除重建 + 退避重连），值得当成一个通用套路记住，而不是各记一遍 API 细节。
4. `mac-virtualcam/` 的两代实现（DAL 插件 vs Camera Extension）建议先读新的（`src/camera-extension/main.swift`
   + `src/obs-plugin/plugin-main.mm:285` 的 `virtualcam_output_start`），旧的 DAL 路径（`src/dal-plugin/*`）
   逻辑更繁琐（自造 Mach 协议 + 手写 CoreMediaIO 插件协议），了解"新方案省掉了什么"比通读旧代码收获更大；
   `win-dshow/virtualcam-module/` 是同一个问题在 Windows/DirectShow 下的对应方案，感兴趣可以对照。
5. `win-capture/` 的 `game-capture.c` + `graphics-hook/*` 这一整套 DLL 注入/图形 API Hook 子系统，是本篇里
   macOS/Linux 都没有对应物的部分（因为 macOS/Linux 靠系统级采集 API 就能拿到窗口/屏幕画面，不需要侵入目标进程）——
   如果不打算做 Windows 专属的游戏捕获功能，`graphics-hook/d3d8/9/10-capture.cpp` 这类老图形 API 的 hook
   可以直接跳过，只看 `graphics-hook.c` 的公共壳 + `d3d11-capture.cpp`/`vulkan-capture.c` 两个现代 API 代表即可。
6. Linux 的 `linux-pipewire/` 建议整体读一遍 `screencast-portal.c` 的 `obs_module_load` 附近代码，
   跟 `linux-pipewire.c` 一起看就能明白"一个 portal 请求怎么落到 PipeWire 流"；五个 Linux 音频后端只需要挑
   `linux-pulseaudio/pulse-input.c` 精读一个，其余四个（ALSA/JACK/OSS/sndio）扫一眼 `xxx_capture_audio`
   之类的回调函数体就够，重复度很高。
