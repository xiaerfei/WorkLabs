# OBS UI 面板分析

## 整体布局

OBS 底部控制区域采用**水平排列的多面板布局**，从左到右依次为 5 个功能面板 + 底部状态栏。所有面板高度一致，使用深色主题（深灰色背景 #1a1a1a ~ #2a2a2a），面板之间有细分隔线。

---

## 面板详情

### 1. 场景面板（场景）
- **位置**：最左侧
- **宽度**：约占总宽 20%
- **结构**：
  - 顶部标题栏：图标 + "场景" 文字标签
  - 内容区：列表视图，当前有一个"场景"条目，选中状态高亮为蓝色
  - 底部工具栏（从左到右）：
    - `+` 添加场景
    - `🗑` 删除场景
    - `□` 复制场景
    - `∧` 上移
    - `∨` 下移

---

### 2. 源面板（源）
- **位置**：第二列
- **宽度**：约占总宽 20%
- **结构**：
  - 顶部标题栏：图标 + "源" 文字标签
  - 内容区（空状态）：
    - 居中显示 `?` 占位图标
    - 提示文字：  
      "您还没有添加任何源。  
      点击下面的 + 按钮，  
      或者右击此处添加一个。"
  - 底部工具栏（从左到右）：
    - `+` 添加源
    - `🗑` 删除源
    - `⚙` 属性设置
    - `∧` 上移
    - `∨` 下移

---

### 3. 混音器面板（混音器）
- **位置**：中间
- **宽度**：约占总宽 20%
- **结构**：
  - 顶部标题栏：图标 + "混音器" 文字标签
  - 音频通道行（麦克风/Aux）：
    - 通道名称标签：`麦克风/Aux`
    - 音量数值标签：`0.0 dB`（右对齐）
    - 电平计（Level Meter）：横向渐变色条
      - 颜色从左到右：绿色 → 黄色 → 红色
      - 刻度标注：-60 / -55 / -50 / -45 / -40 / -35 / -30 / -25 / -20 / -15 / -10 / -5 / 0
    - 音量滑块：蓝色填充的横向 Slider，右端有开关（Toggle）
    - 静音图标（🔊）：位于滑块左侧
  - 底部工具栏：
    - `⚙` 音频高级设置
    - `⋮` 更多选项

---

### 4. 转场动画面板（转场动画）
- **位置**：第四列
- **宽度**：约占总宽 20%
- **结构**：
  - 顶部标题栏：图标 + "转场动画" 文字标签
  - 转场类型下拉框：当前选中 `淡入淡出`，带下拉箭头
  - 时长设置行：
    - 标签：`时长`
    - 数值输入框：`300 ms`
    - 右侧上下微调箭头（SpinBox）
  - 底部工具栏：
    - `+` 添加转场
    - `🗑` 删除转场
    - `⋮` 更多选项

---

### 5. 控制按钮面板（控制按钮）
- **位置**：最右侧
- **宽度**：约占总宽 20%
- **结构**：
  - 顶部标题栏：图标 + "控制按钮" 文字标签
  - 按钮列表（垂直排列，等宽）：
    1. `开始直播` — 主要操作按钮
    2. `开始录制` — 主要操作按钮
    3. `启动虚拟摄像机` + `⚙`（右侧附带齿轮设置图标，分成两段）
    4. `工作室模式` — 次要功能按钮
    5. `设置` — 全局设置入口按钮

---

## 状态栏（底部通栏）

位于整个界面最底部，横跨全宽，包含以下信息（从右到左）：

| 元素 | 内容 |
|------|------|
| FPS 指示 | `30.00 / 30.00 FPS` |
| CPU 使用率 | `CPU: 1.9%` |
| 录制时长 | `00:00:00`（带录制圆点图标） |
| 推流时长 | `00:00:00`（带时钟图标） |
| 网络信号 | 信号强度图标（最左） |

---

## UI 设计规律总结

| 特征 | 描述 |
|------|------|
| 主题风格 | 深色 Dark Theme，接近纯黑背景 |
| 字体颜色 | 浅灰 / 白色文字 |
| 选中高亮 | 蓝色（#1a6fce 左右） |
| 面板结构 | 标题栏 + 内容区 + 底部工具栏，三段式统一结构 |
| 工具栏图标 | 小型单色图标，无文字标注 |
| 控制按钮 | 文字按钮，深灰色背景，圆角矩形，等宽排列 |
| 分隔线 | 细线（1px），颜色接近 #3a3a3a |
| 布局方向 | 水平 Flex / HStack，各面板等高 |

