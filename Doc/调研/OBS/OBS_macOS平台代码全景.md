# OBS macOS 平台代码全景

> **性质**：OBS 源码级调研 · 平台篇（macOS 平台代码地图 / 旁支专题）。
> **调研对象**：obs-studio `32.1.2-94-gf61619ce3`（`/Users/tvum4pro/Documents/github/obs-studio`）。
> **方法**：Glob/Grep 全仓扫描 + 路径与 CMake 行号核对。
> **目的**：给出 OBS 在 macOS 上「平台相关代码到底落在哪」的全景图，作为后续在 macOS 上取经/移植 WorkLabs 的索引。
>
> **与主系列的关系**：主系列四篇（架构骨架 / 源帧缓冲 / 合成 tick / 输出侧）讲的是**跨平台内核逻辑**；本篇是正交的一刀——把同一棵树里**只在 macOS 编译**的那部分单独抽出来。
> 1. [OBS_架构骨架与WorkLabs模块映射](OBS_架构骨架与WorkLabs模块映射.md) — 架构总览 / 系列入口
> 2. [OBS_源异步帧缓冲与时间戳节流](OBS_源异步帧缓冲与时间戳节流.md)
> 3. [OBS_合成tick_音频混音_AV同步](OBS_合成tick_音频混音_AV同步.md)
> 4. [OBS_输出侧_编码_复用_录制推流](OBS_输出侧_编码_复用_录制推流.md)

---

## 0. 一句话概括

OBS 是**单棵源码树、按平台条件编译**。macOS 平台代码靠三条线索就能全部锁定：**文件扩展名 `.m`/`.mm`/`.swift`**、**目录名 `osx/` `macos/` `apple/`**、**CMake 里的 `if(OS_MACOS)` 与 `cmake/os-macos.cmake`**。整个 macOS 适配分四层落地：**libobs 平台抽象层**（Cocoa/CoreAudio）、**图形后端 libobs-metal**（纯 Swift 的 Metal 渲染器，替代别处的 D3D11/OpenGL）、**6 个 mac 专用插件**（采集/编码/虚拟摄像头）、**前端 + 构建签名**（Sparkle 更新、entitlements、Notarization）。

文件规模（全仓扫描）：`.m` 17 个、`.mm` 21 个、`.swift` 39 个（其中 libobs-metal 占 34 个）。

---

## 1. 三层定位法则（怎么一眼认出 macOS 代码）

| 线索 | 含义 | 例子 |
|------|------|------|
| `*.m` | Objective-C 源文件 | `libobs/obs-cocoa.m` |
| `*.mm` | Objective-C++（C++ 与 ObjC 混编） | `frontend/utility/platform-osx.mm` |
| `*.swift` | Swift，**仅** libobs-metal | `libobs-metal/metal-subsystem.swift` |
| 目录 `osx/` | macOS 专属实现子目录 | `libobs/audio-monitoring/osx/` |
| 目录 `macos/` | CMake 脚本与打包资源 | `cmake/macos/` |
| 目录 `apple/` | Apple 平台通用工具（含 iOS 复用） | `libobs/util/apple/` |
| `if(OS_MACOS)` / `os-macos.cmake` | 构建条件入口 | `CMakeLists.txt:28-30` |

`CMakeLists.txt:28-30` 是图形后端按平台分叉的关键证据：

```cmake
add_subdirectory(libobs-opengl)
if(OS_MACOS)
  add_subdirectory(libobs-metal)   # macOS 才编译 Metal 后端
endif()
```

---

## 2. 第一层：libobs 平台抽象

libobs 内核是跨平台的，但底层「系统调用」被抽象成平台实现文件，macOS 对应 Cocoa/CoreFoundation/CoreAudio：

| 文件 | 职责 |
|------|------|
| `libobs/obs-cocoa.m` | OBS 内核的 Cocoa 平台集成（启动初始化、系统信息等） |
| `libobs/util/platform-cocoa.m` | `os_*` 平台工具的 macOS 实现：路径、时间、动态库加载、CPU 信息 |
| `libobs/audio-monitoring/osx/coreaudio-enum-devices.c` | 基于 CoreAudio 枚举监听设备 |
| `libobs/audio-monitoring/osx/coreaudio-output.c` | 音频监听输出（把混音回放到耳机/扬声器） |
| `libobs/audio-monitoring/osx/coreaudio-monitoring-available.c` | 检测监听是否可用 |
| `libobs/util/apple/cfstring-utils.h` | `CFString` ↔ C 字符串互转工具 |

