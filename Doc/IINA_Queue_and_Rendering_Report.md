# IINA 队列设计与渲染体系详细报告

## 1. 队列设计

### 1.1 队列总览

IINA 使用 GCD (Grand Central Dispatch) 的 `DispatchQueue` 作为核心并发框架，为每个 PlayerCore 实例创建独立的队列组，并辅以多种同步原语保证线程安全。

```
┌─────────────────────────────────────────────────────────────────────┐
│                        IINA 队列架构                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    主线程 (Main Thread)                       │   │
│  │  - 所有 UI 更新                                               │   │
│  │  - 播放状态变更通知                                            │   │
│  │  - 用户交互处理                                               │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              ▲                                      │
│                              │ DispatchQueue.main.async             │
│  ┌───────────────────────────┴───────────────────────────────────┐ │
│  │                   MPVController.queue                          │ │
│  │  Label: "com.colliderli.iina.controller"                      │ │
│  │  QoS: .userInitiated                                          │ │
│  │  职责: 读取 mpv 事件、分发到主线程                               │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                   ViewLayer.mpvGLQueue                         │ │
│  │  Label: "com.colliderli.iina.mpvgl"                           │ │
│  │  QoS: .userInteractive (最高优先级)                            │ │
│  │  职责: OpenGL 渲染、帧更新                                     │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │              PlayerCore 实例队列 (每个实例独立)                  │ │
│  │  ┌─────────────────────────────────────────────────────────┐  │ │
│  │  │ backgroundQueue                                          │  │ │
│  │  │ Label: "IINAPlayerCoreTask{N}"                           │  │ │
│  │  │ QoS: .background                                         │  │ │
│  │  │ 职责: 自动加载文件、字幕匹配、后台任务                       │  │ │
│  │  └─────────────────────────────────────────────────────────┘  │ │
│  │  ┌─────────────────────────────────────────────────────────┐  │ │
│  │  │ playlistQueue                                            │  │ │
│  │  │ Label: "IINAPlaylistTask{N}"                             │  │ │
│  │  │ QoS: .utility                                            │  │ │
│  │  │ 职责: 播放列表操作                                        │  │ │
│  │  └─────────────────────────────────────────────────────────┘  │ │
│  │  ┌─────────────────────────────────────────────────────────┐  │ │
│  │  │ thumbnailQueue                                           │  │ │
│  │  │ Label: "IINAPlayerCoreThumbnailTask{N}"                  │  │ │
│  │  │ QoS: .utility                                            │  │ │
│  │  │ 职责: 缩略图生成                                          │  │ │
│  │  └─────────────────────────────────────────────────────────┘  │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                    全局单例队列                                 │ │
│  │  HistoryController.queue (Label: "IINAHistoryController")     │ │
│  │  QoS: .background — 播放历史异步读写                           │ │
│  │                                                               │ │
│  │  PreferenceWindowController.indexingQueue                     │ │
│  │  Label: "IINAPreferenceIndexingTask"                          │ │
│  │  QoS: .userInitiated — 按键绑定索引                           │ │
│  │                                                               │ │
│  │  PrefPluginViewController.queue                               │ │
│  │  Label: "com.collider.iina.plugin-install"                    │ │
│  │  QoS: .userInteractive — 插件安装                             │ │
│  │                                                               │ │
│  │  WebSocketServer.serverQueue                                  │ │
│  │  Label: "IINAWebSocketServer.{label}" — WebSocket 通信        │ │
│  │                                                               │ │
│  │  JavascriptPluginInstance.queue (每个插件独立)                 │ │
│  │  Label: "com.colliderli.iina.plugin.{id}"                     │ │
│  │  QoS: .background — 插件脚本执行                              │ │
│  └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 MPVController 事件队列

**文件**: `iina/MPVController.swift:108-109`

```swift
private lazy var queue = DispatchQueue(label: "com.colliderli.iina.controller",
                                       qos: .userInitiated)
