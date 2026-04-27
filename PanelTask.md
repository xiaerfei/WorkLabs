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

## 四、前置确认（已验证，无需新增 Task）

| 项目 | 状态 |
|------|------|
| `WLObserveStartStreaming` / `WLObserveStartRecording` | **已存在**于 `WLEventConst.h` |
| `WLObserveStopStreaming` / `WLObserveStopRecording` | **已存在** |
| `addCameraSourceWithConfig:` | **已实现** 于 `WLSceneManager` |
| `addVideoSourceWithPath:` | **已实现** 于 `WLSceneManager` |
| `addAudioSourceWithPath:` | **已实现** 于 `WLSceneManager` |

---

## 五、执行任务

### Task 1: 删除废弃文件（必须同步更新 Xcode 项目）

> **重要**：直接删除磁盘文件不会清理 `project.pbxproj` 中的引用，会导致编译报错。
> **必须使用 `mcp__xcode__XcodeRM`** 删除文件（自动同步 pbxproj），或手动清理以下 pbxproj 条目。

删除以下 6 个文件（使用 XcodeRM，每个文件调用一次）：
- `WorkLabs/UI/ControlPanel/WLScenePanel.h`
- `WorkLabs/UI/ControlPanel/WLScenePanel.m`
- `WorkLabs/UI/ControlPanel/WLTransitionPanel.h`
- `WorkLabs/UI/ControlPanel/WLTransitionPanel.m`
- `WorkLabs/UI/ControlPanel/WLControlPanelContainerView.h`
- `WorkLabs/UI/ControlPanel/WLControlPanelContainerView.m`

pbxproj 中已确认的引用（供手动清理时参考）：

| 类型 | ID | 内容 |
|------|----|------|
| PBXBuildFile | 61AA691E5834E71747D8DAB7 | WLScenePanel.m in Sources |
| PBXBuildFile | 72007AC2781B5474AC08B610 | WLControlPanelContainerView.m in Sources |
| PBXBuildFile | 7924514B0A156B04FDA094BF | WLTransitionPanel.m in Sources |
| PBXFileReference | 061C57C4FE8D83AE2434E24F | WLTransitionPanel.h |
| PBXFileReference | 5BE989D556E418EB17B19381 | WLControlPanelContainerView.m |
| PBXFileReference | 857C13881AB44FAFEE0A460D | WLControlPanelContainerView.h |
| PBXFileReference | 86743E9611E0A815E6438FA5 | WLScenePanel.h |
| PBXFileReference | 920EC4A8EE892BEAF00AEC80 | WLScenePanel.m |
| PBXFileReference | 9DDD5D5FFCB6D8E8D78C435E | WLTransitionPanel.m |

### Task 2: 新建 WLPanelViewController

> **重要**：新建文件必须使用 `mcp__xcode__XcodeWrite` 创建，自动加入 Xcode target。直接在磁盘新建文件不会被编译进去。

创建 `WorkLabs/UI/ControlPanel/WLPanelViewController.h/.m`：
- 作为 NSViewController，嵌入 `WLMainViewController` 底部
- 持有 3 个子 Panel（NSView）水平等宽排列，Panel 间 1pt 间隙形成分隔线
- 容器底色 `#3C3C3C`
- 深色主题外观（`NSAppearanceNameDarkAqua`）

**布局约束（Masonry）**：
```objc
// 在 WLMainViewController 中
[self addChildViewController:self.panelVC];
[self.view addSubview:self.panelVC.view];
[self.panelVC.view mas_makeConstraints:^(MASConstraintMaker *make) {
    make.leading.trailing.bottom.equalTo(self.view);
    make.height.mas_equalTo(220);
}];
```

### Task 3: 新建 WLMenuPanelViewController

> **重要**：同 Task 2，使用 `mcp__xcode__XcodeWrite` 创建文件。

创建 `WorkLabs/UI/ControlPanel/WLMenuPanelViewController.h/.m`：
- NSTableView 展示可选媒体源类型列表
- 通过 `callerType`（枚举：Source / AudioMixer）过滤展示项
- 点击行回调执行对应 action + dismiss popover

**摄像头子菜单实现方案：使用 NSMenu**

```
点击「摄像头」行 → 弹出 NSMenu（通过 [NSMenu popUpContextMenu:withEvent:forView:]）
NSMenu 每个 item 对应一个 AVCaptureDevice（从 WLDevicesManager 获取列表）
点击 device item → 调用 WLSceneManager addCameraSourceWithConfig: → dismiss popover
```

不使用嵌套 NSPopover（macOS 不推荐），不使用 inline 展开（TableView 改造成本高）。

### Task 4: 重构 WLSourcePanel

- 数据源过滤为 `type != Audio`
- 底部 toolbar 精简为 `+` | `-`，锚点为 `+` 按钮（`positioningView`）
- `+` 触发 NSPopover + WLMenuPanelViewController（callerType = Source）
- 移除旧 toolbar 上的 `gearshape`、`chevron.up`、`chevron.down` 按钮

### Task 5: WLAudioMixerPanel 占位保留

- 保持当前空壳状态（titleBar + 空白 contentView + `+`/`-` toolbar）
- `+` 接入 NSPopover + WLMenuPanelViewController（callerType = AudioMixer）
- 不实现音频源列表和音量控制

### Task 6: 重构 WLControlsPanel

保留：`streamButton`（开始直播）、`recordButton`（开始录制）、`settingsButton`（设置）

**删除以下属性和方法**：
- `@property NSButton *virtualCamButton`（启动虚拟摄像机）
- `@property NSButton *virtualCamGear`（虚拟摄像机齿轮）
- `@property NSButton *studioButton`（工作室模式）
- `- (void)toggleVirtualCamera`
- `- (void)virtualCameraSettings`
- `- (void)toggleStudioMode`

3 个保留按钮垂直排列，风格统一为深色扁平按钮：
- 开始直播 → 发送 `WLObserveStartStreaming`
- 开始录制 → 发送 `WLObserveStartRecording`
- 设置 → 预留（空实现）

### Task 7: 更新 WLMainViewController

- 替换 `WLControlPanelContainerView` 为 `WLPanelViewController`（见 Task 2 布局代码）
- 使用 `addChildViewController:` 添加
- 清理废弃 import：`#import "WLControlPanelContainerView.h"`、`#import "WLScenePanel.h"`、`#import "WLTransitionPanel.h"`

### Task 8: 验证编译

```bash
xcodebuild -workspace WorkLabs.xcworkspace -scheme WorkLabs -configuration Debug
```