**构建**：`libobs/cmake/os-macos.cmake` 链接系统框架（`os-macos.cmake:4-10` 起）：`AppKit` `AudioToolbox` `AudioUnit` `Carbon` `Cocoa` `CoreAudio` `IOKit` 等。

> **取经点**：音频监听用 `audio-monitoring/<平台>/` 分目录隔离同一组接口的三种实现（osx / win32 / pulse），是「同一抽象、多平台后端」的干净范式。

---

## 3. 第二层：图形后端 libobs-metal（纯 Swift）

`libobs-metal/` 是 macOS 上的图形渲染后端，**34 个 `.swift` 文件**，对应别的平台上的 `libobs-d3d11`（Windows）/ `libobs-opengl`（跨平台）。它实现 libobs 的 `graphics` 抽象 API（`gs_*`），底层走 Apple Metal。

| 文件 | 职责 |
|------|------|
| `metal-subsystem.swift` | 子系统入口，实现 `gs_*` C 接口桥接到 Metal |
| `MetalDevice.swift` | `MTLDevice` 封装、命令队列 |
| `MetalRenderState.swift` | 渲染状态机 |
| `metal-texture2d.swift` / `metal-indexbuffer.swift` / `metal-zstencilbuffer.swift` / `metal-swapchain.swift` | 纹理、索引缓冲、深度模板、交换链 |
| `MTL*+Extensions.swift`（约 10 个） | Metal 类型与 libobs 枚举的互转扩展 |

> **看点**：这是 OBS 里**唯一**大规模用 Swift 写的模块，且通过 C ABI 与纯 C 的 libobs 内核互通——是「Swift 实现、C 接口暴露」的真实工程样本。

---

## 4. 第三层：macOS 专用插件

`plugins/` 下 6 个目录是 macOS 专属（其余为跨平台插件）。插件入口仍是标准的 `OBS_DECLARE_MODULE`（如 `plugins/mac-capture/plugin-main.c`），与跨平台插件加载机制一致。

| 插件 | 路径 | 作用 | 关键技术 |
|------|------|------|----------|
| **mac-capture** | `plugins/mac-capture/` | 屏幕 / 窗口 / 音频设备捕获 | ScreenCaptureKit（`mac-sck-*.m`）、`mac-display-capture.m`、`mac-window-capture.m` |
| **mac-avcapture** | `plugins/mac-avcapture/` | 摄像头 / 视频输入采集 | AVFoundation，`OBSAVCapture.m`，含 `legacy/av-capture.mm` 旧实现 |
| **mac-syphon** | `plugins/mac-syphon/` | Syphon 协议（应用间 GPU 纹理共享） | `syphon.m` / `SyphonOBSClient.m` |
| **mac-videotoolbox** | `plugins/mac-videotoolbox/encoder.c` | 硬件视频编码（H.264/HEVC） | VideoToolbox.framework |
| **mac-virtualcam** | `plugins/mac-virtualcam/` | 虚拟摄像头（向其他 App 输出 OBS 画面） | DAL 插件（`src/dal-plugin/*.mm`）+ 现代 Camera Extension（`src/camera-extension/`）+ Mach IPC（`OBSDALMachServer/Client`） |
| **coreaudio-encoder** | `plugins/coreaudio-encoder/encoder.cpp` | AAC 音频编码（C++） | CoreAudio AudioConverter |

**跨平台插件里的 macOS 分支**（不在上面 6 个目录，但有 macOS 专用文件）：
- `plugins/frontend-tools/auto-scene-switcher-osx.mm` — 按前台窗口自动切场景
- `plugins/obs-vst/mac/` — VST 音频插件宿主（`VSTPlugin-osx.mm`、`EditorWidget-osx.mm`）
- `plugins/text-freetype2/find-font-cocoa.m` — 文字源的字体查找
- `plugins/obs-browser/cmake/os-macos.cmake` — 浏览器源的 macOS 构建

> **mac-virtualcam 双实现**：老系统走 DAL（DeviceAbstractionLayer，已弃用但兼容老 App），新系统走 Camera Extension（系统级扩展，需独立签名与安装）；二者经 Mach 端口与主进程通信。这是 macOS 系统集成最深的一块。

---

