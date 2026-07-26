# 底部 Dock 栏封装重构方案

## Context（为什么要做）

`ViewController.mm` 当前 467 行，一个文件承担了 5 类职责：
WLPreviewView 预览、WLDockView 通用容器、WLSourceRow 模型、Sources dock 的全部交互（表格+增删源+NSOpenPanel+NSTableViewDataSource/Delegate）、Controls dock 占位、3 个 Placeholder dock 占位、整体布局、WLCore 生命周期、预览帧 enqueue。

结果是 ViewController 既管"整体骨架"又管"每个 dock 的内部细节"，5 个 dock 的代码全堆在一个文件里，加新 dock（如 M3 场景、M4 音频）会让这个文件继续膨胀。

目标：把每个底部 Dock 抽成独立的 `NSViewController`，由一个 `WLDockManager` 统一注册、布局、转发生命周期；ViewController 只跟 Manager 打交道，预览 + WLCore 生命周期留在顶层。高内聚低耦合，对齐 OBS"每个面板是一个独立模块"的形态。

## 架构总览

```
ViewController
   │  持有 WLDockManager（属性）
   │  约束 manager.dockBar 到 self.view 底部
   ▼
WLDockManager
   │  持有 5 个 WLDockViewController 子类实例（NSMutableArray）
   │  负责创建/注册/替换 dock、构造 dockBar、转发 viewWillDisappear
   ▼
WLDockViewController（基类）        ← 统一 title + WLDockView 作为 self.view + helper
   ▲     ▲       ▲       ▲       ▲
   │     │       │       │       │
WLSources WLControls WLScenes WLAudio  WLTransitions
DockVC    DockVC     DockVC   MixerDockVC  DockVC
(.mm/OC++) (.m)      (.m)    (.m)         (.m)

5 个 dock 各自独立文件，互不共用——
未来 M3 把 WLScenesDockViewController 从占位改成真功能时，
其他 4 个文件一行都不用动。
```

## 改造范围

只动底部 5 个 Dock。`WLPreviewView` + 预览帧 enqueue + WLCore 启停留在 ViewController（预览是顶层职责，不在本次范围）。

## 文件结构

```
OBSLabs/OBSLabs/
├── ViewController.h / .mm              ← 只剩：布局 + 预览 + WLCore 生命周期 + 持有 dockManager
└── Docks/
    ├── WLDockView.h / .mm             ← 通用容器（深色标题栏 + contentView），所有 dock 共用
    ├── WLDockViewController.h / .m    ← Dock VC 基类
    ├── WLDockManager.h / .m           ← 管理器
    ├── WLSourcesDockViewController.h / .mm        ← OC++（持 WLSource*）
    ├── WLControlsDockViewController.h / .m         ← 纯 OC，占位
    ├── WLScenesDockViewController.h / .m           ← 占位（M3 替换为真功能）
    ├── WLAudioMixerDockViewController.h / .m       ← 占位（M4 替换为真功能）
    └── WLTransitionsDockViewController.h / .m     ← 占位（后续替换为真功能）
```

5 个 dock 各自独立文件，没有共用占位基类——每个 dock 的演进只动自己那一个文件，互不影响。

## 各组件职责

### `WLDockView`（通用容器，原样搬出 ViewController.mm）

接口不变：`initWithTitle:` + `contentView` 只读属性。深色标题栏 24pt + contentView 撑满。零修改。

### `WLDockViewController`（基类）

所有 Dock VC 的父类，封装"把 WLDockView 作为 self.view"的公共行为：

```objc
@interface WLDockViewController : NSViewController
@property (nonatomic, weak, nullable) WLDockManager *manager;   // 反向引用，由 Manager 在 addDock 时设置；dock VC 主动广播事件时用
- (instancetype)initWithTitle:(NSString *)title;
- (WLDockView *)dockView;     // 返回 self.view 强转
- (NSView *)dockContent;      // 返回 dockView.contentView
@end
```

- `loadView` 创建 `WLDockView` 作为 `self.view`
- `manager` 弱引用属性：Manager 在 `addDock:forIdentifier:` 里反向设置 `dock.manager = self`，子类通过 `[self.manager sendEvent:...]` 主动广播事件
- `dockView` / `dockContent` 两个 helper（3 行），子类加自己的 UI 时直接 `[self.dockContent addSubview:...]`
- 子类 override `viewDidLoad` 调 `[super viewDidLoad]` 后塞自己的内容

