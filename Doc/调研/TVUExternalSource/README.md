# TVUAnywhere iOS 直播管线调研 — 文档索引

> 调研对象：tvuanywhere_ios 仓库（行号基线：`share/DefaultTitle` 分支 commit `89e4c235a`，2026-06-12；01 文档及时间戳专题成文更早，行号可能有少量漂移）
>
> 范围：从外部源解析 → 合流合成 → 硬件编码 → Mux/推流的完整非 UI 链路，外加时间戳/时钟同步专题。
>
> **例外**：07 文档与流图集是后补的，基线更新（分别为 `736863f1f` / `bc4021368`），与 01–06 冲突时以它们为准。

---

## 全链路一图流

```mermaid
flowchart LR
    subgraph M0["05 多源采集"]
        Cam[Camera/双摄] 
        SR[屏录/图片/USB/DJI]
    end
    subgraph M1["01 外部源模块"]
        P[Parse<br/>FFmpeg 解析] --> D[Decode<br/>软/硬解] --> S[Sort/Mix<br/>排序·混音]
    end
    subgraph M2["02 合流层 TVUAVStream"]
        Q[8 路队列] --> H[合成<br/>PIP/PBP/水印] --> G[PTS 守门]
    end
    subgraph M3["03 编码层 TVUEncoder"]
        V[H264/H265<br/>VTCompressionSession]
        A["AAC — 见 07<br/>AudioConverter"]
    end
    subgraph M4["04 推流层"]
        X[AVFormatControl<br/>ASF mux] --> T[CTVUTransporterT<br/>callback_data_in]
        Y[TVULiveMediaCenter<br/>libtvulive2] --> Z[SendMsg_SendFrameData]
    end
    SR --> M1
    M0 --> M2
    M1 --> M2 --> M3 --> M4 --> NET((网络))
    Cam -.纯相机直通.-> M3
    M3 -.录制旁路.-> REC[(06 .asf→MP4)]

    classDef m fill:#d1ecf1,stroke:#0c5460
    class M0,M1,M2,M3,M4 m
```

---

## 文档清单（按管线模块）

| # | 文档 | 内容 | 核心代码目录 |
|---|---|---|---|
| 01 | [01-外部源模块-TVUExternalSource.md](./01-外部源模块-TVUExternalSource.md) | 解析/解码/队列/排序/混音 五层架构、类关系、线程模型 | `Transmitter/TVUExternalSource/` |
| 02 | [02-合流层-TVUAVStream.md](./02-合流层-TVUAVStream.md) | 8 路队列、4 线程、PIP/PBP 合成、过渡帧（已禁用）、PTS 守门、isNeedKeyFrame、编码入口 | `TVUAnywhereSDK/TVUAVStream/` |
| 03 | [03-编码层-TVUEncoder.md](./03-编码层-TVUEncoder.md) | VTCompressionSession 全参数（GOP=600 秒真相）、dts 计算与兜底、SPS/PPS、HDR、AAC、切源低码率重启 | `TVUAnywhereSDK/TVUEncoder/` |
| 04 | [04-推流层-Mux与Transport.md](./04-推流层-Mux与Transport.md) | 双链路（ASF/FFmpeg vs libtvulive2）、SEI、NTP 门槛、码率反馈闭环、传输库边界 | `TVUAnywhereSDK/TVUFormat/`、`TVUSEI/`、`transoprtlib/` |
| 05 | [05-多源采集入队.md](./05-多源采集入队.md) | 输入端补全：相机/双摄/屏录/图片/USB/DJI 各源采集→入队、源索引语义、入队丢错位帧 | `TVUScreenRecording/`、`TVUExternSourceLocalPicture/`、`Accsoon/`、`TVUAnywhere.mm` |
| 06 | [06-本地录制旁路.md](./06-本地录制旁路.md) | 两条录制路径、ASF mux、文件分段/容错、ASF→MP4 转换、录制vs直播来源对照 | `TVUAnywhereSDK/TVURecorder/` |
| 07 | [07-音频编码器-TVUAudioEncoderManager.md](./07-音频编码器-TVUAudioEncoderManager.md) | AAC 编码器专题（基线 `736863f1f`）：8 个生产者、10 道闸门、index 守门、二次混音、4 路出口、并发模型、10 条风险 | `TVUAnywhereSDK/TVUEncoder/TVUAudioEncoderManager.mm` |

