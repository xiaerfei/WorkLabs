---
name: wlffmpeg-mediasource-migration
overview: 迁移 WLMediaSource 到 WLFFmpegMediaSource，新建 WLNodeFrameQueue，扩展 WLNodeFrame，实现 WLMediaSourceProvider 协议
todos:
  - id: extend-wlnodeframe
    content: 扩展 WLNodeFrame：添加 audioFrame/next 属性和 flush 方法实现
    status: completed
  - id: create-wlnodeframequeue
    content: 新建 WLNodeFrameQueue：参照 WLNodeQueue 实现线程安全的帧链表队列
    status: completed
    dependencies:
      - extend-wlnodeframe
  - id: migrate-wlffmpegmediasource
    content: 迁移 WLMediaSource 核心逻辑到 WLFFmpegMediaSource 并实现 WLMediaSourceProvider 协议
    status: completed
    dependencies:
      - create-wlnodeframequeue
  - id: build-verify
    content: 使用 xcode 构建项目并修复编译错误
    status: completed
    dependencies:
      - migrate-wlffmpegmediasource
---

## Product Overview

将 WLMediaSource 中的 FFmpeg 解码核心逻辑迁移到 WLFFmpegMediaSource，使其成为实现 WLMediaSourceProvider 协议的完整 FFmpeg 媒体源。同时新建 WLNodeFrameQueue 队列、扩展 WLNodeFrame 支持音频数据并实现资源释放。

## Core Features

### 1. WLNodeFrame 扩展

- 新增 `AVFrame *audioFrame` 属性，用于存储原始音频解码数据（`libavutil/frame.h`）
- 实现 `- (void)flush;` 方法：释放 `audioFrame`(av_frame_free)、释放 `pixelBuffer`(CVPixelBufferRelease)
- dealloc 中调用 flush 确保资源回收

### 2. WLNodeFrameQueue（新建）

- 参照 WLNodeQueue 的 pthread_mutex + pthread_cond 实现模式
- 存储元素类型从 WLNode 改为 WLNodeFrame
- 使用链表结构（head/tail + next 指针），WLNodeFrame 需增加 `next` 属性
- 提供完整接口：initWithSize / enQueue / enQueueNonBlocking / deQueueWithBlock / peek / abort / flush / count
- 放置在 `WorkLabs/Scene/Utils/` 目录下，与 WLNodeFrame 同级

### 3. WLFFmpegMediaSource 核心迁移

从 WLMediaSource.m (543行) 迁移以下逻辑：

- **FFmpeg 初始化**：openFile → openVideoStream (含 VideoToolbox 硬解) → openAudioStream
- **Parse Thread**：av_read_frame 读包，按流索引分发到 videoPacketQueue / audioPacketQueue
- **Video Decode Thread**：从 videoPacketQueue 取包 → avcodec_send_packet → avcodec_receive_frame → 封装为 WLNodeFrame → 入队 videoFrameQueue
- **Audio Decode Thread**：同理，解码后封装为 WLNodeFrame (含 audioFrame) → 入队 audioFrameQueue
- **关键变化**：移除 videoRenderThread 和 audioRenderThread（由外部消费者通过协议方法获取帧）

### 4. WLMediaSourceProvider 协议实现

- `sourceType` 返回 WLMediaSourceTypeFFmpeg
- `sourceName` 从文件路径提取
- `start` 启动 parseThread
- `stop` 停止运行标志 + abort 所有队列 + 释放 FFmpeg 资源
- `nextVideoFrame` 从 videoFrameQueue 出队返回 WLNodeFrame
- `nextAudioFrame` 从 audioFrameQueue 出队返回 WLNodeFrame
- `intrinsicSize` 返回视频原始分辨率
- `volume` / `isActive` / `frameRate` 基础实现

## Tech Stack

- 语言: Objective-C (ARC)
- 平台: macOS 15.2+
- FFmpeg: ffmpeg-kit-local (libavformat, libavcodec, libavutil, libswscale, libswresample)
- 线程同步: pthread_mutex / pthread_cond / stdatomic.h
- 多媒体框架: CoreVideo (CVPixelBuffer), CoreMedia (CMTime)