### `WLDockManager`（管理器 + 事件总线）

#### 事件驱动机制

`sendEvent:info:` 是 Manager 的**统一事件派发入口**，`subscribeEvent:handler:` / `unsubscribeWithTag:` 是 **subscribe 端**。两层职责清晰：
- **命令式 API 内部调 `[self sendEvent:...]`**：执行 dock 增删后派发对应 Did 事件
- **外部（任何 dock VC / ViewController / 未来菜单项）也能调 `[manager sendEvent:...]`**：dock 之间可通过 Manager 互相广播自定义事件而互不知——真正解耦
- **block 订阅模式**：比协议模式更轻量——不需要 observer 协议、不需要弱引用集合，subscribe 返回 tag、unsubscribe 按 tag 退订

```objc
typedef NS_ENUM(NSInteger, WLDockIdentifier) {
    WLDockIdentifierScenes,
    WLDockIdentifierSources,
    WLDockIdentifierAudioMixer,
    WLDockIdentifierTransitions,
    WLDockIdentifierControls,
};

typedef NS_ENUM(NSInteger, WLEventType) {
    WLEventTypeDockDidAdd,
    WLEventTypeDockDidRemove,
    WLEventTypeDockDidReplace,
    WLEventTypeDockVisibilityChanged,   // show/hide
    // 未来扩展（如 WLEventTypeSceneSwitched）只加枚举值，subscribe 接口不变
};

@interface WLDockManager : NSObject
@property (nonatomic, readonly) NSStackView *dockBar;

/// 发送事件
- (void)sendEvent:(WLEventType)event info:(id __nullable)info;

/// 订阅事件，返回 tag 用于退订
- (NSUInteger)subscribeEvent:(WLEventType)event
                     handler:(void(^)(WLEventType event, id __nullable info))handler;

/// 移除订阅的事件
- (void)unsubscribeWithTag:(NSUInteger)tag;

// 命令式 API（内部派发事件）
- (void)setupDefaultDocks;
- (void)addDock:(WLDockViewController *)dock forIdentifier:(WLDockIdentifier)identifier;
- (void)removeDockForIdentifier:(WLDockIdentifier)identifier;
- (void)replaceDockForIdentifier:(WLDockIdentifier)identifier
                        withDock:(WLDockViewController *)newDock;
- (void)setVisible:(BOOL)visible forIdentifier:(WLDockIdentifier)identifier;
- (nullable WLDockViewController *)dockForIdentifier:(WLDockIdentifier)identifier;

- (void)viewWillDisappear;   // 转发给所有 dock VC
@end
```

#### 内部实现要点

- `NSMapTable<NSNumber *, WLDockViewController *> *docks`：identifier → dock VC 映射（强引用 value）
- `NSMutableArray<NSNumber *> *dockOrder`：维护 dockBar 显示顺序
- `NSMutableDictionary<NSNumber *, NSMutableArray *> *subscriptions`：WLEventType → 订阅记录数组
- 每条订阅记录：`{ tag: NSUInteger, handler: block }`（用轻量 struct 或小 NSDictionary 存储）
- `NSUInteger _nextTag`：自增计数器，`subscribeEvent:` 返回后 `_nextTag++`
- `subscribeEvent:handler:`：构造记录 { tag, handler } 追加到 `subscriptions[event]` 数组，返回 tag
- `unsubscribeWithTag:`：遍历 subscriptions 所有事件数组，找到 tag 匹配的记录移除（tag 全局唯一，O(N) 遍历但订阅量极小）
- `sendEvent:info:` 实现：取 `subscriptions[event]` 数组，遍历调 `handler(event, info)`
- `dockBar`：lazy getter，根据 dockOrder 当前可见 dock 构造 NSStackView（horizontal + fillEqually + spacing 6）
- `addDock:forIdentifier:` 内部：写入 docks + 追加 dockOrder + 重建 dockBar + `[self sendEvent:WLEventTypeDockDidAdd info:@{ @"identifier": @(identifier), @"dock": dock }]` + 反向设置 `dock.manager = self`（弱引用）
- `viewWillDisappear`：遍历 docks 调 `[dock viewWillDisappear]`