### 音频专题（07 的上游，2026-08-25）

| 文档 | 内容 |
|---|---|
| [音频专题/A0-音频链路总表.md](./音频专题/A0-音频链路总表.md) | 交叉接线：谁往哪个队列塞、哪些是死代码、五套混音器怎么串 |
| [A1-本地麦克风采集.md](./音频专题/A1-本地麦克风采集.md) | 两套采集实现、9 道闸门、增益静音、PCM 分包 |
| [A2-屏幕录制音频.md](./音频专题/A2-屏幕录制音频.md) | 扩展进程封包、三路队列、25ms 对齐、mixType 真值表 |
| [A3-会议音频与播放侧.md](./音频专题/A3-会议音频与播放侧.md) | Agora/WebRTC/RTIL 上下行、AudioPlayer 六职责、开关真值链 |
| [A4-朗读与Overlay音频.md](./音频专题/A4-朗读与Overlay音频.md) | Web Audio 抓取、TTS 合成与喂流、三路混音器 |
| [A5-DJI与Accsoon音频.md](./音频专题/A5-DJI与Accsoon音频.md) | DJI 块长公式、PTS 重锚与 clamp、Accsoon USB 链路 |

## 时间戳专题（横切视角）

| # | 文档 | 内容 |
|---|---|---|
| 1 | [时间戳专题/01-PTS设计逻辑分析.md](./时间戳专题/01-PTS设计逻辑分析.md) | Camera/三种外部源 PTS 来源、合并策略、切源场景、g_vstarttime 三大用途、OBS 对比、8 张时序图 |
| 2 | [时间戳专题/02-时间戳与时钟漂移调研.md](./时间戳专题/02-时间戳与时钟漂移调研.md) | SortQueueManager 排序时间戳、PTS 链路、Camera 时钟、NTP 漂移补偿与盲区 |
| 3 | [时间戳专题/03-时间戳设计评价.md](./时间戳专题/03-时间戳设计评价.md) | 亮点/脆弱点/重构建议/Review 提问清单 |
| 4 | [时间戳专题/04-NTP时钟同步-TVUHostTimer.md](./时间戳专题/04-NTP时钟同步-TVUHostTimer.md) | TVUHostTimer 接口、相对轴→UTC 绝对轴换算、ntpSynced 推流门槛、两层漂移补偿 |

## 流图集（方法级 · 基线 2026-08-24）

`89e4c235a` 之后代码又走了约 1473 个 commit。这部分用图集单独成篇，**冲突时以图集为准**。
M 系列是**方法级调用图**（一个方法一个盒子，外框是 `Class::method` 或线程）：

| # | 图 | 内容 |
|---|---|---|
| 01 | [全景总览](./流图/01-全景总览.html) | 块级 · 当索引用 |
| M1 | [外部源视频解码链路](./流图/M1-外部源视频解码链路.html) | Parse → 队列 → VT 硬解 → 排序 → 交合流层 |
| M2 | [外部源音频解码链路](./流图/M2-外部源音频解码链路.html) | 分流（含组播捷径）→ 时钟节流 → 硬解 → 三出口 |
| M3 | [合流层四线程与分发](./流图/M3-合流层四线程与分发.html) | 四条 pthread、handler 分发、Metal 直达、三路回填 |
| M4 | [视频编码与推流](./流图/M4-视频编码与推流.html) | Overlay 合成 → I 帧决策 → VT 压缩 → Mux 双链路 |
| M5 | [音频编码器与二次混音](./流图/M5-音频编码器与二次混音.html) | index 守门 → VOIP/Partyline 混音 → AAC |
| M6 | [DJI RTMP 全栈](./流图/M6-DJI-RTMP全栈.html) | chunk 组包 → 抖动缓冲 → 硬解 → index 200 + 控制面 |
| M7 | [Overlay 注入双路](./流图/M7-Overlay注入双路.html) | 画面 GPU 水印 / 声音三路混音 |
| M8 | [后台推流补帧与 PiP](./流图/M8-后台推流补帧与PiP.html) | Plan A/B 降级、补帧率降档、带标记回灌 |
| M9 | [屏幕录制链路](./流图/M9-屏幕录制链路.html) | 扩展进程封包 → 三路队列 → 25ms 对齐混音 |

