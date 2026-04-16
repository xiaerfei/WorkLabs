# WorkLabs OBS-Style Architecture

## 架构概述

WorkLabs 采用类似 OBS 的架构设计，支持多场景切换、多媒体源混合和转场动画。

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     WorkLabs OBS-Style Architecture                      │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                            ┌───────▼───────┐
                            │ WLSceneManager │
                            │  (场景管理器)   │
                            └───────┬───────┘
                                    │
                            ┌───────▼───────┐
                            │    WLScene    │
                            │    (场景)      │
                            └───────┬───────┘
                                    │ (虚线: 包含关系)
              ┌─────────────────────┴─────────────────────┐
              │              Scene 内部                   │
              │  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐│
              │  │FFmpeg│ │Camera│ │Screen│ │Image│ │Color││ ...│
              │  │Source│ │Source│ │Source│ │Source│ │Source││    │
              │  └────┘ └────┘ └────┘ └────┘ └────┘ └────┘│
              │   ────────────┬────────────┬────────────  │  (音频)
              │    视频 ──────┘            └──────────────│
              │                                              │
    ┌─────────▼─────────┐                      ┌──────────▼────────┐
    │ WLSceneRenderer   │                      │   WLMediaMixer    │
    │  (视频合成: Layer/Metal/GL)              │ (音频混音: 音量/淡入淡出/同步) │
    └─────────┬─────────┘                      └──────────┬────────┘
              │ 视频帧                                  │ 音频帧
              └────────────────┬───────────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │ WLTransitionEngine  │
                    │ (转场: Fade/Slide/Cut/Zoom) │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │       Output        │
                    │ (Preview/Record/Stream) │
                    └─────────────────────┘

        ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐
        │Source│  │视频合成│  │音频混音│  │转场动画│
        └──────┘  └──────┘  └──────┘  └──────┘
```

## 视图层级架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        WLSceneManager                                    │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ @property (nonatomic, strong) WLSceneManagerView *managerView;  │   │
│  │ @property (nonatomic, strong) WLScene *currentScene;            │   │
│  │ @property (nonatomic, strong) NSArray<WLScene *> *scenes;      │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     WLSceneManagerView                                   │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ @property (nonatomic, strong) NSView *backgroundView;  (背景层)  │   │
│  │ @property (nonatomic, strong) NSView *contentView;     (内容层)  │   │
│  │ @property (nonatomic, strong) NSView *transitionView; (转场层)  │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                  │
│  │backgroundView│  │ contentView  │  │transitionView│                  │
│  │   (背景)      │  │(当前场景视图) │  │   (转场覆盖)  │                  │
│  └──────────────┘  └──────────────┘  └──────────────┘                  │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                           WLScene                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ @property (nonatomic, copy) NSString *name;                    │   │
│  │ @property (nonatomic, strong) NSMutableArray<id<WLMediaSource>> *sources;   │
│  │ @property (nonatomic, strong) WLMediaMixer *audioMixer;        │   │
│  │ @property (nonatomic, strong) WLSceneView *sceneView;         │   │
│  │ @property (nonatomic, assign) CGSize canvasSize;              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          WLSceneView                                      │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ @property (nonatomic, strong) NSMutableArray<WLSourceView *> *sourceViews; │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐                          │
│  │SourceView1 │ │SourceView2 │ │SourceView3 │ ...                      │
│  │ (媒体源视图) │ │ (媒体源视图) │ │ (媒体源视图) │                          │
│  └────────────┘ └────────────┘ └────────────┘                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## 核心组件

### 1. WLSceneManager (场景管理器)

负责管理所有场景的创建、删除、切换和切换动画。

```objc
@interface WLSceneManager : NSObject

@property (nonatomic, strong, readonly) WLSceneManagerView *managerView;
@property (nonatomic, strong, readonly) WLScene *currentScene;
@property (nonatomic, strong, readonly) NSArray<WLScene *> *scenes;

- (instancetype)initWithContainerView:(NSView *)containerView;
- (WLScene *)createSceneWithName:(NSString *)name;
- (void)removeScene:(WLScene *)scene;
- (void)switchToScene:(WLScene *)scene withTransition:(WLTransition *)transition;
@end
```

### 1.1 WLSceneManagerView (视图容器)

场景管理器的视图容器，包含背景层、内容层、转场层。

```objc
@interface WLSceneManagerView : NSView

@property (nonatomic, strong, readonly) NSView *backgroundView;   // 背景层
@property (nonatomic, strong, readonly) NSView *contentView;     // 内容层 (当前场景)
@property (nonatomic, strong, readonly) NSView *transitionView;  // 转场层