---

## WorkLabs 实现逻辑

### 文件结构

```
WorkLabs/UI/ControlPanel/
├── WLScenePanel.h / .m              # 场景面板
├── WLSourcePanel.h / .m             # 源面板
├── WLAudioMixerPanel.h / .m         # 混音器面板（暂留空）
├── WLTransitionPanel.h / .m         # 转场动画面板
├── WLControlsPanel.h / .m           # 控制按钮面板
└── WLControlPanelContainerView.h/.m # 容器 View
```

### 容器布局（WLControlPanelContainerView）

- 容器背景色 `#3C3C3C`，作为面板间分隔线的底色
- 5 个面板水平排列，Masonry 等宽约束（`make.width.equalTo(firstPanel)`）
- 面板之间 `offset(1)` 间隙，容器底色透出即为 1pt 分隔线
- 统一应用 `NSAppearanceNameDarkAqua`，使 `NSPopUpButton`、`NSStepper` 等系统控件自动渲染为深色

```objc
// 等宽排列核心约束
for (NSUInteger i = 0; i < panels.count; i++) {
    [panel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.bottom.equalTo(self);
        if (i == 0) {
            make.left.equalTo(self);
        } else {
            make.left.equalTo(prev.mas_right).offset(1); // 1pt 分隔
            make.width.equalTo(panels[0]);               // 等宽
        }
        if (i == panels.count - 1) make.right.equalTo(self);
    }];
}
```

### 面板内部结构（三段式，统一模式）

```
┌──────────────────────────┐
│  图标 + 标题（30pt）      │  backgroundColorWithHex:0x252525
├──────────────────────────┤  1pt 分隔线 0x3C3C3C
│  内容区（flex 撑满）      │  backgroundColorWithHex:0x1E1E1E
├──────────────────────────┤  1pt 分隔线 0x3C3C3C
│  工具栏（32pt）           │  backgroundColorWithHex:0x1A1A1A
└──────────────────────────┘
```

### 各面板实现要点

| 面板 | 内容区实现 | 工具栏按钮 |
|------|-----------|-----------|
| `WLScenePanel` | `NSTableView`（无列头，行高 28pt，默认选中第一行） | `+` `−` `❐` `∧` `∨` |
| `WLSourcePanel` | 空状态：`?` 大字 + 提示文字（居中） | `+` `−` `⚙` `∧` `∨` |
| `WLAudioMixerPanel` | 暂留空，待设计 | — |
| `WLTransitionPanel` | `NSPopUpButton`（淡入淡出等）+ `NSTextField`/`NSStepper` 联动 | `+` `−` `⋯` |
| `WLControlsPanel` | 5 个 `NSButton` 垂直排列；虚拟摄像机行右侧带独立齿轮按钮 | — |

### 事件通信（WLEvent 总线）

在 `WLEventConst.h` 中新增事件类型：

```objc
WLObserveStartStreaming,    // 开始直播
WLObserveStopStreaming,     // 停止直播
WLObserveStartRecording,   // 开始录制
WLObserveStopRecording,    // 停止录制
WLObserveSceneChange,      // 场景切换
WLObserveSourceChange,     // 源变化
WLObserveTransitionChange, // 转场变化
```

面板之间**不直接耦合**，通过 `WLSend()` 广播：

```objc
// WLControlsPanel 触发直播
WLSend().type(WLObserveStartStreaming).payload(nil).send();

// WLScenePanel 场景新增
WLSend().type(WLObserveSceneChange).payload(name).send();

// WLTransitionPanel 转场类型变化
WLSend().type(WLObserveTransitionChange).payload(sender.titleOfSelectedItem).send();
```

### 接入 WLMainViewController

```objc
self.controlPanelContainer = [[WLControlPanelContainerView alloc] init];
[self.view addSubview:self.controlPanelContainer];
[self.controlPanelContainer mas_makeConstraints:^(MASConstraintMaker *make) {
    make.left.right.bottom.equalTo(self.view);
    make.height.mas_equalTo(220);
}];
```

### 颜色规范

| 用途 | Hex |
|------|-----|
| 面板背景 | `#1E1E1E` |
| 标题栏背景 | `#252525` |
| 工具栏背景 | `#1A1A1A` |
| 分隔线 / 容器底色 | `#3C3C3C` |
| 主文字 | `rgba(255,255,255, 0.85)` |
| 次文字 / 图标 | `rgba(255,255,255, 0.65)` |
| 占位文字 | `rgba(255,255,255, 0.35~0.45)` |
