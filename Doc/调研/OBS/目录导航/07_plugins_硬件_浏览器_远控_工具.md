# OBS 目录导航 · plugins 专业硬件 / 浏览器源 / WebSocket 远控 / 前端工具

> 源码范围：`plugins/decklink`、`plugins/decklink-output-ui`、`plugins/decklink-captions`、`plugins/aja`、
> `plugins/aja-output-ui`、`plugins/obs-browser`（git submodule，已拉取）、`plugins/obs-websocket`（git submodule，已拉取）、
> `plugins/frontend-tools` ｜ 源文件 185 个（`.c/.cpp/.h/.hpp/.mm/.lua/.py`，不计 `locale/`、`cmake/`、`forms/*.ui`、
> vendored 的 `decklink/*/decklink-sdk/`、`obs-browser/deps/base64`、`obs-websocket/lib/example`）
> ｜ 基于 obs-studio commit `f2db097`（2026-07-09）
> 返回总索引：[README.md](README.md)

## 本篇速查

想找什么 → 去哪：

| 我想看… | 去这里 |
|---|---|
| DeckLink 采集卡的输入/输出回调怎么写（`IDeckLinkInputCallback`） | [`decklink-device-instance.cpp`](#decklink-device-instancecpp) |
| AJA 卡的路由配置（signal routing 字符串怎么解析） | [aja/ 分组说明](#ajaplugins-aja) + [`aja-routing.cpp`](#aja-有哪些非-sdk-文件) |
| DeckLink/AJA 输出面板（Studio Mode 里的"输出"设置窗口）在哪 | [decklink-output-ui/](#decklink-output-uiplugins-decklink-output-ui)、[aja-output-ui/](#aja-output-uiplugins-aja-output-ui) |
| 浏览器源怎么把网页画面变成 OBS 纹理（共享纹理 vs CPU 回读） | [`obs-browser-source.cpp`](#obs-browser-sourcecpp) |
| CEF 子进程怎么起、`window.obsstudio` 这套 JS API 定义在哪 | [obs-browser/ 分组说明](#obs-browserplugins-obs-browser) |
| WebSocket 协议握手（Hello/Identify/Request）在哪个文件 | [`WebSocketServer_Protocol.cpp`](#websocketserver_protocolcpp) |
| 某个 WebSocket 请求（比如 `SetSceneItemTransform`）该去哪个源文件找 | [obs-websocket 请求处理表格](#请求处理-requesthandler) |
| WebSocket 事件（场景切换、录制状态变化）怎么广播给客户端 | [obs-websocket 事件处理表格](#事件处理-eventhandler) |
| 自动切场景（按前台窗口标题匹配）逻辑在哪 | [`auto-scene-switcher.cpp`](#auto-scene-switchercpp) |
| 输出计时器 / Lua-Python 脚本管理器 / Windows 语音字幕 | [frontend-tools 表格](#frontend-toolsplugins-frontend-tools) |

---

## 一句话职责

这一篇覆盖的是**跟"核心合成管线"关系不大、但决定 OBS 能力边界的四类插件**：专业采集卡（DeckLink/AJA，进/出画面走
SDI/HDMI 硬件通道而不是消费级摄像头驱动）、浏览器源（把整个 Chromium 塞进 OBS 当一种"源"）、远程控制协议
（obs-websocket，让外部程序能像人一样操作 OBS）、前端工具集（一批挂在主界面菜单栏上的小功能，各自独立、互不依赖）。
四类插件的共同点：都是通过 `libobs` 的标准协议（`obs_source_info` / `obs_output_info`）或 `obs-frontend-api` /
`obs_websocket_vendor` 这类"旁路"接口接入，不侵入核心合成管线的一行代码。

---

## decklink/　`plugins/decklink/`

**职责**：Blackmagic DeckLink 系列专业采集卡的输入源 + 输出。90% 的目录体积是 vendored 的官方 SDK
（`mac/decklink-sdk/`、`linux/decklink-sdk/`、`win/decklink-sdk/` 三份平台专属头文件/IDL，共 108 个文件（41+40+27）、
约 1.65 万行，里面是历代 `DeckLinkAPI_v*.h` 版本头——SDK 按 DeckLink 驱动版本演进保留了大量历史接口版本以保证向后兼容，
OBS 代码只用最新那份）。**真正是 OBS 自己写的，只有 31 个文件**（不含 SDK、不含 `data/locale/` 下 69 种语言的 `.ini`）。

macOS 上关心的话：`mac/decklink-sdk/` 是本目录用得到的那份 SDK 头，`mac/platform.cpp`（18 行）只是给
`ComPtr`/`IUnknown` 引用计数包一层 macOS 版 `CFPlugInCreateInstance` 之类的胶水，逻辑极薄。

| 文件 | 行数 | 功能 |
|---|---|---|
| `decklink-device-instance.cpp` ⭐ | 824 | 单个 DeckLink 设备实例：`IDeckLinkInputCallback`/输出调度实现，见下方展开 |
| `decklink-device-instance.hpp` | 213 | 上面的类声明（`RenderDelegate<T>` 模板、`DeckLinkDeviceInstance` 类定义） |
| `decklink-output.cpp` | 293 | `obs_output_info` 注册："decklink_output"，把 OBS 的合成结果送进 SDI/HDMI 输出口 |
| `decklink-source.cpp` | 288 | `obs_source_info` 注册："decklink-input"，`OBS_SOURCE_ASYNC_VIDEO｜AUDIO｜CEA_708`（异步源，走帧队列） |
| `decklink-device.cpp` / `.hpp` | 272 / 66 | `DeckLinkDevice`：包一层 `IDeckLink*`，管理该物理设备支持的输入/输出模式列表 |
| `OBSVideoFrame.cpp` / `.h` | 228 / 114 | `IDeckLinkVideoFrame` 的 OBS 自定义实现——OBS 要往 SDI 口送帧时，得先把像素数据包成 SDK 认识的这个接口对象 |
| `DecklinkInput.cpp` / `.hpp` | 152 / 42 | 输入设备的"业务外壳"：设备切换回调、激活/去激活，实际采集帧的活由 `DeckLinkDeviceInstance` 干 |
| `decklink-device-discovery.cpp` / `.hpp` | 135 / 77 | 设备热插拔发现：包一层 `IDeckLinkDiscovery`，插拔时通过回调通知 source/output 刷新属性列表 |
| `DecklinkOutput.cpp` / `.hpp` | 113 / 35 | 输出设备的"业务外壳"，和 `DecklinkInput` 对称 |
| `audio-repack.c` / `.h` / `.hpp` | 95 / 45 / 19 | 音频声道重排（比如把 OBS 内部声道布局挪成 SDI embedded audio 要求的顺序），SSE 加速；`aja/` 里几乎原样复制了一份 |
| `decklink-device-mode.cpp` / `.hpp` | 92 / 31 | 一个"制式"的封装（分辨率+帧率+扫描方式，对应 SDK 的 `IDeckLinkDisplayMode`） |
| `plugin-main.cpp` | 69 | 模块入口：注册 source + output，`log_sdk_version()` 打印驱动版本 |
| `decklink-devices.cpp` / `.hpp` | 15 / 8 | 全局单例 `deviceEnum`（`DeckLinkDeviceDiscovery*`）+ `fill_out_devices` 给属性面板填设备下拉框 |
| `util.cpp` / `.hpp` | 43 / 7 | `BMDVideoConnection`/`BMDAudioConnection` 枚举转可读字符串（"SDI"/"HDMI"/"Embedded"…） |
| `const.h` | 45 | 全部属性 key 的字符串常量（`DEVICE_HASH`/`MODE_ID`/`KEYER`…），source 和 output 共用 |
| `DecklinkBase.h` / `.cpp` | 35 / 18 | `DeckLinkInput`/`DeckLinkOutput` 的公共基类：持有 `DeckLinkDeviceInstance`、`Activate`/`Deactivate` 虚接口 |
| `platform.hpp` + `mac/win/linux platform.cpp` | 33 + 18/42/13 | 平台专属的 `ComPtr`（COM 智能指针）等价物，DeckLink SDK 在非 Windows 上仍走 COM 风格接口 |

### ⭐ 重点文件展开

#### `decklink-device-instance.cpp`
- **做什么**：真正实现 `IDeckLinkInputCallback`（`VideoInputFrameArrived`/`VideoInputFormatChanged`）和
  `IDeckLinkVideoOutputCallback`（`ScheduledFrameCompleted`）两个 SDK 回调接口的地方——采集卡有帧到达/输出缓冲区
  空闲时，驱动直接从内核线程回调到这里。`HandleVideoFrame`（:171）把 `IDeckLinkVideoInputFrame` 的原始像素封成
  `obs_source_frame`、通过 `obs_source_output_video2` 交给核心；`HandleAudioPacket`（:130）同理转 `obs_source_audio`；
  `HandleCaptionPacket`（:252）解 CEA-708 隐藏字幕（`caption/caption.h`）。输出侧 `UpdateVideoFrame`（:657）→
  `ScheduleVideoFrame`（:671）把 OBS 合成好的帧包成 `OBSVideoFrame` 提交给 SDK 的调度队列，`ScheduledFrameCompleted`
  （模板 `RenderDelegate<T>::ScheduledFrameCompleted`，:50）在缓冲区播完后被 SDK 回调，触发下一帧调度——这是一个
  典型的"驱动拉着 OBS 走"的双缓冲流水线，跟 `libobs` 里"OBS 主动推"的合成节拍方向相反。
- **关键入口**：`VideoInputFrameArrived`（:705）、`VideoInputFormatChanged`（:745）、`HandleVideoFrame`（:171）、
  `StartCapture`（:412）、`StartOutput`（:533）。
- **看点**：`VideoInputFormatChanged`（:745）处理的是"信号源制式变了"（比如上游切换了分辨率/帧率）——这是硬件采集卡
  特有的问题，消费级摄像头驱动一般不会中途变format，但 SDI 信号源换源、换设备是常态，必须监听这个事件重新
  `StopCapture`/`StartCapture`。这个"信号可能随时变"的思路，是专业采集卡源和普通摄像头源在设计上的本质区别。

---

## decklink-output-ui/　`plugins/decklink-output-ui/`

**职责**：DeckLink 输出的 Qt 配置面板——挂在 OBS 主界面 Tools 菜单下的独立对话框，选设备/制式/keyer 模式，
底层调用的还是 `decklink_output_info`（在 `decklink/` 里注册），这里只管 UI。

| 文件 | 行数 | 功能 |
|---|---|---|
| `decklink-ui-main.cpp` | 507 | 模块入口 + Tools 菜单挂载点，维护一份隐藏的 `obs_output_t` 实例供面板操作 |
| `DecklinkOutputUI.cpp` | 145 | 对话框的信号槽逻辑：设备下拉框变化 → 拉取该设备支持的制式列表 → 更新 UI |
| `DecklinkOutputUI.h` | 34 | 上面的类声明 |
| `decklink-ui-main.h` | 6 | 空壳声明 |

（`forms/output.ui` 是 Qt Designer 表单，不是代码，不逐行列。）

---

## decklink-captions/　`plugins/decklink-captions/`

**职责**：从 DeckLink 输入源里提取 CEA-708/608 隐藏字幕并转发出去（比如落盘成文件，或喂给别的字幕处理流程）——
是 `decklink/` 采集字幕能力（`HandleCaptionPacket`）的下游消费者，独立成插件是为了让"要不要处理字幕"可选。

| 文件 | 行数 | 功能 |
|---|---|---|
| `decklink-captions.cpp` | 155 | Tools 菜单对话框：选一个 DeckLink 输入源、把它的字幕流写到文件/回调 |
| `decklink-captions.h` | 30 | 上面的类声明 |

---

## aja/　`plugins/aja-*/`

**职责**：AJA 品牌专业采集卡（DeckLink 的竞品）的输入源 + 输出，功能定位和 `decklink/` 完全对应，
但**架构取舍不同**：AJA 的 SDK（`libajantv2`/`libajabase`）是通过 `find_package(LibAJANTV2 REQUIRED)`
（`plugins/aja/CMakeLists.txt:10`）链接的外部依赖，**不在仓库里 vendor 一份 SDK 源码**——所以 `plugins/aja/`
下没有 decklink 那种几万行的 SDK 头文件，24 个文件全部是 OBS/AJA 插件自己的胶水代码。

### aja 有哪些非 SDK 文件

| 文件 | 行数 | 功能 |
|---|---|---|
| `aja-presets.cpp` / `.hpp` | 1834 / 47 | 路由预设表：不同板卡型号 + 输入输出组合下，该走哪条 SDI/HDMI/固件内部信号路径，本组体积最大的文件（几乎全是预设数据） |
| `aja-output.cpp` / `.hpp` | 1238 / 152 | 输出：视频/音频从 DMA 队列写入板卡帧缓冲，见下方与 decklink 对照说明 |
| `aja-source.cpp` / `.hpp` | 1114 / 86 | 输入：`CaptureThread`（:253）轮询板卡帧缓冲，转 `obs_source_output_video`/`audio` |
| `aja-common.cpp` / `.hpp` | 1113 / 95 | 跨 source/output 共用的属性面板辅助函数（下拉框枚举、设备能力查询） |
| `aja-card-manager.cpp` / `.hpp` | 573 / 96 | 单例 `CardManager`：枚举全部 AJA 板卡、按 `kStreamingAppID` 抢占式独占（一张卡同时只服务一个 OBS source/output） |
| `aja-routing.cpp` / `.hpp` | 532 / 60 | 信号路由字符串解析器（如 `"sdi[0][0]->fb[0][0]"`），把易读的 shorthand 转成固件 crosspoint 连接表 |
| `aja-widget-io.cpp` / `.hpp` | 468 / 36 | 路由字符串里各种"部件昵称"（`fb`/`csc`/`sdi`/`lut`/`mix`…）到固件寄存器 ID 的映射表 |
| `aja-props.cpp` / `.hpp` | 401 / 83 | `SourceProps`/`OutputProps`：一份属性面板状态的结构体封装（设备/制式/像素格式/SDI 传输方式等） |
| `audio-repack.c` / `.h` / `.hpp` | 250 / 48 / 22 | 音频声道重排，和 `decklink/audio-repack.c` 几乎同一份代码的独立拷贝 |
| `aja-vpid-data.cpp` / `.hpp` | 140 / 46 | 解析 SDI 信号里的 VPID（Video Payload ID）辅助数据，判断信号的制式/采样/位深 |
| `aja-ui-props.hpp` | 129 | 属性面板控件 key 的字符串常量集中定义（相当于 decklink 的 `const.h`） |
| `main.cpp` | 47 | 模块入口：先 `CNTV2DeviceScanner` 探测有没有 AJA 卡，没有就直接不加载插件（避免空跑） |
| `aja-enums.hpp` | 66 | `IOSelection`/`SDITransport` 等枚举类型定义 |

### aja-output-ui/　`plugins/aja-output-ui/`

**职责**：AJA 输出的 Qt 配置面板，和 `decklink-output-ui/` 对应。

| 文件 | 行数 | 功能 |
|---|---|---|
| `aja-ui-main.cpp` / `.h` | 448 / 20 | 模块入口 + Tools 菜单挂载 |
| `AJAOutputUI.cpp` / `.h` | 253 / 42 | 对话框信号槽逻辑 |

**与 decklink 的相同与不同**：`aja-source.cpp` 用后台线程轮询（`AJASource::CaptureThread`，:253，`Activate` :421
起线程），跟 decklink 靠 SDK 直接回调（`VideoInputFrameArrived`）拿数据的模式不同——AJA SDK 是"卡驱动准备好数据、
应用主动来问"，DeckLink SDK 是"数据到了驱动主动通知应用"，两种硬件厂商 SDK 的设计哲学差异直接决定了插件代码的
线程模型。除此之外两个插件在"设备发现单例 / 属性面板辅助函数 / 输出 DMA 队列"这几块的分层完全对应，读懂一个另一个
基本靠对照着看就行，不需要逐文件通读两遍。

---

## obs-browser/　`plugins/obs-browser/`

**职责**：把 Chromium（通过 **CEF, Chromium Embedded Framework**）整个嵌进 OBS，做成两种东西：
(1) 浏览器源——网页渲染结果当一路视频源合成进画布；(2) 自定义面板（dock）——OBS 主界面里能停靠的网页 UI
（比如 Stream Deck 官方面板、各种第三方控制面板）。子模块已拉取（`ea04212`，134 个文件），以下基于实际代码。

**CEF 怎么以独立子进程方式跑**：CEF 是多进程架构（浏览器进程 + 若干渲染子进程），OBS 主程序自己是"浏览器进程"，
渲染网页的活交给一个独立可执行文件 `obs-browser-page`（源码在 `obs-browser-page/obs-browser-page-main.cpp`，
入口只是 `CefExecuteProcess`，`obs-browser-plugin.cpp:371`）。`obs-browser-plugin.cpp` 里
`CefString(&settings.browser_subprocess_path) = abs_path`（:346）把这个可执行文件的路径喂给 `CefSettings`，
`settings.multi_threaded_message_loop = false`（:315）说明 CEF 消息循环是跟 OBS 自己的 Qt/GUI 主循环合并跑的，
不是各起各的。子进程崩溃（比如某个网页把渲染进程搞挂了）不会带崩 OBS 主进程——这是选它而不是自己拿 libcef 裸调的
主要原因。

**网页画面如何变成 OBS 纹理**：查代码确认，**两条路都有，运行时二选一**（`browser-client.cpp`）：
1. **共享纹理（GPU 零拷贝）**：`OnAcceleratedPaint`（:372）/`OnAcceleratedPaint2`（:468）——CEF 直接把渲染结果
   放进一块 GPU 侧共享内存对象，macOS 上是 `IOSurfaceRef`（`gs_texture_create_from_iosurface`，:435/:492），
   Windows 上是 D3D 共享句柄（`gs_texture_open_shared`/`gs_texture_open_nt_shared`，:441/:449/:497）——网页画面
   全程不经过 CPU。
2. **CPU 回读（`OnPaint`，:304）**：CEF 把渲染结果拷进一块 CPU 内存 `buffer`，OBS 侧 `gs_texture_create(width,
   height, GS_BGRA, 1, (const uint8_t **)&buffer, GS_DYNAMIC)`（:330）逐帧重新上传成纹理——这是老路径/兜底路径，
   多一次 CPU→GPU 拷贝。
   走哪条路由 `hwaccel` 开关 + 编译期 `ENABLE_BROWSER_SHARED_TEXTURE` 决定（`obs-browser-source.cpp:187`
   `tex_sharing_avail = gs_shared_texture_available()`），硬件不支持共享纹理时自动退化成 `OnPaint`。

**给网页的 JS API（`window.obsstudio`）定义在哪**：`browser-app.cpp`，`BrowserApp::OnContextCreated`（:110）——
每个网页 JS 上下文创建时，往 `window` 全局对象上挂一个 `obsstudio` 对象（:114-115），再把 `exposedFunctions`
（:102-108，一个函数名字符串数组：`getControlLevel`/`getCurrentScene`/`startRecording`/`stopStreaming`/`setCurrentScene`/
`getTransitions`… 共 19 个）逐个注册成 `CefV8Value::CreateFunction`（:120-123）。网页调用这些函数时走
`BrowserApp::Execute`（:311，进程内 V8 回调）→ CEF 进程间消息 → OBS 主进程侧真正执行（`obs-browser-source.cpp`
里对应处理，权限受 `ControlLevel` 枚举限制，见 `obs-browser-source.hpp` 的 `enum class ControlLevel`）。反方向，
OBS 主进程也能主动调网页里的 JS 函数：`BrowserApp::ExecuteJSFunction`（:128）用于推送 `onVisibilityChange`/
`onSceneChange` 这类事件回调（`dispatchEvent`，:266）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-browser-plugin.cpp` | 794 | 模块入口：CEF 初始化/关闭（含上文的子进程路径配置）、`obs_source_info` 注册（`.mouse_click`/`.key_click` 等交互回调全在这，转发到 `BrowserSource` 方法，:432-499） |
| `linux-keyboard-helpers.hpp` | 749 | 纯 Linux：X11 keysym → CEF 键码映射表（体积大是因为要覆盖所有键位），macOS/Windows 不编译此文件 |
| `obs-browser-source.cpp` ⭐ | 675 | 浏览器源核心实现类 `BrowserSource`，见下方展开 |
| `browser-client.cpp` | 655 | CEF `CefRenderHandler`/`CefClient` 实现：上文讲的 `OnPaint`/`OnAcceleratedPaint*` 都在这 |
| `panel/browser-panel.cpp` | 591 | 自定义面板（dock）实现：`QCefWidget` 把一个 CEF 浏览器实例嵌进 Qt dock 控件 |
| `panel/browser-panel-client.cpp` | 502 | 面板专用的 CEF client（右键菜单：开发者工具/静音/缩放/复制链接，:23-28 菜单项常量） |
| `browser-app.cpp` ⭐ 见上文 | 425 | 渲染进程侧的 `CefApp`/`CefRenderProcessHandler`：`window.obsstudio` 全部在这 |
| `browser-client.hpp` | 150 | `browser-client.cpp` 的类声明 |
| `obs-browser-source.hpp` | 135 | `BrowserSource` 类声明，`ControlLevel` 枚举定义在此 |
| `obs-browser-page/obs-browser-page-main.cpp` | 134 | 独立子进程可执行文件的 `main`，本质只是转发进 `CefExecuteProcess` |
| `panel/browser-panel.hpp` | 122 | 上面的类声明 |
| `browser-app.hpp` | 110 | `browser-app.cpp` 的类声明 |
| `panel/browser-panel-client.hpp` | 104 | 上面的类声明 |
| `browser-scheme.cpp` / `.hpp` | 71 / 31 | 自定义 URL scheme handler（本地资源协议，给面板/源加载打包进 OBS 的本地网页资源用） |
| `panel/browser-panel-internal.hpp` | 68 | 面板内部共享的私有声明（不对外暴露的实现细节） |
| `cef-headers.hpp` | 62 | 统一 `#include` CEF 各头文件的聚合头，屏蔽不同 CEF 版本的差异 |
| `drm-format.cpp` / `.hpp` | 59 / 21 | Linux DMA-BUF 场景下 CEF 像素格式 ↔ DRM fourcc 格式转换表，非 Linux 平台基本不生效 |

（`deps/base64/` 是 vendored 的第三方 base64 编解码库，只被 `browser-client.cpp` 用来传大块二进制数据，不逐文件展开。）

### ⭐ 重点文件展开

#### `obs-browser-source.cpp`
- **做什么**：`BrowserSource` 类——`obs-browser-plugin.cpp` 里注册的 `obs_source_info` 全部回调最终都落到这个类的
  方法上。`CreateBrowser`（:180）用 `CefBrowserHost::CreateBrowserSync`（:232）真正开一个网页；`Update`（:456）
  响应属性面板变化（URL/分辨率/FPS/是否常驻刷新）；`Render`（:575）每帧把 `texture`（共享纹理或 `OnPaint` 上传出的
  纹理，二者对源代码是同一个 `gs_texture_t*` 字段）画到画布上，Apple 平台还专门处理了 OpenGL 后端下的坐标翻转
  （`flip`，:577-580）。`SendMouseClick`/`SendMouseMove`/`SendMouseWheel`/`SendKeyClick`（:252/:271/:288/:310）把
  OBS canvas 上的用户交互事件转换坐标后转发进 CEF（`SendMouseClickEvent` 等 CEF Host API），这就是"浏览器源可以
  直接在预览里点击网页"的实现路径。
- **关键入口**：`CreateBrowser`（:180）、`Render`（:575）、`Update`（:456）、`SetShowing`（:363，控制
  `deactivate_when_not_showing` 这类省资源开关）。
- **看点**：这是本篇里"框架包办细节、插件只管业务"的又一个样板——真正的 CEF 渲染管线细节（`OnPaint`/
  `OnAcceleratedPaint`）扔给 `browser-client.cpp`，`BrowserSource` 只管"什么时候该有 browser 实例、什么时候该把
  当前纹理画出来、用户交互怎么转发"。跟 `libobs/obs-source-transition.c` 包办转场取纹理、插件只写混合逻辑是
  同一种分工思路的第三次复用（前两次见 `05_plugins_源_滤镜_转场.md` 的滤镜/转场篇）。

---

## obs-websocket/　`plugins/obs-websocket/`

**职责**：让外部程序（Stream Deck、脚本、第三方中控台）通过标准 WebSocket 连接远程控制/查询 OBS 状态——协议是
obs-websocket 5.x（rpc version 1），JSON 报文，基于 `websocketpp`（`WebSocketServer.h:27-28`，
`asio_no_tls` 配置，即裸 WebSocket，TLS 由外层反代或 `wss://` 单独配置决定）。子模块已拉取（`1fcb95b`，5.7.3，181 个文件）。

### 协议层（`websocketserver/`）

**职责**：TCP 连接管理、握手、opcode 分发——不知道"场景""源"这些 OBS 概念，只认 JSON 报文结构。

`WebSocketOpCode`（`types/WebSocketOpCode.h`）定义了报文种类：`Hello`(0，服务端主动打招呼) → 客户端回
`Identify`(1，带密码认证 + 想订阅哪些事件) → 服务端回 `Identified`(2) → 之后才能发 `Request`(6)/`RequestBatch`(8)，
服务端也会随时推 `Event`(5)。整个状态机在 `WebSocketServer::ProcessMessage`
（`websocketserver/WebSocketServer_Protocol.cpp:69`）里用 `switch(opCode)` 实现：未 `Identified` 前只认
`Identify`（:84），`Request`（:190）取出 JSON 里的 `requestType`+`requestData` 转手交给
`RequestHandler::ProcessRequest`（属于下一层）、`RequestBatch`（:235）支持串行/并行/"遇错即停"三种批处理策略。

| 文件 | 行数 | 功能 |
|---|---|---|
| `WebSocketServer.cpp` / `.h` | 464 / 104 | `websocketpp::server` 生命周期：`onOpen`/`onClose`/`onMessage`/`onValidate` 绑定（:44-48）、监听端口、连接表 `_sessions` |
| `WebSocketServer_Protocol.cpp` ⭐ | 411 | 报文级状态机（Hello/Identify/Request/RequestBatch），见下方展开 |
| `rpc/WebSocketSession.h` | 109 | 单个客户端连接的会话状态（认证是否通过、订阅的事件掩码、RPC 版本协商结果） |
| `types/WebSocketOpCode.h` | 129 | 上文的 opcode 枚举 + 每个值的用途注释（文档生成器会读这些注释生成官方协议文档） |
| `types/WebSocketCloseCode.h` | 172 | 各类"主动断开"的错误码（认证失败/JSON 格式错/协议版本不匹配等），配文档注释 |

### 请求处理（`requesthandler/`）

**职责**：把已解析的 JSON 请求路由到具体的 OBS 操作，是这个插件"能干什么"的主体。所有请求方法都是
`RequestHandler` 这一个类的成员函数，但**按业务类别拆进不同 `.cpp` 编译单元**（类声明集中在 `RequestHandler.h`，
`_handlerMap` 这张总调度表在 `RequestHandler.cpp` 里按分类注释分段列出，`RequestHandler.cpp:26` 起）：

| 请求类别文件 | 行数 | 覆盖哪类请求 |
|---|---|---|
| `RequestHandler_Inputs.cpp` | 1114 | 输入源（`obs_source_t` 里非场景类）：音量/静音/滤镜列表/属性读写，本组体量最大 |
| `RequestHandler_SceneItems.cpp` | 846 | 场景条目（一个源挂在某场景里的位置/大小/裁剪/可见性/z 序） |
| `RequestHandler_Config.cpp` | 658 | 场景集合/配置文件/持久化数据/录制目录/画布分辨率等全局设置 |
| `RequestHandler_Outputs.cpp` | 487 | 通用输出状态（虚拟摄像头/回放缓冲，跟 `RequestHandler_Stream`/`_Record` 分开是因为这俩最常用、单独占了文件） |
| `RequestHandler_Scenes.cpp` | 460 | 场景增删查改、当前场景切换 |
| `RequestHandler_Filters.cpp` | 377 | 源滤镜的增删查改（对应 `05_plugins_源_滤镜_转场.md` 里的 `obs-filters/`） |
| `RequestHandler_General.cpp` | 374 | 版本号/统计信息/热键触发/自定义事件广播/Vendor 请求转发 |
| `RequestHandler_Sources.cpp` | 357 | 源的通用操作（截图、激活状态、隐私遮罩） |
| `RequestHandler_Transitions.cpp` | 334 | 转场（对应 `obs-transitions/`）的当前值/切换/时长 |
| `RequestHandler_Ui.cpp` | 309 | 主界面 UI 操作（studio mode、弹窗、当前分屏预览等） |
| `RequestHandler_Record.cpp` | 248 | 录制开始/停止/暂停/切片 |
| `RequestHandler.cpp` / `.h` | 239 / 227 | 总调度：`_handlerMap` 定义 + `ProcessRequest`（:221 起按 `RequestType` 查表调用） |
| `RequestBatchHandler.cpp` / `.h` | 234 / 31 | `RequestBatch` 的串行/并行执行器（并行用 `QThreadPool`） |
| `RequestHandler_MediaInputs.cpp` | 206 | 媒体源播放控制（对应 obs-studio 里的 `ffmpeg-source`：播放/暂停/seek） |
| `RequestHandler_Stream.cpp` | 162 | 推流开始/停止/状态 |
| `RequestHandler_Canvases.cpp` | 64 | 多画布（OBS 30+ 新增的多 canvas 特性）的查询 |
| `rpc/Request.cpp` / `.h` | 408 / 86 | 单条请求的 JSON 解析辅助（类型检查宏、默认值兜底），被所有 `RequestHandler_*.cpp` 复用 |
| `rpc/RequestResult.cpp` / `.h` | 38 / 34 | 统一的响应结构（状态码 + comment + 结果 JSON） |
| `types/RequestStatus.h` | 419 | 全部状态码枚举 + 逐个的文档注释（体积大是因为注释多，不是逻辑复杂） |
| `types/RequestBatchExecutionType.h` | 84 | 批处理的三种模式（`SerialRealtime`/`SerialFrame`/`Parallel`）定义 |

### 事件处理（`eventhandler/`）

**职责**：反方向——OBS 内部状态变化（切场景、录制状态变化、源属性变化…）时主动推给已订阅的客户端。挂钩方式是
`obs_frontend_add_event_callback` + 各类 `obs_source`/`obs_output` 的 signal handler，按同样的业务分类拆文件，
和 `requesthandler/` 一一对应；`EventHandler.cpp`（671 行，本组最大）是核心类实现，其余 `EventHandler_*.cpp`
只是把某类 OBS 信号翻译成 `Broadcast`（对应 `WebSocketServer::BroadcastEvent`）调用。

| 文件 | 行数 | 功能 |
|---|---|---|
| `EventHandler.cpp` | 671 | 核心：注册全部 OBS signal/frontend 回调、`Broadcast` 统一出口、按 `EventSubscription` 位掩码过滤该发给谁 |
| `EventHandler.h` | 201 | 类声明；`InternalEventSubscriptions` 之类的回调类型定义 |
| `EventHandler_Inputs.cpp` | 452 | 输入源相关事件（音量变化/静音切换/滤镜增删） |
| `EventHandler_SceneItems.cpp` | 307 | 场景条目变化事件（增删/可见性/变换） |
| `EventHandler_MediaInputs.cpp` | 207 | 媒体源播放状态事件（开始/结束/暂停/媒体切换） |
| `EventHandler_Scenes.cpp` | 184 | 场景增删/当前场景切换事件 |
| `EventHandler_Outputs.cpp` | 174 | 输出状态变化（流/录制/回放缓冲的开始停止） |
| `EventHandler_Transitions.cpp` | 155 | 转场切换/时长变化事件 |
| `EventHandler_Config.cpp` | 145 | 场景集合/配置文件切换事件 |
| `EventHandler_Filters.cpp` | 227 | 滤镜增删/启用禁用/重排序事件 |
| `EventHandler_Canvases.cpp` | 88 | 多画布增删事件 |
| `EventHandler_Ui.cpp` | 64 | Studio Mode 开关等 UI 事件 |
| `EventHandler_General.cpp` | 36 | 通用退出事件（`ExitStarted`） |
| `types/EventSubscription.h` | 224 | 订阅位掩码枚举（客户端 `Identify` 时声明只要哪几类事件，减少无谓流量） |

### 序列化与工具（`utils/`）

**职责**：JSON ↔ OBS 数据结构的转换胶水，以及跟 `libobs`/加密/平台相关的辅助函数，是上面两层能保持"只管业务逻辑"的
基础设施。

| 文件 | 行数 | 功能 |
|---|---|---|
| `Obs.h` / `.cpp` | 294 / 21 | `Utils::Obs` 命名空间总声明（`ActionHelper`/`ArrayHelper`/`NumberHelper`/`ObjectHelper`/`SearchHelper` 分别在各自 `.cpp` 里实现） |
| `Obs_ArrayHelper.cpp` | 388 | 把 OBS 的场景/源/滤镜列表序列化成 JSON 数组（`GetSceneList`/`GetInputList` 这类请求的共同底层） |
| `Obs_VolumeMeter.cpp` / `.h` / `Obs_VolumeMeter_Helpers.h` | 357 / 100 / 107 | 音量表事件推送（`InputVolumeMeters` 高频事件的采样与节流逻辑） |
| `Json.cpp` / `.h` | 224 / 103 | `obs_data_t` ↔ `nlohmann::json` 双向转换、JSON 合法性校验 |
| `Obs_SearchHelper.cpp` | 139 | 按名称/UUID 查找源、场景条目等的统一查找辅助 |
| `Platform.cpp` / `.h` | 127 / 33 | 跨平台小工具（获取 OBS 版本/系统信息，供 `GetVersion` 请求用） |
| `Obs_ActionHelper.cpp` | 120 | 触发类操作的封装（截图、热键调用等无返回值的"动作"） |
| `Obs_StringHelper.cpp` | 118 | 字符串枚举值转换（比如 `obs_media_state` 数值转可读字符串） |
| `Obs_ObjectHelper.cpp` | 113 | 单个 OBS 对象（源/场景条目）序列化成 JSON object 的共同逻辑 |
| `Obs_NumberHelper.cpp` | 85 | 数值类型的边界检查/转换（防止 JS 客户端传来的数字精度问题） |
| `Crypto.cpp` / `.h` | 85 / 32 | 认证用的 SHA-256 challenge/response 计算（Qt `QCryptographicHash`） |
| `Compat.cpp` / `.h` | 32 / 38 | 跨 OBS 版本的兼容垫片（新旧 API 名字变化时在这里桥接） |
| `Utils.h` | 27 | 零散的小宏/小函数 |

### Qt 配置界面（`src/forms/`）与模块入口

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-websocket.cpp` / `.h` | 304 / 53 | 模块入口：`obs_module_load` 里启动 `WebSocketServer`/`EventHandler`，挂 Tools 菜单 |
| `Config.cpp` / `.h` | 227 / 47 | 持久化配置（端口/密码/是否随 OBS 启动自动开服务），存进 `global.ini` |
| `WebSocketApi.cpp` / `.h` | 377 / 89 | 对外暴露给**其他 OBS 插件**的 C API（`obs_websocket_vendor`——让第三方插件也能注册自己的 vendor request/event，不用改 obs-websocket 源码） |
| `forms/SettingsDialog.cpp` / `.h` | 317 / 55 | Tools 菜单里的设置对话框（端口/密码/显示连接信息） |
| `forms/ConnectInfo.cpp` / `.h` | 135 / 47 | "显示连接信息"弹窗（二维码/明文密码，方便手机客户端扫码连） |

（`lib/example/` 是给第三方开发者看的 vendor API 示例代码，不逐文件展开。）

### ⭐ 重点文件展开

#### `WebSocketServer_Protocol.cpp`
- **做什么**：整个 obs-websocket 协议的状态机落地实现，一个函数 `ProcessMessage`（:69）用大 `switch` 覆盖全部
  6 种客户端可发的 opcode。`Identify`（:91）分支校验 RPC 版本协商、密码 challenge/response（用到 `utils/Crypto.cpp`），
  通过后把会话标记为已认证并回 `Identified`；`Request`（:190）分支直接 new 一个 `RequestHandler` 实例（每个请求都是
  新实例，无跨请求状态）调 `ProcessRequest`；`RequestBatch`（:235）分支多出一层校验：`Parallel` 模式要求线程池
  ≥2 线程（:260，否则拒绝防止死锁）、`variables` 变量替换不支持并行模式（:277）——这些校验本身就是"批处理为什么
  要分三种执行策略"的最好文档。
- **关键入口**：`ProcessMessage`（:69）、`SetSessionParameters`（:57）、`BroadcastEvent`（:356，事件推送出口，
  被 `eventhandler/` 反向调用）。
- **看点**：认证前只放行 `Identify`（:84 的检查）是这类"先握手后干活"协议的标准防御写法；`RequestBatch` 三种
  执行策略（`SerialRealtime`/`SerialFrame`/`Parallel`）体现了一个设计取舍——外部脚本经常需要"连续挪 10 个源的
  位置再统一提交"这种原子操作诉求，obs-websocket 用批处理执行策略而不是引入事务/锁来满足，思路上更接近"提前
  声明好这批操作要不要能并发"而不是运行时加锁。

---

## frontend-tools/　`plugins/frontend-tools/`

**职责**：一批各自独立、挂在 OBS 主界面 Tools 菜单下的小工具，互相之间没有依赖，删掉其中任何一个不影响别的。
唯一的公共点是都通过 `obs-frontend-api`（而不是核心合成协议）跟主界面打交道——这也是为什么它们能作为"外围工具"
而不是核心功能存在。

| 文件 | 行数 | 功能 |
|---|---|---|
| `scripts.cpp` / `.hpp` | 694 / 64 | 脚本管理器：Lua/Python 脚本的加载/热重载/日志窗口/属性面板生成，`ENABLE_SCRIPTING` 编译期开关，见下方展开 |
| `auto-scene-switcher.cpp` ⭐ / `.hpp` | 525 / 46 | 自动切场景：按前台窗口标题正则匹配切场景，见下方展开 |
| `captions.cpp` / `.hpp` | 439 / 21 | Windows 语音字幕主逻辑：把麦克风音频喂给 Windows 语音识别 API，转成文字源实时更新，**仅 Windows**（顶部 `#include <windows.h>` 无条件编译） |
| `captions-mssapi-stream.cpp` / `.hpp` | 410 / 87 | 给 MSSAPI（Microsoft Speech API）喂音频流的 `IStream` 实现，PCM 环形缓冲 |
| `output-timer.cpp` / `.hpp` | 332 / 44 | 输出计时器：设定录制/推流的定时时长，到点自动停止 |
| `auto-scene-switcher-nix.cpp` | 199 | Linux 平台实现：X11 `XGetInputFocus` 拿前台窗口标题 |
| `captions-mssapi.cpp` / `.hpp` | 186 / 47 | MSSAPI 识别引擎的初始化/结果回调，继承 `captions-handler.hpp` 的抽象基类 |
| `captions-handler.hpp` / `.cpp` | 57 / 43 | 字幕识别引擎的抽象基类 + 音频重采样封装（`resampler_obj`），为将来接入别的语音识别引擎（非 MSSAPI）留的抽象层 |
| `auto-scene-switcher-win.cpp` | 77 | Windows 平台实现：`GetWindowTextW`/`GetForegroundWindow` |
| `frontend-tools.c` | 45 | 模块入口：按平台条件编译分别 `InitSceneSwitcher`/`InitCaptions`（仅 Win）/`InitOutputTimer`/`InitScripts`（需 `ENABLE_SCRIPTING`） |
| `auto-scene-switcher-osx.mm` | 45 | **macOS 实现**：`NSWorkspace.runningApplications` 只拿到"前台运行的 App 名字"，不像 Win/X11 能拿到具体窗口标题——见下方取舍说明 |
| `tool-helpers.hpp` | 36 | 全组共用的小工具：按名字找 `OBSWeakSource`、弱引用转字符串名 |

**macOS 上关心的话**：`auto-scene-switcher-osx.mm` 是本目录唯一的 macOS 专属实现（其余俩平台文件不参与编译），
只有 45 行——因为 macOS 出于沙盒/隐私限制，普通 App 拿不到别的 App 具体的窗口标题（Accessibility 权限之外),
`GetWindowList`（:7）能做到的只是"枚举当前运行的 App 列表"（`NSRunningApplication.localizedName`），
匹配规则的粒度天然比 Windows/X11 版本粗（后两者能匹配到具体窗口标题文本，macOS 版本只能匹配到 App 名字）。
这是三个平台文件里**逻辑最简单**但**能力天花板最低**的一份，想在 WorkOBS/libwl 里做类似功能，第一步就要想清楚
"macOS 到底能拿到多细粒度的前台信息"这个平台限制。

**`data/scripts/` 内置脚本**（Lua/Python，供 `scripts.cpp` 加载，每个脚本对应一个独立小功能）：

| 文件 | 行数 | 功能 |
|---|---|---|
| `countdown.lua` | 180 | 倒计时文字源：热键启动，每秒更新一个文字源的内容显示剩余时间 |
| `instant-replay.lua` | 158 | 即时回放：热键触发 `obs_frontend_get_replay_buffer_output` 保存回放缓冲并可自动播放到指定媒体源 |
| `clock-source.lua` | 119 | 自定义时钟源：`OBS_SOURCE_CUSTOM_DRAW` 类型，用 4 张图片（表盘/时/分/秒针）拼一个模拟时钟画面 |
| `url-text.py` | 77 | 定时从一个 URL 拉取文本、写进指定文字源（`urllib.request`，Python 版） |
| `pause-scene.lua` | 44 | 切到指定场景时自动暂停录制、切走时自动恢复——常用于"暂停画面"场景 |

### ⭐ 重点文件展开

#### `auto-scene-switcher.cpp`
- **做什么**：`SwitcherData::Thread`（:398）是个独立线程，`interval` 毫秒轮询一次当前前台窗口标题
  （`GetCurrentWindowTitle`，平台实现分别在 `-win.cpp`/`-nix.cpp`/`-osx.mm`），拿到标题后遍历用户配置的
  `switches`（`vector<SceneSwitch>`，每条是一个"正则表达式 → 目标场景"的映射，:23-27 `SceneSwitch` 结构体里
  `regex re` 直接拿窗口标题当正则源串编译），第一条 `regex_match`（:434）命中的规则对应场景就是要切的目标，
  一条都不命中且开了 `switchIfNotMatching` 就切到兜底场景 `nonMatchingScene`。`Prune`（:52 起）在场景被删除后
  清理失效的 `OBSWeakSource` 弱引用，避免野指针。
- **关键入口**：`SwitcherData::Thread`（:398）、`SwitcherData::Start`（:464）/`Stop`（:471）、
  `SceneSwitch` 结构体（:23）。
- **看点**：拿"窗口标题"直接当正则表达式编译（而不是先转义再做子串匹配）是个很直白但也很危险的设计——用户如果
  在窗口标题匹配框里手滑打进正则元字符（`.`/`*`/`(`），行为会变得难以预测；但换来的好处是配置一条"标题包含
  `Chrome.*YouTube`"这种模糊匹配规则非常轻量，不需要额外发明一套匹配语法。整个自动切场景功能就是"轮询 +
  正则匹配 + 弱引用管理"三件套，没有更复杂的状态机，是这批 frontend-tools 里最值得当"最小工具插件"范本来读的一个。

---

## 阅读建议

1. `decklink/` 和 `aja/` 建议对照读：`decklink-device-instance.cpp`（SDK 回调驱动）vs `aja-source.cpp`/
   `AJASource::CaptureThread`（轮询驱动）——同样是"专业采集卡输入源"，两家 SDK 的线程模型完全相反，这组对比
   比单独读哪一个收获都大。两边的 SDK 本身（decklink 是 vendored 头文件、aja 是外部链接库）都不用读，
   只看 OBS 自己写的胶水代码。
2. `decklink-output-ui/`、`aja-output-ui/`、`decklink-captions/` 是三个很薄的 Qt 面板/小工具，扫一眼
   `obs_output_t`/`obs_source_t` 怎么被面板持有和操作即可，不需要精读。
3. `obs-browser/` 先读 `obs-browser-plugin.cpp` 里 `struct obs_source_info info` 那段（:432-499）建立"哪些回调
   转发到哪个类"的地图，再读 `obs-browser-source.cpp` 的 `Render`/`Update`，最后读 `browser-client.cpp` 的
   `OnPaint`/`OnAcceleratedPaint*` 搞清楚纹理从哪来——这个顺序比直接扎进 `browser-client.cpp` 更容易建立全局感。
   `browser-app.cpp` 的 `window.obsstudio` 部分（:102-128）单独读，跟纹理管线关系不大。
4. `obs-websocket/` 不需要通读每个 `RequestHandler_*.cpp`/`EventHandler_*.cpp`——先读
   `WebSocketServer_Protocol.cpp` 的 `ProcessMessage` 建立协议全貌，再扫一眼 `RequestHandler.cpp` 的 `_handlerMap`
   感受请求分类粒度，之后要用哪类请求（比如做转场自动化）再回头翻对应的 `RequestHandler_Transitions.cpp`。
   `utils/` 下的一堆 `Obs_*Helper.cpp` 属于"要用的时候才看"的胶水，不必提前读。
5. `frontend-tools/` 各文件互相独立，`auto-scene-switcher.cpp` 是最值得读的一个（轮询+正则+弱引用三件套，
   结构最完整但依然足够小）；`captions*` 系列是 Windows-only、且依赖 MSSAPI，跟本项目 macOS 场景关系不大，
   可以整体跳过；`scripts.cpp` 如果不打算给 WorkOBS/libwl 做脚本扩展能力，也可以跳过。
6. 想找"某个具体请求/事件在哪"，直接用本篇速查表或 `requesthandler`/`eventhandler` 的分类表按业务名对号入座，
   不必打开 `RequestHandler.cpp` 从头翻 `_handlerMap`。
