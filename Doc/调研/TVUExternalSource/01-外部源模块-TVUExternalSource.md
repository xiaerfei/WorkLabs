# TVUExternalSource 模块详细分析

> 基于 tvuanywhere_ios 仓库 `products/TVUTransportIOS/TVUAnywherePro/Transmitter/TVUExternalSource/` 目录

> 📚 **系列文档**（完整索引见 [README.md](./README.md)）
> - 本文：模块结构 / 类关系 / 数据流（架构视角）
> - [02-合流层-TVUAVStream.md](./02-合流层-TVUAVStream.md) — 队列合并 / PIP·PBP 合成 / 编码入口
> - [03-编码层-TVUEncoder.md](./03-编码层-TVUEncoder.md) — VideoToolbox 硬编码 / AAC
> - [04-推流层-Mux与Transport.md](./04-推流层-Mux与Transport.md) — Mux / SEI / 传输库边界
> - [时间戳专题/02-时间戳与时钟漂移调研.md](./时间戳专题/02-时间戳与时钟漂移调研.md) — PTS 链路 / Camera 时钟 / 漂移处理（同步视角）
> - [时间戳专题/03-时间戳设计评价.md](./时间戳专题/03-时间戳设计评价.md) — 亮点 / 脆弱点 / 重构建议（评价视角）

---

## 一、模块概述

TVUExternalSource 是一个完整的**外部视频源处理框架**，负责解析、解码、排序、混音外部媒体源。支持三种源类型：本地视频文件、RTSP 流、组播流（UDP）。整体采用经典的**生产者-消费者**模式，适合实时直播场景的低延迟音视频处理。

---

## 二、整体分层架构图

```mermaid
graph TB
    subgraph UI["UI 层 (View Layer)"]
        View[TVUExternalSourceView<br/>缩略图网格主视图]
        Config[(TVUExternalSourceConfig<br/>单例 · 全局配置)]
        InputView[TVUExternalSourceInputView<br/>IP 地址输入]
        Cell[TVUExternalSourceCollectionViewCell<br/>缩略图单元]
        NewUI[TVUInputModule<br/>新 MVC 框架]
    end

    subgraph Parse["解析层 (Parse Layer)"]
        ParseCore[TVUExternalSourceParse<br/>FFmpeg AVFormat 读取]
    end

    subgraph Queue["队列层 (Queue Layer · 生产者-消费者)"]
        QM[TVUExternalSourceQueueManager<br/>本地文件双队列]
        RTPQM[TVUExternalSourceRTPQueueManager<br/>RTSP/网络流双队列]
        BaseQ[[TVUExternalSourceQueue<br/>Free/Work 双队列基础结构]]
    end

    subgraph Decode["解码层 (Decode Layer)"]
        VDec[TVUExternalSourceVideoDecoder<br/>H264/H265 → CVPixelBuffer]
        ADec[TVUExternalSourceAudioDecoder<br/>AAC/MP3 → PCM + 重采样]
        RTPDec[TVUExternalRTPStreamDecoder<br/>RTP 解封装]
    end

    subgraph Process["处理层 (Process Layer)"]
        Sort[TVUExternalSourceSortQueueManager<br/>按 PTS 排序]
        Mixer[(TVUExternalSourceAudioMixerQueueManager<br/>单例 · 双源混音)]
    end

    subgraph Tool["工具层 (Tool Layer)"]
        ExtCam[TVUExternCameraManager]
        VidProc[TVUExtVideoProcessor]
        AudEnc[TVUExtAudioEncoder]
        IPCfg[TVUExternSourceGetIPConfig]
    end

    subgraph Out["输出 (Output)"]
        Encoder[TVUAVStreamManager<br/>编码 + 推流]
    end

    UI -->|driver| Parse
    Parse -->|本地文件| QM
    Parse -->|RTSP/组播| RTPQM
    QM -.基于.-> BaseQ
    RTPQM -.基于.-> BaseQ
    QM --> VDec
    QM --> ADec
    RTPQM --> RTPDec
    RTPQM --> ADec
    VDec --> Sort
    ADec --> Mixer
    Sort --> Encoder
    Mixer --> Encoder
    View -.持有.-> Config
    NewUI -.复用.-> ParseCore

    classDef singleton fill:#fff3cd,stroke:#856404,stroke-width:2px
    classDef ui fill:#d1ecf1,stroke:#0c5460
    classDef core fill:#f8d7da,stroke:#721c24,stroke-width:2px
    classDef proc fill:#d4edda,stroke:#155724

    class Config,Mixer singleton
    class View,InputView,Cell,NewUI ui
    class ParseCore,QM,RTPQM core
    class Sort,VDec,ADec,RTPDec proc
```

> 图例：黄色为单例，红框为核心驱动节点，蓝色为 UI，绿色为解码/处理。

---

## 三、目录结构

