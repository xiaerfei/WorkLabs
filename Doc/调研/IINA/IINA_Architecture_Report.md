# IINA 项目架构调研报告

## 1. 项目概述

**IINA** 是一款现代化的 macOS 原生视频播放器，基于 [mpv](https://mpv.io/) 媒体播放引擎构建。项目使用 **Swift** 为主（少量 Objective-C）编写，采用 **Xcode** 构建系统。

- **仓库地址**: https://github.com/iina/iina
- **当前版本分支**: release/1.4.3
- **主要语言**: Swift (179 个 .swift 文件) + Objective-C (7 个 .m/.h 文件)
- **UI 框架**: AppKit (NSWindow / NSView)
- **核心依赖**: mpv、FFmpeg、JavaScriptCore、Sparkle (自动更新)

---

## 2. 整体架构

### 2.1 架构模式

IINA 采用 **MVC (Model-View-Controller)** 架构，结合以下设计模式：

| 模式 | 应用场景 |
|------|----------|
| **单例模式** | `HistoryController.shared`, `CacheManager.shared`, `NowPlayingInfoManager.shared` |
| **代理模式 (Delegate)** | `FFmpegControllerDelegate`, `WebSocketServerDelegate`, `NSWindowDelegate` |
| **观察者模式** | `NotificationCenter`、KVO 属性观察、`EventController` |
| **命令模式** | `MPVCommand`, `MPVCommandWrappers` 封装 mpv 命令 |
| **工厂模式** | `PlayerCore.createPlayerCore()` 创建播放器实例 |
| **策略模式** | 多种字幕获取器 (`OnlineSubtitleFetcher`) |

### 2.2 核心架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                        AppDelegate                              │
│  (应用生命周期管理、全局窗口、菜单、URL Scheme 处理)              │
└─────────────────────┬───────────────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ PlayerCore 1 │ │ PlayerCore 2 │ │ PlayerCore N │  ← 多实例支持
│   (播放器)    │ │   (播放器)    │ │   (播放器)    │
└──────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                │                │
       ▼                ▼                ▼
┌──────────────────────────────────────────────────────────────────┐
│                    播放器内部组件                                  │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────┐ ┌───────────┐ │
│  │MPVController│ │ PlaybackInfo │ │EventControl│ │  Plugins  │ │
│  │  (mpv桥接)   │ │  (播放状态)   │ │  (事件分发)  │ │ (JS插件)  │ │
│  └──────┬──────┘ └──────────────┘ └────────────┘ └───────────┘ │
│         │                                                       │
│  ┌──────┴──────┐ ┌──────────────┐ ┌────────────────────────┐   │
│  │  VideoView  │ │ FFmpegControl│ │   Window Controllers   │   │
│  │  (OpenGL)   │ │  (缩略图)     │ │  Main / Mini / Initial │   │
│  └─────────────┘ └──────────────┘ └────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 3. 核心组件详解

### 3.1 PlayerCore — 播放器核心

**文件**: `iina/PlayerCore.swift`

`PlayerCore` 是整个播放器的核心类，负责：
- 管理 mpv 实例的生命周期
- 协调各子系统（视频、音频、字幕、播放列表）
- 支持多实例（同时打开多个播放窗口）

```swift
class PlayerCore: NSObject {
    static let first: PlayerCore = createPlayerCore()        // 首个实例
    static var playerCores: [PlayerCore] = []                 // 所有实例
    static var active: PlayerCore                             // 当前活跃实例
    static var newPlayerCore: PlayerCore                      // 获取新实例

    var mpv: MPVController!          // mpv 控制器
    var info: PlaybackInfo           // 播放状态信息
    var mainWindow: MainWindowController!
    var miniPlayer: MiniPlayerWindowController!
    var plugins: [JavascriptPluginInstance] = []
    var events = EventController()   // 事件控制器
}
```

**播放器状态机** ([PlayerState.swift](iina/PlayerState.swift)):

```
idle → loading → starting → loaded → playing ⇄ paused
                    ↓                      ↓
                  stopping → idle      stopping → idle

shuttingDown → shutDown (终态)
```

### 3.2 MPVController — mpv 桥接层

**文件**: `iina/MPVController.swift`

`MPVController` 是 IINA 与 mpv 之间的桥接层，负责：
- 初始化和管理 mpv handle
- 读取和分发 mpv 事件（通过专用 DispatchQueue）
- 设置和监听 mpv 属性变化
- 发送 mpv 命令

```swift
class MPVController: NSObject {
    var mpv: OpaquePointer!                    // mpv_handle
    var mpvRenderContext: OpaquePointer?       // 渲染上下文

    // 监听的属性列表（约 40 个属性）
    let observeProperties: [String: mpv_format] = [
        MPVProperty.trackList: MPV_FORMAT_NONE,
        MPVOption.PlaybackControl.pause: MPV_FORMAT_FLAG,
        MPVOption.Audio.volume: MPV_FORMAT_DOUBLE,
        // ... 更多属性
    ]
}
```

**关键特性**:
- 使用专用 `DispatchQueue` 读取 mpv 事件，避免队列溢出
- 通过 `@Atomic` 属性包装器保证线程安全
- 支持 Hook 系统（Swift 和 JavaScript 两种 Hook）

### 3.3 PlaybackInfo — 播放状态

**文件**: `iina/PlaybackInfo.swift`

存储播放器的实时状态信息：
- 当前播放状态 (`PlayerState`)
- 音量、播放速度、字幕延迟等
- 当前轨道信息（视频/音频/字幕）
- A-B 循环状态
- 播放列表信息

### 3.4 ViewLayer / VideoView — 视频渲染

**文件**: `iina/ViewLayer.swift`, `iina/VideoView.swift`

视频渲染层使用 OpenGL 实现：

```swift
class VideoView: NSView {
    weak var player: PlayerCore!
    var link: CVDisplayLink?                    // 显示链接
    lazy var videoLayer: ViewLayer = ViewLayer(self)
}
```

- `ViewLayer` 继承自 `CAOpenGLLayer`，负责 OpenGL 渲染
- 支持 10-bit 色深、HDR 色调映射
- 支持 ICC 色彩配置文件
- 自动 GPU 切换支持

### 3.5 FFmpegController — FFmpeg 集成

**文件**: `iina/FFmpegController.h`, `iina/FFmpegController.m`

Objective-C 实现的 FFmpeg 控制器，用于：
- 生成视频缩略图（用于进度条预览）
- 读取音频文件的封面艺术
- 探测视频文件信息

---

## 4. 窗口系统

### 4.1 窗口控制器层次

```
PlayerWindowController (基类)
├── MainWindowController     — 主播放窗口（完整 UI）
└── MiniPlayerWindowController — 迷你播放器（音乐模式）
```

### 4.2 主窗口控制器

**文件**: `iina/MainWindowController.swift`

主窗口提供完整的播放器 UI：
- 视频显示区域
- OSC (On-Screen Controller) 控制栏
- 侧边栏（播放列表、设置）
- 标题栏
- 画中画 (PiP) 支持
- 裁剪模式

### 4.3 迷你播放器

**文件**: `iina/MiniPlayerWindowController.swift`

音乐模式下的紧凑播放器：
- 显示专辑封面 / 视频画面
- 简化的播放控制
- 内嵌播放列表

### 4.4 其他窗口

| 窗口 | 文件 | 用途 |
|------|------|------|
| `InitialWindowController` | `InitialWindowController.swift` | 启动时的欢迎/最近文件窗口 |
| `PreferenceWindowController` | `PreferenceWindowController.swift` | 偏好设置 |
| `InspectorWindowController` | `InspectorWindowController.swift` | 媒体信息检查器 |
| `HistoryWindowController` | `HistoryWindowController.swift` | 播放历史 |
| `FilterWindowController` | `FilterWindowController.swift` | 视频/音频滤镜 |
| `LogWindowController` | `LogWindowController.swift` | 日志查看器 |
| `GuideWindowController` | `GuideWindowController.swift` | 使用指南 |
| `FontPickerWindowController` | `FontPickerWindowController.swift` | 字体选择器 |

---

## 5. 插件系统

### 5.1 架构概述

IINA 拥有完整的 JavaScript 插件系统，基于 `JavaScriptCore` 引擎：

```
┌─────────────────────────────────────────────────────────┐
│                    JavascriptPlugin                      │
│  ┌───────────────────────────────────────────────────┐  │
│  │              JavascriptPluginInstance              │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌────────┐  │  │
│  │  │ Core API│ │ Mpv API │ │Event API│ │HTTP API│  │  │
│  │  └─────────┘ └─────────┘ └─────────┘ └────────┘  │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌────────┐  │  │
│  │  │Menu API │ │File API │ │Overlay  │ │Sidebar │  │  │
│  │  └─────────┘ └─────────┘ └─────────┘ └────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 5.2 插件文件

| 文件 | 职责 |
|------|------|
| `JavascriptPlugin.swift` | 插件管理、加载、权限控制 |
| `JavascriptPluginInstance.swift` | 插件实例运行时 |
| `JavascriptAPICore.swift` | 核心 API（打开文件、OSD、播放控制） |
| `JavascriptAPIMpv.swift` | mpv 命令 API |
| `JavascriptAPIEvent.swift` | 事件订阅 API |
| `JavascriptAPIHttp.swift` | 网络请求 API |
| `JavascriptAPIMenu.swift` | 菜单扩展 API |
| `JavascriptAPIOverlay.swift` | 视频叠加层 API |
| `JavascriptAPISidebarView.swift` | 侧边栏视图 API |
| `JavascriptAPIStandaloneWindow.swift` | 独立窗口 API |
| `JavascriptAPIFile.swift` | 文件系统 API |
| `JavascriptAPIWebSocket.swift` | WebSocket API |
| `JavascriptAPIInput.swift` | 输入处理 API |
| `JavascriptAPISubtitle.swift` | 字幕 API |
| `JavascriptAPIPlaylist.swift` | 播放列表 API |
| `JavascriptAPIPreferences.swift` | 偏好设置 API |

### 5.3 插件权限系统

```swift
enum Permission: String {
    case networkRequest = "network-request"     // 网络请求（危险）
    case showOSD = "show-osd"                   // 显示 OSD
    case showAlert = "show-alert"               // 显示弹窗
    case displayVideoOverlay = "video-overlay"  // 视频叠加
    case accessFileSystem = "file-system"       // 文件系统（危险）
}
```

### 5.4 插件 CLI 工具

**目录**: `iina-plugin/`

提供命令行工具用于插件开发：
- `iina-plugin new <name>` — 创建新插件（支持 React/Vue 模板）
- `iina-plugin pack <dir>` — 打包插件为 `.iinaplgz` 文件
- `iina-plugin link <path>` — 链接开发中的插件
- `iina-plugin unlink <path>` — 取消链接

---

## 6. 事件系统

### 6.1 EventController

**文件**: `iina/EventController.swift`

自定义事件系统，用于插件和内部组件间通信：

```swift
class EventController {
    struct Name: RawRepresentable, Hashable {
        // 窗口事件
        static let windowLoaded = Name("iina.window-loaded")
        static let windowFullscreenChanged = Name("iina.window-fs.changed")
        static let windowWillClose = Name("iina.window-will-close")

        // 播放事件
        static let fileLoaded = Name("iina.file-loaded")
        static let fileStarted = Name("iina.file-started")
        static let mpvInitialized = Name("iina.mpv-initialized")

        // UI 事件
        static let thumbnailsReady = Name("iina.thumbnails-ready")
        static let pluginOverlayLoaded = Name("iina.plugin-overlay-loaded")
        static let menuUpdate = Name("iina.menu-update")
    }

    var listeners: [Name: [String: EventCallable]] = [:]
}
```

---

## 7. 数据管理

### 7.1 偏好设置

**文件**: `iina/Preference.swift`

使用 `UserDefaults` 存储，通过类型安全的 Key 访问：

```swift
struct Preference {
    struct Key: RawRepresentable, Hashable {
        static let pauseWhenOpen = Key("pauseWhenOpen")
        static let fullScreenWhenOpen = Key("fullScreenWhenOpen")
        static let softVolume = Key("softVolume")
        // ... 100+ 个配置项
    }
}
```

### 7.2 播放历史

**文件**: `iina/HistoryController.swift`

- 使用 `NSKeyedArchiver` 序列化存储
- 支持记录播放位置以便续播
- 后台队列异步读写

### 7.3 缩略图缓存

**文件**: `iina/CacheManager.swift`, `iina/ThumbnailCache.swift`

- 管理视频缩略图的磁盘缓存
- 支持缓存大小限制和自动清理

### 7.4 按键映射

**文件**: `iina/KeyMapping.swift`, `iina/KeyCodeHelper.swift`

- 支持自定义按键绑定
- 兼容 mpv 原生按键格式
- 支持显示 macOS 原生快捷键样式

---

## 8. 辅助系统

### 8.1 字幕系统

| 文件 | 功能 |
|------|------|
| `OnlineSubtitle.swift` | 在线字幕获取框架 |
| `OpenSubSubtitle.swift` | OpenSubtitles API 集成 |
| `ShooterSubtitle.swift` | 射手网字幕 |
| `AssrtSubtitle.swift` | assrt 字幕 |
| `AutoFileMatcher.swift` | 自动匹配本地字幕文件 |

### 8.2 外部扩展

| 组件 | 目录 | 功能 |
|------|------|------|
| Safari 扩展 | `OpenInIINA/` | Safari 浏览器"在 IINA 中打开"扩展 |
| Chrome 扩展 | `browser/Chrome_Open_In_IINA/` | Chrome 扩展 |
| Firefox 扩展 | `browser/Firefox_Open_In_IINA/` | Firefox 扩展 |
| CLI 工具 | `iina-cli/` | 命令行启动工具 |

### 8.3 系统集成

| 文件 | 功能 |
|------|------|
| `NowPlayingInfoManager.swift` | macOS 控制中心集成 |
| `TouchBarSupport.swift` | Touch Bar 支持 |
| `SleepPreventer.swift` | 防止系统休眠 |
| `PowerSource.swift` | 电源状态监控 |
| `WebSocketServer.swift` | WebSocket 服务器（插件通信） |
| `KeychainAccess.swift` | 钥匙串访问（存储凭据） |

### 8.4 日志系统

**文件**: `iina/Logger.swift`

- 支持多子系统日志（player、video、window 等）
- 支持文件日志输出（可在偏好设置中开启）
- 日志级别：fatal, error, warning, info, debug, verbose

---

## 9. 国际化

项目支持 **50+ 种语言**，通过 `.lproj` 目录实现本地化：

```
iina/
├── en.lproj/       # 英语（基准）
├── zh-Hans.lproj/  # 简体中文
├── zh-Hant.lproj/  # 繁体中文
├── ja.lproj/       # 日语
├── ko.lproj/       # 韩语
├── fr.lproj/       # 法语
├── de.lproj/       # 德语
├── ...             # 更多语言
```

使用 Crowdin 进行翻译管理（`crowdin.yml`）。

---

## 10. 构建系统

### 10.1 Xcode 项目

**目录**: `iina.xcodeproj/`

主要 Target：
- **IINA** — 主应用
- **iina-cli** — 命令行工具
- **iina-plugin** — 插件管理 CLI
- **OpenInIINA** — Safari 扩展

### 10.2 依赖管理

**目录**: `deps/`

预编译的本地依赖：
- `lib/` — 预编译库文件
- `include/` — 头文件
- `executable/` — 可执行文件

### 10.3 配置文件

| 文件 | 用途 |
|------|------|
| `Configs/` | Xcode 配置文件 |
| `.editorconfig` | 编辑器配置 |
| `.gitignore` | Git 忽略规则 |
| `.typos.toml` | 拼写检查配置 |

---

## 11. 关键数据流

### 11.1 播放文件流程

```
用户打开文件
    ↓
AppDelegate.openURLs()
    ↓
PlayerCore.openURLs() → 创建/复用 PlayerCore 实例
    ↓
MPVController.loadfile() → 发送 mpv 命令
    ↓
mpv 事件循环
    ↓
MPV_EVENT_FILE_LOADED → 更新 PlaybackInfo
    ↓
MainWindowController 更新 UI
```

### 11.2 mpv 事件处理流程

```
MPVController.queue (专用线程)
    ↓
mpv_wait_event() → 读取事件
    ↓
switch(event.type)
    ├─ MPV_EVENT_PROPERTY_CHANGE → 更新 PlaybackInfo → 主线程 UI 更新
    ├─ MPV_EVENT_FILE_LOADED → 触发 EventController.fileLoaded
    ├─ MPV_EVENT_SHUTDOWN → 清理资源
    └─ MPV_EVENT_LOG_MESSAGE → Logger 记录
```

---

## 12. 线程模型

| 线程/队列 | 用途 |
|-----------|------|
| **主线程** | UI 更新、用户交互 |
| **MPVController.queue** | mpv 事件读取（高优先级） |
| **PlayerCore.backgroundQueue** | 自动加载文件、字幕匹配 |
| **PlayerCore.playlistQueue** | 播放列表操作 |
| **PlayerCore.thumbnailQueue** | 缩略图生成 |
| **HistoryController.queue** | 历史记录读写 |
| **WebSocketServer.serverQueue** | WebSocket 通信 |

使用 `@Atomic` 属性包装器和 `ReadWriteLock` 保证线程安全。

---

## 13. 总结

### 架构优势

1. **清晰的职责分离**: PlayerCore 管理播放逻辑，WindowController 管理 UI，MPVController 管理底层引擎
2. **多实例支持**: 可同时打开多个播放窗口
3. **可扩展的插件系统**: 基于 JavaScript 的插件架构，API 丰富
4. **完善的事件系统**: 支持内部组件和插件间的解耦通信
5. **线程安全设计**: 使用原子属性和读写锁保护共享状态

### 潜在改进点

1. 部分 UI 逻辑混在 Model 层（如 `KeyMapping` 中的显示逻辑）
2. 可考虑引入更现代的响应式框架（如 Combine）简化状态同步
3. 大量使用 XIB 文件，可逐步迁移到 SwiftUI

---

*报告生成时间: 2026-06-04*
*基于 IINA release/1.4.3 分支*
