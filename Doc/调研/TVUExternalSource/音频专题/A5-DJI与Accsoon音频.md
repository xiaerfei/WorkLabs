# DJI RTMP 音频 与 Accsoon/SeeMo 音频 — 方法级梳理

> 基线：`share/SPAR-705` @ `736863f1f`（2026-08-25）。代码根目录
> `products/TVUTransportIOS/TVUAnywherePro/`，本文所有 `文件:行号` 均以该 checkout 实测。
>
> 两条链路的共同汇聚点是 `TVUAudioEncoderManager.encode:`，其内部闸门见
> [07-音频编码器-TVUAudioEncoderManager.md](../07-音频编码器-TVUAudioEncoderManager.md)；
> 接线全图见 [A0-音频链路总表.md](./A0-音频链路总表.md)。
>
> 两条链路**互不相通**：DJI 走 `AVAudioConverter`（一次完成解码+重采样+声道适配），
> 直接产出 `CMSampleBuffer` 送编码器；Accsoon 走 `AudioConverter`（AudioToolbox）
> 解到源规格 PCM，再由 libswresample 重采样，最后经 `TVUExtAudioEncoder`
> **重新分包成固定 4096 字节**。**块规格差异是两条链路最本质的区别**，见 §1.3 / §2.3。

---

# 第一部分：DJI RTMP 音频（external_source_index = 200）

源索引常量：`kTVUOSMORTMPSourceIndex = 200`（`TVUOSMORTMPSourceIndex.h:15`）。
头文件注释说明了取 200 的三条约束：避开 `-1`（本地麦克风）、避开 `1/2/3/4`（本地文件外部源，
防编码层重启检测误触发）、避开 `100`（`TVUScreenRecordingSourceIndex`）。

## 1.1 AAC 解码：用什么解

**`AVAudioConverter`**（AVFoundation），不是 `AudioConverterRef`，与 VideoToolbox 无关。
持有对象在 `TVUIRLAudioDecoder.m:12-16`：`aacFormat` / `pcmFormat` /
`AVAudioCompressedBuffer` / `AVAudioPCMBuffer` / `AVAudioConverter`。

### 输入 AAC 格式怎么来

`AudioSpecificConfig`（FLV Audio Tag payload 跳过 2 字节控制头）由
`TVUIRLAudioConfig.initWithData:` 逐位解析（`TVUIRLAudioConfig.m:35-50`）：

```
objectType  = bytes[0] >> 3                              // 合法域 [1,10]，否则返回 nil
freqIndex   = ((bytes[0] & 0x07) << 1) | (bytes[1] >> 7) // 合法域 [0,12]
channelCount= (bytes[1] & 0x78) >> 3                     // 合法域 [0,7]
```

`freqIndex → sampleRate` 走标准 AAC 采样率表（`TVUIRLAudioConfig.m:8-25`，
96000/88200/64000/48000/44100/32000/24000/22050/16000/12000/11025/8000/7350）。

再组装 `AudioStreamBasicDescription`（`TVUIRLAudioConfig.m:52-64`）：
`mFormatID = kAudioFormatMPEG4AAC`、`mFramesPerPacket = 1024`、
`mFormatFlags = (UInt32)objectType`，`mBytesPerPacket / mBytesPerFrame / mBitsPerChannel` 全 0
（压缩格式），最后 `avAudioFormat` 用它 `initWithStreamDescription:`（`TVUIRLAudioConfig.m:66-69`）。

FLV 侧的分发在 `TVUIRLMediaPipeline.m:688-703`：只接 `codec == 0xA`（AAC，
`kFlvAudioCodecAac`，`TVUIRLMediaPipeline.m:53`），其它 codec 直接 `stopWithReason:`
断连（`:693-696`）；`aacPacketType == 0` 走序列头，`== 1` 走 raw 帧。

### 输出 PCM 规格

钉死为编码器期望的格式（`TVUIRLAudioDecoder.m:44-47`）：

```objc
[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                 sampleRate:kTVUAudioEncoderSampleRate   // 48000
                                   channels:kTVUAudioEncoderStereoChannel // 2
                                interleaved:YES];
```

常量出处 `TVUAudioEncoderManager.h:15-16`。注释（`TVUIRLAudioDecoder.m:41-43`）明确：
`AVAudioConverter` 一次性完成 **AAC 解码 + 重采样 + 声道适配**，
下游 `RTMPIngestController` 不再做 PCM→PCM 转换。

## 1.2 重采样在哪一步

**在 `AVAudioConverter` 内部**，没有独立的重采样器。
`initFromFormat:aacFormat toFormat:pcmFormat`（`TVUIRLAudioDecoder.m:62`）里输入是源采样率的
AAC、输出是 48 kHz stereo Int16，SRC 由 `AVAudioConverter` 自己承担。
`RTMPIngestController.mm:370-371` 的注释也是这个意思。

## 1.3 块长 ⚠️（重点）

### 代码事实

| 项 | 值 | 出处 |
|---|---|---|
| `AVAudioCompressedBuffer` packetCapacity | 1 | `TVUIRLAudioDecoder.m:71` |
| `AVAudioCompressedBuffer` maximumPacketSize | `4096 × aacFormat.channelCount` | `TVUIRLAudioDecoder.m:72` |
| `AVAudioPCMBuffer` frameCapacity | `ceil(1024 × 48000 / srcRate) + 16` | `TVUIRLAudioDecoder.m:75-76` |
| 每次 `convertToBuffer:` 输入 | 恰好 1 个 AAC packet = 1024 源采样 | `TVUIRLAudioDecoder.m:95-114` |
| `CMSampleBuffer` numSamples | `pcm.frameLength` | `TVUIRLAudioDecoder.m:147,159` |
| 送编码器的 `param.size` | `CMBlockBufferGetDataPointer` 得到的 `pcmLength` | `RTMPIngestController.mm:378,405` |

**输出帧数公式**（每个 AAC 帧）：

```
frameLength = 1024 × 48000 / srcSampleRate     （SRC 实际产出，容量上留 +16 裕量）
byteLength  = frameLength × 2 声道 × 2 字节 = frameLength × 4
```

按源采样率算出的块规格：

| DJI AAC 源采样率 | frameLength | 送编码器字节数 | 是否 == 4096 |
|---|---|---|---|
| 48000 | 1024 | **4096** | ✅ 恰好 |
| 44100 | ≈1115 | ≈4460 | ❌ 多 364 B |
| 32000 | 1536 | 6144 | ❌ |
| 24000 | 2048 | 8192 | ❌ |
| 16000 | 3072 | 12288 | ❌ |
| 8000 | 6144 | 24576 | ❌ |

代码里已经明确写下了这个约束（`RTMPIngestController.mm:415-416`）：

> 「DJI 的块长 = 1024 × 48000/其 AAC 采样率 帧，只有源本身是 48kHz 才和混音器的块规格一致。」

### 块长 ≠ 4096 时下游 `TVUAudioEncoderManager` 的行为（**存疑点**）

沿 `encode:` 逐段核对（`TVUAudioEncoderManager.mm:92-409`）：

1. **闸门都过**：`channel == 2` 过 `:179`；`sampleRate == 48000` 过 `:184`；
   单声道转双声道分支 `:191` 不触发（本来就是 stereo，`stereo_pcm_buffer` 只有
   `kTVUAudioEncoderPCMSize = 4096` 字节，走这条路才会溢出 —— DJI 不走）。
2. **缓冲不会溢出**：`encoderData.data` 与 `aacBuffer` 都在 `param->size > 4096` 时
   `realloc`（`:338-340`、`:351-353`）。