```

**设计要点**:

1. **专用事件读取线程**: 该队列专门用于读取 mpv 事件，不执行耗时操作
2. **QoS: .userInitiated**: 保证事件及时被读取，避免事件队列溢出
3. **事件循环**: 使用 `while` 循环 + `mpv_wait_event` 持续读取

```swift
private func readEvents() {
    queue.async {
        while ((self.mpv) != nil) {
            let event = mpv_wait_event(self.mpv, 0)!
            let eventId = event.pointee.event_id
            if eventId == MPV_EVENT_NONE {
                break
            }
            self.handleEvent(event)
            if eventId == MPV_EVENT_SHUTDOWN {
                break
            }
        }
    }
}
```

4. **主线程分发**: 所有需要更新 UI 的事件都通过 `DispatchQueue.main.async` 分发到主线程

```swift
case MPV_EVENT_FILE_LOADED:
    DispatchQueue.main.async { self.player.fileLoaded() }

case MPV_EVENT_VIDEO_RECONFIG:
    DispatchQueue.main.async { self.player.onVideoReconfig() }

case MPV_EVENT_SEEK:
    DispatchQueue.main.async { [self] in
        player.info.isSeeking = true
        player.syncUI(.time)
    }
```

### 1.3 ViewLayer 渲染队列

**文件**: `iina/ViewLayer.swift:71`

```swift
private let mpvGLQueue = DispatchQueue(label: "com.colliderli.iina.mpvgl",
                                       qos: .userInteractive)
```

**设计要点**:

1. **QoS: .userInteractive**: 最高优先级，保证渲染流畅
2. **异步渲染触发**: 通过 `update()` 方法将渲染任务分发到此队列

```swift
func update(force: Bool = false) {
    mpvGLQueue.async { [self] in
        if force { forceDraw = true }
        needsFlip = true
        display()
    }
}
```

### 1.4 PlayerCore 实例队列

**文件**: `iina/PlayerCore.swift:306-308`

```swift
backgroundQueue = DispatchQueue(label: "IINAPlayerCoreTask\(playerNumber)", qos: .background)
playlistQueue = DispatchQueue(label: "IINAPlaylistTask\(playerNumber)", qos: .utility)
thumbnailQueue = DispatchQueue(label: "IINAPlayerCoreThumbnailTask\(playerNumber)", qos: .utility)
```

每个 PlayerCore 实例拥有独立的队列组，实现：

| 队列 | QoS | 用途 |
|------|-----|------|
| `backgroundQueue` | `.background` | 自动加载同目录文件、字幕文件匹配 |
| `playlistQueue` | `.utility` | 播放列表的增删改查操作 |
| `thumbnailQueue` | `.utility` | 视频缩略图生成 |

**Ticket 机制** (防止过期任务):

```swift
@Atomic var backgroundQueueTicket = 0

// 提交任务前递增 ticket
backgroundQueueTicket += 1
let currentTicket = backgroundQueueTicket

backgroundQueue.async {
    // 检查 ticket 是否过期
    guard currentTicket == self.backgroundQueueTicket else { return }
    // 执行任务...
}
```

### 1.5 同步原语

IINA 实现了多层次的同步机制：

#### 1.5.1 Lock (os_unfair_lock 封装)

**文件**: `iina/Lock.swift`

```swift
class Lock {
    private let lock = OSUnfairLockImpl()

    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        return try lock.withLock(body)
    }
}
```

- 使用 `os_unfair_lock` (macOS 10.12+) 实现高效锁
- 非递归锁，避免死锁风险

#### 1.5.2 @Atomic 属性包装器

**文件**: `iina/Atomic.swift`

```swift
@propertyWrapper class Atomic<Value> {
    private let lock = Lock()
    private var value: Value

    var wrappedValue: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        return try lock.withLock { return try body(&value) }
    }
}
```

**使用场景**:
- `PlayerCore.backgroundQueueTicket` — 任务计数器
- `ViewLayer.needsFlip` — 渲染标志
- `ViewLayer.forceDraw` — 强制渲染标志
- `ViewLayer.inLiveResize` — 窗口调整状态
- `PlaybackInfo.state` — 播放状态

#### 1.5.3 ReadWriteLock (pthread_rwlock 封装)

**文件**: `iina/ReadWriteLock.swift`

```swift
final class ReadWriteLock {
    private var rwlock = pthread_rwlock_t()