#### sendEvent info 约定

命令式 API 内部派发事件时，`info` 按约定传 NSDictionary：
- `WLEventTypeDockDidAdd`：`@{ @"identifier": @(WLDockIdentifier), @"dock": dockVC }`
- `WLEventTypeDockDidRemove`：`@{ @"identifier": @(WLDockIdentifier) }`
- `WLEventTypeDockDidReplace`：`@{ @"identifier": @(WLDockIdentifier), @"oldDock": oldVC, @"newDock": newVC }`
- `WLEventTypeDockVisibilityChanged`：`@{ @"identifier": @(WLDockIdentifier), @"visible": @(YES/NO) }`

外部自定义事件（未来 M3 场景联动等）的 info 格式由发送方和订阅方自行约定。

#### visibility vs remove 的区别

- `setVisible:NO`：只是从 dockBar 移除 view，dock VC 仍由 Manager 持有、状态保留，可恢复（OBS"显示/隐藏 dock"）
- `removeDock`：彻底摘除 + 释放，不可恢复（OBS"关闭 dock"）

#### 未来扩展点（不实现，留接口）

- Will+Did 双向事件（Will 允许订阅方否决）：本次 YAGNI
- 应用层事件（sourceAdded / sceneSwitched / recordingStarted）：本次 YAGNI，扩展时只需加 `WLEventType` 枚举值 + 派发方调 sendEvent，subscribe 接口不变
- `insertDock:forIdentifier:atIndex:`：本次 setupDefaultDocks 顺序固定，不需要

#### M3 联动示例（dock 之间互相广播，无需互知）

```objc
// WLScenesDockViewController 切场景后：
[self.manager sendEvent:WLEventTypeSceneSwitched    // 未来加的枚举值
                    info:@{ @"sceneIndex": @(3) }];

// WLSourcesDockViewController viewDidLoad 里订阅：
_tag = [self.manager subscribeEvent:WLEventTypeSceneSwitched
                             handler:^(WLEventType event, id info) {
    NSInteger sceneIndex = [info[@"sceneIndex"] integerValue];
    // 刷新源列表
}];
```

### 各子 Dock VC

**`WLSourcesDockViewController`**（OC++，搬走 ViewController 里所有 Sources 相关代码）
- 持有：`rows`（NSMutableArray<WLSourceRow *>）、`tableView`、`removeButton`
- 私有模型 `WLSourceRow` 留在自己的 .mm 文件里（不暴露给外部）
- 实现 `NSTableViewDataSource / NSTableViewDelegate`
- 实现方法：`pickAddSourceType:` / `addSourceFromMenu:` / `addMediaFileSource` / `removeSelectedSource:` / `warn:`
- 直接调 `WLCore::add_source` / `WLCore::remove_source`（静态 API，全局可达，无需 ViewController 转发——这正是 OBS 全局 API 的设计意图）
- `viewWillDisappear`：清空 rows + reload tableView + disable removeButton（自己管自己）

**`WLControlsDockViewController`**（纯 OC，占位）
- 5 个 disabled 按钮：开始推流 / 开始录制 / 虚拟摄像头 / Studio Mode / 设置
- 垂直 NSStackView fillEqually
- 等 M2 录制 / M5 推流时再激活

**`WLScenesDockViewController`**（纯 OC，当前占位，M3 替换真功能）
- 当前：居中灰字"场景（≈M3）"
- M3 时本文件替换为真场景列表逻辑

**`WLAudioMixerDockViewController`**（纯 OC，当前占位，M4 替换真功能）
- 当前：居中灰字"音频混音（M4）"
- M4 时本文件替换为真音频混音逻辑

**`WLTransitionsDockViewController`**（纯 OC，当前占位）
- 当前：居中灰字"转场（后续）"
- 转场功能上线时本文件替换为真转场逻辑

> 三个占位 dock 各自独立文件，不共用基类。当前实现是 ~15 行的"label 居中"重复，但换来后续替换真功能时只动单个文件、零交叉影响。

## 改造后的 ViewController（核心片段）