3. **编码器配置是硬性 1024 帧/包**：`setupEncoder` 里
   `outputFormat.mFramesPerPacket = kTVUAudioEncoderFramesPerPacket = 1024`（`:594`），
   `AudioConverterFillComplexBuffer` 每次固定 `outputDataPacketSize = 1`（`:364-365`）
   —— 即每次调用只要 1 个 AAC 输出包，需要**恰好 1024 帧 = 4096 字节**输入。
4. **输入回调是无状态的**（`AudioEncoderConverterComplexInputDataProc`，`:695-710`）：

   ```objc
   ioData->mBuffers[0].mData         = audioDecoder->data;
   ioData->mBuffers[0].mDataByteSize = audioDecoder->size;
   // 注意：*ioNumberDataPackets 没有被回写；也没有任何 offset / 已消费游标
   ```

   它把**整块**交出去，既不回写实际提供的包数，也不记录消费位置。

**由此推出（代码层面的必然结论）**：一次 `encode:` 调用最多只能变成 1 个 AAC 包
（1024 帧 / 4096 字节）。`param->size > 4096` 的余量**没有任何代码路径去消费**——
下一帧到来时 `encoderData` 被整块覆盖（`:342-343`）。所以 44.1 kHz 源的 ≈364 字节/帧
（≈8.2%）不会进流。48 kHz 源正好对齐，无损。

**未确认（需运行时验证）**：
`AudioConverterFillComplexBuffer` 在「回调不回写 `*ioNumberDataPackets`、
`mDataByteSize` 又大于本次所需」时的确切取舍（截断到 1024 帧 / 报错 / 反复回调），
Apple 未文档化。上面第 4 点是从代码结构推断的，**没有实测**。
真正要确认的是「DJI OA5 Pro 的 AAC 到底是不是 48 kHz」——若是，本节整段不构成风险。
定位方法见 §3。

### 顺带受影响的两处

- 录制旁路 `writeAudioAssetWithParam:`（`:410-516`）按 `param->size` 算
  `count = size / (2 × channel)`（`:483`），块长多少都能自洽，不受影响。
- Partyline 推流 `pushAudioData:andSampes:param->size/(2*param->channel)`（`:237`）
  同样按实际 size 算，不受影响。
- **只有 AAC 编码这一步是硬 1024 帧。**

## 1.4 PTS 链路（RTMP timestamp → `TVUAudioEncoderData.pts`）

### 逐级换算式

**① RTMP chunk 时间戳 → 流内相对 ms**（`TVUIRLMediaPipeline.m:221-231, 734`）

```
mediaTimestamp   = messageTimestamp                （absolute chunk）
                 或 mediaTimestamp += messageTimestamp（delta chunk）
mediaTimestampZero = 首个 message 的 mediaTimestamp   （:228-230，一次性锚）
audioTs(ms)      = mediaTimestamp − mediaTimestampZero
```

**② 加上会话 host base**（`TVUIRLMediaPipeline.m:735-736`）

```
base(ms) = [connection basePresentationTimeStampMs]   // = 1000 × CACurrentMediaTime()，首次调用锚一次
                                                      // TVUIRLStreamConnection.m:713-719
pts(ms)  = (int64)(audioTs + base)
→ 送解码器：CMTimeMake(pts, 1000)                       // TVUIRLMediaPipeline.m:759
```

注释（`:736`）说明：`latency` **不再加进 PTS**，已挪到缓冲延迟层（Plan 18）。

**③ 解码出口重锚到 host time**（`TVUIRLAudioDecoder.m:119-129` →
`TVUIRLStreamConnection.m:789-874`）

```
若首帧：audioFirstPts = pts                                   // :800-803
若 basetime 未锚：anchorBasetime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000)
                                                              // :804-808，audio 是 master
sourceDelta = pts − audioFirstPts                             // :809
newPts      = anchorBasetime + sourceDelta                    // :810
```

> 注意：② 里加的 `base` 在 ③ 里被 `− audioFirstPts` 抵消掉了，净效果是
> `newPts ≈ (首个音频帧解码时刻的 CACurrentMediaTime) + (audioTs − audioFirstTs)`。

**④ 单调 clamp**（`TVUIRLStreamConnection.m:849-856`）

```objc
if (!didInsaneReset && CMTIME_IS_VALID(lastAudioNewPts) &&
    CMTimeCompare(newPts, lastAudioNewPts) <= 0) {
    newPts = CMTimeAdd(lastAudioNewPts, CMTimeMake(1, pts.timescale));   // pts.timescale==1000 → +1ms
    clamped = YES;
}
lastAudioNewPts = newPts;
```

**为什么要 clamp**：属性声明处（`TVUIRLStreamConnection.m:113-115`）与实现处（`:849`）
两处注释一致 ——「极端 video burst 下 PLL 多次连续下拉 basetime 可能让 audio newPts 不增；
保证 audio newPts 严格单调，**绕过 `TVUAudioEncoderManager` 的 `last_audio_pts` 守卫**」。
那道守卫在 `TVUAudioEncoderManager.mm:171-177`：

```objc
static Float64 last_audio_pts = 0;
if (last_audio_pts > current_audio_pts) { log; return; }   // 回退一帧就整帧丢
last_audio_pts = current_audio_pts;
```

它是**全进程单一静态量**（所有音源共用），所以 PTS 一旦回退就会连锁丢帧。
`kTVUIRLDJIBasetimePLLEnabled = NO` 的现状下 PLL 不动 basetime，clamp 事实上是防御性的
（`:849` 注释也写作「防 PLL 下拉致回退」）。

**⑤ `CMSampleBufferGetPresentationTimeStamp` → `TVUAudioEncoderData.pts`**
（`RTMPIngestController.mm:401-408`）

```objc
Float64 framePts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer));
param.pts = framePts;    // 单位：秒（Float64）
```

注释（`:399-400`）说明为什么不用 `CACurrentMediaTime()`：那会受 server 回调线程调度抖动
影响导致音频颤抖，用 sampleBuffer 自带的重锚 PTS 才严格单调均匀。

**⑥ 编码器内部再转 ms**（`TVUAudioEncoderManager.mm:145`）

```objc
int64_t newPts = (int64_t)((param->pts − g_vstarttime) × 1000);
```

### video 侧如何对齐 audio

`remapVideoDecodedPts:`（`TVUIRLStreamConnection.m:737-784`）用
`anchorFirstPts = audioFirstPtsReady ? audioFirstPts : videoFirstPts`（`:753`）
—— 即 **video 拿 audioFirstPts 当首帧基准**，使同源时刻 video newPts == audio newPts、
有效 A/V offset = 0；audio 未到达时才回退 videoFirstPts 兜底、不丢帧（`:751-752` 注释）。
日志里的 `avRawDiff` 只是诊断 DJI 源固有的 A/V 首帧差（`:777-779`）。

## 1.5 抖动缓冲：音频有独立的一份

**独立**，不与视频共用队列或线程：

| | audio | video |
|---|---|---|
| 类 | `TVUIRLBufferedAudio` | `TVUIRLBufferedCompressedVideo`（解码前，默认）/ `TVUIRLBufferedVideo`（解码后） |
| 串行队列 | `com.tvu.dji.buffered.audio`（`TVUIRLBufferedAudio.m:37`） | `com.tvu.dji.buffered.compressed.video` / `com.tvu.dji.buffered.video` |
| 缓冲位置 | **始终解码后**（`TVUIRLMediaPipeline.m:76` 注释：「音频始终走解码后缓冲」） | 由 `kTVUIRLDJIDecodeBeforeBuffer = YES` 决定放解码前（`:78`） |
| DriftTracker | **无** | 有（`TVUIRLBufferedVideo.m:44`） |

**启用条件**（`TVUIRLMediaPipeline.m:717, 720-724`）：