    func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }
        return try body()
    }

    func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }
        return try body()
    }
}
```

- 支持多读单写并发模型
- 适用于读多写少的场景

#### 1.5.4 @ReadWriteAtomic 属性包装器

**文件**: `iina/ReadWriteAtomic.swift`

```swift
@propertyWrapper class ReadWriteAtomic<Value> {
    private let lock = ReadWriteLock()

    var wrappedValue: Value {
        get { lock.read { value } }
        set { lock.write { value = newValue } }
    }

    func withReadLock<R>(_ body: (Value) throws -> R) rethrows -> R {
        return try lock.read { return try body(value) }
    }

    func withWriteLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        return try lock.write { return try body(&value) }
    }
}
```

**使用场景**:
- `VideoView.isUninited` — 视图初始化状态（频繁读取，很少写入）

#### 1.5.5 MainThreadPriorityLock (主线程优先锁)

**文件**: `iina/ViewLayer.swift:467-490`

```swift
private class MainThreadPriorityLock {
    private let lock = NSCondition()
    private var needsLock = false

    func beforeLocking() {
        if Thread.isMainThread {
            lock.lock()
            needsLock = true
            lock.unlock()
            lock.broadcast()
        } else {
            lock.lock()
            while needsLock { lock.wait() }
            lock.unlock()
        }
    }

    func afterLocked() {
        if Thread.isMainThread {
            lock.lock()
            needsLock = false
            lock.unlock()
            lock.broadcast()
        }
    }
}
```

**设计目的**: 解决主线程在获取 `displayLock` 时的锁饥饿问题。当主线程需要锁时，其他线程会被阻塞，让主线程优先获取锁。

### 1.6 队列间通信模式

```
┌─────────────────────────────────────────────────────────────────┐
│                      队列间通信模式                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  mpv 事件队列 ──→ 主线程                                         │
│  (queue)          (DispatchQueue.main.async)                    │
│                                                                 │
│  渲染队列 ──→ OpenGL 渲染                                        │
│  (mpvGLQueue)     (CAOpenGLLayer display)                       │
│                                                                 │
│  mpv 回调 ──→ 渲染队列                                           │
│  (mpvUpdateCallback)  (ViewLayer.update())                      │
│                                                                 │
│  CVDisplayLink ──→ mpv                                          │
│  (displayLinkCallback)  (mpvReportSwap)                         │
│                                                                 │
│  后台队列 ──→ 主线程                                             │
│  (backgroundQueue)  (DispatchQueue.main.async)                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. 渲染体系设计

### 2.1 渲染架构总览

IINA 使用 OpenGL 通过 mpv 的渲染 API 进行视频渲染，整体架构如下：