- (void)setBackgroundColor:(NSColor *)color;
- (void)setBackgroundImage:(NSImage *)image;
@end
```

### 2. WLScene (场景)

代表一个场景，包含多个媒体源和视图。

```objc
@interface WLScene : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<id<WLMediaSource>> *sources;
@property (nonatomic, strong) WLMediaMixer *audioMixer;
@property (nonatomic, strong, readonly) WLSceneView *sceneView;
@property (nonatomic, assign) CGSize canvasSize;

- (instancetype)initWithName:(NSString *)name canvasSize:(CGSize)size;
- (void)addSource:(id<WLMediaSource>)source atRect:(CGRect)rect;
- (void)removeSource:(id<WLMediaSource>)source;
- (CMSampleBufferRef)renderFrame;
@end
```

### 2.1 WLSceneView (场景视图)

场景的视图表现，管理所有媒体源视图。

```objc
@interface WLSceneView : NSView

@property (nonatomic, weak) WLScene *scene;
@property (nonatomic, strong) NSMutableArray<WLSourceView *> *sourceViews;

- (void)addSourceView:(WLSourceView *)sourceView;
- (void)removeSourceView:(WLSourceView *)sourceView;
- (void)updateLayouts;
@end
```

### 3. WLMediaSource 协议 (媒体源)

抽象所有媒体源，实现此协议即可接入系统。

```objc
@protocol WLMediaSource <NSObject>
- (void)start;
- (void)stop;
- (CMSampleBufferRef)nextVideoFrame;   // 获取下一视频帧
- (CMSampleBufferRef)nextAudioFrame;   // 获取下一音频帧
- (CGSize)intrinsicSize;                // 原始分辨率
- (float)volume;
- (void)setVolume:(float)volume;
- (BOOL)isActive;
@end
```

#### 实现类型

| 类名 | 功能 |
|------|------|
| `WLFFmpegMediaSource` | 文件/流媒体播放 (基于现有 WLMediaSource) |
| `WLCameraMediaSource` | 摄像头捕获 (基于现有 WLVideoManager) |
| `WLScreenMediaSource` | 屏幕捕获 |
| `WLImageMediaSource` | 静态图片 |
| `WLColorMediaSource` | 纯色/背景 |
| `WLTextMediaSource` | 文本/文字叠加 |

### 3.1 WLSourceView (媒体源视图)

每个媒体源对应的视图，负责渲染该源的输出。

```objc
@interface WLSourceView : NSView

@property (nonatomic, weak) id<WLMediaSource> source;
@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) CGFloat cropTop;
@property (nonatomic, assign) CGFloat cropBottom;
@property (nonatomic, assign) CGFloat cropLeft;
@property (nonatomic, assign) CGFloat cropRight;
@property (nonatomic, assign) CGFloat volume;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) NSInteger zIndex;

- (void)renderWithSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end
```

### 4. WLSceneRenderer (视频合成器)

将多个媒体源的帧合成最终输出帧。

```objc
@interface WLSceneRenderer : NSObject
@property (nonatomic, assign) CGSize canvasSize;
@property (nonatomic, strong) NSMutableArray<WLSourceLayout *> *layouts;

- (void)addSource:(id<WLMediaSource>)source withLayout:(WLSourceLayout *)layout;
- (void)removeSource:(id<WLMediaSource>)source;
- (CMSampleBufferRef)render;
@end

@interface WLSourceLayout : NSObject
@property (nonatomic, assign) CGRect frame;        // 位置和大小
@property (nonatomic, assign) CGFloat cropTop;      // 裁剪边
@property (nonatomic, assign) CGFloat cropBottom;
@property (nonatomic, assign) CGFloat cropLeft;
@property (nonatomic, assign) CGFloat cropRight;
@property (nonatomic, assign) CGFloat volume;       // 音量
@property (nonatomic, assign) BOOL visible;         // 可见性
@property (nonatomic, assign) NSInteger zIndex;     // 层级
@end
```

### 5. WLMediaMixer (音频混音器)

混合多个音频源，支持音量控制和淡入淡出。

```objc
@interface WLMediaMixer : NSObject
@property (nonatomic, strong) NSMutableArray<id<WLMediaSource>> *audioSources;

- (void)setVolume:(float)volume forSource:(id<WLMediaSource>)source;
- (float)volumeForSource:(id<WLMediaSource>)source;
- (void)fadeInSource:(id<WLMediaSource>)source duration:(NSTimeInterval)duration;
- (void)fadeOutSource:(id<WLMediaSource>)source duration:(NSTimeInterval)duration;
- (CMSampleBufferRef)mixAudio;
@end
```

### 6. WLTransitionEngine (转场动画)

处理场景切换时的转场效果。

```objc
typedef NS_ENUM(NSInteger, WLTransitionType) {
    WLTransitionTypeNone,    // 切换
    WLTransitionTypeFade,    // 淡入淡出
    WLTransitionTypeSlide,    // 滑动
    WLTransitionTypeCut,      // 硬切
    WLTransitionTypeZoom,     // 缩放
    WLTransitionTypeFadeColor // 带颜色淡入淡出
};