```objc
BOOL useBuffer = kTVUIRLDJIJitterBufferEnabled && (self.connection.latency > 0);
if (useBuffer && !self.bufferedAudio) {
    double latencySec = self.connection.latency / 1000.0;
    self.bufferedAudio = [[TVUIRLBufferedAudio alloc] initWithName:@"dji-audio"
                                                          latency:latencySec
                                                       maxLatency:kTVUIRLDJIMaxBufferLatency]; // 5.0s
}
```

- `kTVUIRLDJIJitterBufferEnabled = YES`（`TVUIRLMediaPipeline.m:71`，功能级总开关/紧急回滚）
- `kTVUIRLDJIMaxBufferLatency = 5.0`（`TVUIRLMediaPipeline.m:84`，与 watchdog 的 5s 字节停滞阈值对齐）
- `connection.latency` 来自 `TVUIRLDJIStreamModel.latency`，赋值链：
  `TVUIRLDJIControlBS.m:77` → `RTMPIngestController.latency` → `startWithPort:` 构造
  `TVUIRLStreamProfile`（`RTMPIngestController.mm:87`）→ `connect` 时 `client.latency = matched.latency`
  （`TVUIRLMediaPipeline.m:351`）。
  **默认值 = 1000 ms**（`kTVUIRLDJIDefaultLatency = 1000`，`TVUIRLDJIStreamModel.m:15,46`）。
  ⚠️ `RTMPIngestController.mm:78` 的 `_latency = 2000` 只在 ControlBS 没赋值时生效；
  `TVUIRLMediaPipeline.m:352` 的注释「默认 2000ms」与 model 常量（1000）**不一致，注释已过期**。

### 出帧节奏

`output` 每 tick 一次，interval = `frameLength / sampleRate`（`TVUIRLBufferedAudio.m:83`，
48k/1024 ≈ 21.33 ms），由 `TVUIRLSimpleTimer` 的 `dispatch_source` 挂在 `_queue` 上
（`TVUIRLSimpleTimer.m:41-54`）。`frameLength` / `sampleRate` 在首帧从格式里读
（`TVUIRLBufferedAudio.m:67-76`，兜底 1024 / 48000）。

三段行为（`TVUIRLBufferedAudio.m:114-160`）：
1. **蓄水期**：`firstPts + latency > now` 就不出帧（`:126-132`）。
2. **开闸后**：队列非空就出，`currentFillLevel() <= latency` 才停（`:138-151`）
   —— 积压时一个 tick 出多帧追赶收敛，稳态每 tick 1 帧。
3. **overflow**：`enforceOverflowDrop`（`:165-177`）超 `maxLatency`（换算成帧数，`:182-187`）
   丢最老帧；format 未初始化时兜底硬上限 300 帧（`:11`）。

### underrun：绝不补静音 ✅ 已核实

`TVUIRLBufferedAudio.m:156-159`：

```objc
if (drained > 0) { return; }
// 队列真空(underrun:抖动吃穿 latency 缓冲)→ 不输出、等真帧(绝不补静音);仅累计 gap tick 供日志。
_consecutiveUnderrunTicks++;
```

恢复时只打一行 gap 日志、不补帧（`:142-146`）。设计理由写在 `:105-107`：

> 「绝不补静音：推流场景保源 PTS、收到就推，断流的时间 gap 交服务端（5s 缓冲）按 PTS 重排；
> 本地补静音是从 Moblin『实时播放（声卡每拍必须有数据）』误植的 —— 对推流既污染内容
> （塞假静音）又造成颤音（真帧/静音高频交替）。」

`:109-113` 的 bug 注记记录了三层根因（延迟锁死 / 临界抖动 / 补静音自伤）。

> ⚠️ **头文件注释已过期**：`TVUIRLBufferedAudio.h:7` 仍写着
> 「underrun 输出『填零静音』(PTS 递推、不重复内容)」，与 `.m:156-159` 的实现相反。
> 以 `.m` 为准。

## 1.6 audioFirstPts 对齐 / PLL / MediaClock / DriftTracker

### PLL 开关

```objc
static const BOOL kTVUIRLDJIBasetimePLLEnabled = NO;   // TVUIRLStreamConnection.m:23
```

`:19-23` 的注释：`NO` = basetime 首帧锚定后固定（仍把 stream-pts 折到 host time，只是不抗漂移），
用于测「不动 basetime」的音画质量；关掉时**仍算 drift/filt 供日志观测**，但不 correction、不 PANIC 重锚。

PLL 参数（`TVUIRLStreamConnection.m:793-797`，开关关闭时只用于算日志）：

| 常量 | 值 | 含义 |
|---|---|---|
| `kBasetimeScale` | 1000000 | 微秒 timescale，保 sub-ms correction 精度 |
| `kEmaAlpha` | 0.005 | EMA 时间常数 ≈ 4.3 s @ 48k/1024 |
| `kPllGain` | 0.01 | 比例反馈增益 |
| `kMaxCorrectionMsPerFrame` | 1.0 | 单帧 correction 限幅 ±1 ms |
| `kInsaneDriftMs` | 5000.0 | PANIC 阈值，超过就整体归零重锚 |

反馈式（`:816-847`，仅在开关为 YES 时执行）：

```
driftMs         = (newPtsSec − CACurrentMediaTime()) × 1000
filteredDriftMs = filteredDriftMs × (1 − 0.005) + driftMs × 0.005
correctionMs    = clamp(filteredDriftMs × 0.01, ±1.0)
anchorBasetime -= CMTimeMake(round(correctionMs × 1000), 1000000)
```

PANIC 分支（`:824-838`）归零 anchor + audio/video firstPts + `lastAudioNewPts` 等全部状态，下一帧重锚。

### audio 是 basetime master

`:786-788` 注释：audio 首帧锚 basetime，video 共享只读；
audio **不经解码前缓冲**（早解码）所以 basetime 早锚 —— 根治 video 主导时的开播音画错位，
原「basetime 未就绪丢弃 audio」的逻辑已删除。
`TVUIRLAudioDecoder.m:119-129` 保留了 `!CMTIME_IS_VALID(remappedPts) → return` 的
invalid 分支，但注释（`:120-121`）说明改 audio 主导后不再返 invalid，**留作防御**。

锚状态字段由 `os_unfair_lock _anchorLock` 保护（`TVUIRLStreamConnection.m:74`），
因为 VT 异步回调线程与 RTMP socket 线程会并发触发 `remap*`。
`stopWithReason:` 时整体归零（`:203-219`）。

### MediaClock：接了线但**没有消费者**

- 每解码一帧都喂：`pipelineDidObserveAudioPts:` → `setLatestAudioPresentationTimeStamp:`
  （`TVUIRLStreamConnection.m:695-698`），video 侧对称（`:700-703`）。
- `update`（`TVUIRLMediaClock.m:40-60`）：`avDiff = latestAudioPts − latestVideoPts`，
  EMA `×0.98 + ×0.02`，变化 ≤ 100 ms 就不上报；`avDiff > 0` 抬 audio 目标延迟、否则压 video。
  `initWithTargetLatency:2.0`（`TVUIRLStreamConnection.m:153`）。
- 结果经 `forwardTargetVideoLatency:audioLatency:`（`:708-709`）转
  `TVUIRLStreamingServer.m:230-234` 的 delegate 回调
  `server:didUpdateTargetVideoLatency:audioLatency:`。
- **该 delegate 方法在整个工程里只有协议声明（`TVUIRLStreamingServer.h:28`）和这处调用点，
  没有任何实现**（全仓 grep 只有 3 处命中，全在这两个文件里）。
  `RTMPIngestController` 未实现它 → `respondsToSelector:` 为假 → 决策被丢弃。

**结论：MediaClock 当前对音频（和视频）没有任何实际作用**，`BufferedAudio.setTargetLatency:`
（`TVUIRLBufferedAudio.m:218-220`）无人调用。

### DriftTracker：音频完全不参与