```
┌─────────────────────────────────────────────────────────────────────┐
│                        IINA 渲染架构                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                     mpv 核心 (libmpv)                        │   │
│  │  - 解码视频帧                                                  │   │
│  │  - 应用滤镜                                                    │   │
│  │  - 色彩空间转换                                                │   │
│  │  - HDR 色调映射                                                │   │
│  └────────────────────────────┬────────────────────────────────┘   │
│                               │                                     │
│                               ▼                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │               mpv_render_context (渲染上下文)                 │   │
│  │  - mpv_render_context_create() 创建                          │   │
│  │  - mpv_render_context_render() 渲染到 FBO                    │   │
│  │  - mpv_render_context_update() 检查更新                      │   │
│  │  - update_callback 回调通知新帧可用                           │   │
│  └────────────────────────────┬────────────────────────────────┘   │
│                               │                                     │
│                               ▼                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                   ViewLayer (CAOpenGLLayer)                  │   │
│  │  - 管理 OpenGL 上下文和像素格式                               │   │
│  │  - 实现 draw(inCGLContext:) 渲染帧                           │   │
│  │  - 处理 ICC Profile 和 HDR                                   │   │
│  │  - 管理显示链接 (CVDisplayLink)                               │   │
│  └────────────────────────────┬────────────────────────────────┘   │
│                               │                                     │
│                               ▼                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                     VideoView (NSView)                       │   │
│  │  - 宿主视图，持有 ViewLayer                                   │   │
│  │  - 管理 CVDisplayLink                                        │   │
│  │  - 处理拖放、鼠标事件                                         │   │
│  │  - HDR/EDR 模式管理                                          │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 OpenGL 上下文创建

**文件**: `iina/ViewLayer.swift:291-378`

#### 2.2.1 像素格式选择

```swift
private static func createPixelFormat(_ player: PlayerCore) -> (CGLPixelFormatObj, GLint) {
    // 1. 优先使用硬件加速
    if swRender != .yes {
        (pix, depth, err) = ViewLayer.findPixelFormat(player)
    }
    // 2. 回退到软件渲染
    if (err != kCGLNoError || pix == nil) && swRender != .no {
        (pix, depth, err) = ViewLayer.findPixelFormat(player, software: true)
    }
}
```

**像素格式属性优先级**:

| 属性 | 说明 | 必需 |
|------|------|------|
| `kCGLPFAOpenGLProfile` | OpenGL 版本 (3.2 Core / Legacy) | 是 |
| `kCGLPFAAccelerated` | 硬件加速 | 是 |
| `kCGLPFADoubleBuffer` | 双缓冲 | 是 |
| `kCGLPFABackingStore` | 后备存储 | 可选 |
| `kCGLPFAAllowOfflineRenderers` | 离线渲染器 | 可选 |
| `kCGLPFAColorSize: 64` | 10-bit 色深 | 可选 |
| `kCGLPFAColorFloat` | 浮点颜色 | 可选 |
| `kCGLPFASupportsAutomaticGraphicsSwitching` | 自动 GPU 切换 | 可选 |

**OpenGL 版本回退策略**:
```
1. 尝试 OpenGL 3.2 Core Profile
2. 如果失败，回退到 OpenGL Legacy Profile
```

#### 2.2.2 上下文创建

```swift
private static func createContext(_ pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
    var ctx: CGLContextObj?
    CGLCreateContext(pixelFormat, nil, &ctx)

    // 启用垂直同步
    var i: GLint = 1
    CGLSetParameter(ctx, kCGLCPSwapInterval, &i)

    // 启用多线程 GL 引擎
    CGLEnable(ctx, kCGLCEMPEngine)

    CGLSetCurrentContext(ctx)
    return ctx
}
```

**关键配置**:
- **垂直同步 (VSync)**: 通过 `kCGLCPSwapInterval` 启用，避免画面撕裂
- **多线程 GL 引擎**: 通过 `kCGLCEMPEngine` 启用，允许 OpenGL 在多线程环境下工作

### 2.3 mpv 渲染上下文

**文件**: `iina/MPVController.swift:684-705`

```swift
func mpvInitRendering() {
    let apiType = MPV_RENDER_API_TYPE_OPENGL
    var openGLInitParams = mpv_opengl_init_params(
        get_proc_address: mpvGetOpenGLFunc,
        get_proc_address_ctx: nil
    )

    var params = [
        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: openGLInitParams),
        mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: 1),
        mpv_render_param()
    ]

    mpv_render_context_create(&mpvRenderContext, mpv, &params)

    // 设置更新回调
    mpv_render_context_set_update_callback(
        mpvRenderContext!,
        mpvUpdateCallback,
        mutableRawPointerOf(obj: player.mainWindow.videoView.videoLayer)
    )
}
```

**渲染参数**:

| 参数 | 说明 |
|------|------|
| `MPV_RENDER_PARAM_API_TYPE` | 使用 OpenGL 渲染 API |
| `MPV_RENDER_PARAM_OPENGL_INIT_PARAMS` | OpenGL 初始化参数 |
| `MPV_RENDER_PARAM_ADVANCED_CONTROL` | 启用高级控制（截图等） |

### 2.4 渲染流程

#### 2.4.1 完整渲染流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                      完整渲染流程                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. mpv 解码新帧                                                 │
│     └─→ 调用 mpvUpdateCallback                                  │
│                                                                 │
│  2. mpvUpdateCallback                                           │
│     └─→ ViewLayer.update()                                      │
│         └─→ mpvGLQueue.async { display() }                      │
│                                                                 │
│  3. ViewLayer.display()                                         │
│     ├─→ mainThreadPriorityLock.beforeLocking()                  │
│     ├─→ displayLock.lock()                                      │
│     ├─→ super.display() (CAOpenGLLayer)                         │
│     │   ├─→ canDraw() 检查                                      │
│     │   │   └─→ mpv.shouldRenderUpdateFrame()                   │
│     │   └─→ draw(inCGLContext:)                                 │
│     │       ├─→ glClear()                                       │
│     │       ├─→ mpv_render_context_render()                     │
│     │       └─→ glFlush()                                       │
│     └─→ CATransaction.flush()                                   │
│                                                                 │
│  4. CVDisplayLink 回调 (每帧)                                    │
│     └─→ displayLinkCallback                                     │
│         └─→ mpv.mpvReportSwap()                                 │
│             └─→ mpv_render_context_report_swap()                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 2.4.2 canDraw 检查

**文件**: `iina/ViewLayer.swift:159-171`

```swift
override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                      forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
    // 窗口调整大小时跳过主线程绘制
    guard !(inLiveResize && Thread.isMainThread) else { return false }

    return videoView.$isUninited.withReadLock() { isUninited in
        guard !isUninited else { return false }
        if !inLiveResize {
            isAsynchronous = false
        }
        // 只有 mpv 报告有新帧时才绘制
        return forceDraw || videoView.player.mpv.shouldRenderUpdateFrame()
    }
}
```

#### 2.4.3 draw(inCGLContext:) 渲染

**文件**: `iina/ViewLayer.swift:173-219`

```swift
override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                   forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
    videoView.$isUninited.withReadLock() { isUninited in
        guard !isUninited else { return }

        needsFlip = false
        forceDraw = false

        let mpv = videoView.player.mpv!

        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

        // 获取当前 FBO 和视口
        var i: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &i)
        var dims: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)

        var flip: CInt = 1

        withUnsafeMutablePointer(to: &flip) { flip in
            if let context = mpv.mpvRenderContext {
                fbo = i != 0 ? i : fbo

                var data = mpv_opengl_fbo(
                    fbo: Int32(fbo),
                    w: Int32(dims[2]),
                    h: Int32(dims[3]),
                    internal_format: 0
                )

                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: .init(data)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: .init(flip)),
                    mpv_render_param(type: MPV_RENDER_PARAM_DEPTH, data: .init(bufferDepth)),
                    mpv_render_param()
                ]

                // 调用 mpv 渲染
                mpv_render_context_render(context, &params)
            } else {
                // 没有渲染上下文时显示黑色
                glClearColor(0, 0, 0, 1)
                glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            }
        }
        glFlush()
    }
}
```

**渲染参数说明**:

| 参数 | 说明 |
|------|------|
| `MPV_RENDER_PARAM_OPENGL_FBO` | 目标帧缓冲对象 |
| `MPV_RENDER_PARAM_FLIP_Y` | Y 轴翻转（OpenGL 坐标系） |
| `MPV_RENDER_PARAM_DEPTH` | 颜色深度 (8-bit 或 16-bit) |

### 2.5 CVDisplayLink 显示链接

**文件**: `iina/VideoView.swift:206-275`

CVDisplayLink 是 Core Video 提供的高精度定时器，与显示器刷新率同步。

#### 2.5.1 创建和启动

```swift
private func obtainDisplayLink() -> CVDisplayLink {
    let result = CVDisplayLinkCreateWithActiveCGDisplays(&link)
    guard let link = link else {
        Logger.fatal("Cannot create display link: \(codeToString(result)) (\(result))")
    }
    return link
}

