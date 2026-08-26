# 音视频流图集

> 绘制基线：tvuanywhere_ios 仓库 `share/SPAR-705` 分支 commit `bc4021368`（2026-08-24）
>
> 工具：`diagram-design` 2.6.1 默认皮肤 · 方法级图由 [`_gen/`](./_gen/README.md) 的脚本生成
>
> 文字分析见上一级 [README.md](../README.md)。文字文档行号基线是 `89e4c235a`（2026-06-12），
> 本图集晚约 1473 个 commit，**冲突时以本图集为准**。

---

## 00 · 全景总览（块级，当索引用）

| 图 | 内容 |
|---|---|
| [01-全景总览](./01-全景总览.html) | 7 类采集源 → 5 路队列 / 3 套混音器 → 编码 → Mux 双链路 → 传输库 |

## M 系列 · 方法级调用图

粒度：**一个方法一个盒子**。外框是拥有这段调用的 `Class::method` 或线程，框内每个盒子是一次真实调用，
框底小字是这段里其余的调用表达式与约束。虚线 = 循环 / 返回 / 旁路，蓝线 = 跨线程或跨进程交接。

| # | 图 | 覆盖 | 规模 |
|---|---|---|---|
| M1 | [外部源视频解码链路](./M1-外部源视频解码链路.html) | Parse 读包 → 解码队列 → VT 硬解 → didDecompress → 排序 → 交合流层 | 27 盒 / 28 边 |
| M2 | [外部源音频解码链路](./M2-外部源音频解码链路.html) | 包分流（含组播软解捷径）→ 时钟节流出队 → AAC 硬解 → 定长块 → 三出口 | 26 / 25 |
| M3 | [合流层四线程与分发](./M3-合流层四线程与分发.html) | 四条 pthread、14 种 streamType → 4 组 handler、Metal 直达旁路、三路回填 | 23 / 17 |
| M4 | [视频编码与推流](./M4-视频编码与推流.html) | sendToEncoder 前段 → Overlay 合成 → I 帧决策 → VT 压缩 → Mux 双链路 | 29 / 28 |
| M5 | [音频编码器与二次混音](./M5-音频编码器与二次混音.html) | encode: 校验 → 声道归一 → Agora 分叉 → index 守门 → 二次混音 → AAC | 23 / 22 |
| M6 | [DJI RTMP 全栈](./M6-DJI-RTMP全栈.html) | Transport → chunk 组包 → 消息分派 → 抖动缓冲 → 硬解 → index 200；音频带 + 控制面 | 32 / 31 |
| M7 | [Overlay 注入双路](./M7-Overlay注入双路.html) | 画面：GPU 水印 / 整帧替换；声音：JS 抓 Web Audio + 弹幕朗读 → 三路混音 | 28 / 23 |
| M8 | [后台推流补帧与 PiP](./M8-后台推流补帧与PiP.html) | 统一喂点 → Plan A/B 降级 → 补帧率降档 → 带标记回灌 → 画中画 | 21 / 22 |
| M9 | [屏幕录制链路](./M9-屏幕录制链路.html) | 扩展进程封包 → Peertalk socket → 三路队列 → 视频直送 / 音频 25ms 对齐混音 | 24 / 24 |

**建议顺序**：01 建立全局 → M1/M2（外部源）→ M3/M4/M5（主干）→ M6/M7/M8/M9（四个子系统）。

## AUDIO 系列 · 音频全链路（2026-08-25 补，基线 `736863f1f`）

M 系列偏视频主干，音频只覆盖了外部源解码（M2）与编码器（M5）两端。这一组把**所有音频源**补齐：

| # | 图 | 覆盖 | 规模 |
|---|---|---|---|
| A0 | [音频全景](./AUDIO-0-音频全景.html) | **先看这张**。7 个活源 → 四级改道阶梯 → 3 套前置混音器 → encode: → 4 路出口 | 25 盒 / 26 边 |
| A1 | [本地麦克风采集](./AUDIO-1-本地麦克风采集.html) | AudioUnit / AudioQueue 双实现、9 道闸门、两处抹零、重采样分包、四路分流 | 37 / 37 |
| A2 | [屏幕录制音频](./AUDIO-2-屏幕录制音频.html) | 扩展进程 → Peertalk → 主 App 三 case、四份 static 副本改道、25ms 对齐 | 36 / 35 |
| A3 | [会议音频双向](./AUDIO-3-会议音频双向.html) | 上行三路（Agora/WebRTC/RTIL）、下行拉流与播放、二次混音三选一 | 32 / 30 |
| A4 | [朗读与 Overlay 音频](./AUDIO-4-朗读与Overlay音频.html) | JS 抓 Web Audio、AVSpeechSynthesizer 合成、Overlay 混音器三路 | 33 / 32 |
| A5 | [DJI 与 Accsoon 音频](./AUDIO-5-DJI与Accsoon音频.html) | DJI RTMP 解码+抖动缓冲+PTS 重锚（index 200）、Accsoon USB 软解（index 5） | 46 / 45 |

配套文字：[音频专题/](../音频专题/)（A0 接线总表 + A1–A5 五篇）与
[07-音频编码器](../07-音频编码器-TVUAudioEncoderManager.md)（汇聚点专题）。
**M2 与 M5 同属这一组**：M2 是外部源那条源链路，M5 是 A0 里 encode: 那个盒子的展开。

### 这一轮核出的死代码