全仓 `TVUIRLDriftTracker` 的使用点只有 `TVUIRLBufferedVideo.m`（`:28,44,138,148,227,231`）。
`TVUIRLBufferedAudio.m` 不 import、不持有。
`TVUIRLBufferedAudio.h:8` 的注释也说明了这个设计：
「音画同步靠音视频共享同一 basetime（解码出口），buffer 自身不再做 drift」。

> ⚠️ `TVUIRLDriftTracker.h:10` 的注释仍写着「master(audio) 算 drift 并经 setDrift: 喂给
> slave(video) 共用」，**与现状不符**（音频侧根本没有 tracker）。这句是移植 Moblin 时的遗留描述。

## 1.7 增益/静音：为什么单独实现一份

```objc
// RTMPIngestController.mm:428-441
- (void)applyCaptureGain:(float)gain toInterleavedInt16PCM:(int16_t *)samples byteLength:(size_t)byteLength {
    int const MAX = 32767, MIN = -32768;
    double f = 1;
    size_t sampleCount = byteLength / 2;              // int16 样本数（声道无关）
    for (size_t i = 0; i < sampleCount; i++) {
        double output = (double)samples[i] * (double)gain;
        output = output * f;
        if (output > MAX) { f = (double)MAX / output; output = MAX; }
        if (output < MIN) { f = (double)MIN / output; output = MIN; }
        if (f < 1) { f += ((double)1 - f) / (double)32; }
        samples[i] = (int16_t)output;
    }
}
```

**算法**：逐样本乘 gain，再乘一个**带记忆的软限幅系数 `f`**。一旦某个样本削顶，
`f` 被压到 `MAX/output`（< 1）并对后续样本持续生效；随后每个样本按
`f += (1 − f)/32` 缓慢回爬到 1。即一个「攻击瞬时、释放约 32 样本时间常数」的软限幅器，
避免硬 clip 产生的爆音。`gain == 0` 即静音。

**为什么单独一份**：注释在 `:425-427` 和 `:391-394`。
DJI 音频走 RTMP 解码后的 PCM，**不经本地采集链 `TVURecorder`**，所以界面上的 Mute 开关
（`tvuSetAudioCaptureGain:0`）对 DJI 直播原本无效。这里在送编码器前施加同一增益，
与本地麦克风 `TVURecorder.setCaptureGainWithSource:` 同语义。

**与本地实现逐行核对**（`TVURecorder.mm:2632-2663`）：常量、`f` 递推、限幅顺序完全一致，
唯一差异是本地版本 out-of-place（`bufferData → outData`）、DJI 版本 in-place。**算法等价。**

**gain 从哪读**：`[[TVUAudioCaptureManager manager] getAudioCaptureGain]`
（`RTMPIngestController.mm:395`）→ `liveRecorder.gain`（`TVUAudioCaptureManager.mm:211-214`）。
`gain == 1.0f` 走快路径跳过（`:396`）。注释（`:393-394`）指出关键点：
gain 存活于 `liveRecorder`，`stopAudioCapture` **不清空它**，所以 DJI 接管期间读取仍可靠。

## 1.8 `handleDecodedAudio` 三路改道

入口是 delegate 方法 `server:didReceiveAudioSampleBuffer:`
（`RTMPIngestController.mm:366-423`，即任务里说的 `handleDecodedAudio`）。
执行顺序（注意增益施加点在改道 ① 之后、改道 ②/③ 之前）：

| # | 分支 | 条件 | 去向 | 增益 |
|---|---|---|---|---|
| ① | 屏共改道 | `[TVUScreenRecordingServerSocketManager manager].isReceivingFrame`（`:387`） | `tvuSendAudioToScreenShare()` → `TVUScreenRecordingQueueManager::addDataToScreenRecordingQueue(sourceQueue[TVUScreenRecordingAudioMic])`（`:47-60`） | **不预施加**，由队列的 `adjustAudioGain` 施加（`TVUScreenRecordingQueueManager.mm:267`） |
| ② | 朗读混音改道 | `[TVUSnapshotManager manager].shouldOutputAudioStream`（`:417`） | `TVUOverlayAudioMixerManager::addDataToAudioMixer(&param, sourceQueue[TVUAudioMixerSourceLocalCamera])`（`:419`） | **已在 `:396-398` 施加** |
| ③ | 直送编码器 | 以上都不成立（`:422`） | `[[TVUAudioEncoderManager manager] encode:&param]` | 同上 |

**① 的理由**（`:382-385`）：屏幕分享开启时 `encode:` 只接受 `TVUScreenRecordingSourceIndex`
（`TVUAudioEncoderManager.mm:96-100`），直送会被丢弃；改走屏共 mic 队列后与内置 mic 走同一条
混音链，受 `getShareScreenAudioMixType` 控制 —— `TVUShareScreenConfigShareScreenAudioOnlyType`
时整帧丢弃（`:49-51`）。

**② 的理由**（SPAR-765，`:413-416`）：与 `aacEncoder.mm` 里本地 mic 的分叉同构。
混出来那帧的 index 取自主源、仍是 200，编码器收得下
（`TVUOverlayAudioMixerManager.mm:366`）。块长对不上时混音器**跳过辅源、把主源原样透传**
并打日志（`TVUOverlayAudioMixerManager.mm:333-347`：
`overlay/tts block size %d != mic %d, skip mixing it`），主源音频本身不受影响。
`shouldOutputAudioStream` = `webManager.shouldOutputAudioStream || [TVUWebChatManager manager].needsAudioMixing`
（`TVUSnapshotManager.m:340-346`，整段在 `#if (defined _TVUIRLSDK)` 内）。

**共同前置**（无论走哪条）：`CMSampleBufferGetDataBuffer` +
`CMBlockBufferGetDataPointer` 拿裸 PCM 指针（`:372-381`），任一步失败直接 return。

## 1.9 本地采集接管

三个方法都在主线程串行化（非主线程 `dispatch_async` 到主队列），都对音频源索引下手：

| 方法 | 行号 | `updateExternalSourceIndex:` | `streamType` | 采集动作 |
|---|---|---|---|---|
| `suspendLocalCapture` | `:163-198` | `kTVUOSMORTMPSourceIndex`(200)，`:172` | `TVUAVStreamOSMORTMP`，`:174` | 前台 `stopAudioCapture`；**后台反而 `startAudioCapture`**（`:179-183`）；`stopCaptureSession`（`:184`） |
| `resumeLocalCaptureIfNeeded` | `:205-231` | `kTVULocalCameraExternalSourceIndex`(−1)，`:214` | `TVUAVStreamCamera`，`:215` | 仅在主页 `startCaptureSession + startAudioCapture`（`:216-222`） |
| `forceResumeLocalCapture` | `:237-268` | 同上，`:242`（**无条件**） | 同上，`:243` | 主页且相机确实没跑才 start（`:252-255`）；mic 只在 `wasSuspended` 时 start（`:257-259`） |

**触发时机**：`suspendLocalCapture` 由**首个视频帧**触发，不是 publish 握手
（`:334-343`，`_firstVideoFrameReceived` 一次性标志）；理由见 `:97-98` 与 `:133-134`
—— 避免 server 启动后等待 DJI 接入这段时间麦克风帧（index=−1）一直被过滤刷 error log、
以及 preview 长时间静止。
`resumeLocalCaptureIfNeeded` 双路触发：`stop`（`:115`）与
`didStopPublishingStream:`（`:142`）。
`forceResumeLocalCapture` 是 watchdog 专用的硬恢复，跳过
`if (!_localCaptureSuspended) return` 守卫（`.h:55-64` 说明）。

### `suspendLocalCapture` 后台不停采集的原因