func startDisplayLink() {
    let link = obtainDisplayLink()
    guard !CVDisplayLinkIsRunning(link) else { return }
    updateDisplayLink()
    CVDisplayLinkSetOutputCallback(link, displayLinkCallback, mutableRawPointerOf(obj: self))
    CVDisplayLinkStart(link)
}
```

#### 2.5.2 显示链接回调

```swift
fileprivate func displayLinkCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ context: UnsafeMutableRawPointer?
) -> CVReturn {
    let videoView = unsafeBitCast(context, to: VideoView.self)
    videoView.$isUninited.withReadLock() { isUninited in
        guard !isUninited else { return }
        // 通知 mpv 帧已交换
        videoView.player.mpv.mpvReportSwap()
    }
    return kCVReturnSuccess
}
```

**关键作用**: `mpvReportSwap()` 告诉 mpv 渲染的帧已经显示在屏幕上，mpv 据此进行帧调度。

#### 2.5.3 显示器切换处理

```swift
func updateDisplayLink() {
    guard let window = window, let link = link, let screen = window.screen else { return }
    let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! UInt32

    if (currentDisplay == displayId) { return }
    currentDisplay = displayId

    CVDisplayLinkSetCurrentCGDisplay(link, displayId)

    // 获取实际刷新率
    let actualData = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
    let nominalData = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)

    // 通知 mpv 实际刷新率
    player.mpv.setDouble(MPVOption.Video.displayFpsOverride, actualFps)

    refreshEdrMode()  // 刷新 HDR 模式
}
```

#### 2.5.4 节能管理

```swift
// 播放活跃时启动显示链接
func displayActive() {
    displayIdleTimer?.invalidate()
    startDisplayLink()
}

