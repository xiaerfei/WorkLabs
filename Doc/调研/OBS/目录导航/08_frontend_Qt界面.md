# OBS 目录导航 · frontend（Qt 桌面界面）

> 源码范围：`frontend/` ｜ 源文件 413 个（377 个 `.c/.cpp/.h/.hpp/.m/.mm` + 36 个 `forms/*.ui`）｜ 代码约 86,800 行
> 基于 obs-studio commit `f2db097`（2026-07-09）
> 返回总索引：[README.md](README.md)

## 本篇速查

想找什么 → 去这里：

| 我想看… | 去这里 |
|---|---|
| 进程入口、命令行参数、单实例检测、崩溃处理挂载 | [`obs-main.cpp`](#obs-maincpp) |
| `QApplication` 子类：配置文件/本地化/主题加载/生命周期 | [`OBSApp.cpp`](#obsappcpp) / `OBSApp_Themes.cpp` |
| 插件用的 frontend API（`obs_frontend_*`）实现在哪 | [`api/`](#api) + 顶层 `OBSStudioAPI.cpp` |
| 主窗口 `OBSBasic` 现在在哪个目录、怎么拆的 | [`widgets/OBSBasic*`](#obsbasic-主窗口拆分后) |
| Qt 窗口怎么变成 `obs_display`、鼠标拖拽怎么换算成源变换 | [`widgets/OBSQTDisplay.cpp`](#obsqtdisplaycpp) / [`widgets/OBSBasicPreview.cpp`](#obsbasicpreviewcpp) |
| 混音条、音量表（VU meter）怎么画的 | [`components/VolumeMeter.cpp`](#volumemetercpp) / `VolumeControl.cpp` / `widgets/AudioMixer.cpp` |
| 场景/来源列表（拖拽排序、分组、显隐） | [`components/SourceTree*`](#场景来源列表-sourcetree-家族) |
| 属性面板、滤镜面板、变换面板这些弹窗 | [`dialogs/OBSBasic*`](#dialogs　dialogs) |
| 简单/高级输出、多路编码（Multitrack Video） | [`utility/SimpleOutput.cpp` / `AdvancedOutput.cpp` / `MultitrackVideoOutput.cpp`](#输出管线-simpleoutput-advancedoutput-basicoutputhandler-multitrackvideo) |
| 崩溃日志收集与上传 | [`utility/CrashHandler*`](#崩溃处理与日志-crashhandler-家族) |
| 主题/QSS 样式怎么解析的 | [`OBSApp_Themes.cpp`](#obsappcpp) + `utility/OBSTheme*` |
| 新手引导向导（自动配置） | [`wizards/AutoConfig*`](#wizards　wizards) |
| Twitch/YouTube/Restream 登录鉴权 | [`oauth/`](#oauth　oauth) |
| 从 OBS Classic / Streamlabs / XSplit 导入场景 | [`importer/` + `importers/`](#importer--importers　importer-importers) |

---

## 一句话职责

`frontend/` 是整个仓库里**唯一**直接依赖 Qt6 的部分：它不实现任何采集/编码/合成逻辑，只调 `libobs` 的公开 API（`obs.h` + `frontend/api/obs-frontend-api.h`）把场景、源、输出这些对象摆成一个可操作的桌面程序。数据流是单向的——`libobs` 不知道 `frontend` 的存在，`frontend` 通过信号回调（`obs_source_get_signal_handler` 等）订阅 `libobs` 状态变化来刷新 UI，用户操作再通过 `obs_*` 函数写回 `libobs`。插件如果想反过来操作 UI（比如 `obs-websocket`、`frontend-tools`），走的是 `frontend/api/` 暴露的 C 接口，而不是直接链接这个目录。

---

## 顶层入口与应用骨架

**职责**：进程怎么起来、`QApplication` 长什么样、插件怎么拿到操作 UI 的接口——这三件事都在 `frontend/` 根目录，不属于任何子目录。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-main.cpp` ⭐ | 1114 | 进程入口 `main()`：信号处理、命令行解析、日志文件轮转、崩溃处理器挂载、单实例检测、启动 `OBSApp` |
| `OBSApp.cpp` ⭐ | 2055 | `QApplication` 子类实现：配置文件（global/user ini）初始化、本地化（`.ini` 翻译表）、`libobs` 初始化入口 `OBSInit`、信号（SIGINT/SIGTERM）处理、翻译 hook |
| `OBSApp.hpp` | 298 | 上面的类声明；`OBSApp` 持有 `mainWindow`（`OBSBasic*`）、`CrashHandler`、`ThumbnailManager`、更新分支列表等全局单例状态 |
| `OBSApp_Themes.cpp` ⭐ | 1120 | 主题系统实现：解析 `.theme`/`.qss` 文件里的自定义变量（颜色/尺寸/计算表达式），生成最终 QSS 和 `QPalette` |
| `OBSStudioAPI.cpp` | 763 | `obs_frontend_callbacks` 接口的**具体实现**——把 `obs_frontend_get_current_scene()` 这类调用转发到 `OBSBasic *main` 的真实方法 |
| `OBSStudioAPI.hpp` | 242 | 上面那份的类声明（`struct OBSStudioAPI : obs_frontend_callbacks`） |

### 插件用的 frontend API 在哪

**公开头文件 + 转发层在 `frontend/api/`，不在 `libobs/`**：

| 文件 | 行数 | 功能 |
|---|---|---|
| `api/obs-frontend-api.h` | 267 | 插件 `#include` 的公开头，声明所有 `obs_frontend_*` C 函数（获取/切换场景、开始录制、场景集合管理、hotkey 面板注册……） |
| `api/obs-frontend-api.cpp` | 688 | 每个 `obs_frontend_*` 函数的**壳实现**：转调全局 `unique_ptr<obs_frontend_callbacks> c` 上的虚函数（`c` 由 `obs_frontend_set_callbacks_internal()` 在 `OBSBasic::OBSInit` 里注入，见 `api/obs-frontend-api.cpp:8`） |
| `api/obs-frontend-internal.hpp` | 147 | `struct obs_frontend_callbacks`：一个纯虚接口，声明了 `obs_frontend_get_main_window` 等全部方法——`OBSStudioAPI`（根目录）就是这个接口的唯一实现 |

调用链：插件调 `obs_frontend_get_current_scene()`（`api/obs-frontend-api.cpp`）→ 转发到全局回调对象的虚函数 → 真正落到 `OBSStudioAPI::obs_frontend_get_current_scene()`（`OBSStudioAPI.cpp:56`）→ 操作 `main`（即 `OBSBasic*`）。这是一层典型的"C 接口 + C++ 虚表"桥接，作用是让 `frontend/api` 编译成独立的动态库（`obs-frontend-api.dylib`），插件不需要链接整个 `frontend` 目标。

### 主窗口 `OBSBasic` 现在在哪

新版 OBS 把主窗口类**拆到了 `widgets/` 目录**，`OBSBasic.cpp`（2246 行）只保留构造/析构/`OBSInit`/`closeEvent`/`Get()` 这些核心骨架，其余按功能各拆成一个 `widgets/OBSBasic_*.cpp`——**都是同一个 `class OBSBasic`（声明于 `widgets/OBSBasic.hpp`）的成员函数分卷实现，没有子类化**。详见下面 `widgets/` 分组的完整列表。`.hpp` 只有一份：`widgets/OBSBasic.hpp`（1698 行）。

---

## widgets　`widgets/`（49 文件）

**职责**：这是 UI 层的"重型"目录——主窗口本体、预览画面、混音条容器、投影仪窗口、状态栏/统计浮窗都在这。除 `OBSBasic` 拆分外，其余文件基本一文件一类。

### OBSBasic 主窗口（拆分后）

`OBSBasic.cpp` + 26 个 `OBSBasic_*.cpp` 都实现同一个类，按 CMake 里 `ui-widgets.cmake` 登记的顺序，功能对应关系如下：

| 文件 | 行数 | 功能 |
|---|---|---|
| `OBSBasic.hpp` | 1698 | 类声明本体：几乎所有子系统的状态和方法签名都汇总在这一个头里 |
| `OBSBasic.cpp` ⭐ | 2246 | 构造函数（:232，建 UI、连信号）、`OBSInit()`（:991，初始化 `libobs`/加载场景集合/建 Display）、`closeEvent`（:1714）、单例 `Get()`（:2149） |
| `OBSBasic_SceneCollections.cpp` | 1709 | 场景集合（Scene Collection）的新建/切换/导入导出/自动备份 |
| `OBSBasic_Transitions.cpp` | 1562 | 转场（Transition）管理：quick transition 按钮、T-bar、转场时长 |
| `OBSBasic_SceneItems.cpp` | 1435 | 场景项（sceneitem）增删/复制/锁定/顺序调整——预览里选中源之后的菜单动作大多在这 |
| `OBSBasic_Scenes.cpp` | 1026 | 场景（Scene）本身的增删改名/切换当前场景 |
| `OBSBasic_Profiles.cpp` | 914 | Profile（一套输出参数配置）的增删切换 |
| `OBSBasic_MainControls.cpp` | 712 | 主界面"开始推流/录制/回放缓冲"等按钮的业务逻辑 |
| `OBSBasic_Preview.cpp` ⭐ | 676 | 预览 tick 回调 `RenderMain`（:132）、预览开关、缩放模式、安全框/间距参考线绘制——**渲染侧**逻辑（和下面`OBSBasicPreview.cpp`的**交互侧**是两个文件配合） |
| `OBSBasicStatusBar.cpp` | 620 | 底部状态栏控件实现（见下） |
| `OBSBasicStats.cpp` | 601 | "统计"浮窗（FPS/CPU/内存/丢帧）实现（见下） |
| `OBSProjector.cpp` | 499 | 投影仪窗口实现（见下） |
| `OBSBasic_Streaming.cpp` | 479 | 推流开始/停止状态机、重试逻辑 |
| `OBSBasic_Recording.cpp` | 431 | 录制开始/停止、分段录制 |
| `OBSBasic_StudioMode.cpp` | 414 | 导播模式（Program/Preview 双预览）切换与转场 |
| `OBSBasic_Dropfiles.cpp` | 342 | 拖文件到主窗口自动建源 |
| `OBSBasic_Hotkeys.cpp` | 318 | 全局热键的加载/保存/触发分发 |
| `OBSBasic_Clipboard.cpp` | 301 | 源/场景项的复制粘贴（含变换属性） |
| `OBSBasic_ContextToolbar.cpp` | 293 | 选中特定类型源时，属性面板上方出现的快捷工具条（调用 `components/*Toolbar.*` 家族） |
| `OBSBasic_Browser.cpp` | 293 | CEF 浏览器源/浏览器面板的收藏夹与自定义浏览器停靠 |
| `OBSBasicControls.cpp` | 285 | 精简控件栏实现（见下） |
| `OBSBasic_Projectors.cpp` | 280 | 打开/管理各种投影仪（场景/源/预览/多视图）窗口 |
| `OBSBasic_Docks.cpp` | 260 | 停靠面板（dock）的注册、布局保存恢复 |
| `OBSBasic_YouTube.cpp` | 259 | YouTube 直播/聊天面板集成 |
| `OBSBasic_Updater.cpp` | 246 | 应用内更新检查/提示的 UI 部分（真正下载逻辑在 `utility/AutoUpdateThread*`） |
| `OBSBasic_ReplayBuffer.cpp` | 236 | 回放缓冲（Replay Buffer）开始/保存 |
| `OBSBasic_Icons.cpp` | 227 | 场景/源列表的类型图标映射 |
| `OBSBasic_VirtualCam.cpp` | 185 | 虚拟摄像头开关与配置弹窗联动 |
| `OBSBasic_SysTray.cpp` | 160 | 系统托盘图标与菜单 |
| `OBSBasic_OutputHandler.cpp` | 148 | 创建/持有 `BasicOutputHandler`（Simple 或 Advanced）实例 |
| `OBSBasic_Service.cpp` | 128 | 推流服务（Twitch/YouTube/自定义 RTMP）配置读写 |
| `OBSBasic_Canvases.cpp` | 64 | 多画布（`OBS::Canvas`，`utility/OBSCanvas.hpp`）增删——较新功能，一个 `OBSBasic` 可以有多个独立画布 |
| `OBSBasic_Screenshots.cpp` | 54 | 截图当前预览/源 |
| `OBSBasic_StatusBar.cpp` | 26 | 只有一个 `ShowStatusBarMessage` 转发函数，命名和 `OBSBasicStatusBar.cpp`（状态栏控件类）容易搞混，注意区分 |

### 预览控件：Qt 窗口如何变成 `obs_display`

| 文件 | 行数 | 功能 |
|---|---|---|
| `OBSQTDisplay.cpp` ⭐ | 222 | 把一个 `QWidget` 包成 `obs_display_t` 的渲染目标——机制见下 |
| `OBSQTDisplay.hpp` | 49 | 声明：持有一个 `OBSDisplay display`（RAII 包装的 `obs_display_t*`） |
| `OBSBasicPreview.cpp` ⭐ | 2742 | `OBSQTDisplay` 子类，主画布预览控件：鼠标选中/拖动/缩放/裁剪/旋转源，画选中框和参考线——机制见下 |
| `OBSBasicPreview.hpp` | 201 | 声明：`ItemHandle` 缩放把手枚举、`screenToItem`/`itemToScreen` 变换矩阵等交互状态 |

### 音频混音条与其它主窗口子控件

| 文件 | 行数 | 功能 |
|---|---|---|
| `AudioMixer.cpp` | 1127 | 混音条**容器面板**：管理一组 `VolumeControl`（见 `components/`），响应源增删/激活事件、显示模式（隐藏/仅活跃源）、布局（横/竖） |
| `AudioMixer.hpp` | 150 | 同上声明 |
| `OBSBasicStatusBar.cpp` | 620 | 底部状态栏：推流/录制计时、码率/丢帧/网络拥塞指示灯 |
| `OBSBasicStatusBar.hpp` | 107 | 同上声明 |
| `OBSBasicStats.cpp` | 601 | "统计"信息浮窗：FPS、CPU/内存占用、渲染耗时、丢帧数（定时器轮询 `libobs` 的 `obs_get_*` 统计接口） |
| `OBSBasicStats.hpp` | 85 | 同上声明 |
| `OBSProjector.cpp` | 499 | 投影仪窗口：场景/源/预览/多视图的独立全屏或窗口化渲染目标，也是基于 `OBSQTDisplay` 派生的一个渲染回调（`OBSRender`/`OBSRenderMultiview`） |
| `OBSProjector.hpp` | 68 | 同上声明 |
| `OBSBasicControls.cpp` | 285 | 精简版控制栏（用于紧凑布局/移动端式操作） |
| `OBSBasicControls.hpp` | 71 | 同上声明 |
| `OBSMainWindow.hpp` | 15 | `OBSBasic` 的抽象基类，只声明 `Config()` / `OBSInit()` 两个纯虚函数——存在的意义是让别的代码（如 `OBSApp`）不用 `#include` 整个 `OBSBasic.hpp` 就能持有指针 |
| `ColorSelect.cpp` / `.hpp` | 26 / 32 | 背景色选择的小控件 |
| `StatusBarWidget.cpp` / `.hpp` | 10 / 19 | 状态栏里一个自定义子部件（配 `forms/StatusBarWidget.ui`） |

### ⭐ 重点文件展开

#### `widgets/OBSQTDisplay.cpp`
- **做什么**：定义 `class OBSQTDisplay : public QWidget`，这是"一块能被 `libobs` 直接画进去的 Qt 区域"的通用基类，`OBSBasicPreview`、`OBSProjector` 都继承它。
- **关键入口**：
  - `QTToGSWindow`（:39）：从 `QWindow` 拿原生窗口句柄——macOS 上是 `(id)window->winId()` 塞进 `gs_window.view`（:44），Windows 用 `HWND`，Linux 按 X11/Wayland 分支处理。
  - `OBSQTDisplay::OBSQTDisplay`（:73）：构造时设置一串"让 Qt 别插手绘制"的 widget attribute：`WA_PaintOnScreen`、`WA_NoSystemBackground`、`WA_OpaquePaintEvent`、`WA_NativeWindow`（强制创建原生窗口，不然拿不到 native handle）。
  - `CreateDisplay`（:131）：拿 `GetPixelSize` 算出物理像素尺寸，填一个 `gs_init_data`（`format = GS_BGRA`），调 `obs_display_create(&info, backgroundColor)` 拿到 `obs_display_t*`，存进 `display` 成员，发 `DisplayCreated` 信号。
  - `resizeEvent`/`moveEvent`（:196/:184）：分别调 `obs_display_resize()` 和 `obs_display_update_color_space()`，保持 libobs 侧渲染目标和 Qt 控件几何同步。
- **看点**：`paintEngine()` 直接返回 `nullptr`（:213）——明确告诉 Qt"这块区域我自己画，你的 QPainter 不要碰"。整个类没有任何 `paintEvent` 里的绘制代码，`obs_display_t` 是通过原生窗口句柄被 libobs 的图形后端（Metal/D3D11/OpenGL）**直接合成到这块屏幕区域**，不经过 Qt 的合成流程——这是 Qt 应用里"塞一块原生 GPU 画布"的标准写法，如果 WorkOBS/libwl 要在 Cocoa 里做类似的事，对应的就是拿 `NSView` 的 `id` 传给 Metal layer，而不是走 `NSView drawRect:`。

#### `widgets/OBSBasicPreview.cpp`
- **做什么**：`OBSQTDisplay` 的子类，承载主预览区的**所有鼠标交互**——选中、拖动、8 向缩放把手、裁剪、旋转、框选、吸附。渲染侧的 tick 回调（`RenderMain`）在 `widgets/OBSBasic_Preview.cpp`，这里只管交互和交互态的覆盖层绘制（选中框/参考线）。
- **关键入口**：
  - `GetMouseEventPos`（:51）：**Qt 坐标 → OBS 画布坐标**的核心换算。`OBSBasic` 维护 `previewX/previewY`（预览区在窗口里的偏移，像素）和 `previewScale`（画布像素 / 屏幕像素的缩放比），换算公式是 `pos = (qtPos - preview偏移/像素比) * (像素比/previewScale)`——先扣掉预览区左上角偏移，再按当前缩放级别换算回画布的原始像素坐标系。
  - `mousePressEvent`（:563）→ `GetItemAtPos`（:232，用 `obs_scene_enum_items` 逐项做碰撞检测）判断点在哪个 sceneitem 上，`GetStretchHandleData`（:453）判断是否点在某个缩放把手上。
  - `mouseMoveEvent`（:1600）：按当前状态分流到 `RotateItem`（:1552）/ `CropItem`（:1347）/ `StretchItem`（:1466）/ `MoveItems`（:1022）/ `BoxItems`（框选，:1200）。
  - `MoveItems`（:1022）→ 内部 `move_items`（:991）回调对每个选中的 `obs_sceneitem_t` 调 `obs_sceneitem_get_pos` / `obs_sceneitem_set_pos`，本质是"鼠标位移量（画布坐标系下）直接加到源当前 pos 上"，分组（group）还要经 `invGroupTransform` 转换到父级坐标系。
  - `StretchItem`（:1466）：按住某个把手拖动时，重新计算 `obs_sceneitem_crop`/`pos`/`scale`，并用 `screenToItem`/`itemToScreen`（`matrix4`）在屏幕坐标和源局部坐标间来回转换。
- **看点**：这个文件是"预览里拖东西"这件事在 OBS 里的完整实现范本——**没有专门的 hit-test 数据结构**，每次鼠标事件都是 `obs_scene_enum_items` 全量遍历 + 矩阵变换判断包围盒，胜在场景项数量通常很小（几十个内），换来的是不用维护额外的空间索引。旋转/裁剪的实现细节（`RotatePos`、`ClampAspect`、`SnapItemMovement` 吸附判定）也都在这一个文件里，是 WorkOBS 做预览拖拽交互时最值得抄作业的地方。

---

## components　`components/`（91 文件）

**职责**：可复用的 Qt 自定义控件集合，被 `widgets/`、`dialogs/`、`settings/` 各处拼装使用。90% 是"一个类一对 .cpp/.hpp"的小控件，按功能族分组如下。

### 音量表与混音条

| 文件 | 行数 | 功能 |
|---|---|---|
| `VolumeControl.cpp` | 1009 | 混音条里**一条源的完整控制条**：名字、静音按钮、监听按钮、滑块、右键菜单（改名/属性/降噪、峰值类型、衰减速率），内部持有一个 `VolumeMeter` |
| `VolumeControl.hpp` | 173 | 同上声明 |
| `VolumeMeter.cpp` ⭐ | 908 | 音量表（VU meter）绘制控件——机制见下 |
| `VolumeMeter.hpp` | 207 | 同上声明：一堆可配置颜色（正常/警告/错误的前景背景色）、`warningLevel`/`errorLevel` 阈值 |
| `VolumeName.cpp` / `.hpp` | 217 / 70 | 混音条里源名字那一小块可编辑标签 |
| `VolumeSlider.cpp` / `.hpp` | 80 / 25 | 音量滑块（继承 `QSlider`，支持 dB/百分比刻度） |
| `BalanceSlider.hpp` | 21 | 左右声道平衡滑块 |
| `MuteCheckBox.hpp` | 26 | 静音复选框外观定制 |
| `VolumeAccessibleInterface.cpp` / `.hpp` | 62 / 26 | 给 VU meter 加系统无障碍（screen reader）支持 |
| `OBSAdvAudioCtrl.cpp` / `.hpp` | 613 / 90 | **"高级音频属性"弹窗里一行的控件**（不同于混音条的 `VolumeControl`）：音量/平衡/单声道/声道混流分配，供 `dialogs/OBSBasicAdvAudio` 使用 |

### 场景/来源列表 SourceTree 家族

| 文件 | 行数 | 功能 |
|---|---|---|
| `SourceTree.cpp` / `.hpp` | 662 / 75 | 来源列表视图本体（`QListView` 定制），拖拽排序、多选、分组、右键菜单入口 |
| `SourceTreeModel.cpp` / `.hpp` | 450 / 47 | 数据模型：订阅 `OBS_FRONTEND_EVENT_*`，把 `obs_scene_enum_items` 的结果映射成 `QAbstractListModel` 行 |
| `SourceTreeItem.cpp` / `.hpp` | 583 / 80 | 单行 item widget：可见性/锁定图标、双击改名、悬停高亮 |
| `SourceTreeDelegate.cpp` / `.hpp` | 17 / 15 | 自定义 item delegate（配合分组的树形缩进绘制） |
| `SceneTree.cpp` / `.hpp` | 247 / 45 | 场景列表（和来源列表是姊妹控件，结构类似但绑定的是 scene 而非 sceneitem） |
| `VisibilityItemWidget.cpp`/`.hpp`、`VisibilityItemDelegate.cpp`/`.hpp` | 71/35、70/17 | 来源列表行内"眼睛图标"可见性开关 |
| `SourceSelectButton.cpp` / `.hpp` | 222 / 75 | "+"按钮弹出的新建源类型选择菜单 |

### 源上下文工具条（选中特定类型源时出现）

被 `widgets/OBSBasic_ContextToolbar.cpp` 调用，每种源类型一个工具条子类，都继承 `SourceToolbar`：

| 文件 | 行数 | 功能 |
|---|---|---|
| `SourceToolbar.cpp` / `.hpp` | 62 / 26 | 基类：保存旧属性、生成可撤销的属性变更 |
| `TextSourceToolbar.cpp` | 152 | 文本源：字体/颜色快捷编辑 |
| `ComboSelectToolbar.cpp` | 107 | 下拉选择类源的公共基类（设备类源常用） |
| `DeviceCaptureToolbar.cpp` | 59 | 摄像头/采集卡设备切换 |
| `ColorSourceToolbar.cpp` | 83 | 纯色源的颜色快捷编辑 |
| `GameCaptureToolbar.cpp` | 92 | 游戏捕获窗口选择 |
| `ImageSourceToolbar.cpp` | 54 | 图片源的文件路径 |
| `WindowCaptureToolbar.cpp` / `DisplayCaptureToolbar.cpp` | 42 / 41 | 窗口/屏幕捕获目标选择 |
| `AudioCaptureToolbar.cpp` / `ApplicationAudioCaptureToolbar.cpp` | 34 / 22 | 音频采集设备/按应用采集音频 |
| `BrowserToolbar.cpp` | 23 | 浏览器源 URL 快捷编辑 |

### 属性面板辅助控件

| 文件 | 行数 | 功能 |
|---|---|---|
| `AlignmentSelector.cpp` / `.hpp` | 324 / 71 | 3×3 九宫格对齐方式选择器（变换面板"位置对齐"/"边界对齐"用） |
| `AccessibleAlignmentSelector.*` / `AccessibleAlignmentCell.*` | 126+47 / 71+51 | 上面控件的无障碍适配 |
| `OBSPreviewScalingComboBox.cpp`/`.hpp`、`OBSPreviewScalingLabel.cpp`/`.hpp` | 124/64、31/34 | 预览缩放模式下拉框与标签 |
| `AbsoluteSlider.cpp` / `.hpp` | 167 / 37 | 支持任意范围输入的滑块（配数值框） |
| `OBSSourceLabel.cpp` / `.hpp` | 60 / 45 | 通用"源名字标签"（悬停显示完整名） |
| `MenuButton.cpp`/`.hpp`、`MenuCheckBox.cpp`/`.hpp` | 37/16、112/50 | 下拉菜单按钮 / 带菜单的复选框 |
| `UrlPushButton.cpp` / `.hpp` | 27 / 22 | 可点击跳转的链接按钮 |

### 多视图、媒体控件与其它

| 文件 | 行数 | 功能 |
|---|---|---|
| `Multiview.cpp` / `.hpp` | 779 / 68 | 多视图（Multiview/九宫格监看）渲染：`Render(cx, cy)` 用 `libobs` 绘制多个场景缩略图到一张画布，`GetSourceByPosition` 反查鼠标点在哪个格子 |
| `MediaControls.cpp` / `.hpp` | 539 / 79 | 媒体源播放控制条（播放/暂停/进度条/时间），订阅 `obs_source_media_*` 回调 |
| `FlowLayout.cpp`/`.hpp`、`FlowFrame.cpp`/`.hpp` | 170/40、134/37 | 自适应换行布局（源工具条、快捷面板用） |
| `UIValidation.cpp` / `.hpp` | 117 / 28 | 表单校验通用弹窗（如"名字不能为空"提示） |
| `FocusList.cpp` / `.hpp` | 26 / 17 | 键盘可聚焦的列表基类 |
| `ClickableLabel.hpp`、`DelButton.hpp`、`EditWidget.hpp`、`SilentUpdateCheckBox.hpp`、`SilentUpdateSpinBox.hpp` | 均 <25 | 各种"改个属性不触发多余信号"的小控件封装 |

---

## utility　`utility/`（116 文件）

**职责**：不属于任何单一窗口的支撑代码——输出管线胶水、崩溃处理、自动更新、主题解析、平台适配、各类 Model/Delegate。是本篇文件数最多的目录，按功能族分组。

### 输出管线：SimpleOutput / AdvancedOutput / BasicOutputHandler / MultitrackVideo

| 文件 | 行数 | 功能 |
|---|---|---|
| `BasicOutputHandler.hpp` | 151 | 抽象基类 `struct BasicOutputHandler`：持有 `fileOutput`/`streamOutput`/`replayBuffer`/`virtualCam` 四个 `obs_output_t`，声明 `SetupStreaming`/`SetupRecording`/`Update` 等纯虚接口 |
| `BasicOutputHandler.cpp` | 614 | 非虚共享逻辑：启停通用状态机、录制路径生成、事件通知 |
| `SimpleOutput.cpp` / `.hpp` | 966 / 63 | "简单"输出模式实现：x264/QSV/NVENC/AMD/Apple 各编码器的推荐参数预设（CRF/CQP 换算） |
| `AdvancedOutput.cpp` / `.hpp` | 983 / 47 | "高级"输出模式：自定义编码器/多路音轨（vod track）/自定义 FFmpeg 输出 |
| `MultitrackVideoOutput.cpp` / `.hpp` | 924 / 70 | 多路视频（同时推多个分辨率/码率）输出编排，配合下面的 GoLiveAPI |
| `MultitrackVideoError.cpp` / `.hpp` | 46 / 22 | 多路视频出错时的用户提示文案（错误码 → 本地化文案映射） |
| `GoLiveAPI_Network.cpp` / `.hpp` | 136 / 15 | 请求 Twitch"Go Live"多路配置服务的网络层 |
| `GoLiveAPI_PostData.cpp` / `.hpp` | 79 / 13 | 组装上报给 Go Live API 的 JSON |
| `GoLiveAPI_CensoredJson.cpp` / `.hpp` | 89 / 13 | 日志里打印请求体时脱敏（流密钥等） |
| `WHIPSimulcastEncoders.hpp` | 86 | WHIP 推流的多档编码器（simulcast）配置结构 |
| `audio-encoders.cpp` / `.hpp` | 428 / 16 | 音频编码器参数（AAC 各码率）的通用枚举/校验逻辑 |
| `FFmpegCodec.cpp` / `.hpp` | 189 / 76 | 自定义 FFmpeg 输出弹窗用的编码器枚举（可选编码器列表、参数） |
| `FFmpegFormat.cpp` / `.hpp` | 70 / 80 | 同上，封装格式（容器）枚举 |
| `FFmpegShared.hpp` | 45 | 上面两者共用的小工具/常量 |
| `StartMultiTrackVideoStreamingGuard.hpp` | 20 | RAII 守卫，防止多路推流启动过程中重入 |
| `VCamConfig.hpp` | 23 | 虚拟摄像头配置的数据结构（输出类型/源） |

### 崩溃处理与日志 CrashHandler 家族

| 文件 | 行数 | 功能 |
|---|---|---|
| `CrashHandler.hpp` | 97 | `namespace OBS { class CrashHandler }`：跨平台的崩溃/未清理关闭检测统一接口 |
| `CrashHandler.cpp` | 392 | 平台无关部分：日志文件状态机（`LogFileType`/`LogFileState`）、崩溃日志上传队列 |
| `CrashHandler_Windows.cpp` | 85 | Windows：读 WER（Windows Error Reporting）崩溃转储目录 |
| `CrashHandler_MacOS.mm` | 115 | **macOS**：读 `~/Library/Logs/DiagnosticReports` 崩溃日志目录（`getDiagnosticReportsDirectory`） |
| `CrashHandler_Linux.cpp` / `CrashHandler_FreeBSD.cpp` | 40 / 40 | Linux/FreeBSD 对应实现（当前基本是占位） |
| `RemoteTextThread.cpp` / `.hpp` | 219 / 63 | 后台线程发 HTTP 请求拉文本（更新说明、日志上传响应等通用工具） |

### "新版本特性"页（What's New）

| 文件 | 行数 | 功能 |
|---|---|---|
| `WhatsNewInfoThread.cpp` / `.hpp` | 296 / 18 | 后台拉取并校验"新版本特性"页内容（`FetchAndVerifyFile`，带签名校验） |
| `WhatsNewBrowserInitThread.cpp` / `.hpp` | 20 / 17 | 预热内嵌浏览器（提前跑一次 `run()` 触发浏览器初始化，减少弹窗时的白屏等待） |

### 自动更新（Windows 独立更新器 vs macOS Sparkle）

| 文件 | 行数 | 功能 |
|---|---|---|
| `AutoUpdateThread.cpp` / `.hpp` | 351 / 29 | Windows：拉取更新清单、触发独立的 `updater/` 可执行文件 |
| `MacUpdateThread.cpp` / `.hpp` | 74 / 22 | **macOS**：包一层 `QThread` 调用 Sparkle 的检查更新 API |
| `OBSSparkle.mm` / `.hpp` | 39 / 24 | **macOS**：封装 Sparkle 框架（`SPUUpdater`）的 Objective-C++ 胶水 |
| `OBSUpdateDelegate.mm` / `.h` | 45 / 38 | **macOS**：Sparkle 的 delegate 实现，处理更新渠道（`allowedChannelsForUpdater`）和按钮状态观察 |
| `win-dll-blocklist.c` | 357 | Windows：进程启动早期挂 DLL 黑名单钩子，防止已知会崩溃的第三方注入 DLL 加载 |
| `update-helpers.cpp` / `.hpp` | 35 / 5 | 更新流程共用的 `strprintf` 等小工具 |

### 主题与样式

| 文件 | 行数 | 功能 |
|---|---|---|
| `OBSTheme.hpp` | 47 | `struct OBSTheme`：主题元数据（id/name/author/继承关系 `extends`/`parent`） |
| `OBSThemeVariable.hpp` | 44 | `struct OBSThemeVariable`：主题变量的类型系统（颜色/尺寸/数字/字符串/别名/四则运算/min/max），真正的解析逻辑在根目录 `OBSApp_Themes.cpp` |
| `OBSProxyStyle.cpp` / `.hpp` | 28 / 24 | `QProxyStyle` 定制（比如隐藏鼠标光标的 `OBSInvisibleCursorProxyStyle`） |
| `OBSTranslator.cpp` / `.hpp` | 36 / 31 | `QTranslator` 子类，桥接 `libobs` 的 `.ini` 本地化文本表到 Qt 的翻译机制；`obs-main.cpp` 里 `program.installTranslator(&translator)` 就是装的它 |

### 多画布 / YouTube API / 平台适配

| 文件 | 行数 | 功能 |
|---|---|---|
| `OBSCanvas.cpp` / `.hpp` | 105 / 52 | `namespace OBS { class Canvas }`：`obs_canvas_t` 的 RAII 包装，支撑 `widgets/OBSBasic_Canvases.cpp` 的多画布功能 |
| `YoutubeApiWrappers.cpp` / `.hpp` | 533 / 86 | YouTube Data API 封装（创建直播、获取分类/隐私设置），供 `docks/YouTubeAppDock`、`dialogs/OBSYoutubeActions` 用 |
| `platform.hpp` | 109 | 跨平台函数声明的统一入口（`CheckIfAlreadyRunning`、`GetDataFilePath`、`isInBundle` 等），三个平台各自实现 |
| `platform-osx.mm` ⭐（辅助） | 361 | **macOS** 实现：`isInBundle`（:31，检查是否跑在 bundle 里而非裸二进制）、`GetDataFilePath`（:36）、`CheckIfAlreadyRunning`（:45，用 `NSRunningApplication` 按 bundle id 查同类进程数） |
| `platform-windows.cpp` / `platform-x11.cpp` | 446 / 327 | Windows / Linux(X11+Wayland) 对应实现 |
| `system-info-macos.mm` | 101 | **macOS**：读 CPU 型号（`sysctlbyname("machdep.cpu.brand_string")`）等系统信息，供"统计"面板/崩溃日志用 |
| `system-info-windows.cpp` / `system-info-posix.cpp` | 262 / 676 | Windows / 通用 POSIX 系统信息实现 |
| `crypto-helpers-mac.mm` | 未单列(小) | **macOS**：用 Security 框架（`SecKeyRef`/`SecItemImport`）验证更新包签名 |
| `crypto-helpers-mbedtls.cpp` / `.hpp` | 未单列 | 非 macOS 平台用 mbedTLS 做同样的签名校验 |

### 其它工具类（Model/Delegate/杂项）

| 文件 | 行数 | 功能 |
|---|---|---|
| `RemuxQueueModel.cpp` / `.hpp` | 387 / 78 | "混流"（Remux，无损转封装）弹窗的批量任务队列模型 |
| `RemuxEntryPathItemDelegate.cpp` / `.hpp` | 215 / 46 | 上面队列表格里"路径"列的编辑代理（弹文件选择器） |
| `RemuxWorker.cpp` / `.hpp` | 63 / 44 | 实际执行 remux 的后台线程封装 |
| `MissingFilesModel.cpp` / `.hpp` | 306 / 68 | "缺失文件"弹窗（打开场景集合时源文件路径失效）的数据模型 |
| `MissingFilesPathItemDelegate.cpp` / `.hpp` | 163 / 44 | 同上，路径列编辑代理 |
| `ExtraBrowsersModel.cpp` / `.hpp` | 259 / 55 | 自定义浏览器停靠面板列表的数据模型 |
| `ExtraBrowsersDelegate.cpp` / `.hpp` | 133 / — | 同上表格的编辑代理 |
| `ThumbnailManager.cpp` / `.hpp` | 268 / 91 | 场景/源缩略图生成与缓存管理（限流+异步） |
| `ThumbnailItem.cpp` / `.hpp`、`ThumbnailView.cpp` / `.hpp` | 196/70、65/54 | 缩略图单项和列表视图控件 |
| `ScreenshotObj.cpp` / `.hpp` | 387 / 76 | 从 `obs_source_t` 抓一帧转 `QImage` 的通用逻辑（缩略图/截图共用） |
| `SceneRenameDelegate.cpp` / `.hpp` | 57 / — | 场景列表改名时的行内编辑代理 |
| `undo_stack.cpp` / `.hpp` | 170 / 58 | 全局撤销/重做栈——`OBSBasic` 持有一个 `undo_s` 实例，各处操作把 `undo_data`/`redo_data`（通常是场景 JSON 快照）压栈 |
| `QuickTransition.cpp` / `.hpp` | 47 / 48 | "快速转场"按钮对象（绑定一个转场源+时长+可选热键） |
| `PreviewProgramSizeObserver.cpp` / `.hpp` | 221 / 57 | 导播模式下预览/节目两块区域的尺寸联动（一个变化另一个跟着调整分栏） |
| `item-widget-helpers.cpp` / `.hpp` | 59 / 43 | 列表行 widget 的通用创建/更新小工具 |
| `NativeEventFilter.cpp` / `.hpp` | 未单列(小) / 小 | 全局原生事件过滤器（配合 `OBSApp` 的单例信号处理） |
| `NativeEventFilter_Windows.cpp` | 66 | Windows 下原生事件过滤的平台实现 |
| `BaseLexer.hpp` | 小 | 包一层 `libobs` 的 `lexer`（配置文件解析用的词法分析器） |
| `obf.c` / `.h` | 小 | 简单混淆字符串解密（`deobfuscate_str`，用于代码里不直接明文写密钥类字符串） |
| `SurfaceEventFilter.hpp` | 小 | 监听 `OBSQTDisplay` 的 `QPlatformSurfaceEvent`（原生 surface 创建/销毁） |
| `SettingsEventFilter.hpp` / `ResizeSignaler.hpp` | 小 | 设置窗口的按键事件过滤 / 尺寸变化信号中转 |
| `display-helpers.hpp` | 146 | `GetPixelSize` 等 DPI 缩放相关的像素尺寸计算——`OBSQTDisplay`/`OBSBasicPreview` 都依赖它 |

### utility/models　`utility/models/`

| 文件 | 行数 | 功能 |
|---|---|---|
| `branches.hpp` | 41 | `struct JsonBranch`：更新分支（stable/beta 等）的 JSON 反序列化结构 |
| `multitrack-video.hpp` | 287 | 多路视频 Go Live API 响应的 JSON 结构（`nlohmann::json` 反序列化） |
| `whatsnew.hpp` | 68 | "新版本特性介绍"页内容的 JSON 结构 |

---

## dialogs　`dialogs/`（40 文件）

**职责**：各种模态/非模态弹窗，`.hpp` 基本都只是薄薄一层 `QDialog` 声明 + `#include "ui_XXX.h"`（对应 `forms/XXX.ui`）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `OBSBasicFilters.cpp` / `.hpp` | 1165 / 126 | **滤镜面板**：源/滤镜双栏列表 + 属性视图，滤镜链的增删排序 |
| `OBSBasicSourceSelect.cpp` / `.hpp` | 952 / 96 | **新建源**弹窗：选类型、新建 vs 复用已有源、来源工具条（`FlowLayout`+`SourceSelectButton`）拼装 |
| `OBSYoutubeActions.cpp` / `.hpp` | 748 / 76 | YouTube 直播场次的创建/调度操作（配 `RemoteTextThread` 子类拉取分类/隐私设置） |
| `OBSBasicProperties.cpp` / `.hpp` | 508 / 74 | **属性面板**：单个源的 `obs_properties_t` 渲染（`OBSPropertiesView` 来自 `shared/`） |
| `OBSBasicTransform.cpp` / `.hpp` | 476 / 63 | **变换面板**：位置/缩放/旋转/裁剪/对齐/边界框数值编辑，和预览里拖拽是同一份 sceneitem 状态的两个入口 |
| `OBSBasicInteraction.cpp` / `.hpp` | 402 / 64 | "交互"弹窗：把鼠标/键盘事件转发给源（浏览器源、媒体源等支持交互的源） |
| `OBSRemux.cpp` / `.hpp` | 317 / 72 | 混流（Remux）批量转换弹窗 UI，逻辑委托给 `utility/RemuxQueueModel`/`RemuxWorker` |
| `OBSBasicAdvAudio.cpp` / `.hpp` | 195 / 44 | "高级音频属性"弹窗，逐源生成 `components/OBSAdvAudioCtrl` 行 |
| `OBSAbout.cpp` / `.hpp` | 172 / 19 | 关于弹窗 |
| `LogUploadDialog.cpp` / `.hpp` | 150 / 52 | 日志上传进度弹窗 |
| `OBSMissingFiles.cpp` / `.hpp` | 144 / 53 | 缺失文件弹窗 UI，数据模型是 `utility/MissingFilesModel` |
| `OBSIdianPlayground.cpp` / `.hpp` | 137 / 34 | Idian（OBS 新 UI 组件库）的控件试验/预览弹窗，开发调试用 |
| `OBSLogViewer.cpp` / `.hpp` | 130 / 22 | 应用内日志查看器 |
| `OBSBasicVCamConfig.cpp` / `.hpp` | 129 / 31 | 虚拟摄像头配置弹窗 |
| `NameDialog.cpp` / `.hpp` | 124 / 49 | 通用"输入一个名字"弹窗（新建场景/源/分组都复用它） |
| `OAuthLogin.cpp` / `.hpp` | 113 / 28 | OAuth 登录网页容器弹窗（内嵌浏览器视图） |
| `OBSPermissions.cpp` / `.hpp` | 98 / — | **macOS 专属**：麦克风/摄像头/屏幕录制系统权限状态检查与引导弹窗 |
| `OBSWhatsNew.cpp` / `.hpp` | 66 / 21 | "新版本特性"弹窗 |
| `OBSExtraBrowsers.cpp` / `.hpp` | 36 / 23 | 自定义浏览器停靠面板的增删管理弹窗 |
| `OBSUpdate.cpp` / `.hpp` | 45 / 28 | 更新提示弹窗 |

---

## docks　`docks/`（8 文件）

| 文件 | 行数 | 功能 |
|---|---|---|
| `OBSDock.cpp` / `.hpp` | 46 / 18 | 所有停靠面板的公共基类（`QDockWidget` 定制，处理显示事件） |
| `BrowserDock.cpp` / `.hpp` | 28 / 36 | 通用浏览器停靠面板（内嵌 CEF `QCefWidget`） |
| `YouTubeAppDock.cpp` / `.hpp` | 454 / 54 | YouTube 直播管理面板（创建广播、切换直播流key/账号模式） |
| `YouTubeChatDock.cpp` / `.hpp` | 35 / 23 | YouTube 聊天室嵌入面板 |

---

## settings　`settings/`（11 文件）

| 文件 | 行数 | 功能 |
|---|---|---|
| `OBSBasicSettings.cpp` ⭐ | 6082 | 设置窗口主体——**全仓单文件行数最大之一**，General/Stream/Output/Audio/Video/Hotkeys/Advanced 各页签的读取/校验/保存全在这一个类里 |
| `OBSBasicSettings.hpp` | 459 | 同上声明（数百个成员变量对应每个设置项控件） |
| `OBSBasicSettings_Stream.cpp` | 1869 | "推流"页签单独拆出：服务商选择、服务器列表拉取、流密钥校验 |
| `OBSBasicSettings_A11y.cpp` | 360 | 无障碍相关设置页逻辑 |
| `OBSBasicSettings_Appearance.cpp` | 170 | 外观/主题选择页逻辑 |
| `OBSHotkeyWidget.cpp` / `.hpp` | 246 / 99 | 热键录制控件（一个源/动作可绑定多个组合键） |
| `OBSHotkeyEdit.cpp` / `.hpp` | 223 / 96 | 热键录制的单个输入框（捕获按键组合） |
| `OBSHotkeyLabel.cpp` / `.hpp` | 73 / 35 | 热键列表左侧的动作名标签 |

### ⭐ 重点文件展开

#### `settings/OBSBasicSettings.cpp`
- **做什么**：设置窗口的"上帝类"——6082 行，几乎每个设置控件的信号槽都直接挂在这个类上，没有按页签再拆子类（`_Stream`/`_A11y`/`_Appearance` 是仅有的三个例外拆分）。
- **看点**：这是一个反面案例式的"看点"——体量大到本身就是"要不要按页签彻底拆类"的活教材；如果 WorkOBS 的设置页也会长成这样，提前按 Tab 拆独立 `NSViewController` 会比事后重构省事得多。

---

## wizards　`wizards/`（11 文件）

**职责**：首次运行/性能优化引导的"自动配置向导"，多页式 `QWizardPage` 流程。

| 文件 | 行数 | 功能 |
|---|---|---|
| `AutoConfig.cpp` / `.hpp` | 388 / 124 | 向导容器：管理页面跳转顺序、最终把结果写回 Profile 配置 |
| `AutoConfigTestPage.cpp` / `.hpp` | 1243 / 78 | **带宽/性能测试页**：实际起一段测试推流探测最大码率、CPU 编码能力 |
| `AutoConfigStreamPage.cpp` / `.hpp` | 712 / 51 | 推流服务/画质目标选择页 |
| `AutoConfigVideoPage.cpp` / `.hpp` | 131 / 20 | 分辨率/帧率选择页 |
| `AutoConfigStartPage.cpp` / `.hpp` | 48 / 24 | 向导首页（选"仅优化录制"还是"优化推流"） |
| `TestMode.hpp` | 64 | 测试模式下 mock 掉真实网络请求的开关（方便调试向导本身） |

---

## oauth　`oauth/`（12 文件）

**职责**：各推流平台的账号登录鉴权，`Auth`/`OAuth` 是抽象基类，各平台派生一个子类。

| 文件 | 行数 | 功能 |
|---|---|---|
| `Auth.cpp` / `.hpp` | 87 / 60 | 鉴权抽象基类：`Type`（无鉴权/OAuth 流密钥/OAuth 关联账号）、`Def` 注册结构，序列化到 service.json |
| `OAuth.cpp` / `.hpp` | 223 / 53 | OAuth 流程通用实现：token 保存/刷新判定（`TokenExpired`）、注册回调 `RegisterOAuth` |
| `AuthListener.cpp` / `.hpp` | 107 / 24 | 本地起一个临时 HTTP 监听接收 OAuth 回调重定向 |
| `TwitchAuth.cpp` / `.hpp` | 510 / 38 | Twitch 登录 + 调用 Twitch API 拿频道信息 |
| `YoutubeAuth.cpp` / `.hpp` | 311 / 39 | YouTube（Google OAuth）登录 |
| `RestreamAuth.cpp` / `.hpp` | 285 / 24 | Restream.io 登录 |

---

## updater　`updater/`（10 文件，**Windows 专属**）

**职责**：这是一个**独立的 Windows 可执行文件**（不是 `OBSApp` 内的一部分），`updater.hpp` 直接 `#include <windows.h>`，macOS 走的是完全不同的路径（`utility/OBSSparkle.mm` 调系统 Sparkle 框架，见上）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `updater.cpp` / `.hpp` | 2159 / 125 | 更新器主程序：下载增量包、校验、替换文件、重启主程序 |
| `http.cpp` | 455 | 极简 HTTP(S) 客户端（基于 WinHTTP） |
| `patch.cpp` | 150 | 二进制增量补丁应用 |
| `hash.cpp` | 81 | 文件哈希校验 |
| `manifest.hpp` | 93 | 更新清单 JSON 结构 |
| `helpers.hpp` / `.cpp` | 40 / 6 | 杂项小工具 |
| `init-hook-files.c` | 小 | 更新过程里需要提前处理的钩子文件列表 |
| `resource.h` / `updater.rc` / `updater.manifest` | — | Windows 资源文件（图标/清单/UAC 提权声明） |

---

## importer / importers　`importer/`、`importers/`（12 文件）

**职责**：`importer/` 是**弹窗 UI**，`importers/` 是**各软件的实际解析器**——两个目录配合完成"从其它直播软件导入场景集合"。

| 文件 | 行数 | 功能 |
|---|---|---|
| `importer/OBSImporter.cpp` / `.hpp` | 248 / 46 | 导入弹窗：选文件、选目标 profile/collection、进度展示 |
| `importer/ImporterModel.cpp` / `.hpp` | 210 / 61 | 待导入项列表的数据模型 |
| `importer/ImporterEntryPathItemDelegate.cpp` / `.hpp` | 161 / 44 | 路径列编辑代理 |
| `importers/importers.cpp` / `.hpp` | 103 / 168 | 统一入口：探测文件属于哪种格式，分发给下面具体解析器 |
| `importers/classic.cpp` | 576 | 解析 **OBS Classic**（初代 OBS，非本仓库）的配置格式 |
| `importers/xsplit.cpp` | 533 | 解析 **XSplit** 的场景配置 |
| `importers/sl.cpp` | 525 | 解析 **Streamlabs OBS** 的场景配置 |
| `importers/studio.cpp` | 287 | 解析**本家旧版 OBS Studio**场景集合（跨大版本兼容导入） |

---

## plugin-manager　`plugin-manager/`（4 文件）

| 文件 | 行数 | 功能 |
|---|---|---|
| `PluginManager.cpp` / `.hpp` | 312 / 78 | `namespace OBS`：扫描已安装插件模块信息（`ModuleInfo`：display_name/module_name/路径），供设置页展示 |
| `PluginManagerWindow.cpp` / `.hpp` | 178 / 46 | 插件管理器的独立窗口 UI |

---

## models　`models/`（4 文件）

| 文件 | 行数 | 功能 |
|---|---|---|
| `Rect.hpp` / `.cpp` | 98 / 35 | 通用矩形数值类型（含安全类型转换 `safeConvertToDouble`，防止溢出） |
| `SceneCollection.hpp` / `.cpp` | 64 / 71 | `namespace OBS::SceneCollection`：场景集合文件路径与坐标模式（`SceneCoordinateMode::Absolute/Relative`——新旧版本场景 JSON 坐标系兼容）封装 |

---

## api　`api/`

见上文"顶层入口与应用骨架"一节——`obs-frontend-api.h`（267 行，公开头）、`obs-frontend-api.cpp`（688 行，转发实现）、`obs-frontend-internal.hpp`（147 行，回调接口声明）。这是**唯一**独立打包成动态库（`obs-frontend-api`）供插件链接的部分，其余 `frontend/` 目录整体编译进主程序，插件不可见。

---

## forms　`forms/`（36 个 `.ui` + 资源）

**职责**：Qt Designer 生成的界面布局文件，逐个对应一个 `.cpp/.hpp` 类（同名，找类实现直接去 `dialogs/`、`widgets/`、`settings/`、`components/`、`wizards/`、`importer/`、`plugin-manager/` 找对应目录即可）：

| `.ui` | 对应实现 |
|---|---|
| `OBSBasic.ui` | `widgets/OBSBasic.cpp` |
| `OBSBasicControls.ui` | `widgets/OBSBasicControls.cpp` |
| `OBSBasicFilters.ui` / `OBSBasicProperties.ui` / `OBSBasicSourceSelect.ui` / `OBSBasicTransform.ui` / `OBSBasicInteraction.ui` / `OBSBasicVCamConfig.ui` | `dialogs/` 同名 `.cpp` |
| `OBSBasicSettings.ui` | `settings/OBSBasicSettings.cpp` |
| `OBSAdvAudio.ui` | `dialogs/OBSBasicAdvAudio.cpp` |
| `ColorSelect.ui` | `widgets/ColorSelect.cpp` |
| `StatusBarWidget.ui` | `widgets/StatusBarWidget.cpp` |
| `OBSAbout.ui` / `LogUploadDialog.ui` / `OBSExtraBrowsers.ui` / `OBSIdianPlayground.ui` / `OBSLogViewer.ui` / `OBSMissingFiles.ui` / `OBSPermissions.ui` / `OBSRemux.ui` / `OBSUpdate.ui` / `OBSYoutubeActions.ui` | `dialogs/` 同名 `.cpp` |
| `OBSImporter.ui` | `importer/OBSImporter.cpp` |
| `PluginManagerWindow.ui` | `plugin-manager/PluginManagerWindow.cpp` |
| `AutoConfig*.ui`（Start/Stream/Test/Video/Finish 5 个） | `wizards/AutoConfig*.cpp` |
| `XML-Schema-Qt5.15.xsd` | `.ui` 文件本身的 XML schema，非界面 |
| `fonts/`、`images/`、`source-toolbar/`、`obs.qrc` | 字体、图标资源与 Qt 资源清单（打包进二进制的静态资源） |

---

## 阅读建议

1. 先看 `obs-main.cpp` 的 `main()`（:888）和 `OBSApp::OBSInit`（`OBSApp.cpp:1225`），搞清楚"进程起来到 `libobs` 初始化完成"这条主线，再看 `OBSBasic::OBSInit`（`widgets/OBSBasic.cpp:991`）——这是唯一必须按顺序读的部分，其它目录都可以按需查表跳读。
2. 想学预览交互，直接看 `widgets/OBSQTDisplay.cpp` + `widgets/OBSBasicPreview.cpp` 这两个文件就够了，不需要先读完 `OBSBasic.cpp`——`GetMouseEventPos`（:51）和 `mouseMoveEvent`（:1600）是全篇价值密度最高的两段代码。
3. 音量表/混音条按"`VolumeMeter`（画表）← `VolumeControl`（一条控制条）← `AudioMixer`（整个面板容器）"的包含顺序读，`obs_volmeter_create`/`obs_volmeter_add_callback` 这两个调用点（`components/VolumeMeter.cpp:294`）是它和 `libobs` 音频子系统对接的唯一接缝。
4. `settings/OBSBasicSettings.cpp`（6082 行）和 `widgets/OBSBasic.cpp` 系列不建议通读，遇到具体设置项/具体功能时用符号名反查对应小节即可——这类"上帝类"读目录比读内容更有效率。
5. `dialogs/`、`docks/`、`wizards/`、`oauth/`、`importer(s)/`、`plugin-manager/`、`models/` 这几个小目录都是"功能自解释"的独立弹窗/流程，用不到可以完全跳过，等实际要做同类功能（比如 WorkOBS 要接场景导入或第三方登录）再回来精读对应文件。
6. `updater/` 是 Windows 专属可执行文件，macOS 侧对应逻辑在 `utility/OBSSparkle.mm`/`OBSUpdateDelegate.mm`/`MacUpdateThread.cpp`——在 macOS 上写更新功能应该看后面这几个文件，不是 `updater/`。