`:176-178` 注释：后台停采集会让后台失去唯一在跑的音频单元 → 「audio」后台模式失效 →
App 被系统杀。所以 `g_app_active_state == kTVUAPPActiveState_Background` 时反而
`startAudioCapture`，其采样由 `isSendAuidoToEncoder` 整体丢弃，不会污染 DJI 音频。
同一逻辑在 `TVUAnywhere.mm:453-462`（进后台/锁屏时若 `isDJIRTMPRunning` 就重启本地采集）。

### `+[TVURecorder isSendAuidoToEncoder]` 里的 OSMORTMP 条

```objc
// TVURecorder.mm:1417-1445
+ (BOOL)isSendAuidoToEncoder {
    TVUAVStreamManager *streamManager = TVUAVStreamManager::getInstance();
#if (defined _TVUIRLSDK)
    if (streamManager->streamType == TVUAVStreamOSMORTMP) {
        return NO;                                  // :1424-1426
    }
#endif
    if (isLocalFile && ... ) { return NO; }         // :1428-1443（外部源/本地文件那条，见 §2.5）
    return YES;
}
```

`:1420-1423` 注释：DJI 接管期间本地 mic 必须**整体丢弃**，不送编码器也不送屏幕分享 mic 队列
（否则与 DJI 音频混音污染）；后台保活时采集单元照跑，只丢采样。
两个调用点：`TVURecorder.mm:580`（Audio Unit 回调）与 `:800`（Audio Queue 回调）。

**这是 `#if (defined _TVUIRLSDK)` 独占的**，主 App 没有这条。

## 1.10 BLE 侧：确认无音频

`TVUIRLSDK/OSMORTMP/DJIBLE/` 全目录（15 个文件 + `Support/`）
`grep -ri audio` **零命中**。BLE 只做设备发现、配网、启停推流的控制面
（`TVUIRLDJIDevice` / `TVUIRLDJIDeviceScanner` / `TVUIRLDJIStreamManager` /
`TVUIRLDJIMessage` / `TVUIRLDJIDeviceMessage`），媒体面完全走 Wi-Fi RTMP。
唯一被音频链路用到的是 `DJIBLE/Support/TVUIRLSimpleTimer`（`BufferedAudio` 的出帧定时器）。

---

# 第二部分：Accsoon / SeeMo 音频（external_source_index = 5）

源索引：`kTVUExternalAccsoonIndex = 5`（`TVUAccsoonManager.mm:164`）。

## 2.1 USB 进来后的完整路径

### ① USB 库回调（Accsoon SDK 内部线程）

`TVUAccsoonManager.mm:290-294`：

```objc
rtmsuListener.audioDataHandler = ^(NSMutableData *adts, uint64_t timestamp) {
    self.audioStreamTime = [TVUDateTool getCurrentTimestamp];        // 活性时间戳，isLiveWithBulidInAudioStream 用
    self.audioErrorCode = [self acceptAudioData:adts andTimestamp:timestamp];
};
```

`:266` / `:272` / `:289` 三处注释都写着「all block callback in library inner thread，
take care of thread safety yourself」—— **线程名未确认**（在 Accsoon 闭源库
`Transmitter/Accsoon/libs` 内部）。

格式由 `audioChannelHandler` 上报（`:276-288`）：`channelMode` 1=Stereo / 0=Mono、
`sampleRate`、`bitwidth` 1=16bit / 0=8bit，存进静态结构 `tvu_AccsoonAudioInfo`（`:226`）。
`:274` 注释说硬件固定 AAC、48000 Hz、16bit。

### ② `acceptAudioData:andTimestamp:` — 剥 ADTS 头 + 打 PTS

`TVUAccsoonManager.mm:629-700`。五道前置闸门（都是"等视频先就绪"）：

| 返回码 | 条件 | 行号 |
|---|---|---|
| −1 | `first_video_frame_timestamp == 0` | `:642-645` |
| −2 | `frame_duration == 0` | `:647-650` |
| −3 | `total_frame_count == 0` | `:652-655` |
| −4 | `tvu_AccsoonAudioInfo == NULL`（还没收到 audioChannelHandler） | `:660-662` |
| −5 | `videoDecoder.externalSourceBaseTime == 0` | `:664-667` |
| −6 | `pts_us < 0` | `:683-690` |

```objc
int aac_size = audioData.length − kTVU_ADTS_HEADER_LEGHT;   // 7，:672；:670 注释：不剥会解码失败
memcpy(accBuffer, bytes + 7, aac_size);                      // :673-674，malloc/free 每帧一次
param.channel    = channelMode == 1 ? 2 : 1;                 // :677
param.sampleRate = tvu_AccsoonAudioInfo->sampleRate;         // :678
param.external_source_index = kTVUExternalAccsoonIndex;      // :679（=5）
param.time_base  = videoDecoder.externalSourceBaseTime;      // :680
param.pts        = (timestamp − first_audio_frame_timestamp) / tvu_timetamp_scale
                   + videoDecoder.externalSourceBaseTime;    // :682,692-693，单位：秒
[self.audioDecoder decode:&param];                            // :694
```

`externalSourceBaseTime` 由**视频**解码首帧回调锚定（`TVUExternalRTPStreamDecoder.mm:100-101`）
—— 所以音频 PTS 与视频共用同一基准。

### ③ `TVUExternalSourceAudioDecoder.decode:` — AAC → PCM（源规格）

`TVUExternalSourceAudioDecoder.mm:62-170`。用 **`AudioConverterRef`（AudioToolbox 软解）**，
不是 AVAudioConverter：

- 解码器在 `channel` / `sampleRate` 变化或首次时重建（`:72-84` → `setupDecoder:sampleRate:`）。
- `setupDecoder`（`:208-288`）：输入 `kAudioFormatMPEG4AAC` + `mFramesPerPacket = 1024`
  （`:229`）；**输出 PCM 的采样率和声道数 = 源的采样率和声道数**（`:214-215`），
  不在这一步转 48k。编解码器用 `kAppleSoftwareAudioCodecManufacturer`（`:238`）；
  iOS 18 上 `getAudioCalssDescriptionWithType:` 返回 NULL 会 crash，`:241-273` 手动构造
  `AudioClassDescription` 兜底（ITA-1161，注记在 `:242-252`）。
- 输出 buffer 大小 `pcmDataPacketSize(1024) × 2 × input_channel`（`:100-101`），
  一次 `AudioConverterFillComplexBuffer` 出 1024 帧（`:118`）。
- 输入回调 `AudioDecoderConverterComplexInputDataProc`（`:188-206`）回写
  `outDataPacketDescription`（AAC 是变长包，必须给 packet description）。

### ④ 重采样：libswresample（仅在需要时）

条件（`:80` 和 `:136`，两处判据相同）：
`input_channel != 2 || input_sampleRate != 48000`。

```objc
_ffmpegResample = [[TVUFFmpegResample alloc] initWithResampleDic:resample_dic andSrcNBSample:1024];  // :82
[_ffmpegResample convertor_feed_data:&data andLen:byteSize andOutSize:&outSize andOutBuffer:outData]; // :140
```

`getResampleDicWithParam:`（`:337-355`）：src/dst 都是 `AV_SAMPLE_FMT_S16`，
`dst_sample_rate = kTVUAudioSampleRate`（48000，`TVUConst.h:410`）、`dst_nb_channels = 2`。
实现是 `swr_convert`（`TVUFFmpegResample.mm:208-270`，`swr_get_delay` +
`av_rescale_rnd(AV_ROUND_UP)` 算输出帧数，输出 buffer 按需扩容）。
输出 buffer 预分配 `mDataByteSize × 5`（`:139`），足够 8k→48k（6×）以外的所有比例
—— **8 kHz 源会不够**（6144 帧 × 4 = 24576 > 1024×2×1×5 = 10240）；
Accsoon 硬件是 48 kHz（`:274` 注释）所以走不到这条，但这是个潜在越界，**未运行时验证**。

