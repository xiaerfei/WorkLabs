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