@interface WLTransition : NSObject
@property (nonatomic, assign) WLTransitionType type;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, strong) NSColor *fadeColor;   // 淡入淡出颜色

+ (instancetype)transitionWithType:(WLTransitionType)type duration:(NSTimeInterval)duration;
@end

@interface WLTransitionEngine : NSObject
@property (nonatomic, strong) WLTransition *currentTransition;
@property (nonatomic, assign) float progress;  // 0.0-1.0

- (void)applyTransitionFromScene:(WLScene *)fromScene
                         toScene:(WLScene *)toScene
                      transition:(WLTransition *)transition
                          update:(void (^)(float progress))updateBlock;
- (CMSampleBufferRef)outputFrame;
@end
```

### 7. Output (输出)

最终合成后的输出目标。

```objc
typedef NS_ENUM(NSInteger, WLOutputType) {
    WLOutputTypePreview,   // 本地预览
    WLOutputTypeRecord,    // 录制
    WLOutputTypeStream     // 流媒体推送 (RTMP/HLS)
};

@interface WLOutput : NSObject
@property (nonatomic, assign) WLOutputType type;
@property (nonatomic, strong) WLVideoEncoder *videoEncoder;
@property (nonatomic, strong) WLAudioEncoder *audioEncoder;

- (void)startWithURL:(NSURL *)url;
- (void)stop;
- (void)pushVideoFrame:(CMSampleBufferRef)frame;
- (void)pushAudioFrame:(CMSampleBufferRef)frame;
@end
```

## 数据流

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           逻辑层                                          │
│  ┌─────────────┐     ┌─────────────┐     ┌────────────────────────────┐ │
│  │ MediaSource │────▶│SceneRenderer│────▶│  WLTransitionEngine         │ │
│  │  (视频帧)    │     │  (视频合成)  │     │   (转场动画)                 │ │
│  └─────────────┘     └─────────────┘     └────────────────────────────┘ │
│         │                                        │                       │
│         │ 音频帧                                  │                       │
│         ▼                                        │                       │
│  ┌─────────────┐                                 │                       │
│  │MediaMixer   │─────────────────────────────────┘                       │
│  │  (音频混音)  │                                                         │
│  └─────────────┘                                                         │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                           视图层                                          │
│                                                                          │
│  WLSceneManagerView                                                       │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ ┌──────────────┐  ┌────────────────────────────────────────────┐  │  │
│  │ │backgroundView│  │  contentView (当前 WLSceneView)            │  │  │
│  │ │   (背景)      │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐   │  │  │
│  │ │              │  │  │SourceView│ │SourceView│ │SourceView│   │  │  │
│  │ └──────────────┘  │  │    1     │ │    2     │ │    3     │   │  │  │
│  │                   │  └──────────┘ └──────────┘ └──────────┘   │  │  │
│  │ ┌──────────────┐  │  └────────────────────────────────────────────┘  │  │
│  │ │transitionView│  │                                                │  │
│  │ │   (转场覆盖)  │  └────────────────────────────────────────────────┘  │
│  │ └──────────────┘                                                     │
│  └───────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                           输出层                                          │
│                     Output (Preview / Record / Stream)                   │
└──────────────────────────────────────────────────────────────────────────┘
```

## 颜色说明

| 颜色 | 组件类型 |
|------|----------|
| 🔵 蓝色 | SceneManager |
| 🟢 绿色 | Scene |
| 🟡 黄色 | MediaSource / SourceView |
| 🟣 紫色 | 视频合成器 (WLSceneRenderer) |
| 🔴 红色 | 音频混音器 (WLMediaMixer) |
| 🟠 橙色 | 转场引擎 (WLTransitionEngine) |
| ⚪ 灰色 | 输出 (Output) |

## 与现有代码整合

| 现有组件 | 整合方式 |
|----------|----------|
| `WLMediaSource` | 重构为 `WLFFmpegMediaSource`，实现 `WLMediaSource` 协议 |
| `WLVideoManager` | 包装为 `WLCameraMediaSource`，实现 `WLMediaSource` 协议 |
| `WLNodeQueue` | 复用为媒体源的消息队列 |
| `WLViedoPreview` | 作为 Preview 输出目标 |

## 待实现

- [ ] WLSceneManager 场景管理
- [ ] WLSceneManagerView 视图容器
- [ ] WLScene 场景类
- [ ] WLSceneView 场景视图
- [ ] WLMediaSource 协议及各实现类
- [ ] WLSourceView 媒体源视图
- [ ] WLSceneRenderer 视频合成
- [ ] WLMediaMixer 音频混音
- [ ] WLTransitionEngine 转场动画
- [ ] WLOutput 输出模块