### ⑤ `TVUExtAudioEncoder::pushFrame` — 重新分包成固定 4096 字节

```objc
// 有重采样：TVUExternalSourceAudioDecoder.mm:153
TVUExtAudioEncoder::get_instance()->pushFrame(outData, outSize, userData.pts * 1000, param->external_source_index);
// 无重采样（源本就是 48k stereo）：:156
TVUExtAudioEncoder::get_instance()->pushFrame(mBuffers[0].mData, mBuffers[0].mDataByteSize, userData.pts * 1000, param->external_source_index);
```

注意 `pts × 1000` —— 到这里单位变成 **毫秒**。

`pushFrame` → `TVUExtPCMFrameList::pushFrame`（`TVUExtAudioEncoder.mm:309-318, 359-412`）：
把任意长度的输入**切/拼**进 50 个固定 `PCMBUFF_SIZE = 4096` 字节的槽位
（`PCMFRAMELIST_SIZE = 50`，`.h:69`；`PCMBUFF_SIZE`，`.h:36`）：

```
// 每个槽位的时间戳按已写入字节数补偿（mm:382-383）
movtime(ms) = dataposition / (m_dataSizePerSec / 1000)
pFramebuff->timestamp = frametime + movtime
// m_dataSizePerSec = sampleRate × channel × 2 （mm:324，由 setPara 传入 48000/2 → 192000）
// 槽位写满 4096 才 m_writeindex++ / m_count++ （mm:399-405）
```

`m_count >= 50` 时直接丢弃并打错误日志（`:369-372`）。
`setPara(48000, 2, 0, 1024)` 在 `TVUExternalSourceAudioDecoder.mm:50` 调用。

> **这一层是 Accsoon 与 DJI 最大的结构差异**：Accsoon 的块长被 `TVUExtPCMFrameList`
> **强制规整为 4096 字节**，无论源采样率如何；DJI 没有这一层，块长直接是
> `1024 × 48000/srcRate` 帧（§1.3）。

## 2.2 `TVUExtAudioEncoder::doencode()` — 消费线程

**方法体在 `TVUExtAudioEncoder.mm:182-275`**（任务里给的 130 是 `encodeFrame`，
一个空实现 `:125-128`）。

### 线程

`pthread_setname_np("tvu_ext_pcm_separator")`（`:133`，在 `encodeThread` 里）。
线程由 `startEncode()` 用 `pthread_create` 起（`:99-113`），
`endEncode()` 置 `_doExit` 并 `pthread_join`（`:115-123`）。
`startEncode` 的调用点是 `TVUExternalSourceAudioDecoder.mm:210`（`setupDecoder` 开头），
所以每次解码器重建都会尝试起线程 —— `:102` 只在 `__state != ENCODING` 时 create，
但 `doencode` 开头（`:184-188`）会挡住重入。

### 主循环

```objc
for (;;) {
    if (_doExit) break;                                       // :196-199
    TVUExtPCMFrame *pframe = __list.popFrame();
    if (pframe == NULL) { usleep(1000*10); continue; }         // :202-205，空转 10ms
    if (pframe->size == pframe->capacity) { /* 4096 才处理 */ } // :206
    else log4cplus_error("get raw data size error %ld != %ld") // :265-267
}
// 退出后：__list.clear(); __state = STOP; [[TVUAudioEncoderManager manager] stopEncoder];  :270-272
```

`pframe->size == pframe->capacity` 这道判据保证**送进 `encode:` 的一定是 4096 字节**。

### 组装 `TVUAudioEncoderData`（`:209-215`）

```objc
static TVUAudioEncoderData encodeParam = {0};       // 注意是 static
encodeParam.data       = pframe->buff;
encodeParam.size       = pframe->size;              // 恒 4096
encodeParam.channel    = kTVUAudioEncoderStereoChannel;   // 2
encodeParam.sampleRate = kTVUAudioEncoderSampleRate;      // 48000
encodeParam.pts        = pframe->timestamp / 1000.0;      // ms → 秒
encodeParam.external_source_index = pframe->external_source_index;
```

`pthread_mutex_unlock(&pframe->mutex)` 提前到 `:230` —— `:216-229` 的注记记录了原因
（ITA-824 死锁：锁范围套住 `TVUExternalSourceAudioMixerQueueManager` 的 `pthread_cond_wait`
会让主线程阻塞进而死锁）。

### 屏共改道（IRL 独占，`:231-239`）

```objc
#if (defined _TVUIRLSDK)
if ([TVUScreenRecordingServerSocketManager manager].isReceivingFrame) {
    tvuSendAudioToScreenShare(pframe->buff, pframe->size, encodeParam.pts, kTVUAudioEncoderStereoChannel);
    pframe->size = 0;
    continue;
}
```

`tvuSendAudioToScreenShare`（`:144-158`）与 DJI 版本（`RTMPIngestController.mm:47-60`）
结构完全相同，唯一差异是 `param.sampleRate` 用 `kTVUAudioSampleRate`（`TVUConst.h:410`）
而 DJI 用 `kTVUAudioEncoderSampleRate`（`TVUAudioEncoderManager.h:16`）—— **两个常量都是 48000**。
`TVUShareScreenConfigShareScreenAudioOnlyType` 时整帧丢弃（`:146-148`）。

### `switch (streamType)` 四个分支（`:246-261`）

```objc
switch (TVUAVStreamManager::getInstance()->streamType) {
    case TVUAVStreamExternalSourcePIP:
    case TVUAVStreamExternalSourcePBP:
    case TVUAVStreamExternalSource:
    {
        if (streamType == TVUAVStreamExternalSource && ![[TVUAnywhere manager] tvuIsReplaceBackgroundStart]) {
            tvuEncodeOrMixExternalSourceAudio(&encodeParam);                       // :252  ← 纯外部源
        } else {
            TVUExternalSourceAudioMixerQueueManager::manager()
                ->addDataToAudioMixer(&encodeParam, sourceQueue[TVUAudioMixerSourceExternalSource]);  // :254
        }
    }
    break;
    default:
        [[TVUAudioEncoderManager manager] encode:&encodeParam];                     // :259
        break;
}
```

四个分支的语义（`case` 是 3 个 + `default`，落地 3 条去向）：

| 分支 | 条件 | 去向 |
|---|---|---|
| A | `streamType == ExternalSource && !tvuIsReplaceBackgroundStart` | `tvuEncodeOrMixExternalSourceAudio()`（**Accsoon/SeeMo 正常走这条**，因为 `parseStart` 把 streamType 设成了 `ExternalSource`） |
| B | `streamType ∈ {PIP, PBP}`，或 `ExternalSource && tvuIsReplaceBackgroundStart` | 塞 `TVUExternalSourceAudioMixerQueueManager` 的 `[ExternalSource]` 路，与本地 mic 前置混音 |
| C | `default`（Camera / OSMORTMP / 其它） | 直送 `encode:` |

> C 分支在 Accsoon 场景下是**竞态兜底**：`parseStart` 是 `dispatch_async` 到主线程设
> streamType 的（`TVUIRLAccsoonHandler.mm:188-199`），首帧音频可能早于它到达，
> 此时 streamType 还是 `Camera` → 走 C → 因 index 不匹配被 `encode:` 的闸门丢弃。
> 这是**推断**，未运行时验证。

### `tvuEncodeOrMixExternalSourceAudio()`（`:33-42`）

```objc
static void tvuEncodeOrMixExternalSourceAudio(TVUAudioEncoderData *param) {
#if (defined _TVUIRLSDK)
    if ([TVUSnapshotManager manager].shouldOutputAudioStream) {
        TVUOverlayAudioMixerManager *mixer = TVUOverlayAudioMixerManager::manager();
        mixer->addDataToAudioMixer(param, mixer->sourceQueue[TVUAudioMixerSourceLocalCamera]);
        return;
    }
#endif
    [[TVUAudioEncoderManager manager] encode:param];
}
```