索引、旧图过时点清单与事实速记见 [流图/README.md](./流图/README.md)。生成脚本在 [流图/_gen/](./流图/_gen/README.md)。

### AUDIO 系列 · 音频全链路（基线 `736863f1f`）

M 系列偏视频主干。这一组把所有音频源补齐 —— 本地采集、屏录、会议、朗读、Overlay、DJI、Accsoon：

| # | 图 | 内容 |
|---|---|---|
| A0 | [音频全景](./流图/AUDIO-0-音频全景.html) | **先看这张**：7 个活源 → 四级改道 → 3 套混音器 → encode: → 4 路出口 |
| A1 | [本地麦克风采集](./流图/AUDIO-1-本地麦克风采集.html) | AudioUnit / AudioQueue 双实现、9 道闸门、重采样分包 |
| A2 | [屏幕录制音频](./流图/AUDIO-2-屏幕录制音频.html) | 跨进程两带、四份 static 副本改道、25ms 对齐 |
| A3 | [会议音频双向](./流图/AUDIO-3-会议音频双向.html) | 上行三路 / 下行拉流播放 / 二次混音三选一 |
| A4 | [朗读与 Overlay 音频](./流图/AUDIO-4-朗读与Overlay音频.html) | JS 抓 Web Audio、TTS 合成、混音器三路 |
| A5 | [DJI 与 Accsoon 音频](./流图/AUDIO-5-DJI与Accsoon音频.html) | DJI 抖动缓冲 + PTS 重锚、Accsoon USB 软解 |

配套文字见 [音频专题/](./音频专题/)：A0 接线总表 + A1–A5 五篇链路文档。

---

## 方案（非源码分析）

| 文档 | 内容 |
|---|---|
| [方案/RTMP聚合转发-时间戳重算与PLL方案.md](./方案/RTMP聚合转发-时间戳重算与PLL方案.md) | RTMP Server 聚合转发的时间戳重算缺陷分析、单锚点方案、PLL 锁相环设计、Python 模拟（DJI RTMP 相关设计输入） |

---

## 建议阅读顺序

1. **建立静态模型**：01 → 02 → 03 → 04（顺着数据流读，每篇开头有上下游链接）；音频侧接着读 07
2. **理解动态时序**：时间戳专题 01 → 02
3. **重构/评审决策**：时间戳专题 03 + 各模块文档末尾的"风险/注意点"小节

## 关键事实速记

- 时间基准只有一个：`g_vstarttime`（首帧的 HostTime 秒值），视频 dts 与音频 pts 都减它，单位毫秒。它在三处互斥初始化（H264/H265 编码器、合流层入队），谁先处理首帧谁初始化。推到云端时再叠加 NTP 偏移抬到 UTC 绝对轴（见时间戳专题 04）。
- 编码器 GOP 配置为 600 **秒**：I 帧实际由业务事件（首帧/切源/切摄像头/R 端请求）驱动，不靠周期 GOP。
- 推流前置双门槛：`g_livestate && ntpSynced`。
- 外部源断帧无兜底：过渡帧机制在 `TVUAVStreamManager.mm:2584` 被硬禁用。
- 纯内置相机直播不经过合流层（`isOnlyBuildInCameraStream` 直通编码）。
- 音频没有合流层：源隔离、格式归一、二次混音全压在 `TVUAudioEncoderManager -encode:` 一个方法里，
  8 个生产者线程在它的 `pthread_mutex` 上串行（详见 07）。
- 音频 `index` 不匹配是**整块丢弃，不补静音**；混音输出的 index 必须取**主源**的。