## 5. 第四层：前端 / UI 与构建签名

### 5.1 前端 macOS 代码（`frontend/utility/`）

| 文件 | 职责 |
|------|------|
| `platform-osx.mm` | 前端平台工具(窗口、URL、系统交互) |
| `system-info-macos.mm` | 采集 macOS 系统信息(用于日志/崩溃报告) |
| `CrashHandler_MacOS.mm` | 崩溃处理 |
| `OBSSparkle.mm` / `OBSUpdateDelegate.mm` | Sparkle 框架自动更新集成 |
| `crypto-helpers-mac.mm` | 加密助手(更新签名校验等) |
| `frontend/dialogs/OBSPermissions.cpp` | macOS 权限请求对话框(摄像头/麦克风/屏幕录制授权) |

### 5.2 构建 / 打包 / 签名

| 路径 | 职责 |
|------|------|
| `cmake/macos/` | 全局 macOS 构建：`helpers.cmake`、`xcode.cmake`(代码签名/Notarization)、`compilerconfig.cmake`、`buildspec.cmake` |
| `frontend/cmake/os-macos.cmake` | 前端 macOS 链接与打包配置 |
| `frontend/cmake/feature-sparkle.cmake` | Sparkle 更新特性开关 |
| `frontend/cmake/macos/Info.plist.in` | App 的 Info.plist 模板 |
| `frontend/cmake/macos/entitlements.plist` / `entitlements-extension.plist` | 应用 / 扩展权限(沙盒、硬化运行时、设备访问) |
| `cmake/macos/resources/` | `AppIcon.icns`、DMG 背景 `background.tiff`、打包脚本 `package.applescript` |

签名相关能力(`cmake/macos/xcode.cmake`)：adhoc / 手动 / team 签名、Hardened Runtime、Secure Timestamp、Notarization。

---

## 6. 全景速查表

```
obs-studio/
├── CMakeLists.txt                    # if(OS_MACOS) → libobs-metal
├── libobs/
│   ├── obs-cocoa.m                   # 内核 Cocoa 集成
│   ├── util/platform-cocoa.m         # os_* 平台实现
│   ├── util/apple/                   # CFString 等通用工具
│   ├── audio-monitoring/osx/         # CoreAudio 监听
│   └── cmake/os-macos.cmake          # 框架链接
├── libobs-metal/                     # ★ Swift Metal 图形后端(34 文件)
├── plugins/
│   ├── mac-capture/                  # 屏幕/窗口/音频(ScreenCaptureKit)
│   ├── mac-avcapture/                # 摄像头(AVFoundation)
│   ├── mac-syphon/                   # Syphon 纹理共享
│   ├── mac-videotoolbox/             # VideoToolbox 硬编
│   ├── mac-virtualcam/               # 虚拟摄像头(DAL + Camera Extension)
│   ├── coreaudio-encoder/            # CoreAudio AAC
│   └── (frontend-tools/obs-vst/text-freetype2 内的 *-osx.mm)
├── frontend/utility/*.mm             # 前端平台/Sparkle/崩溃/系统信息
├── frontend/cmake/macos/             # Info.plist / entitlements / 资源
└── cmake/macos/                      # 签名 / Notarization / DMG 打包
```

---

## 7. 对 WorkLabs 的启示

1. **平台隔离靠目录与扩展名，不靠 `#ifdef` 满天飞**：OBS 把平台实现放进 `osx/`/`win32/` 子目录或独立 `*-osx.mm` 文件，CMake 按 `OS_MACOS` 选编译单元。比起在共享源码里塞大量条件编译，这种「同接口多文件」更易读、易测。
2. **图形后端可整体替换**：macOS 用 Metal、Windows 用 D3D11，背后是同一套 `gs_*` 抽象 API。WorkLabs 若要跨平台 GPU 合成,值得照搬「图形抽象层 + 可插拔后端」的边界。
3. **系统能力(采集/编码/虚拟输出)各自成插件**：与内核解耦,单插件失败不拖垮主程序。mac-virtualcam 的 DAL→Camera Extension 双实现,是应对 macOS 系统 API 更替的范例。
4. **Swift 与 C 内核互通可行**：libobs-metal 证明可以用 Swift 写性能模块并通过 C ABI 暴露给纯 C/C++ 内核——为 WorkLabs 在 macOS 上用 Swift 写局部模块提供了先例。