**作用**：SPAR-769 —— 朗读要混进流时，把外部源音频改道 `TVUOverlayAudioMixerManager`
**当主源（节拍源）**，与 `aacEncoder.mm` 里 mic 的分叉同构；否则直送 `encode:`。
`:30-32` 注释解释了为什么本地 mic 不会来抢主源队列：SeeMo 接管时
`TVUIRLAccsoonHandler.parseStart` 置了 `isLocalFile = true`，mic 在
`isSendAuidoToEncoder` 就被丢弃。单独抽成函数只为把 `#if` 隔在 `switch` 外面。

**与 DJI 的对称性**：DJI 的等价分叉在 `RTMPIngestController.mm:417-421`，
用同一个开关、同一条队列、同一个 `TVUAudioMixerSourceLocalCamera` 主源槽位。
两者不会同时活跃（DJI 接管时 streamType 是 OSMORTMP，Accsoon 是 ExternalSource）。

## 2.3 `tvuApplyExternalSourceCaptureGain()` 增益施加点

**定义** `TVUExtAudioEncoder.mm:165-179`（整段在 `#if (defined _TVUIRLSDK)` 内，`:160-180`）。
**调用点 `:241-244`**：

```objc
// 非屏幕分享: Accsoon 不经本地采集链, 在送编码器前对 PCM 施加同一增益, 让 Mute 开关生效。
float captureGain = [[TVUAudioCaptureManager manager] getAudioCaptureGain];
if (captureGain != 1.0f) {
    tvuApplyExternalSourceCaptureGain((uint8_t *)pframe->buff, pframe->size, captureGain);
}
```

算法与 DJI 的 `applyCaptureGain:toInterleavedInt16PCM:byteLength:`
（`RTMPIngestController.mm:428-441`）**逐行相同**（同样的 MAX/MIN、同样的 `f += (1−f)/32`
软限幅），只是签名从 ObjC 方法换成 C 函数、参数顺序不同。
`:161-164` 的注释也明确说是 mirror 了 `RTMPIngestController` / `TVURecorder` 的实现。

**位置很关键**：在屏共改道（`:235-239`）**之后**、`switch` （`:246`）**之前**。
即屏共时不预施加（队列的 `adjustAudioGain` 会施加），其它三条路都已施加。
**in-place 修改 `pframe->buff`**，所以 `encodeParam.data` 指向的就是改过的数据。

## 2.4 `isLiveWithBulidInAudioStream` — 无音频流时的内置 mic 兜底

**定义** `TVUAccsoonManager.mm:711-733`。返回 YES 的**全部**条件：

```objc
if (!isConnectedAccessory || !isAccessoryWorking)                     return NO;   // :713-715
if (first_video_frame_timestamp == 0 || total_frame_count == 0)       return NO;   // :716-718
if (isHaveShowAbnormalAlert)                                          return NO;   // :720-722
return ([TVUDateTool getCurrentTimestamp] − audioStreamTime) > 1.0;                // :724-732
```

即：**设备插着且在工作 + 视频已经在跑 + 没弹异常告警 + 超过 1 秒没收到任何音频包**
（`audioStreamTime` 由 `audioDataHandler` 每帧刷新，`:292`；`startUsbWork` 里初始化，`:332`）。
`TVU_AUDIO_MAX_IINTERVAL = 1.0`（`:710`）。
头文件注释（`TVUAccsoonManager.h:71-76`）：「目前在没有音频流的情况下才会触发」。

**场景**：Accsoon/SeeMo 设备只出视频不出音频（型号差异 / 未插麦 / 音频通道故障）。

### 为什么能绕过编码器的 index 守门，而且只在主 App

`TVUAudioEncoderManager.mm:249-271` 是一段 `#if / #else`：

```objc
#if (defined TVU_HIT_ME) || (defined _TVUSDKANYWHERE)
  #if (defined _TVUIRLSDK)
    if (![TVUScreenRecordingServerSocketManager manager].isReceivingFrame
        && param->external_source_index != self.external_source_index)          // :252  ← IRL：没有 bypass
  #else
    if (param->external_source_index != self.external_source_index)             // :254
  #endif
#else
    BOOL isAccsoonWithBuildIn = [[TVUAccsoonManager manager] isLiveWithBulidInAudioStream];   // :264
    if (![...].isReceivingFrame && !isAccsoonWithBuildIn
        && param->external_source_index != self.external_source_index)          // :265  ← 主 App：有 bypass
#endif
{ log; unlock; return; }
```

`:258-263` 的注记（alfredfu 2024-05-22）：「是否在连接 Accsoon 的时候，使用内置 mic 的声音。
在这里添加，防止索引的判断过滤掉。」

**机理**：Accsoon 工作时编码器的 `external_source_index` 被设成 5
（`TVUExternalRTPStreamDecoder.mm:100-106`，视频解码首帧回调里 `updateExternalSourceIndex:`），
而内置 mic 的帧带 index = −1 → 不等 → 本该被 `:265` 丢弃。
`isAccsoonWithBuildIn` 把这道守门短路掉，让 mic 帧进入编码。

**为什么只在主 App**：这段 bypass 写在 `#else` 分支里，即
`TVU_HIT_ME` / `_TVUSDKANYWHERE` **都没定义**的构建（主 Transmitter App）。
IRL SDK 走的是 `#if` 里的 `_TVUIRLSDK` 子分支（`:252`），**没有** `isAccsoonWithBuildIn` 项。

### mic 内容会被静音

`TVURecorder.mm:570-601`（Audio Unit 回调）：

```objc
isAccsoonWithBuildIn = [[TVUAccsoonManager manager] isLiveWithBulidInAudioStream];  // :573(IRL) / :576(主App)
if (![TVURecorder isSendAuidoToEncoder] && !isAccsoonWithBuildIn) { drop; }         // :580 ← bypass 第一道
...
if (voiceState == Slience || isAccsoonWithBuildIn) { memset(bufferData, 0, bufferSize); }  // :598-600
```

`:564-568` 注记：「当检测 Accsoon 设备没有音频流时候，使用内置 mic 的音频流，
**并且把音频流设置成静音**」。所以这条兜底的目的不是"用手机麦当替代音源"，
而是**保住一条有效的静音音轨**（避免下游因音频断流出问题）。

> ⚠️ **IRL 侧这条兜底事实上到不了编码器**：`TVURecorder.mm:573` 的 bypass 在 IRL 存在
> （mic 静音帧不被 `:580` 丢），但 `TVUAudioEncoderManager.mm:252` 的 index 守门在 IRL
> **没有** `isAccsoonWithBuildIn` 短路 → index −1 ≠ 5 → 帧仍被丢。
> 这是**读码推断**，**未运行时验证**（见 §3）。
> Audio Queue 那条回调（`TVURecorder.mm:800`）连 `isAccsoonWithBuildIn` 都不判，
> 直接按 `isSendAuidoToEncoder` 丢。

## 2.5 `isLocalFile` 在 Accsoon 场景下怎么用

**全局标志**，定义在 `TVUAnywhere.mm:130`（`bool isLocalFile = false;`），
5 个文件 `extern` 引用（`MainViewController.mm:72`、`TVUExternalSourceView.mm:49`、
`TVUInputSourceParseModule.mm:24`、`TVURecorder.mm:118`、`TVUIRLAccsoonHandler.mm:41`）。

### Accsoon 侧的三个写入点（都在 `TVUIRLAccsoonHandler.mm`）