```
TVUExternalSource/
├── TVUExternalSourceParse/          # 核心解析模块（FFmpeg）
│   ├── TVUExternalSourceParse.h
│   └── TVUExternalSourceParse.mm
│
├── TVUExternalSourceDecoder/        # 解码器模块
│   ├── TVUExternalSourceVideoDecoder.h/mm    # 视频解码（H264/H265 → CVPixelBuffer）
│   ├── TVUExternalSourceAudioDecoder.h/mm    # 音频解码 + FFmpeg 重采样
│   └── TVUExternalRTPStreamDecoder.h/mm      # RTP 流解码（用于 RTSP 源）
│
├── TVUExternalSourceQueue/          # 数据队列管理
│   ├── TVUExternalSourceQueue.h/mm              # 基础队列数据结构（Free/Work 双队列）
│   ├── TVUExternalSourceQueueManager.h/mm       # 本地文件队列管理器
│   ├── TVUExternalSourceRTPQueueManager.h/mm    # RTP 网络流队列管理器
│   ├── TVUExternalSourceSortQueueManager.h/mm   # 视频帧排序队列（按 PTS）
│   └── TVUExternalSourceAudioMixerQueueManager.h/mm  # 音频混音队列（单例）
│
├── TVUExternalSourceView/           # UI 视图层
│   ├── TVUExternalSourceView.h/mm               # 主视图容器（缩略图网格 3×2）
│   ├── TVUExternalSourceConfig.h/m              # 配置管理器（单例）
│   ├── TVUExternalSourceInputView.h/mm          # IP 地址输入视图
│   ├── TVUExternalSourceCollectionViewCell.h/mm # 缩略图单元格
│   └── TVUExternalButton.h/m                    # 自定义按钮
│
├── TVUExternSourceTool/             # 工具类
│   ├── TVUExternSourceTool.h/mm                 # 外部源工具方法
│   ├── TVUExternCameraManager.h/mm              # 外部相机管理器
│   ├── TVUExtVideoProcessor.h/mm                # 视频处理器
│   ├── TVUExtAudioEncoder.h/mm                  # 音频编码器
│   └── TVUExternSourceGetIPConfig.h/mm          # IP 配置获取
│
└── TVUInputModule/                  # 输入源选择模块（新 UI 框架）
    ├── Controller/
    │   ├── TVUInputSourceVC.h/m                 # 输入源选择主控制器
    │   └── TVUInputSourceConfig.h/mm            # 输入源配置
    ├── Models/
    │   ├── TVUCameraTypeItem.h/m                # 摄像头类型模型
    │   ├── TVUCameraSelectionItem.h/m           # 摄像头选择模型
    │   ├── TVUClipItem.h/m                      # 视频片段模型
    │   └── TVUClipOperationResult.h/mm          # 操作结果模型
    ├── Views/
    │   ├── TVUCameraTypeCell.h/m                # 摄像头类型单元格
    │   ├── TVUCameraSelectionCell.h/m           # 摄像头选择单元格
    │   └── TVUClipCell.h/m                      # 视频片段单元格
    ├── ParseModule/
    │   ├── TVUInputSourceParseModule.h/mm       # 输入源解析模块
    │   └── TVUImageBufferManager.h/mm           # 图像缓冲管理器
    ├── Gestures/
    │   └── TVUInputGestureCoordinator.h/mm      # 手势协调器
    ├── MediaPicker/
    │   └── TVUMediaPicker.h/mm                  # 媒体选择器
    ├── TVUInputSourceConstants.h                # 常量定义
    └── TVUSourceInputModule.h/mm                # 主模块入口
```

---

## 四、核心类详解

### 4.1 TVUExternalSourceParse — 数据解析核心

**职责：** 使用 FFmpeg 库解析外部源文件（本地视频、RTSP 流、组播 URL）。是整个模块的入口和数据源头。

**关键枚举定义：**

```objc
// 数据源类型
typedef enum : NSUInteger {
    TVUExternalSourceLocalFile = 0,      // 本地文件
    TVUExternalSourceMuticastUrl,        // 组播 URL（UDP）
    TVUExternalSourceRTSP,               // RTSP 流
} TVUExternalSourceType;

// 错误类型
typedef enum : NSUInteger {
    TVUExternalSourceErrorNone = 0,
    TVUExternalSourceErrorOpenFile,
    TVUExternalSourceErrorVideoStreamNotFound,
    TVUExternalSourceErrorAudioStreamNotFound,
    TVUExternalSourceErrorCodecNotFound,
    TVUExternalSourceErrorOpenCodec,
    TVUExternalSourceErrorUnsupportVideoEncodingFormat,
    TVUExternalSourceErrorUnsupportVideoResolution,
    TVUExternalSourceErrorUnsupportVideoFPS,
    TVUExternalSourceErrorUnsupportAudioEncodingFormat,
    // ...
} TVUExternalSourceError;
```

**关键方法：**

```objc
// 预检查：验证文件是否支持（分辨率、FPS、编码格式）
- (TVUExternalSourceError)preParseWithPath:(NSString *)path;

// 开始解析：启动 FFmpeg 读取线程和队列管理器
- (TVUExternalSourceError)startParseWithPath:(NSString *)path
                                    andIndex:(int)external_source_index;

// 获取第一帧作为缩略图
- (TVUExternalSourceError)startParseWithPathTakePic:(NSString *)path;

// 获取源信息（分辨率、FPS、编码格式等）
- (NSDictionary *)getSourceInfo;

// 停止解析
- (void)stopParse;
```

