# ControlPanel 重构计划

## 一、设计目标

将底部控制面板从当前 5 面板水平布局重构为 `WLPanelViewController` 驱动 3 面板水平布局：

```
WLPanelViewController (水平排列)
  ├── WLSourcePanel        ├── WLAudioMixerPanel        ├── WLControlsPanel
  [Icon | 源]              [Icon | 混音器]              [Icon | 控制]
  列表 + [+ | -]           （待设计） + [+ | -]         开始直播 / 开始录制 / 设置
```

### 与现状对比

| 项目 | 现状 | 重构后 |
|------|------|--------|
| 容器 | WLControlPanelContainerView (NSView) | WLPanelViewController (NSViewController) |
| 布局方向 | 水平 5 列等宽 | 水平 3 列等宽 |
| Panel 数量 | 5（场景/源/混音器/转场/控制） | 3（源/混音器/控制） |
| WLScenePanel | 存在 | 删除 |
| WLTransitionPanel | 存在 | 删除 |
| 容器高度 | 220pt | 220pt（保持） |

---

## 二、数据模型分析

两个 Panel 共享 `WLMediaSourceItem` 作为统一数据模型，从 `WLSceneManager.sources` 获取并按类型过滤：

| Panel | 过滤条件 | 来源 |
|-------|---------|------|
| WLSourcePanel | `type == Camera` 或 `type == Video` | `[WLSceneManager manager].sources` 过滤 |
| WLAudioMixerPanel | `type == Audio`（待实现） | `[WLSceneManager manager].sources` 过滤 |

`WLMediaSourceItem` 已包含 Panel 所需的所有属性：

| 属性 | Panel 用途 |
|------|-----------|
| `name` | 列表显示名称 |
| `type` | 决定归属哪个 Panel + 列表图标 |
| `isSelected` | 行选中高亮 |
| `volume` / `muted` | AudioMixer Panel 音量滑块 / 静音按钮（待实现） |
| `running` | 运行状态指示 |

不需要新增任何数据模型。

---

## 三、各 Panel 详细设计

### 3.1 WLSourcePanel（视频源 Panel）

标题为：源

```
---------------------------
Icon | 源
---------------------------
Source 1  (Camera.fill)
Source 2  (film)

---------------------------
+ | -
---------------------------
```

- **数据源**：`WLSceneManager.sources` 过滤 `type != Audio`
- **列表图标**：Camera → `camera.fill`，Video → `film`
- '+' 点击弹出 NSPopover，内含 `WLMenuPanelViewController`，展示可选媒体源类型（Camera、Video File 等）
- 选中列表项 → 执行对应添加操作 → Popover 自动 dismiss
- '-' 删除选中源
- 空状态显示引导提示
- 移除旧版 toolbar 的 gearshape / chevron.up / chevron.down 按钮

### 3.2 WLAudioMixerPanel（音频混音 Panel — 占位）

> **混音器 Panel 暂时留空，待后续设计完善后再实现具体功能。**

标题为：混音器

```
---------------------------
Icon | 混音器
---------------------------
        （待设计）

---------------------------
+ | -
---------------------------
```

- 保留 titleBar（Icon + "混音器"）+ 底部 toolbar（+ | -）
- 内容区暂为空（保持当前 WLAudioMixerPanel 的空壳状态）
- '+' 弹出 NSPopover + WLMenuPanelViewController（复用）
- '-' 预留
- **本次重构不实现音频源列表、音量滑块、静音按钮**

### 3.3 WLControlsPanel（控制 Panel）

```
---------------------------
Icon | 控制
---------------------------
    [ 开始直播 ]
    [ 开始录制 ]
    [   设置   ]
---------------------------
```

- 3 个按钮垂直排列，风格统一为深色扁平按钮
- 开始直播 → 发送 `WLObserveStartStreaming`
- 开始录制 → 发送 `WLObserveStartRecording`
- 设置 → 预留
- 移除旧版的虚拟摄像机、工作室模式按钮

### 3.4 WLMenuPanelViewController（添加源 Popover）

NSPopover 中承载的菜单 ViewController，列出可添加的媒体源类型：

```
┌─────────────────────────┐
│ 📷 摄像头         ▸     │
│ 🎬 视频文件              │
│ 🎵 音频文件              │
└─────────────────────────┘
```