| 位置 | 值 | 时机 |
|---|---|---|
| `parseStart`（`:185-200`，`isLocalFile = true` 在 `:197`） | `true` | 收到 `kTVUExternalSourceParseStart` 通知（由 `TVUExternalRTPStreamDecoder.mm:105` 在视频解码首帧发出）；同时把 `streamType` 设为 `TVUAVStreamExternalSource`（`:195`）并 `tvuStopVideoCapture`（`:196`） |
| `parseFinish`（`:202-219`，`isLocalFile = false` 在 `:214`） | `false` | 收到 `kTVUExternalSourceParseFinish`；**只在 `liveViewDidAppear` 为真时才置回**（`:211-215`） |
| `handleAppDidEnterBackground`（`:111-125`，`:121`） | `false` | 进后台，同时 streamType 回 Camera、`updateExternalSourceIndex:-1`（`:118-120`） |

两个通知都 `tvu_dispatch_main_async_safe` 到主线程串行化
（`:186-188` / `:203-206` 注释：通知可能来自 VT 解码线程或 USB 库内部线程）。

### 它如何让 mic 被丢

`TVURecorder.isSendAuidoToEncoder`（`:1428-1443`）：

```objc
if (isLocalFile &&
    streamType != TVUAVStreamExternalSourcePIP &&
    streamType != TVUAVStreamExternalSourcePBP &&
    (streamType == TVUAVStreamExternalSource && ![[TVUAnywhere manager] tvuIsReplaceBackgroundStart])
    && ![TVUScreenRecordingServerSocketManager manager].isReceivingFrame      // :1435（IRL）
) {
    return NO;
}
```

Accsoon 正常工作时：`isLocalFile == true`（parseStart 置）、
`streamType == TVUAVStreamExternalSource`（parseStart 置）、
`tvuIsReplaceBackgroundStart == false`、屏共未开 → **返回 NO → mic 整体丢弃**。
这正是 `TVUExtAudioEncoder.mm:30-32` 注释所依赖的前提
（「本地 mic 不会来抢主源队列」）。

PIP / PBP / ReplaceBackground 场景下条件不成立 → mic 照送 → 与外部源在
`TVUExternalSourceAudioMixerQueueManager` 里前置混音（对应 §2.2 的 B 分支）。

> 名字容易误导：`isLocalFile` 在 Accsoon 场景下表达的不是"本地文件"，而是
> **"视频源已被某个外部源接管"**。这个变量同时被本地文件外部源
> （`TVUExternalSourceView.mm` / `TVUInputSourceParseModule.mm`）复用。

---

# 第三部分：不确定 / 需运行时验证的点

按重要性排序。

## ① DJI OA5 Pro 的 AAC 采样率 —— 决定 §1.3 是否是真问题

**未确认**。代码只按 AudioSpecificConfig 解析，没有任何地方假定 48 kHz。
`TVUIRLAudioDecoder.m:59-61` 的日志会打出来：

```
rtmp-server: AAC type=%@ sampleRate=%.0f Hz channels=%u ... → PCM 48000 Hz stereo Int16
```

**验证**：抓一次 DJI 推流的日志，找这一行看 `sampleRate`。
若是 48000，§1.3 的全部推论都不构成实际风险；若不是，需要在
`TVUIRLAudioDecoder` 出口做 4096 字节重分包（Accsoon 那样的
`TVUExtPCMFrameList` 机制）才能不丢音频。

## ② `AudioConverterFillComplexBuffer` 对"超量输入 + 未回写 ioNumberDataPackets"的行为

**未确认**。`AudioEncoderConverterComplexInputDataProc`
（`TVUAudioEncoderManager.mm:695-710`）不回写 `*ioNumberDataPackets`、
不维护消费游标。当 `param->size > 4096` 时 Apple 的取舍未文档化
（截断 / 报错 / 反复回调同一块）。

**验证**：构造一次 44.1 kHz 的 AAC 推流（或直接在 `encode:` 里注入 4460 字节块），
看 `:365` 的 status 返回值和 `outputPacketDescriptions.mDataByteSize`，
并用录音旁路（`tvuIsEnableRecordCBR`）对比时长是否被压缩 ≈8%。

## ③ Accsoon 8 kHz 源时重采样输出 buffer 可能越界

`TVUExternalSourceAudioDecoder.mm:139` 分配 `mDataByteSize × 5`；
8 kHz→48 kHz 需要 6 倍。硬件注释（`TVUAccsoonManager.mm:274`）说固定 48 kHz，
所以现实中走不到。**未运行时验证**，也不确定是否存在别的低采样率外部源共用这条路径。

## ④ IRL 上 `isLiveWithBulidInAudioStream` 兜底是否真的失效

§2.4 的推断：IRL 缺 `TVUAudioEncoderManager.mm` 侧的 bypass，静音 mic 帧应被 index 守门丢弃。
**未运行时验证**。
**验证**：IRL + SeeMo（拔掉音频源）开播，看是否出现
`external source index is different, current parse index: 5, buffer index: -1`
（`TVUAudioEncoderManager.mm:268`）持续刷屏，且流里完全没有音轨。

## ⑤ Accsoon 首帧音频早于 `parseStart` 的竞态

§2.2 的 C 分支推断。`parseStart` 是 async 到主线程的，音频消费线程
（`tvu_ext_pcm_separator`）可能先跑到 `switch`。
**未运行时验证**，也不确定实际时序上是否可能（`acceptAudioData` 有
`externalSourceBaseTime == 0` 闸门，而该值和 `parseStart` 通知在
`TVUExternalRTPStreamDecoder.mm:100-106` 是同一处同步设置的 —— 可能天然排除了竞态）。

## ⑥ Accsoon USB 回调的线程名

**未确认**。回调发生在 Accsoon 闭源库内部线程（`Transmitter/Accsoon/libs`），
源码里只有「library inner thread」的文字说明（`TVUAccsoonManager.mm:266,272,289,296,301`）。
**验证**：在 `audioDataHandler` 里打 `pthread_getname_np` 或
`[NSThread currentThread]`。

## ⑦ `MediaClock` 是死代码还是待接线

`server:didUpdateTargetVideoLatency:audioLatency:` 全仓无实现（§1.6）。
不确定这是"故意留白等后续接"还是"接线漏了"。
`BufferedAudio.setTargetLatency:` / `BufferedVideo.setTargetLatency:` 也因此无人调用。
**需与作者确认意图**，代码本身无法判定。

## ⑧ 三处已过期的注释（代码正确、注释错误，非行为问题）

| 位置 | 注释说 | 实际 |
|---|---|---|
| `TVUIRLBufferedAudio.h:7` | underrun 输出「填零静音」 | `.m:156-159` 不输出、等真帧 |
| `TVUIRLDriftTracker.h:10` | master(audio) 算 drift 喂 slave(video) | 音频侧没有 DriftTracker，只有 video 用 |
| `TVUIRLMediaPipeline.m:352` | latency 默认 2000ms | `kTVUIRLDJIDefaultLatency = 1000`（`TVUIRLDJIStreamModel.m:15`） |
| `TVUIRLStreamConnection.m:723-733` | basetime 在 **video** 首帧锚定；audio 未就绪时整帧丢弃 | 已改成 audio 主导（`:786-788` 是新注释），旧段落未删 |

## ⑨ 一个跨源的全局隐患（代码事实，影响面未验证）

`TVUAudioEncoderManager.mm:171` 的 `static Float64 last_audio_pts` 是
**全进程单一静态量**，所有音源（mic / DJI / Accsoon / 屏共 / 外部源 / 混音出口）共用。
源切换瞬间若新源的 PTS 基准比旧源低，会连续丢帧直到新源 PTS 追上。
DJI 侧的单调 clamp（§1.4 ④）只保证**自己**单调，不解决跨源跳变。
Accsoon 侧没有任何 clamp。**影响面未运行时验证。**