| 位置 | 状态 |
|---|---|
| `aacEncoder` 的 PCM 环形池整套 | `startEncode()` 函数体连 `pthread_create` 一起被注释（`:87-98`），`tvu_mic_pcm_separator` 线程从不启动；`doencode()` 里的 `encode:`/`stopEncoder` 都不可达。mic 唯一出口是 `sendFrameToEncoder` |
| 屏共 Mic 走扩展进程 | 收发两侧都注释（`Client.mm:121` / `MainViewController.mm:7682` / `TVUIRLSDK.mm:443`）。原因见 `:7684`「Now use audioUnit to capture」 |
| `tvuSendAudioToScreenShare` 第四份副本 | `TVUScreenRecordPcmContractor.mm:121` 本 TU 内无调用方 |
| `TVURecorder.mm:2346` 的 `encode:` | 在注释块里（`:2338-2347`） |
| `AudioPlayer::caculateVolumeDB` | 两个调用点都被注释，`getLVolDB` 恒返回 −40 |
| `MediaClock` 对音频的决策 | `server:didUpdateTargetVideoLatency:audioLatency:` 全仓无实现，算完就扔 |

### 音频事实速记

- **三个主源共用一套四级改道阶梯**（屏共 > 朗读/Overlay 混音 > PIP/PBP 混音 > 直送），
  mic / Accsoon / DJI 三处实现逐行同构；三份增益实现也逐行等价。
- **两套混音器的 index 规则相反**：Overlay 取主源、PIP/PBP 取辅源优先。取错就整块被编码器丢掉。
- **块规格 4096 字节 = 1024 帧 × 2ch × int16** 是隐含契约；DJI 是唯一破坏它的源
  （`1024 × 48000 / 源采样率` 帧），44.1k 源约 8.2% 音频不进流。
- **两个辅源都不产生有效 PTS**，混音输出一律用主源的 pts 与 index。
- **`last_audio_pts` 是全进程静态且永不复位**；只有 DJI 主动 clamp 绕开它，Accsoon 裸奔。
- **一个 Agora API 两种时间单位**：Partyline 传 UTC 毫秒、RTIL VoIP 传秒，未找到补偿代码。
- **`data_mix` 按首帧定长**是系统性模式，Overlay 那份已改成按需扩容，另两处照搬即可。

图宽 2300–3700px，在页面内的框里横向拖动。

---

## 核对出的旧图过时点

语雀手绘图（旧基线）与当前代码不一致的地方：

| 旧图内容 | 现状 |
|---|---|
| `TVUAudioSampleHandle`、`caculateVolumn(…)` | **已不存在**。外部源音频现在走 `TVUExtAudioEncoder::pushFrame` → `doencode()`（见 M2） |
| `pushSample:andPtsOffset:sourceType:` | **0 处引用**。被合流层 + `encode:isNeedKeyFrame:externalSourceIndex:` 取代（见 M3 / M4） |
| `pushRenderSampleBuffer:` | **0 处引用**。预览走 TVURenderQueue + renderWithSamplebuffer（见 M3） |
| `addSampleData(sample)` | **0 处引用**。录制走 `TVURecordMuxHandler::addVideoData`（见 M4） |
| `addData` 4 个参数 | 现在 5 个，多了 `current_frame_index`（见 M1） |
| `sort()` 首帧只改 index | 现在还会发 `kTVUExternalSourceStopLastSource` + `kTVUExternalSourceParseStart` 两个通知 |

---

## 事实速记（本轮核实过的）

- 源索引：本地相机 `−1`、双摄第二路 `1001`、屏幕录制 `100`、DJI RTMP `200`、外部源按槽位。
- 队列 8 路：5 路输入（Camera / MutiCamera / External / OSMO / OSMORTMP）+ 3 路回填（Render / Encoder / AutoPan）。
- streamType 14 种，`TVUAVStreamOSMORTMP` 最新加。
- 三套混音器数组尺寸各自独立：`kTVUAudioMixerSourceSize = 2`（共享，不能改）、
  `kTVUOverlayMixerQueueCount = 3`、`kTUScreenRecordingMediaSize = 3`。
- 音频编码器三道硬门槛：声道数、采样率必须 48k、`external_source_index` 必须等于当前活跃源
  —— 不符是**整块丢弃**，不是静音。
- **编码器 GOP 两边不对称**：`TVUConst.h` 里两个常量都是 `60 * 10`，但 H.264 设给
  `MaxKeyFrameIntervalDuration`（单位**秒** → 等于关掉周期 GOP），H.265 设给
  `MaxKeyFrameInterval`（单位**帧** → 30fps 下约 20 秒一个 I 帧）。旧文档的「GOP=600 秒」对 H.265 不成立。
- DJI 流层面（RTMP / BLE / SEI 四路）都没有旋转角度，最终开放用户在 Advance 手选 0/90/180/270。
- 后台补帧率必须跟着实时帧率降档（50/60 → 25，25/30 → 10）；直降固定 10fps 会让后台硬编停止出包。
- 全链路唯一还生效的补帧是屏录的 `addTransitionFrame()`（>99ms 复用上一帧）；合流层那套已被硬禁用。

---

## 重绘

块级图 01 是手写 SVG，直接改 HTML。M 系列是脚本生成的：

```bash
cd _gen && python3 build_m3.py
```

细节见 [_gen/README.md](./_gen/README.md)。