```objc
// ViewController.mm
#import "WLDockManager.h"

@interface ViewController ()
@property (nonatomic, strong) WLPreviewView *previewView;
@property (nonatomic, strong) WLDockManager *dockManager;
- (void)enqueuePreviewFrame:(CVPixelBufferRef)pixbuf pts:(int64_t)pts_ns;
@end

@implementation ViewController

- (void)buildUI {
    // ... previewArea / preview 创建与约束（不变）

    self.dockManager = [WLDockManager new];
    [self.dockManager setupDefaultDocks];
    NSStackView *dockBar = self.dockManager.dockBar;
    dockBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:dockBar];

    // dockBar 约束（底部、固定高 200）—— 不变
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self.dockManager viewWillDisappear];   // 转发：dock VC 先清自己数据
    WLCore::set_frame_output(NULL, NULL);   // 再摘回调、shutdown
    WLCore::shutdown();
    [self.previewView.videoLayer flush];
}

@end
```

ViewController 删掉的代码：
- `WLDockView` 整个 `@interface`/`@implementation`（搬到 Docks/WLDockView.mm）
- `WLSourceRow` 整个 `@interface`/`@implementation`（搬到 WLSourcesDockViewController.mm 内部）
- `fillSourcesDock:` / `fillControlsDock:` / `fillPlaceholderDock:text:` 三个方法
- `pickAddSourceType:` / `addSourceFromMenu:` / `addMediaFileSource` / `removeSelectedSource:` / `warn:`
- `numberOfRowsInTableView:` / `tableView:viewForTableColumn:row:` / `tableViewSelectionDidChange:`
- 属性 `rows` / `tableView` / `removeButton`
- `<NSTableViewDataSource, NSTableViewDelegate>` 协议声明

ViewController 保留：
- `WLPreviewView` 内部类（预览，本次不动）
- `previewView` 属性、`enqueuePreviewFrame:pts:`
- `onCompositedFrame` 回调 + `WLCore::startup/shutdown/set_frame_output`
- 整体布局约束（previewArea + dockBar + 16:9 aspect-fit + 最小尺寸约束）
- 新增 `dockManager` 属性

### 生命周期顺序（关键）

关窗时：`[self.dockManager viewWillDisappear]` 先调用（每个 dock VC 清自己的 rows/状态）→ 然后 ViewController 才 `WLCore::shutdown()`。这保证 Sources dock 在 WLCore 销毁前已经摘掉自己的展示模型对 `WLSource*` 的借用引用，避免悬空指针。

注：Sources dock 的 `WLSourceRow.src` 是借用（owner = WLCore），dock VC 自己清 rows 只摘展示模型，不 delete 源——`remove_source` 还是走 dock VC 的删除按钮逻辑。但 viewWillDisappear 时 dock VC 把 rows 清空、tableView reload 后，就不再有任何视图引用 `WLSource*` 了，WLCore 随后 shutdown 安全。

## 实施步骤