// 播放暂停时延迟停止显示链接
func displayIdle() {
    displayIdleTimer?.invalidate()
    // 6 秒后停止，匹配 QuickTime 行为
    displayIdleTimer = Timer(timeInterval: 6.0, ...)
    RunLoop.current.add(displayIdleTimer!, forMode: .default)
}
```

### 2.6 HDR/EDR 支持

**文件**: `iina/VideoView.swift:416-474`

#### 2.6.1 HDR 检测

```swift
func requestEdrMode() -> Bool? {
    // 获取视频色彩信息
    let primaries = mpv.getString(MPVProperty.videoParamsPrimaries)
    let gamma = mpv.getString(MPVProperty.videoParamsGamma)
    let peak = mpv.getDouble(MPVProperty.videoParamsSigPeak)

    // 只有 HLG 或 PQ 传输函数才是 HDR
    guard gamma == "hlg" || gamma == "pq" else { return false }

    // 根据 primaries 选择色彩空间
    switch primaries {
    case "display-p3":
        name = CGColorSpace.displayP3_PQ
    case "bt.2020":
        name = CGColorSpace.itur_2100_PQ
    case "bt.709":
        return false  // SDR
    }

    // 检查显示器是否支持 EDR
    guard (window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0 else {
        return false
    }
}
```

#### 2.6.2 ICC Profile 管理

```swift
func setICCProfile() {
    let screenColorSpace = player.mainWindow.window?.screen?.colorSpace

    if !Preference.bool(for: .loadIccProfile) {
        player.mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)
    } else if let screenColorSpace {
        // 设置 ICC Profile 参数
        videoLayer.setRenderICCProfile(screenColorSpace)
        player.mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, true)
    }

    // 设置色彩空间
    videoLayer.colorspace = sdrColorSpace
    videoLayer.wantsExtendedDynamicRangeContent = false
    player.mpv.setString(MPVOption.GPURendererOptions.targetTrc, "auto")
    player.mpv.setString(MPVOption.GPURendererOptions.targetPrim, "auto")
}
```

### 2.7 OpenGL 上下文同步

**文件**: `iina/MPVController.swift:718-726`

```swift
func lockAndSetOpenGLContext() {
    CGLLockContext(openGLContext)      // 锁定上下文
    CGLSetCurrentContext(openGLContext) // 设为当前线程的上下文
}

