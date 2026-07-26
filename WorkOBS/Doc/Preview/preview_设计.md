# Per-Source 交互式预览设计

## 背景

WorkOBS 原先只有一个 `WLPreviewView`（`AVSampleBufferDisplayLayer`）直显合成帧（实际 last-source-wins），用户无法在预览上拖拽/缩放源的位置。

参考 WorkLabs 的 `WLStreamPreview` + `WLStreamViewController`，将交互式浮层搬进 WorkOBS。**当前阶段不做 Metal 合成**，先实现 UI 交互层。

## 架构

```
ViewController
├─ previewArea（深色外围）
│  └─ WLCanvasView（画布容器，16:9 居中）
│     ├─ WLSourcePreview (源A) ← 可拖拽/缩放/选中/右键
│     ├─ WLSourcePreview (源B)
│     └─ ...
├─ WLDockManager（底部 5 dock）
└─ WLCore 生命周期
```

## 文件结构

```
OBSLabs/OBSLabs/
├── ViewController.mm               ← 画布 + 浮层管理 + 帧轮询
├── Canvas/
│   ├── WLCanvasView.h/.m           ← 画布容器（点击空白取消选中）
│   ├── WLCanvasLayout.h/.m         ← 画布布局模型（per-source rect + z-order）
│   └── WLSourcePreview.h/.mm       ← 交互式浮层（AVSampleBufferDisplayLayer + 拖拽/缩放/选中/右键）
└── Docks/
    └── WLSourcesDockViewController.mm  ← 源添加/删除 → 事件总线 → ViewController 创建/移除浮层
```

## 数据流

```
源添加：
  SourcesDock → WLCore::add_source + start
    → sendEvent:SourceAdded {sourcePtr, name, type}
    → ViewController handler:
      1. 创建 WLSourcePreview（初始 frame = 画布中央 50%）
      2. 加入 canvasView
      3. 记录到 sources 数组
      4. WLCanvasLayout 设置初始 layout

帧路由（轮询，不改 C++）：
  ViewController 30fps NSTimer
    → 遍历 sources → WLSource::get_frame(now_ns, &pts)
    → retain → dispatch_async main → enqueuePixelBuffer:pts:

拖拽/缩放：
  WLSourcePreview mouseDown/Dragged/Up
    → delegate sourcePreview:didUpdateFrame:
    → ViewController canvasRectFromViewRect → WLCanvasLayout 更新

源删除：
  SourcesDock → sendEvent:SourceRemoved {sourcePtr}
    → ViewController handler:
      1. 移除 preview + flush
      2. WLCanvasLayout 移除 layout
      3. sources 数组移除
```

## WLSourcePreview（从 WorkLabs WLStreamPreview 搬入）

参照 `WorkLabs/UI/WLStreamPreview.m`（428 行），保留全部交互逻辑：

### 核心功能
- **AVSampleBufferDisplayLayer** 渲染视频帧
- **8 handle 拖拽缩放**：BottomLeft/Bottom/BottomRight/Left/Right/TopLeft/Top/TopRight
- **等比缩放**：按 videoAspect 锁定宽高比，锚对角/对边
- **选中态**：红色 borderLayer + 8 个红色 handleLayer
- **右键菜单**：置顶/上移/下移/置底/取消选中/移除源
- **首帧自适应**：收到首帧按 videoAspect 调整 frame 高度
- **丢帧背压**：atomic pendingEnqueues >= 2 时丢帧（拖动时防内存尖峰）

### Delegate 协议

```objc
@protocol WLSourcePreviewDelegate <NSObject>
- (void)sourcePreview:(WLSourcePreview *)preview didUpdateFrame:(CGRect)frame;
@optional
- (void)sourcePreviewDidRequestSelect:(WLSourcePreview *)preview;
- (void)sourcePreviewDidRequestDeselect:(WLSourcePreview *)preview;
- (void)sourcePreviewDidRequestRemove:(WLSourcePreview *)preview;
- (void)sourcePreview:(WLSourcePreview *)preview didRequestZOrderAction:(WLZOrderAction)action;
@end
```

## WLCanvasLayout（画布布局模型）

```objc
@interface WLCanvasLayout : NSObject
@property CGSize canvasSize;                     // 默认 1920×1080
- (void)setLayoutRect:(CGRect)rect forSourceID:(NSString *)sid;
- (CGRect)layoutRectForSourceID:(NSString *)sid;
- (void)removeLayoutForSourceID:(NSString *)sid;
- (void)bringToFront/sendToBack/moveUp/moveDown:(NSString *)sid;
- (NSArray<NSString *> *)sourceOrder;  // bottom → top
@end
```

内部：`NSMutableDictionary<NSString*, NSValue*> *layouts` + `NSMutableArray<NSString*> *order`。

## 坐标换算

```
画布像素坐标 ←→ canvasView 显示坐标

viewRectFromCanvasRect:  (cr.origin.x * fx, cr.origin.y * fy, cr.size.width * fx, cr.size.height * fy)
canvasRectFromViewRect:  (vr.origin.x * fx, vr.origin.y * fy, vr.size.width * fx, vr.size.height * fy)

fx = canvasView.bounds.width  / canvasLayout.canvasSize.width
fy = canvasView.bounds.height / canvasLayout.canvasSize.height
```

窗口 resize 时通过 `NSViewFrameDidChangeNotification` 重算所有浮层位置。

## 帧路由策略

当前方案（轮询）：
- 30fps NSTimer 遍历所有源
- 调 `WLSource::get_frame(now_ns, &pts)` 获取当前帧
- retain → dispatch_async main → enqueuePixelBuffer:pts:
- 只处理异步源（`WL_SOURCE_ASYNC` 位）

后续可升级为 C++ 回调方案（`output_video` 里触发 per-source callback），但不阻塞 UI 交付。

## 与 WorkLabs 的差异

| 方面 | WorkLabs | WorkOBS |
|------|----------|---------|
| 协议 | WLStreamRenderingProtocol | WLSourcePreviewDelegate（自定义） |
| 帧来源 | WLStreamsManager 路由 | WLSource::get_frame 轮询 |
| 画布模型 | WLCanvasModel（已有） | WLCanvasLayout（新建） |
| 合成 | Metal（WLVideoMix） | 无（后续加入） |
| 坐标换算 | WLStreamViewController 内 | ViewController 内 |