**内部工作流程：**
1. `preParseWithPath:` — 打开 AVFormatContext，查找视频/音频流，验证参数
2. `startParseWithPath:andIndex:` — 创建 QueueManager，启动 GCD 线程逐帧读取 AVPacket
3. 读取到的 AVPacket 封装为 `TVUExternalSourceDecodeParam`，入队到 QueueManager
4. `stopParse` — 停止线程，释放 FFmpeg 资源

---

**Parse 内部状态机：**

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> PreParsing : preParseWithPath
    PreParsing --> Validated : 分辨率/FPS/编码合法
    PreParsing --> Error : 不支持的格式
    Validated --> Parsing : startParseWithPath andIndex
    Parsing --> Parsing : 读取 AVPacket 入队
    Parsing --> EndOfFile : 文件末尾
    EndOfFile --> Parsing : Infinite 循环
    EndOfFile --> Stopped : OneTime 终止
    Parsing --> Stopped : stopParse
    Stopped --> [*]
    Error --> [*]
```

---

### 4.2 TVUExternalSourceQueue — 基础队列数据结构

**职责：** 定义解码数据的队列节点和队列容器，线程安全的 Free/Work 双队列。

**核心数据结构：**

```cpp
// 解码参数（队列节点数据）
struct TVUExternalSourceDecodeParam {
    uint8_t *data;               // 视频/音频裸数据
    int dataSize;
    uint8_t *extraData;          // H264/H265 的 VPS/SPS/PPS
    int extraDataSize;
    int channel;                 // 音频通道数
    int sampleRate;              // 音频采样率
    CMSampleTimingInfo timingInfo;
    Float64 pts;                 // 显示时间戳
    Float64 time_base;           // 时间基
    TVUExternalSourceVideoRotate videoRotate;     // 视频旋转角度
    TVUExternalSourceVideoCodingFormat codingFormat; // H264/H265
    int fps;
    int external_source_index;
    int current_frame_index;
    BOOL isHDR;
};
```

**队列操作模式：**
- **Free Queue**：空闲节点池，预分配内存
- **Work Queue**：待处理数据队列
- 生产者从 Free Queue 取节点 → 填充数据 → 入队 Work Queue
- 消费者从 Work Queue 取节点 → 解码处理 → 归还 Free Queue
- 使用 `pthread_mutex_t` + `pthread_cond_t` 保证线程安全

---

**Free/Work 双队列流转：**

```mermaid
flowchart LR
    subgraph Producer["生产者 (Parse 线程)"]
        P1[读取 AVPacket]
    end
    subgraph FreeQ["Free Queue<br/>(空闲节点池)"]
        F1[Node1]
        F2[Node2]
        F3[Node...]
    end
    subgraph WorkQ["Work Queue<br/>(待处理数据)"]
        W1[Filled]
        W2[Filled]
    end
    subgraph Consumer["消费者 (解码线程)"]
        C1[解码处理]
    end

    P1 -->|1.dequeue| FreeQ
    FreeQ -->|2.取出空节点| P1
    P1 -->|3.填充数据后enqueue| WorkQ
    WorkQ -->|4.dequeue| C1
    C1 -->|5.处理完归还| FreeQ

    style Producer fill:#fff3cd
    style Consumer fill:#d4edda
    style FreeQ fill:#e2e3e5
    style WorkQ fill:#f8d7da
```

> 使用 `pthread_mutex_t` + `pthread_cond_t`：队列满时生产者阻塞，队列空时消费者阻塞。

---

### 4.3 TVUExternalSourceQueueManager — 本地文件队列管理器

**职责：** 管理本地文件的视频+音频双队列，创建并管理解码线程池。

```cpp
class TVUExternalSourceQueueManager {
    TVUExternalSourceQueue *sourceQueue[2];       // [0]=视频队列 [1]=音频队列
    TVUExternalSourceVideoDecoder *videoDecoder;
    TVUExternalSourceAudioDecoder *audioDecoder;

    void startThread();          // 启动视频+音频解码线程
    void endThread();            // 停止解码线程
    void addDataToDecoder();     // 从 Work Queue 取数据送入解码器
    int freeQueueLength();       // 获取空闲队列长度（用于流控）
};
```

---

### 4.4 TVUExternalSourceRTPQueueManager — 网络流队列管理器

**职责：** 处理 RTSP/RTP 流的队列管理，与 QueueManager 结构类似，但使用 `TVUExternalRTPStreamDecoder` 处理 RTP 数据。支持线程挂起和恢复。

---

### 4.5 TVUExternalSourceVideoDecoder — 视频解码器

**职责：** 将 H264/H265 裸数据解码为 CVPixelBufferRef（YUV 格式），送入排序队列。

```objc
@property (nonatomic) TVUExternalSourceSortQueueManager *sortQueueManager;

- (void)decode:(TVUExternalSourceDecodeParam *)param;
```

**解码流程：**
```
AVPacket → avcodec_send_packet() → avcodec_receive_frame()
    → AVFrame (YUV) → CVPixelBufferRef
    → 添加到 SortQueueManager（按 PTS 排序）