## Tech Architecture

### 系统架构（迁移前后对比）

```
┌─ 原 WLMediaSource 架构 ──────────────────────────────┐
│  parseThread → [WLNodeQueue(WLNode)]                 │
│    → decodeThread → [WLNodeQueue(WLNode)]            │
│      → renderThread → WLStreamsManager (推送模式)      │
└───────────────────────────────────────────────────────┘

┌─ 新 WLFFmpegMediaSource 架架构 ───────────────────────┐
│  parseThread → [WLNodeQueue(WLNode)]  ← 内部包队列     │
│    → decodeThread → [WLNodeFrameQueue(WLNodeFrame)]   │
│      → 外部调用者 ← nextVideoFrame()/nextAudioFrame() │
│              (拉取模式 / Pull-based via Protocol)     │
└───────────────────────────────────────────────────────┘
```

### 数据流详细设计

1. **start() 被调用** → 设置 running=YES → 启动 parseThread
2. **parseThread**: configureFFmpeg → 初始化 packetQueues(WLNodeQueue) + frameQueues(WLNodeFrameQueue) → 启动 decodeThreads → 循环 av_read_frame 按流索引分发 packet 到对应的 packetQueue
3. **videoDecodeThread**: 循环从 videoPacketQueue 取 WLNode(AVPacket) → avcodec_send_packet → avcodec_receive_frame → 将 AVFrame 转换为 WLNodeFrame(含 pixelBuffer 或保留 AVFrame 引用) → 入队 videoFrameQueue(WLNodeFrameQueue)
4. **audioDecodeThread**: 同理 → WLNodeFrame(含 audioFrame=av_frame_clone) → 入队 audioFrameQueue
5. **外部消费者** 调用 nextVideoFrame / nextAudioFrame → 从对应 WLNodeFrameQueue 非阻塞出队 → 返回 WLNodeFrame（调用者使用后自行决定是否 flush）
6. **stop() 被调用** → running=NO → abort 所有 queue → join 等待线程退出 → releaseFFmpegResources

### 关键技术决策

1. **内部 packet 队列继续使用 WLNodeQueue/WLNode**：packet 阶段不需要对外暴露，复用现有 WLNode/WLNodeQueue 避免不必要的重写。只有 frame 队列升级为 WLNodeFrameQueue/WLNodeFrame
2. **WLNodeFrame 增加 `next` 属性**：因为 WLNodeFrameQueue 采用链表实现（参照 WLNodeQueue），需要节点持有 next 指针
3. **视频帧的 pixelBuffer 填充策略**：当 VideoToolbox 硬解时，AVFrame->data[0] 包含 CVPixelBufferRef，需通过 CVPixelBufferRetain 转换；软解时暂不转换 pixelBuffer（后续可加 swscale），仅保留 AVFrame 数据
4. **音频帧存储策略**：新增 audioFrame 属性直接持有 av_frame_clone 后的 AVFrame*，外部消费者可读取 sampleRate/channelCount/data 等信息
5. **线程模型简化**：去掉 renderThread 及其时间戳同步逻辑（baseTime/ptsOffset），这些应由场景调度器统一管理。WLFFmpegMediaSource 只负责"生产"帧并放入队列
6. **nextVideoFrame/nextAudioFrame 使用非阻塞出队**：deQueueWithBlock:NO，避免阻塞渲染线程。如果队列为空返回 nil，由调用方处理

### 目录结构

```
WorkLabs/Scene/
├── Utils/
│   ├── WLNodeFrame.h              # [MODIFY] 新增 audioFrame 属性、next 指针、flush 方法声明
│   ├── WLNodeFrame.m              # [MODIFY] 实现初始化、flush、dealloc
│   ├── WLNodeFrameQueue.h         # [NEW]    线程安全帧队列（参照 WLNodeQueue）
│   ├── WLNodeFrameQueue.m         # [NEW]    链式队列实现
│   └── WLMediaSourceProvider.h    # [NO CHANGE] 协议定义不变
└── MediaSources/FFmpeg/
    ├── WLFFmpegMediaSource.h      # [MODIFY] 扩展接口：initWithPath、内部属性
    └── WLFFmpegMediaSource.m      # [MODIFY] 完整实现：FFmpeg 解码 + 协议方法
```