func unlockOpenGLContext() {
    CGLUnlockContext(openGLContext)    // 解锁上下文
}
```

**锁顺序规则** (避免死锁):
```
OpenGL 上下文锁 → isUninited 锁 → displayLock
```

### 2.8 跳帧渲染

**文件**: `iina/ViewLayer.swift:264-278`

当 IINA 在后台播放（如只播放音频）时，需要跳过渲染以节省资源：

```swift
// 在 display() 末尾检查是否需要跳帧
if let renderContext = videoView.player.mpv.mpvRenderContext,
   videoView.player.mpv.shouldRenderUpdateFrame() {
    var skip: CInt = 1
    var params: [mpv_render_param] = [
        mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: .init(skip)),
        mpv_render_param()
    ]
    mpv_render_context_render(renderContext, &params)
}
```

### 2.9 窗口调整大小处理

**文件**: `iina/ViewLayer.swift:101-108`

```swift
@Atomic var inLiveResize: Bool = false {
    didSet {
        if inLiveResize {
            isAsynchronous = true  // 启用异步绘制
        }
        update(force: true)       // 强制更新
    }
}
```

**设计要点**:
- 窗口调整大小时启用 `isAsynchronous`，让 AppKit 定期调用 `canDraw`
- 跳过主线程绘制，避免动画卡顿
- 使用 `force: true` 强制渲染

---

## 3. 渲染优化策略

### 3.1 帧调度优化

```
┌─────────────────────────────────────────────────────────────────┐
│                      帧调度优化                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 按需渲染                                                     │
│     - canDraw() 检查 mpv 是否有新帧                              │
│     - 只有 shouldRenderUpdateFrame() 返回 true 时才渲染          │
│                                                                 │
│  2. 显示链接节电                                                 │
│     - 暂停时延迟 6 秒停止 CVDisplayLink                          │
│     - 避免不必要的 CPU 唤醒                                      │
│                                                                 │
│  3. 跳帧渲染                                                     │
│     - 后台播放时使用 SKIP_RENDERING                              │
│     - 节省 GPU 资源                                              │
│                                                                 │
│  4. 主线程优先锁                                                 │
│     - 避免主线程锁饥饿                                           │
│     - 防止界面卡顿                                               │
│                                                                 │
│  5. 递归锁                                                       │
│     - displayLock 使用 NSRecursiveLock                           │
│     - 处理 CATransaction.flush() 触发的重入                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 色彩管理

| 功能 | 实现方式 |
|------|----------|
| SDR 内容 | sRGB 色彩空间 |
| HDR 内容 | PQ/HLG 传输函数 + BT.2020/P3 色域 |
| ICC Profile | 通过 `MPV_RENDER_PARAM_ICC_PROFILE` 传递给 mpv |
| 色调映射 | mpv 内置算法，可配置 |
| 10-bit 渲染 | `kCGLPFAColorSize: 64` + `kCGLPFAColorFloat` |

---

## 4. 关键设计决策总结

### 4.1 队列设计决策

| 决策 | 原因 |
|------|------|
| mpv 事件使用专用队列 | 避免事件队列溢出，保证及时读取 |
| 渲染使用最高 QoS | 保证视频播放流畅 |
| 每个 PlayerCore 独立队列 | 支持多实例，避免相互干扰 |
| 主线程优先锁 | 解决 UI 锁饥饿问题 |
| Ticket 机制 | 防止过期后台任务执行 |

### 4.2 渲染设计决策

| 决策 | 原因 |
|------|------|
| 使用 CAOpenGLLayer | 与 AppKit 集成良好，支持 Retina |
| 后台线程渲染 | 避免主线程阻塞导致 UI 卡顿 |
| CVDisplayLink 同步 | 精确帧同步，避免撕裂 |
| 递归锁 | 处理 Core Animation 重入 |
| 跳帧渲染 | 节省后台播放时的 GPU 资源 |

---

*报告生成时间: 2026-06-04*
*基于 IINA release/1.4.3 分支*