```

---

### 4.6 TVUExternalSourceAudioDecoder — 音频解码器

**职责：** 解码音频数据，使用 FFmpeg 进行音频重采样（转换采样率、通道数）。

**解码流程：**
```
AVPacket → avcodec_send_packet() → avcodec_receive_frame()
    → AVFrame (PCM) → TVUFFmpegResample（重采样）
    → 输出到 AudioMixerQueueManager
```

---

### 4.7 TVUExternalSourceSortQueueManager — 视频帧排序队列

**职责：** 按 PTS（Presentation TimeStamp）对视频帧排序，确保乱序到达的帧按正确时序输出。

```cpp
void addData(CMSampleBufferRef samplebuffer, Float64 pts,
             int fps, int external_source_index, int current_frame_index);
int length();  // 返回当前队列中帧数
```

**工作原理：**
- 维护 Work Queue（待排序帧）和 Free Queue（空闲节点）
- 视频解码后帧可能乱序（B 帧），排序队列确保按 PTS 顺序输出
- 排序完成后输出给编码器

---

### 4.8 TVUExternalSourceAudioMixerQueueManager — 音频混音管理器

**职责：** 单例模式，将外部源音频与本地摄像头音频进行混音。

```cpp
class TVUExternalSourceAudioMixerQueueManager {
    TVUExternalSourceAudioMixerQueue *sourceQueue[2];  // [0]=本地摄像头 [1]=外部源

    void addDataToAudioMixer(TVUAudioEncoderData *param, ...);
    void audioMixer();  // 执行混音操作
};
```

**混音流程：**
```
外部源音频（解码+重采样后） + 本地摄像头音频
    → audioMixer() 混音处理
    → 输出混合后的音频给编码器
```

---

**音频双源混音示意：**

```mermaid
flowchart LR
    LocalMic[本地摄像头麦克风] --> Q0[sourceQueue 0<br/>本地音频队列]
    ExtSrc[外部源音频<br/>重采样后] --> Q1[sourceQueue 1<br/>外部音频队列]
    Q0 --> Mix{audioMixer 混音}
    Q1 --> Mix
    Mix --> Out[混合后 PCM]
    Out --> AAC[AAC 编码器]

    style Mix fill:#ffe5b4,stroke:#d97706,stroke-width:2px
```

---

## 五、UI 层类详解

### 5.1 TVUExternalSourceView — 主视图

**职责：** 显示外部源的缩略图网格（3 列 2 行），管理源的选择、删除、切换，处理 PIP/PBP 多屏模式。

**关键委托方法：**

```objc
@protocol TVUExternalSourceViewDelegate
- (void)externalSourceViewOpenAlbumForVideo;       // 打开相册选视频
- (void)externalSourceViewParseBegin;              // 解析开始
- (void)externalSourceViewParseComplete;           // 解析完成
- (void)externalSourceViewSwitchToExteranalCameraWithWidth:(int)width
                                                    height:(int)height
                                                    andFps:(int)fps;