1. 创建 `OBSLabs/OBSLabs/Docks/` 目录
2. 写 `WLDockView.h` / `WLDockView.mm`：把 ViewController.mm 里的 WLDockView 原样搬出（含深色样式 + header + contentView 布局）
3. 写 `WLDockViewController.h` / `.m`：基类，`initWithTitle:` + `loadView` 创建 WLDockView 作为 self.view + `dockView` / `dockContent` helper
4. 写 `WLSourcesDockViewController.h` / `.mm`：继承基类，搬 Sources 全部逻辑，WLSourceRow 作为私有内部类放在 .mm 顶部；`viewWillDisappear` 清自己的 rows
5. 写 `WLControlsDockViewController.h` / `.m`：继承基类，搬 fillControlsDock 的按钮栈
6. 写 3 个独立占位 dock VC：`WLScenesDockViewController.h/.m` / `WLAudioMixerDockViewController.h/.m` / `WLTransitionsDockViewController.h/.m`，各自继承基类、各自 viewDidLoad 里摆一个居中灰字 label。当前实现重复 ~15 行，换来后续替换真功能时零交叉影响。
7. 写 `WLDockManager.h` / `.m`：
   - 定义 `WLDockIdentifier` / `WLEventType` 枚举
   - 内部维护 `NSMapTable<NSNumber*, WLDockViewController*> *docks` + `NSMutableArray<NSNumber*> *dockOrder` + `NSMutableDictionary<NSNumber*, NSMutableArray*> *subscriptions` + `NSUInteger _nextTag`
   - 实现 `subscribeEvent:handler:`（构造订阅记录追加到 subscriptions 数组，返回 tag）/ `unsubscribeWithTag:`（遍历找到 tag 匹配记录移除）/ `sendEvent:info:`（取 subscriptions[event] 数组遍历调 handler）
   - 实现命令式 API（`addDock:forIdentifier:` / `removeDockForIdentifier:` / `replaceDockForIdentifier:withDock:` / `setVisible:forIdentifier:` / `dockForIdentifier:`），每个 API 执行 dock 操作后调 `[self sendEvent:...]` 派发对应 Did 事件；`addDock:` 内部反向设置 `dock.manager = self`
   - `setupDefaultDocks`：依次 `addDock:` 创建 Sources/Controls/Scenes/Audio/Transitions 5 个 dock VC（顺序即 dockBar 从左到右）
   - `dockBar` getter：根据 dockOrder 当前可见 dock 构造 NSStackView（horizontal + fillEqually + spacing 6）；visibility 变化时调用方需触发 dockBar 重建（本次实现：setVisible 时直接重建 dockBar 的 arrangedSubviews）
   - `viewWillDisappear`：遍历 docks 调 `[dock viewWillDisappear]`
8. 改 `ViewController.mm`：
   - 删除上述搬走的代码
   - import `WLDockManager.h`
   - 加 `dockManager` 属性
   - buildUI 改成创建 manager + setup + 把 `manager.dockBar` 摆进布局
   - viewWillDisappear 改成先调 `[self.dockManager viewWillDisappear]`，再 shutdown WLCore
9. 在 `OBSLabs/` 目录运行 `xcodegen generate` 重新生成工程
10. 编译验证（用 XcodeBuildMCP 的 BuildProject 或 xcode MCP 的 BuildProject）

## 验证方式

1. **编译通过**：`xcodegen generate` + 构建无 error
2. **运行表现一致**：
   - 启动后 5 个 dock 显示正常，标题/内容跟重构前一致
   - Sources dock：点 + 弹菜单 → 选媒体文件 → 添加成功、表格出现新行 → 选中行点 − 能删除
   - Sources dock：未选中行时 − 按钮 disabled，选中后 enabled
   - Controls dock：5 个按钮显示但 disabled
   - Scenes/Audio/Trans：居中灰字提示文字正确
   - 预览区不受影响，能正常 enqueue 帧
   - 窗口可自由 resize、最小宽度 800、最小高度由 preview≥100 隐式保证
3. **生命周期**：关窗时无 crash（dock VC 先清数据、VC 再 shutdown WLCore）
4. **架构**：ViewController 不再 import 任何 Dock 子类头文件，只 import `WLDockManager.h`——验证"ViewController 跟具体 dock 解耦"
5. **事件机制**（本期最小验证）：
   - ViewController subscribe `WLEventTypeDockDidAdd`，在控制台 NSLog 收到的 info（setupDefaultDocks 应触发 5 次）
   - 调一次 `[manager setVisible:NO forIdentifier:WLDockIdentifierSources]` 验证：dockBar 重排、Sources dock 视图消失、subscribe handler 收到 `WLEventTypeDockVisibilityChanged` 事件
   - 再调 `setVisible:YES` 恢复

## 不做的事

- 不动 WLPreviewView / 预览 enqueue（用户只说做 Dock）
- 不动 WLCore / WLSource 任何 C++ 代码
- 不实现 Will+Did 双向事件（YAGNI，只做 Did）
- 不实现应用层事件枚举（sourceAdded/sceneSwitched 等 YAGNI，未来加只需扩 `WLEventType` 枚举值 + 派发方调 `sendEvent:info:`，subscribe 接口不变）
- 不改 storyboard / AppDelegate / project.yml 的 sources 配置（xcodegen 自动包含 Docks/ 子目录）
- `replaceDockForIdentifier:withDock:` 本期实现接口签名 + 真实替换逻辑（M3 替换占位为真功能时即可用），但本期不接入调用方