- 以 NSTableView 展示源类型列表，每行 icon + 名称
- 根据调用方过滤可选项：
  - WLSourcePanel 调用 → 显示 Camera、Video File
  - WLAudioMixerPanel 调用 → 显示 Audio File
- 点击行 → 执行对应 action，Popover dismiss
- 摄像头行右侧 `▸` 展开子菜单选择具体设备

### 3.5 添加源交互流程

#### 视频文件流程

```
点击 '+' → NSPopover 弹出 → 选择「视频文件」→ NSOpenPanel 选文件
→ WLSceneManager.addVideoSourceWithPath:
→ 创建 WLMediaSourceItem (type=Video) + WLMediaSource engine
→ WLObserveSourceChange 事件发出
→ WLSourcePanel 监听事件 → tableView reload → 新 Item 出现在列表
→ [item start] → sourceEngine.start → running=YES
```

#### 摄像头流程

```
点击 '+' → NSPopover 弹出 → 选择「摄像头 ▸」→ 展开设备子列表 → 点击设备
→ WLSceneManager.addCameraSourceWithConfig:
→ 创建 WLMediaSourceItem (type=Camera) + WLCameraSource engine
→ WLObserveSourceChange 事件发出
→ WLSourcePanel 监听事件 → tableView reload → 新 Item 出现在列表
→ [item start] → sourceEngine.start → running=YES
```

#### 音频文件流程

```
点击 '+' → NSPopover 弹出 → 选择「音频文件」→ NSOpenPanel 选文件
→ WLSceneManager.addAudioSourceWithPath:
→ 创建 WLMediaSourceItem (type=Audio) + WLMediaSource engine
→ WLObserveSourceChange 事件发出
→ WLAudioMixerPanel 监听事件 → tableView reload → 新 Item 出现在列表（待实现）
→ [item start] → sourceEngine.start → running=YES
```

关键约定：添加源后自动调用 `[item start]`，无需用户手动启动。

---

## 四、执行任务

### Task 1: 删除废弃文件

删除：
- `WorkLabs/UI/ControlPanel/WLScenePanel.h`
- `WorkLabs/UI/ControlPanel/WLScenePanel.m`
- `WorkLabs/UI/ControlPanel/WLTransitionPanel.h`
- `WorkLabs/UI/ControlPanel/WLTransitionPanel.m`
- `WorkLabs/UI/ControlPanel/WLControlPanelContainerView.h`
- `WorkLabs/UI/ControlPanel/WLControlPanelContainerView.m`

### Task 2: 新建 WLPanelViewController

创建 `WorkLabs/UI/ControlPanel/WLPanelViewController.h/.m`：
- 作为 NSViewController，嵌入 `WLMainViewController` 底部
- 持有 3 个子 Panel（NSView）水平等宽排列
- 容器底色 0x3C3C3C（Panel 间 1pt 间隙形成分隔线）
- 深色主题外观

### Task 3: 新建 WLMenuPanelViewController

创建 `WorkLabs/UI/ControlPanel/WLMenuPanelViewController.h/.m`：
- NSTableView 展示可选媒体源类型列表
- 支持按调用方类型过滤展示项
- 点击行回调执行对应 action + dismiss popover
- 摄像头项展开设备子列表

### Task 4: 重构 WLSourcePanel

- 数据源过滤为 `type != Audio`
- 底部 toolbar 精简为 + | -
- '+' 触发 NSPopover + WLMenuPanelViewController
- 移除旧 toolbar 多余按钮

### Task 5: WLAudioMixerPanel 占位保留

- 保持当前空壳状态（titleBar + 空白 contentView + +/- toolbar）
- '+' 接入 NSPopover + WLMenuPanelViewController
- 不实现音频源列表和音量控制

### Task 6: 重构 WLControlsPanel

- 精简为 3 个按钮：开始直播 / 开始录制 / 设置
- 移除虚拟摄像机、工作室模式按钮

### Task 7: 更新 WLMainViewController

- 替换 `WLControlPanelContainerView` 为 `WLPanelViewController`
- 使用 `addChildViewController:` 添加
- 清理废弃 import

### Task 8: 验证编译

```bash
xcodebuild -workspace WorkLabs.xcworkspace -scheme WorkLabs -configuration Debug
```