- (void)pipStateChanged:(BOOL)state;               // PIP 状态变化
@end
```

### 5.2 TVUExternalSourceConfig — 配置管理器（单例）

```objc
@property (nonatomic, assign) TVUExternalSourceType sourceType;
@property (nonatomic, assign) TVUExternalSourceAudioResampleType audioResampleType;  // AudioToolbox / FFmpeg
@property (nonatomic, assign) TVUExternalSourceCirculationType circulationType;      // One Time / Infinite
@property (nonatomic, assign, readonly) TVUExtCameraRoateDegree roateDegree;        // 旋转角度
@property (nonatomic, assign, readonly) BOOL flipsVideo;                            // 是否翻转
```

### 5.3 TVUExternalSourceCollectionViewCell — 缩略图单元格

显示外部源的缩略图，附带视频时长、FPS 信息，提供删除、镜像等操作按钮。

### 5.4 TVUExternalSourceInputView — IP 地址输入

用于输入 RTSP/组播地址的文本输入视图。

---

**UI 层组件组合关系：**

```mermaid
graph TB
    View[TVUExternalSourceView<br/>主容器] --> CV[UICollectionView<br/>3×2 网格]
    CV --> Cell1[Cell #1]
    CV --> Cell2[Cell #2]
    CV --> CellN[Cell ...]
    View --> InputView[TVUExternalSourceInputView<br/>IP 输入]
    View -.读取.-> Config[(TVUExternalSourceConfig<br/>单例)]
    View -.持有.-> Parse[TVUExternalSourceParse]
    View ==委托==> Delegate{{TVUExternalSourceViewDelegate}}
    Delegate -.回调.-> Host[宿主 ViewController]

    classDef sg fill:#fff3cd,stroke:#856404,stroke-width:2px
    class Config sg
```

---

## 六、TVUInputModule — 新 UI 框架

这是对外部源选择 UI 的现代化重构，采用清晰的 MVC 架构：

| 类 | 职责 |
|---|---|
| **TVUSourceInputModule** | 主模块入口，协调各子模块 |
| **TVUInputSourceVC** | 输入源选择视图控制器 |
| **TVUInputSourceConfig** | 输入源配置 |
| **TVUInputSourceParseModule** | 封装 TVUExternalSourceParse 的解析逻辑 |
| **TVUImageBufferManager** | 图像缓冲管理器 |
| **TVUMediaPicker** | 媒体选择器（相册/文件） |
| **TVUInputGestureCoordinator** | 手势协调器 |
| **TVUCameraTypeItem** | 摄像头类型数据模型 |
| **TVUCameraSelectionItem** | 摄像头选择数据模型 |
| **TVUClipItem** | 视频片段数据模型 |
| **TVUClipOperationResult** | 操作结果模型 |

**TVUInputModule MVC 分层关系：**

```mermaid
graph TB
    subgraph Entry["入口"]
        SIM[TVUSourceInputModule<br/>主模块入口]
    end

    subgraph Controller["Controller"]
        VC[TVUInputSourceVC]
        Cfg[TVUInputSourceConfig]
        Gesture[TVUInputGestureCoordinator]
    end

    subgraph Model["Model"]
        CamType[TVUCameraTypeItem]
        CamSel[TVUCameraSelectionItem]
        Clip[TVUClipItem]
        OpRes[TVUClipOperationResult]
    end

    subgraph View["View"]
        CamTypeCell[TVUCameraTypeCell]
        CamSelCell[TVUCameraSelectionCell]
        ClipCell[TVUClipCell]
    end

    subgraph Service["Service / Parse"]
        ParseMod[TVUInputSourceParseModule]
        ImgBuf[TVUImageBufferManager]
        Picker[TVUMediaPicker]
        OldParse[TVUExternalSourceParse<br/>复用旧核心]
    end

    SIM --> VC
    SIM --> Cfg
    SIM --> Gesture
    VC --> CamTypeCell
    VC --> CamSelCell
    VC --> ClipCell
    CamTypeCell -.绑定.-> CamType
    CamSelCell -.绑定.-> CamSel
    ClipCell -.绑定.-> Clip
    VC --> ParseMod
    VC --> Picker
    ParseMod --> ImgBuf
    ParseMod -->|封装| OldParse

    classDef ctrl fill:#d1ecf1,stroke:#0c5460
    classDef model fill:#d4edda,stroke:#155724
    classDef view fill:#fff3cd,stroke:#856404
    classDef svc fill:#f8d7da,stroke:#721c24

    class VC,Cfg,Gesture ctrl
    class CamType,CamSel,Clip,OpRes model
    class CamTypeCell,CamSelCell,ClipCell view
    class ParseMod,ImgBuf,Picker,OldParse svc
```

---

## 七、工具类详解

| 类 | 职责 |
|---|---|
| **TVUExternSourceTool** | 通用工具方法（格式转换、文件路径处理等） |
| **TVUExternCameraManager** | 外部相机（如 USB 摄像头）的连接和管理 |
| **TVUExtVideoProcessor** | 视频数据后处理（裁剪、缩放、格式转换） |
| **TVUExtAudioEncoder** | 外部源音频编码（PCM → AAC） |
| **TVUExternSourceGetIPConfig** | 获取设备网络 IP 配置信息 |

---

## 八、完整数据流图

```mermaid
flowchart TB
    User([👤 用户选择外部源<br/>本地文件 / RTSP / 组播 URL])
    UIView[TVUExternalSourceView<br/>缩略图网格 · 选择/删除/切换]

    subgraph ParseLayer["🔍 解析层"]
        Pre[1.preParseWithPath:<br/>打开 AVFormatContext<br/>校验 分辨率≤4K · FPS 15~60 · 编码]
        Start[2.startParseWithPath:andIndex:<br/>创建 QueueManager<br/>启动 GCD 线程读 AVPacket]
        Pre --> Start
    end

    subgraph QueueLayer["📦 队列层（按源类型分支）"]
        QM[TVUExternalSourceQueueManager<br/>本地文件<br/>sourceQueue 0=Video<br/>sourceQueue 1=Audio]
        RTPQM[TVUExternalSourceRTPQueueManager<br/>RTSP/网络流<br/>RTP 解封装]
    end

    Pkt[/AVPacket → TVUExternalSourceDecodeParam<br/>enQueue WorkQueue/]

    subgraph VideoPath["🎬 视频解码链路 (pthread)"]
        VDec[TVUExternalSourceVideoDecoder]
        VStep1[avcodec_send_packet]
        VStep2[avcodec_receive_frame → AVFrame YUV]
        VStep3[转 CVPixelBufferRef]
        VSort[TVUExternalSourceSortQueueManager<br/>按 PTS 排序 · 处理 B 帧]
        VDec --> VStep1 --> VStep2 --> VStep3 --> VSort
    end

    subgraph AudioPath["🔊 音频解码链路 (pthread)"]
        ADec[TVUExternalSourceAudioDecoder]
        AStep1[avcodec_send_packet]
        AStep2[avcodec_receive_frame → AVFrame PCM]
        AStep3[TVUFFmpegResample<br/>采样率/通道数转换]
        AMix[(TVUExternalSourceAudioMixerQueueManager<br/>单例 · 与本地麦混音)]
        ADec --> AStep1 --> AStep2 --> AStep3 --> AMix
    end

    LocalMic[本地摄像头音频]
    Encoder[TVUAVStreamManager / TVUAudioEncoderManager<br/>H264/AAC 编码 → 推流]

    User --> UIView --> ParseLayer
    Start --> QM
    Start --> RTPQM
    QM --> Pkt
    RTPQM --> Pkt
    Pkt --> VDec
    Pkt --> ADec
    LocalMic -.-> AMix
    VSort --> Encoder
    AMix --> Encoder

    classDef user fill:#e7f5ff,stroke:#0c5460
    classDef parse fill:#fff3cd,stroke:#856404
    classDef queue fill:#f8d7da,stroke:#721c24
    classDef video fill:#d4edda,stroke:#155724
    classDef audio fill:#d1ecf1,stroke:#0c5460
    classDef out fill:#e2e3e5,stroke:#383d41,stroke-width:2px

    class User user
    class UIView,Pre,Start parse
    class QM,RTPQM,Pkt queue
    class VDec,VStep1,VStep2,VStep3,VSort video
    class ADec,AStep1,AStep2,AStep3,AMix,LocalMic audio
    class Encoder out
```

---

## 九、类关系图（Class Diagram）

```mermaid
classDiagram
    class TVUExternalSourceParse {
        -AVFormatContext* formatCtx
        -TVUExternalSourceQueueManager* queueManager
        -TVUExternalSourceRTPQueueManager* rtpQueueManager
        +preParseWithPath(path) TVUExternalSourceError
        +startParseWithPath(path, index) TVUExternalSourceError
        +startParseWithPathTakePic(path) TVUExternalSourceError
        +getSourceInfo() NSDictionary
        +stopParse() void
    }

    class TVUExternalSourceQueueManager {
        -TVUExternalSourceQueue sourceQueue[2]
        -TVUExternalSourceVideoDecoder* videoDecoder
        -TVUExternalSourceAudioDecoder* audioDecoder
        +startThread() void
        +endThread() void
        +addDataToDecoder() void
        +freeQueueLength() int
    }

    class TVUExternalSourceRTPQueueManager {
        -TVUExternalSourceRTPQueue sourceQueue[2]
        -TVUExternalRTPStreamDecoder* rtpDecoder
        -TVUExternalSourceAudioDecoder* audioDecoder
        +startThread() void
        +suspendThread() void
        +resumeThread() void
    }

    class TVUExternalSourceQueue {
        -pthread_mutex_t mutex
        -pthread_cond_t cond
        -Node* freeQueue
        -Node* workQueue
        +enqueue(data) void
        +dequeue() Node*
    }

    class TVUExternalSourceVideoDecoder {
        -AVCodecContext* codecCtx
        -TVUExternalSourceSortQueueManager* sortQueueManager
        +decode(param) void
    }

    class TVUExternalSourceAudioDecoder {
        -AVCodecContext* codecCtx
        -TVUFFmpegResample* resampler
        +decode(param) void
    }

    class TVUExternalRTPStreamDecoder {
        +decodeRTPPacket(data) void
    }

    class TVUExternalSourceSortQueueManager {
        -SortQueue* sortQueue
        +addData(buffer, pts, fps, index, frameIdx) void
        +length() int
    }

    class TVUExternalSourceAudioMixerQueueManager {
        <<Singleton>>
        -TVUExternalSourceAudioMixerQueue sourceQueue[2]
        +sharedInstance()$ TVUExternalSourceAudioMixerQueueManager*
        +addDataToAudioMixer(param) void
        +audioMixer() void
    }

    class TVUExternalSourceView {
        -TVUExternalSourceParse* parse
        -UICollectionView* collectionView
        -TVUExternalSourceInputView* inputView
        -TVUExternalSourceViewDelegate delegate
        +reloadSources() void
    }

    class TVUExternalSourceConfig {
        <<Singleton>>
        +sourceType: TVUExternalSourceType
        +audioResampleType: TVUExternalSourceAudioResampleType
        +circulationType: TVUExternalSourceCirculationType
        +roateDegree: TVUExtCameraRoateDegree
        +flipsVideo: BOOL
        +sharedConfig()$ TVUExternalSourceConfig*
    }

    class TVUExternalSourceCollectionViewCell
    class TVUExternalSourceInputView
    class TVUSourceInputModule
    class TVUInputSourceVC
    class TVUInputSourceParseModule
    class TVUImageBufferManager

    TVUExternalSourceParse *-- TVUExternalSourceQueueManager : 组合
    TVUExternalSourceParse *-- TVUExternalSourceRTPQueueManager : 组合
    TVUExternalSourceQueueManager *-- "2" TVUExternalSourceQueue
    TVUExternalSourceQueueManager *-- TVUExternalSourceVideoDecoder
    TVUExternalSourceQueueManager *-- TVUExternalSourceAudioDecoder
    TVUExternalSourceRTPQueueManager *-- TVUExternalRTPStreamDecoder
    TVUExternalSourceRTPQueueManager *-- TVUExternalSourceAudioDecoder
    TVUExternalSourceVideoDecoder *-- TVUExternalSourceSortQueueManager
    TVUExternalSourceAudioDecoder ..> TVUExternalSourceAudioMixerQueueManager : 输出
    TVUExternalSourceView *-- TVUExternalSourceParse
    TVUExternalSourceView ..> TVUExternalSourceConfig : 读取
    TVUExternalSourceView *-- TVUExternalSourceCollectionViewCell : 容器
    TVUExternalSourceView *-- TVUExternalSourceInputView
    TVUSourceInputModule *-- TVUInputSourceVC
    TVUInputSourceVC *-- TVUInputSourceParseModule
    TVUInputSourceParseModule ..> TVUExternalSourceParse : 封装/复用
    TVUInputSourceParseModule *-- TVUImageBufferManager
```

---

## 十、模块协作时序图

下面展示用户从选择源到推流的端到端时序：

```mermaid
sequenceDiagram
    autonumber
    participant U as 用户
    participant V as TVUExternalSourceView
    participant P as TVUExternalSourceParse
    participant QM as QueueManager
    participant VD as VideoDecoder
    participant AD as AudioDecoder
    participant SQ as SortQueueMgr
    participant AM as AudioMixerMgr (单例)
    participant E as 编码/推流

    U->>V: 选择本地视频/输入 RTSP
    V->>P: preParseWithPath:
    P-->>V: 校验通过 (返回 ErrorNone)
    V->>P: startParseWithPath:andIndex:
    P->>QM: 创建并初始化 QueueManager
    QM->>VD: 启动视频解码 pthread
    QM->>AD: 启动音频解码 pthread

    loop FFmpeg 读取循环
        P->>P: av_read_frame() 得到 AVPacket
        alt 视频包
            P->>QM: enqueue 视频 WorkQueue
            QM->>VD: 取出 → decode
            VD->>VD: H264/H265 → CVPixelBuffer
            VD->>SQ: addData(buffer, pts)
            SQ->>E: 按 PTS 顺序输出
        else 音频包
            P->>QM: enqueue 音频 WorkQueue
            QM->>AD: 取出 → decode + 重采样
            AD->>AM: addDataToAudioMixer
            AM->>AM: 与本地麦混音
            AM->>E: 输出混合 PCM
        end
    end

    U->>V: 切走/删除源
    V->>P: stopParse
    P->>QM: endThread
    QM->>VD: pthread_join
    QM->>AD: pthread_join
```

---

## 十一、线程模型

| 线程 | 类型 | 职责 |
|---|---|---|
| **Parse Queue** | dispatch_queue_t (GCD) | AVPacket 读取，逐帧从媒体文件/流中提取数据 |
| **Video Decode Thread** | pthread | 从视频 Work Queue 取数据，调用 VideoDecoder 解码 |
| **Audio Decode Thread** | pthread | 从音频 Work Queue 取数据，调用 AudioDecoder 解码 |
| **Audio Mixer Thread** | pthread (单例) | 混合外部源音频和本地摄像头音频 |
| **Sort Thread** | pthread | 按 PTS 对视频帧排序，保证输出时序正确 |

**线程同步机制：**
- `pthread_mutex_t` — 队列访问互斥锁
- `pthread_cond_t` — 条件变量，用于线程等待/通知（队列空/满时阻塞）
- `dispatch_queue_t` — GCD 分派队列，用于高层操作

**线程间数据流动：**

```mermaid
flowchart LR
    subgraph T1["📥 Parse Queue (GCD)"]
        ReadPkt[av_read_frame<br/>读取 AVPacket]
    end

    subgraph T2["🎬 Video Decode Thread (pthread)"]
        VTake[dequeue Video WorkQueue]
        VDoDec[VideoDecoder.decode]
    end

    subgraph T3["🔊 Audio Decode Thread (pthread)"]
        ATake[dequeue Audio WorkQueue]
        ADoDec[AudioDecoder.decode + 重采样]
    end

    subgraph T4["🔀 Sort Thread (pthread)"]
        SortIn[按 PTS 排序<br/>处理 B 帧乱序]
    end

    subgraph T5["🎚️ Audio Mixer Thread (pthread, 单例)"]
        MixIn[audioMixer 混音<br/>外部源 + 本地麦]
    end

    ReadPkt -->|mutex+cond| VTake
    ReadPkt -->|mutex+cond| ATake
    VTake --> VDoDec --> SortIn
    ATake --> ADoDec --> MixIn

    classDef gcd fill:#fff3cd,stroke:#856404
    classDef pth fill:#d4edda,stroke:#155724
    classDef sg fill:#f8d7da,stroke:#721c24,stroke-width:2px

    class T1 gcd
    class T2,T3,T4 pth
    class T5 sg
```

> 关键约束：所有跨线程入队/出队都通过 `pthread_mutex_t + pthread_cond_t` 保护；当 Work Queue 空时消费线程在 `cond_wait` 阻塞，生产者填充后 `cond_signal` 唤醒。

---

## 十二、支持的格式与限制

| 项目 | 支持范围 |
|---|---|
| **视频编码** | H264、H265 (HEVC) |
| **最大分辨率** | 3840×2160 (4K) |
| **FPS 范围** | 15 ~ 60 |
| **音频格式** | AAC、MP3、PCM |
| **源类型** | 本地文件、组播 URL (UDP)、RTSP (TCP/UDP) |

**特殊功能：**
- **循环播放** — 本地文件支持 One Time / Infinite 两种模式
- **旋转补偿** — 自动处理视频旋转元数据（0°/90°/180°/270°）
- **音频混音** — 支持与本地摄像头音频实时混音
- **缩略图提取** — 获取源的第一帧作为预览缩略图
- **HDR 支持** — 检测并标记 HDR 内容

---

## 十三、总结

TVUExternalSource 模块是一个设计良好的外部视频源处理框架，核心架构分为五层：

1. **解析层** (TVUExternalSourceParse) — 使用 FFmpeg 解析多种源格式，是数据的源头
2. **队列层** (QueueManagers) — 线程安全的 Free/Work 双队列，生产者-消费者模式
3. **解码层** (VideoDecoder / AudioDecoder) — 视频硬软解码 + 音频解码重采样
4. **处理层** (SortQueueManager / AudioMixerQueueManager) — 视频帧排序 + 音频混音
5. **UI 层** (View / Config / InputModule) — 用户交互界面和配置管理

整体设计清晰，多线程并发处理确保实时直播场景下的音视频同步和低延迟输出。新增的 TVUInputModule 子模块对 UI 层进行了现代化重构，采用更清晰的 MVC 架构。

**五层架构精简图：**

```mermaid
graph LR
    L5[🖼️ UI 层<br/>View / Config / InputModule] --> L1
    L1[🔍 解析层<br/>TVUExternalSourceParse] --> L2
    L2[📦 队列层<br/>QueueManager / RTPQueueManager] --> L3
    L3[🎞️ 解码层<br/>VideoDecoder / AudioDecoder] --> L4
    L4[⚙️ 处理层<br/>SortQueueMgr / AudioMixerMgr] --> Out[📡 编码推流]

    classDef ui fill:#d1ecf1,stroke:#0c5460,stroke-width:2px
    classDef parse fill:#fff3cd,stroke:#856404,stroke-width:2px
    classDef queue fill:#f8d7da,stroke:#721c24,stroke-width:2px
    classDef dec fill:#d4edda,stroke:#155724,stroke-width:2px
    classDef proc fill:#e2d4f0,stroke:#5a3d8f,stroke-width:2px
    classDef out fill:#e2e3e5,stroke:#383d41,stroke-width:2px

    class L5 ui
    class L1 parse
    class L2 queue
    class L3 dec
    class L4 proc
    class Out out
```

---

## 附：所有 mermaid 图清单

| # | 图名 | 类型 | 位置 |
|---|---|---|---|
| 1 | 整体分层架构 | graph TB | §二 |
| 2 | Parse 状态机 | stateDiagram | §4.1 |
| 3 | Free/Work 双队列流转 | flowchart LR | §4.2 |
| 4 | 音频双源混音 | flowchart LR | §4.8 |
| 5 | UI 层组件组合 | graph TB | §5 末 |
| 6 | TVUInputModule MVC | graph TB | §六 |
| 7 | 完整数据流 | flowchart TB | §八 |
| 8 | 类关系（classDiagram） | classDiagram | §九 |
| 9 | 模块协作时序 | sequenceDiagram | §十 |
| 10 | 线程间数据流动 | flowchart LR | §十一 |
| 11 | 五层架构精简图 | graph LR | §十三 |

---

## 附：关联文档

| 文档 | 视角 | 核心内容 |
|---|---|---|
| **本文** `01-外部源模块-TVUExternalSource.md` | 架构 / 静态结构 | 模块分层、目录、类关系、数据流图、线程模型 |
| [时间戳专题/02-时间戳与时钟漂移调研.md](./时间戳专题/02-时间戳与时钟漂移调研.md) | 时间戳 / 同步 | SortQueueManager 时间戳、PTS 链路、Camera 时钟、`g_vstarttime`、NTP 补偿、漂移处理评估 |
| [时间戳专题/03-时间戳设计评价.md](./时间戳专题/03-时间戳设计评价.md) | 评价 / 重构决策 | 设计亮点、脆弱点、重构建议、Review 提问清单 |

**两份文档的承接关系：**

```mermaid
flowchart LR
    A[模块分析.md<br/>知道每个类做什么、怎么组合] --> B[时间戳调研.md<br/>知道每个类怎么处理时间戳、<br/>如何与 Camera 同步、有没有漂移补偿]
    B --> C[设计评价.md<br/>评价这套设计的优缺点、<br/>是否需要重构、改哪里]
    C -.反过来印证.-> A

    classDef arch fill:#d1ecf1,stroke:#0c5460,stroke-width:2px
    classDef sync fill:#fff3cd,stroke:#856404,stroke-width:2px
    classDef eval fill:#f8d7da,stroke:#721c24,stroke-width:2px
    class A arch
    class B sync
    class C eval
```

> 建议阅读顺序：先看模块分析建立**静态模型** → 再读时间戳调研理解**动态时序与同步策略** → 最后看评价文档辅助**重构决策**。