### 关键代码结构

**WLNodeFrame 扩展属性:**

```objc
// WLNodeFrame.h 新增
#import "libavutil/frame.h"

@interface WLNodeFrame : NSObject
// ... 现有属性 ...

/// 音频原始帧数据（仅 audio 类型有效，内部管理生命周期）
@property (nonatomic, unsafe_unretained, nullable) AVFrame *audioFrame;

/// 链表下一节点（WLNodeFrameQueue 内部使用）
@property (nonatomic, strong, nullable) WLNodeFrame *next;

/// 释放所有持有的资源
- (void)flush;
@end
```

**WLNodeFrameQueue 接口:**

```objc
// WLNodeFrameQueue.h
@interface WLNodeFrameQueue : NSObject
@property (nonatomic, assign, readonly) NSInteger nodeSize;
@property (nonatomic, assign) NSInteger allSize;
@property (nonatomic, assign, readonly) BOOL abortRequest;
@property (nonatomic, copy, nullable) NSString *queueName;
@property (nonatomic, strong, nullable) WLNodeFrame *head;
@property (nonatomic, strong, nullable) WLNodeFrame *tail;

- (instancetype)initWithSize:(int)size;
- (void)enQueue:(WLNodeFrame *)frame;
- (BOOL)enQueueNonBlocking:(WLNodeFrame *)frame;
- (nullable WLNodeFrame *)deQueueWithBlock:(BOOL)block;
- (nullable WLNodeFrame *)peek;
- (void)abort;
- (void)flush;
- (int)count;
@end
```

**WLFFmpegMediaSource 接口扩展:**

```objc
// WLFFmpegMediaSource.h
@interface WLFFmpegMediaSource : NSObject <WLMediaSourceProvider>
/// 媒体文件路径
@property (nonatomic, copy, readonly) NSString *path;
/// 是否正在运行
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

- (instancetype)initWithPath:(NSString *)path;
// start/stop/nextVideoFrame/nextAudioFrame/intrinsicSize 继承自 WLMediaSourceProvider
@end
```

## Implementation Notes

1. **性能考虑**：videoFrameQueue 容量建议设为 4（与原 WLMediaSource 一致），audioFrameQueue 设为 20。packet 队列容量保持 video=15/audio=20
2. **内存管理**：WLNodeFrame 的 audioFrame 使用 `unsafe_unretained` 或 `assign`（与原 WLNode.frame 一致风格），由 flush 方法负责 av_frame_free。pixelBuffer 需要 CVPixelBufferRetain/CVPixelBufferRelease 配对
3. **线程安全**：WLNodeFrameQueue 的所有公共方法均在 mutex 保护下；isActive 可用 atomic_bool 或 @synchronized 保证
4. **停止顺序**：stop() 应先设 running=NO → abort packetQueues（让 decodeThread 自然退出）→ 等待 decodeThread 完成（decodeThread 退出时会 abort frameQueues）→ 最后 releaseFFmpegResources。注意不再需要 _activeRenderThreads 原子计数（去掉了 renderThread），简化资源释放时机
5. **VideoToolbox pixelBuffer 提取**：当 frame->format == AV_PIX_FMT_VIDEOTOOLBOX 时，frame->data[0] 即为 CVPixelBufferRef，需要 `(CVPixelBufferRef)frame->data[0]` 并 CVPixelBufferRetain
6. **向后兼容**：原有的 WLMediaSource 保持不动（位于 WorkLabs/Core/MediaSource/），WLFFmpegMediaSource 是全新的 Scene 模块实现

## Agent Extensions

### MCP

- **xcode**
- Purpose: 在 Xcode 项目中创建新文件（WLNodeFrameQueue.h/m）、修改已有文件（WLNodeFrame.h/m、WLFFmpegMediaSource.h/m），并在构建后检查编译错误
- Expected outcome: 所有文件正确创建/修改并通过编译验证