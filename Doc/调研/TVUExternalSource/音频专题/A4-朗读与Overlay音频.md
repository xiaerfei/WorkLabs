# A4 弹幕朗读（TTS）与 Overlay 音频注入

> 基线：分支 `share/SPAR-705` @ `736863f1f4f9700e65c95b4e561c1aeba1846819`（2026-08-25）。
> 代码根目录 `products/TVUTransportIOS/TVUAnywherePro/`，本文所有行号均以该 checkout 实测为准。
> 接线总览见 [A0-音频链路总表.md](./A0-音频链路总表.md)；汇聚点（编码器）见
> [07-音频编码器-TVUAudioEncoderManager.md](../07-音频编码器-TVUAudioEncoderManager.md)。
>
> 本篇覆盖 `TVUOverlayAudioMixerManager` 这一套**三路前置混音器**，以及它两个辅源的生产链：
> 弹幕朗读（TTS）和 Overlay 网页声（Web Audio 抓取）。

---

## 目录

- [一、三路混音器 `TVUOverlayAudioMixerManager`](#一三路混音器-tvuoverlayaudiomixermanager)
- [二、TTS 朗读链路](#二tts-朗读链路)
- [三、Overlay Web Audio 链路](#三overlay-web-audio-链路)
- [四、上游改道：`shouldOutputAudioStream`](#四上游改道shouldoutputaudiostream)
- [五、三路块规格 / PTS / 启停 汇总表](#五三路块规格--pts--启停-汇总表)
- [六、不确定 / 需运行时验证的点](#六不确定--需运行时验证的点)

---

## 一、三路混音器 `TVUOverlayAudioMixerManager`

文件：`Transmitter/TVUOverlays/AudioMix/TVUOverlayAudioMixerManager.h` / `.mm`
线程名：`TVUOverlayAudioMixerManagerThread`（`TVUOverlayAudioMixerManager.mm:252`）

### 1.1 三路队列的语义与生产者

`sourceQueue[]` 长度由**本文件独立定义**的 `kTVUOverlayMixerQueueCount = 3`
（`TVUOverlayAudioMixerManager.h:28`）决定 —— 刻意不改共享的 `kTVUAudioMixerSourceSize`
（`TVUExternalSourceAudioMixerQueueManager.h:15`，那个还被 PIP/PBP 那套用来开数组）。

| 下标 | 常量 | 语义 | 生产者（调 `addDataToAudioMixer` 的地方） |
|---|---|---|---|
| 0 | `TVUAudioMixerSourceLocalCamera`（`TVUExternalSourceAudioMixerQueueManager.h:28`） | **本地采集 = 主源 / 节拍源** | `aacEncoder.mm:304`（mic）<br>`TVUExtAudioEncoder.mm:37`（外部源 / Accsoon）<br>`RTMPIngestController.mm:419`（DJI RTMP） |
| 1 | `TVUAudioMixerSourceExternalSource`（`…QueueManager.h:29`） | Overlay 网页声 | `TVUWebviewAudioOutputManager.mm:155` |
| 2 | `kTVUOverlayMixerQueueIndexTTS`（`TVUOverlayAudioMixerManager.h:35`） | 弹幕朗读（TTS） | `TVUChatTTSManager.mm:482` |

第 0 路的三个生产者是**互斥的三种主源**，选谁由 `shouldOutputAudioStream` 分流决定，见 [§四](#四上游改道shouldoutputaudiostream)。

构造时给每一路打 `sourceType` 标签（`TVUOverlayAudioMixerManager.mm:41-43`）：只有第 0 路是
`TVUAudioMixerSourceLocalCamera`，第 1/2 路都归 `TVUAudioMixerSourceExternalSource`。
这个标签唯一的作用是决定「free 队列取不到 node 时怎么办」——主源直接返回丢块，辅源进
1 秒超时等待（`TVUOverlayAudioMixerManager.mm:74-121`）。

**标志位 ≠ 数组下标。** `TVUOverlayMixerSource` 是按位标志
（`None=0` / `Overlay=1<<0` / `TTS=1<<1`，`TVUOverlayAudioMixerManager.h:18-22`），
和上面的数组下标是两套东西，头文件 `:32-34` 明确警告现在数值撞上（都是 1、2）纯属巧合。
`queueForSource()` 就是这两套之间的唯一翻译层（`TVUOverlayAudioMixerManager.mm:149-156`）：

```cpp
case TVUOverlayMixerSourceOverlay: return sourceQueue[TVUAudioMixerSourceExternalSource];
case TVUOverlayMixerSourceTTS:     return sourceQueue[kTVUOverlayMixerQueueIndexTTS];
default:                           return sourceQueue[TVUAudioMixerSourceLocalCamera];
```

> ⚠️ `default` 分支把「任何非 Overlay/TTS 的值」都映射到主源队列，包括 `TVUOverlayMixerSourceNone`
> 和 `Overlay|TTS` 这样的组合值。目前没有调用方传这些值，但这是个静默的错路由风险。

### 1.2 `start` / `stop` / `isSourceActive` 全调用表

| 方法 | 调用点 | 触发时机 / 条件 |
|---|---|---|
| `start(Overlay)` | `TVUWebSnapshotManager.mm:130` | `checkAudioOutputState` 里，任一 `TVUWebSnapshotView.shouldOutputAudioStream` 为真 |
| `stop(Overlay)` | `TVUWebSnapshotManager.mm:132` | 同上，全部为假 |
| `start(TTS)` | `TVUChatTTSManager.mm:334` | `applyMixerState` 里 `mixesIntoStream == YES` |
| `stop(TTS)` | `TVUChatTTSManager.mm:336` | `applyMixerState` 里 `mixesIntoStream == NO` |
| `isSourceActive(TTS)` | `TVUChatTTSManager.mm:322`（`mixerRunningForStream`） | 供 `shouldOutputAudioStream` 判断「本地采集要不要改道」 |
| `isSourceActive(TTS)` | `TVUChatTTSManager.mm:472`（`drainStreamAccumFromTimer`） | 入队前紧贴着的最后一道闸 |
| `queueForSource(TTS)->resetWorkQueue()` | `TVUChatTTSManager.mm:333`（开之前清积压）、`:530`（`dropPendingStreamAudio`） | — |

**`start(Overlay)` / `stop(Overlay)` 的上游条件链**
（`TVUWebSnapshotManager.mm:116-135`，整段包在 `#if (defined _TVUIRLSDK)` 里）：

```objc
- (void)checkAudioOutputState {
    BOOL shouldOutput = NO;
    for (TVUWebSnapshotView <TVUSnapshotProtocol> *webSnap in self.snapMaps) {
        if (webSnap.shouldOutputAudioStream) { shouldOutput = YES; break; }
    }
    self.shouldOutputAudioStream = shouldOutput;
    if(self.shouldOutputAudioStream){
        TVUOverlayAudioMixerManager::manager()->start(TVUOverlayMixerSourceOverlay);
    }else{
        TVUOverlayAudioMixerManager::manager()->stop(TVUOverlayMixerSourceOverlay);
    }
}
```

单个 view 的开关是 `TVUWebSnapshotView.mm:267`：

```objc
self.shouldOutputAudioStream = overlayItem.enableAudioStreamOutput
                            && overlayItem.viewMode == TVUOverlayURLViewModeLive;
```

`checkAudioOutputState` 的三个调用点：`TVUWebSnapshotManager.mm:97`（插入 overlay）、
`:113`（移除 overlay）、`:163`（重置 overlay 属性）。

`enableAudioStreamOutput` 是 overlay item 上的持久化开关，来源：
- 设置页开关：`TVUOverlaySettingVC.mm:650-655`（cell 的 `keyName` 在 `TVUOverlayItemCell.mm:195`）
- 默认值：`TVUOverlayItem.m:141`（`NO`）/ `:146`（`YES`，另一个分支）
- Preview 模式下强制关：`TVUOverlaySettingVC.mm:713-714`
- **同时只允许一个带音频的 overlay**：`TVUOverlayWindow.mm:510-514`，插入第二个时提示
  `Only support one overlay audio mixing with microphone` 并把开关持久化成 `NO`。
  这里刻意读 `[TVUWebSnapshotManager manager].shouldOutputAudioStream` 而不是
  `TVUSnapshotManager` 那个 —— 后者含了 TTS 的 mix，会导致「朗读一开就再也插不进带音频的 overlay」
  （`TVUOverlayWindow.mm:507-509` 注释）。

**`start(TTS)` / `stop(TTS)` 的上游条件链** = `TVUChatTTSManager.mixesIntoStream`
（`TVUChatTTSManager.mm:303-306`）：

```objc
return self.enabled && _outputMode == TVUChatTTSOutputBoth && _streamMixReady;
```

三项拆开是**六个条件**（`TVUChatTTSManager.h:59-61`）：

| 条件 | 来源 |
|---|---|
| 朗读引擎开着（`engine != Off`） | `TVUChatTTSManager.mm:295-297` |
| mix 开关开着（`outputMode == Both`） | `TVUChatTTSManager.mm:406`（setter 持久化 + `applyMixerState`） |
| 本机正在推到弹幕平台 | `TVUWebChatManager.m:208`（`TVUIRLLiveStatus.outputChatPlatformLiving`） |
| 聚合弹幕 html 正在显示 | `TVUWebChatManager.m:221`（`self.aggregateDisplaying`） |
| overlay 的 mode 是 Preview & Live | `TVUWebChatManager.m:210`（`chatModel.viewMode == Live`） |
| 音频输出不是内建扬声器 | `TVUWebChatManager.m:216-220` |

后四个汇聚成 `streamMixReady`（`TVUWebChatManager.m:221`），由 `syncStreamMixReady` 计算，
其 setter（`TVUChatTTSManager.mm:310-314`）触发 `applyMixerState`。
`syncStreamMixReady` 的调用点：`TVUWebChatManager.m:153`（html 显示）、`:175`（关窗）、
`:695`（`TVUIRLEventChatPlatformLivingChanged`）、`:708`（`TVUIRLEventMicDeviceChanged` 借作路由变化）、
`:716`（`TVUIRLEventDJIStreamingChanged` / `TVUIRLEventAccsoonCameraWorkingChanged`）、
`:913`（改 viewMode）。

`applyMixerState` 的三个入口：`loadPersistedEngine`（`TVUChatTTSManager.mm:283`，启动读持久化后必须对齐一次）、
`setEngine:`（`:395`）、`setOutputMode:`（`:418`）、以及 `setStreamMixReady:`（`:313`）。

### 1.3 幂等语义

`start` / `stop` 用**按位标记**而不是引用计数（`TVUOverlayAudioMixerManager.h:77-79`）：
overlay 那边是「应用当前状态」式调用、会反复调，计数会一路加上去减不回来。

- `start`（`.mm:171-187`）：`activeSources |= source`；只有从 `None` 变成非 `None` 时才
  `threadSuspend = false` + `pthread_cond_broadcast`，并把 `lastLocalNodeMs` 重置为当前时刻。
- `stop`（`.mm:189-214`）：`activeSources &= ~source`；变成 `None` 时才 `threadSuspend = true`。
  **只清停掉那一路自己的 workQueue**（`.mm:201`），主源队列只在真的挂起时才清（`.mm:203`）——
  注释 `.mm:199-200` 说明这是修过的 bug：以前无条件清所有源，关掉朗读会把 overlay 正在排的音频一起丢掉。
- 最后唤醒可能卡在「等空闲 node」的写入方（`.mm:208-213`）。

### 1.4 `activeSources` / `lastLocalNodeMs` 的无锁设计（与注释核对）

头文件声明（`TVUOverlayAudioMixerManager.h:105` / `:110`）：

```cpp
volatile TVUOverlayMixerSource activeSources;   // 只在持有 mutex 时写，读不加锁
volatile int64_t lastLocalNodeMs;               // 完全无锁
```

**核对结果：基本一致，有两处小偏差。**

`activeSources` 的写入点：

| 位置 | 是否持 `mutex` | 备注 |
|---|---|---|
| `.mm:46`（构造函数） | 否 | 线程还没创建，无竞争，符合意图 |
| `.mm:174`（`start`） | ✅ 是 | |
| `.mm:192`（`stop`） | ✅ 是 | |
| `.mm:242`（`endThread`） | ❌ 否 | 且此时 `mutex` 已被 `destroy`（`.mm:235`）。**但 `endThread` 全仓零调用方**，见下 |

读取点：`isSourceActive`（`.mm:168`，无锁，注释 `.mm:160-167` 解释得很详细：本方法在音频采集
线程上每块调一次≈21ms 一次，而 `mutex` 被混音线程在整个 `audioMixer()` 期间持有、里面还有
`usleep(20ms)`，加锁会直接掉块）、`audioMixer()`（`.mm:309` / `:313`，本身跑在 `mutex` 里，安全）、
`audioMixer()` 里的静音丢弃判定（`.mm:287` / `:290`）。

`lastLocalNodeMs`：写 = `addDataToAudioMixer`（`.mm:68`，采集线程，**故意放在所有早返回之前**，
因为要的信号是「采集侧确实在送」而不是「入队成功」）+ `start`（`.mm:182`，持锁）；
读 = `audioMixer`（`.mm:286`）。**与注释完全一致。**

时钟用 `CLOCK_MONOTONIC`（`.mm:14-18`，`tvuMixerNowMs()`），注释明确说不能用
`CLOCK_REALTIME`（用户改系统时间会跳）。

> ⚠️ `endThread()`（`.mm:216-247`）头上有一段自述缺陷的注释：全仓零调用方、单例从不析构；
> 三个队列只置 `NULL` 不 `delete`（泄漏）、置 `NULL` 后 `queueForSource()` / `audioMixer()`
> 会 NULL 解引用、`mutex` 已 destroy 后续 `start/stop` 是 UB。已核实：`endThread` 在
> `products/` 下确实只有定义没有调用。

### 1.5 `audioMixer()` 主循环（`.mm:269-382`）

调用链：`startThreadTask`（`.mm:250`，设线程名）→ `audioMixerThread`（`.mm:257-267`）→ `audioMixer`。

`audioMixerThread` 的形状值得注意：

```cpp
while (!threadToEnd) {
    pthread_mutex_lock(&mutex);
    if (threadSuspend) {
        pthread_cond_wait(&cond, &mutex);
    }
    audioMixer();                 // ← 整个 audioMixer() 都在 mutex 里跑（含 usleep 20ms）
    pthread_mutex_unlock(&mutex);
}
```

**取节点顺序**：

1. **先看主源水位**（`.mm:271`）：`sourceQueue[LocalCamera]->workQueueSize() <= 0` 就走静音判定，
   `usleep(20ms)` 后 return —— 主源是节拍源，没有主源块这一轮就什么都不混。
2. **静音判定**（`.mm:286`）：`tvuMixerNowMs() - lastLocalNodeMs >= kTVUOverlayMixerLocalSilenceDropMs`
   （`= 1000` ms，`.h:40`）才丢辅源队列，并且**只丢在用的那一路**（`.mm:287-292`）。
   `.mm:272-285` 的 SPAR-753 注释解释了为什么不能用「此刻 mic 队列为空」当判据：
   mic 是 21.33ms 一块的节拍源，混完立刻回到循环开头时下一块还没到，**空队列恰恰是正常工作时的常态**
   （一秒约 47 次）；而朗读是突发写入（一批 22~59 块 = 0.5~1.26 秒语音），旧判据下每批只有第一块
   混得出去、其余整队被清 —— 实测一分钟丢掉 716 块 ≈ 15 秒朗读。
3. 出主源节点（`.mm:298`），`NULL` 直接 return（`.mm:301-303`）。
4. **按位取辅源**（`.mm:307-316`）：`activeSources` 里没有那一位就连队列都不碰。
5. **混音缓冲按需扩容**（`.mm:318-330`）：`static uint8_t *data_mix` + `data_mix_capacity`，
   注释说原来是 `malloc(size*2)` 一次就不管，块变大会溢出。
6. **块长校验**（`.mm:332-348`）：

```cpp
if (overlay_node->size == local_node->size) others[otherCount++] = ...;
else log4cplus_error(... "overlay block size %d != mic %d, skip mixing it" ...);
```
   同样的判断对 `tts_node`（`.mm:343-348`）。注释 `.mm:332-334` 说明理由：`mix()` 按 mic 的长度
   逐样本读，辅源短了就越界读；三路现在都是 4096 字节（1024 帧 × 双声道 × int16），
   不一致宁可不混也不能读野内存。
7. `otherCount == 0` 时**直接 memcpy 主源**（`.mm:351`），否则调 `mix()`（`.mm:353-355`）。
8. 送编码器（`.mm:357-367`），归还节点（`.mm:369-374`），唤醒等待方（`.mm:376-381`）。

**归还节点必须判空**（`.mm:373-374`）：注释 `.mm:370-372` 说取不到辅源节点是**正常情况**
（那一路没开，或开着但此刻没数据 —— 朗读的消息间隙），而 `resetNode(NULL)` 会打 error 日志，
本方法每 21.33ms 跑一轮，无条件调用就是每秒几十条日志。

### 1.6 `mix()` 算法（`.mm:384-424`）

```cpp
void mix(uint8_t *mic, uint8_t **others, int sourceCount,
         uint8_t *mix_data, int buffer_size, double coefficient)
```

- 逐 int16 样本（`for i < buffer_size/2`）。
- **mic 原样叠加，不乘系数**（`.mm:398`）。
- 其余各路（overlay / TTS）**都乘同一个 `coefficient`**（`.mm:402-404`）—— 这就是 ducking：
  系数按 mic 的音量算出来，主播说话时自动把辅源压低。
- 系数来源（`.mm:353-354`）：`tvuGetVolumeScale(getPcmDB((char *)local_node->data, local_node->size))`
  - `getPcmDB`（`TVUAnywhereTool.h:284-307`）：取块内峰值 → dB → 归一化到 0~60
  - `tvuGetVolumeScale`（`TVUAnywhereTool.h:324-327`）查表 `tvuVolumeScale[61]`，表由
    `tvuInitVolumeScaleMap()`（`:318-322`）在混音器构造时初始化（`TVUOverlayAudioMixerManager.mm:55`）
  - `getMixCoefficient`（`TVUAnywhereTool.h:309-314`）：`factor = 1 - db * 0.015`，
    即 mic 静音（db=0）时辅源系数 1.0，mic 满音（db=60）时系数 0.1
- 归一化限幅：溢出时算回缩因子 `f`，之后每样本 `f += (1-f)/32` 缓慢恢复（`.mm:406-421`）——
  一个带 attack/release 的软限幅器。

### 1.7 输出 index 取**主源**（`.mm:366`）

```cpp
param.external_source_index = local_node->external_source_index;
```

注释（`.mm:363-365`）：

> 去向由主源决定：编码器按 index 过滤，DJI 接管期间只收 OSMORTMP(200)，带辅源的 -1 会被整块丢掉。
> 主源是本地 mic(-1) 时结果和原来取辅源(-1) 一样，所以对既有场景是恒等变换；
> 只有 DJI 音频当主源(200) 时才有区别，而那正是要的。

**这与另一套混音器取值规则相反** —— `TVUExternalSourceAudioMixerQueueManager.mm:244` 是
「辅源优先」（见 A0 §2）。两个辅源生产者都固定写 `external_source_index = -1`
（`TVUWebviewAudioOutputManager.mm:151`、`TVUChatTTSManager.mm:480`），所以取主源是唯一
能让 DJI(200) / Accsoon 场景活下来的选择。

`kTVULocalCameraExternalSourceIndex = -1` 定义在 `TVUAudioEncoderManager.h:19`。

### 1.8 挂起 / 唤醒，以及「没人用时不走混音」的旁路

**挂起条件**：`activeSources == None`（`.mm:193-194`）→ `threadSuspend = true`，
线程下一轮在 `.mm:262` 的 `pthread_cond_wait` 上停住。

**唤醒条件**：第一路 `start` 时（`.mm:178-184`）`threadSuspend = false` + `pthread_cond_broadcast`。

**旁路的实现方式**：混音器**自己不做旁路**——旁路在上游。生产者每块都问
`[TVUSnapshotManager manager].shouldOutputAudioStream`（`aacEncoder.mm:297` 是
`else if (...)`），为假就走原来的直送编码器路径，压根不碰混音器。而这个属性的真值最终
（对 TTS 那一半）来自 `isSourceActive(TTS)`：

```
aacEncoder.mm:297  else if ([TVUSnapshotManager manager].shouldOutputAudioStream)
  → TVUSnapshotManager.m:345   webManager.shouldOutputAudioStream || [TVUWebChatManager manager].needsAudioMixing
                                        ↑ overlay 那一路                    ↑ TTS 那一路（缓存值）
  → TVUWebChatManager.m:201    needsAudioMixing = mixerRunning
  → TVUChatTTSManager.mm:340   self.mixerStateDidChange(self.mixerRunningForStream)
  → TVUChatTTSManager.mm:322   isSourceActive(TVUOverlayMixerSourceTTS)   ← 唯一真相源
```

`TVUChatTTSManager.mm:316-320` 解释了为什么必须问混音器的**实际**状态而不是「想不想混」：
`aacEncoder` 那边是 `else if`，一旦为真本地音频就**只**进混音器、不再直接编码，两边差一点
音频就整段丢失（注释里记了实测踩过的坑：开着 mix 重启 app → 想混但没人调过 `start` → 音频全丢
→ 接收端连画面都不出）。

`needsAudioMixing` 之所以是**缓存的 atomic 属性**而不是 getter 里现算
（`TVUWebChatManager.h:54-59`、`.m:64`）：音频采集线程每帧读它，不能在 getter 里走
`[TVUChatTTSManager manager]` 惰性链，否则首次创建发生在音频线程上（init 里有锁和文件 I/O）。

### 1.9 队列内部结构（`TVUOverlayAudioMixerQueue`）

- 每路两条链表：`freeQueue`（LIFO，头插头取）+ `workQueue`（FIFO，尾插头取），
  各自一把 `pthread_mutex`（`.mm:456-528`）。
- 池大小 `kTVUAduioMixerQueueNodeSize = 60`（`TVUExternalSourceAudioMixerQueueManager.h:16`），
  按 21.33ms/块算 ≈ **1.28 秒**缓冲。
- 节点结构 `TVUAudioMixerQueueNode`（`TVUExternalSourceAudioMixerQueueManager.h:32-40`）：
  `data / pts / channel / sample_rate / size / external_source_index / next`。
- `addDataToAudioMixer` 内部 `malloc + memcpy`（`.mm:139-141`），**不接管调用方内存**。
- `resetNode` 释放 data 并把节点还给 `freeQueue`（`.mm:548-561`）。
- 辅源在 free 池取不到 node 时进 `pthread_cond_timedwait` 1 秒超时循环
  （`.mm:80-119`，注释 `.mm:91` 明确写「添加超时逻辑防止死锁」，原来的无限 `pthread_cond_wait`
  被注释掉在 `.mm:89`）。**这个 `external_cond` 是 overlay 和 TTS 共用的**
  （`TVUChatTTSManager.mm:463-465` 注释提到这点，所以 TTS 侧刻意留一格余量避免走进这个分支）。

---

## 二、TTS 朗读链路

涉及文件（全部在 `Transmitter/TVUOverlays/ChatAggregator/ChatTTS/`）：

| 文件 | 职责 |
|---|---|
| `TVUChatTTSManager.{h,mm}` | 队列 / 过滤 / 去重 / 文本组装 / **推流侧攒块喂混音器** |
| `TVUChatTTSSpeaker.h` | 音频出口协议（`speakText:voice:rate:preDelay:completion:` + `stop`） |
| `TVUChatTTSStreamSpeaker.{h,mm}` | 唯一实现：`writeUtterance:` 取 PCM，一份数据两个去处 |
| `TVUAudioEnginePlayer.{h,mm}` | 本地播放（`AVAudioEngine` + `AVAudioPlayerNode`），48k/Float32/**mono** |
| `TVUChatTTSSettings.{h,m}` | rate / pauseBetweenMessages / maxMessageAge / 过滤器 / 语言 |
| `TVUChatTTSVoiceCatalog.{h,mm}` | 语音枚举 |

### 2.1 文本从哪来

```
TVUChatAggregator（Twitch IRC / YouTube / Kick 三个 client）
  → aggregator.messageAdmitted        (TVUWebChatManager.m:105-107)
      → [[TVUChatTTSManager manager] say:message]
  → aggregator.engagementReceived     (TVUWebChatManager.m:110-112)
      → [[TVUChatTTSManager manager] sayEngagement:event]
```

`say:`（`TVUChatTTSManager.mm:536`）在**调用线程**先取 `receivedAt`（`.mm:540`，排队等待也算年龄），
然后整段清洗 / 语言识别 / 过滤放到串行队列 `com.tvu.chat.tts`（`.mm:161`）上做——
`NLLanguageRecognizer` 不是线程安全的，而三个平台的 client 各在自己的线程上投递（`.mm:543-546`）。

出队与朗读在 `trySpeakNextLocked`（`.mm:852-905`）：
优先队列先清空再轮普通队列（`.mm:863`），跳过设备上没装语音包的（`.mm:867-868`），
按需拼 `"用户名 says: 正文"`（`.mm:878-886`），最后
`[self.speaker speakText:… preDelay:self.settings.pauseBetweenMessages completion:…]`（`.mm:895-904`）。

### 2.2 用什么合成：`AVSpeechSynthesizer.writeUtterance:`（**本地**，非服务端 TTS）

`TVUChatTTSStreamSpeaker.mm:93` 建 `AVSpeechSynthesizer`，
`.mm:182-203` 的 `writeUtterance:toBufferCallback:` 是唯一取音频的入口。

**没有服务端 TTS。** 唯一的引擎枚举里 `TVUChatTTSEngineTtsMonster`（云端）**未实现**，
`setEngine:` 里直接回落到 `System`（`TVUChatTTSManager.mm:377-380`、`loadPersistedEngine` 里
`.mm:271` 同样处理）。协议 `TVUChatTTSSpeaker.h:19-20` 说明这个协议是给将来的云端引擎留的接缝。

**曾经有第二条实现**（mix 关时用 `speakUtterance:` 让系统发声），2026-08-07 的 A/B 实测
把它删了 —— 走自己的 engine 反而省约 2.4 个百分点 CPU（10.06% → 7.65%，各 6 个 30 秒窗口、
区间完全不重叠），见 `TVUChatTTSManager.mm:212-224` 和 `TVUChatTTSSpeaker.h:14-17`。
现在 mix 开关**只决定要不要把 PCM 也送去混音**，不再切换实现。

**空 buffer 的两种含义**（`TVUChatTTSStreamSpeaker.mm:191-200`）：
`frameLength == 0` = 这句合成结束（不是错误）→ 先 `flushBatchForSeq:` 再
`handleSynthesisFinishedForSeq:`。而如果整句一个有效 buffer 都没给（部分语音/系统版本上的
Apple 已知问题），`handleSynthesisFinishedForSeq:` 里 `receivedAnyPCM == NO`
（`.mm:435-444`）→ **直接丢掉这条，不回落**，只报 TPDS `kTVUTpdsReasonSynthEmpty`。
刻意不回落成 `speakUtterance:`，那会变成「mix 开着却只有主播听得到」（`.h:13-15`）。

### 2.3 拿到 buffer 后怎么处理（合成回调线程）

```
[合成回调线程] writeUtterance 回调 (AVAudioBuffer)
  → consumeSourceBuffer:seq:            (.mm:207)
      → convertBuffer:seq:              (.mm:354)   源格式 → 48k/Float32/mono
      → appendToBatch:seq:              (.mm:220)   攒到 300ms
          → flushBatchForSeq:           (.mm:266)
              → emitBatchBuffer:seq:    (.mm:275)   一份数据两个去处
```

**转换器按句重建**（`.mm:354-365`）：`converter == nil || converterSeq != seq || 源格式变了`
就新建。理由：转换器带内部重采样状态，跨句复用会把上一句的尾巴带进来；源格式还会随语音变
（不同语言/音质的语音采样率不同）。目标格式 = `player.format` = **48kHz / Float32 / mono / 非交错**
（`TVUAudioEnginePlayer.mm:25-28`）。

采样率不同必须用带 input block 的接口（`convertToBuffer:fromBuffer:` 不支持重采样），
容量按比例放大 `+16` 给 SRC 边界留裕量（`.mm:366-371`）。

**攒块 300ms**（`kTVUChatTTSBatchSeconds = 0.3`，`.mm:34`）：`writeUtterance` 每次只给约
11.6ms（实测 256 个源采样点），一句 3 秒话回调 300 次；攒到 300ms 再发，内存分配 / 跨线程投递 /
播放队列碎片都少 25 倍。合成比实时快 25~45 倍（实测 6.5 秒音频只花 232ms），所以播放侧永远追不上。
两处强制 flush 兜住短消息和句尾（`.mm:32-33`、`:193-197`）。

攒块缓冲和 converter 一样**只在合成回调线程访问、不加锁**，靠 `batchSeq` 惰性重建来隔离
上一句残留（`.mm:69-74`、`:245-262`），`teardownCurrentUtterance`（主线程）刻意不去动它们
（`.mm:168-178`）。

### 2.4 怎么进 `sourceQueue[kTVUOverlayMixerQueueIndexTTS]`

```
[合成回调线程] emitBatchBuffer:seq:                 TVUChatTTSStreamSpeaker.mm:275
  → stereoInt16FromMonoBuffer:                       .mm:399   Float32 mono → Int16 interleaved stereo
  → dispatch_async(self.outputQueue)                 .mm:284   "com.tvu.chat.tts.stream" 串行队列
      → self.pcmOutput(interleaved)                  .mm:287
[com.tvu.chat.tts.stream]
  → TVUChatTTSManager 里注册的 block                 TVUChatTTSManager.mm:236-242
      → dispatch_async(self.streamFeedQueue)         .mm:239   "com.tvu.chat.tts.mixfeed" 串行队列
[com.tvu.chat.tts.mixfeed]
          → feedStreamPCM:                           .mm:435
              → [self.streamAccum appendData:pcm]    .mm:439
              → drainStreamAccumFromTimer:NO         .mm:440
                  → mixer->addDataToAudioMixer(&param, queue)   .mm:482
```

`pcmOutput` block 只在 `speaker` getter 里创建时写一次（`TVUChatTTSManager.mm:236`），
合成回调线程只读，没有竞争；要不要真的送由 `streamOutputEnabled`（atomic）控制
（`TVUChatTTSStreamSpeaker.h:41-43`），切 mix 开关只改这个标志、不重建 speaker、不打断正在读的那句
（`TVUChatTTSManager.mm:420-429`）。

**为什么中间要两级串行队列**：`outputQueue`（`.mm:52-54`）是为了不在合成回调线程直接调
`pcmOutput` —— 下游要喂混音器，万一它阻塞会拖住系统的语音合成线程。`streamFeedQueue`
（`TVUChatTTSManager.mm:170`）负责攒块和按混音器空位节奏送，`streamAccum` 靠它串行保证线程安全。

`drainStreamAccumFromTimer:` 的三道闸（`.mm:453-511`）：

1. **水位闸**（`.mm:466`）：`queue->workQueueSize() >= kTVUAduioMixerQueueNodeSize - 1` 就 break，
   留一格余量，**永远走不进** `addDataToAudioMixer` 里那个「队列满等 1 秒超时」的分支
   （那个 `external_cond` 和 overlay 共用）。
2. **活性闸**（`.mm:472`）：`!mixer->isSourceActive(TTS)` 就 break。
   注释 `.mm:468-471` 解释为什么必须判在 `addDataToAudioMixer` **紧前面**：
   `stop()` 是「先改 `activeSources`、再清队列」，所以读到已停就一定还没清、读到未停就说明
   清理还没开始，两种情况都不会残留。
3. **游标读**（`.mm:461`、`:485-488`）：循环结束后一次性裁掉已消费部分，
   避免每块都 `memmove` 整个 accum（O(n²) → O(n)）。

**重试节奏** `kTTSStreamRetryInterval = 0.5`（`.mm:67`）：还有整块没送出去就 `dispatch_after`
再试一次，`streamDrainScheduled` 保证全程最多一条待触发的重试
（`.mm:443-452` 注释记了这个 bug 的实测数据：不区分 `fromTimer` 时一条 6.1 秒的消息
`drains=2349` ≈ 20 条并行定时器链 × 123 跳）。

**积压告警** `kTTSStreamAccumWarnBytes = kTTSStreamBlockBytes * 1400` ≈ 30 秒（`.mm:72`）：
**只报不丢**（`.mm:490-498`），因为 accum 里是一句话连续的 PCM，丢头部等于砍掉开头。

### 2.5 采样率 / 声道 / 块长怎么对齐到 4096 字节 / 48k / 双声道

| 阶段 | 格式 | 位置 |
|---|---|---|
| `AVSpeechSynthesizer` 源 buffer | 随语音而变（实测 256 帧/次 ≈ 11.6ms） | `TVUChatTTSStreamSpeaker.mm:190` |
| `AVAudioConverter` 输出 | **48000 Hz / Float32 / mono / 非交错** | `TVUAudioEnginePlayer.mm:25-28`（= `engineFormat`） |
| 攒块缓冲 | 同上，容量 `48000 × 0.3 = 14400` 帧 | `TVUChatTTSStreamSpeaker.mm:249-251` |
| `stereoInt16FromMonoBuffer:` 输出 | **48000 Hz / Int16 / stereo / interleaved** | `.mm:399-426` |
| `streamAccum` 切块 | **4096 字节** = `kTVUAudioEncoderPCMSize` | `TVUChatTTSManager.mm:50`、`:462` |
| 送混音器的 `param` | `channel = kTVUAudioEncoderStereoChannel (2)`<br>`sampleRate = kTVUAudioEncoderSampleRate (48000)`<br>`size = 4096` | `TVUChatTTSManager.mm:476-478` |

常量定义在 `TVUAnywhereSDK/TVUEncoder/TVUAudioEncoderManager.h`：
`kTVUAudioEncoderFramesPerPacket = 1024`（`:13`）、`kTVUAudioEncoderMonoChannel = 1`（`:14`）、
`kTVUAudioEncoderStereoChannel = 2`（`:15`）、`kTVUAudioEncoderSampleRate = 48000`（`:16`）、
`kTVUAudioEncoderPCMSize = 4096`（`:17`）。

4096 = 1024 帧 × 2 声道 × 2 字节。`TVUChatTTSManager.mm:44-49` 的注释给了**三个独立来源互相印证**
这个值：`kTVUAudioEncoderPCMSize`；`TVURecorder.mm` 的 `kTVURecoderPCMMaxBuffSize(2048)` × 声道数；
overlay 音频那条路的 `needSize`。

**播放侧走 mono、只在送混音器时才扩成双声道**（`TVUChatTTSStreamSpeaker.h:17-19`、
`TVUAudioEnginePlayer.h:29-32`）—— 这样重采样只需处理一个声道。

**「一步完成」指的是 `stereoInt16FromMonoBuffer:`**（`.mm:394-426`，注释在 `:394-398`）：
全程 vDSP，最后两次 `vDSP_vfixr16` 用 `stride = kTVUChatTTSStreamChannels (2)` 分别写偶数位和奇数位：

```objc
vDSP_vsmul(src, 1, &scale, tmp, 1, frames);        // × 32767
vDSP_vclip(tmp, 1, &lo, &hi, tmp, 1, frames);      // clamp ±32767/-32768（必须，否则回绕爆音）
vDSP_vfixr16(tmp, 1, dst,     kTVUChatTTSStreamChannels, frames);   // 左：偶数位
vDSP_vfixr16(tmp, 1, dst + 1, kTVUChatTTSStreamChannels, frames);   // 右：奇数位
```

「转换和单声道复制成双声道一步完成，不需要再单独走一趟 `monoConvertToStereoWithMonoAudio:`」
（`.mm:397-398`）—— 对照之下 overlay 那条路是**先转 Int16 再单独跑一趟 `convertToStereo`**
（`TVUWebviewAudioOutputManager.mm:87-96`、`:143`），多一次遍历。

`vDSP_vfixr16` 是四舍五入版（`vfix16` 是截断），与原来的 `lrintf` 行为一致（`.mm:422`）。
`scratchFloat` 按需扩容后复用，只在合成回调线程用（`.mm:65-67`、`:408-412`）。

### 2.6 PTS 从哪来 —— **不从 TTS 来**

**这一路本身不产生 PTS。** 送进混音器的 `param.pts` 显式写 0
（`TVUChatTTSManager.mm:479`）：

```objc
param.pts = 0;   // 混出来的那一帧用的是本地块的 pts，这里不参与
```

混音器出块时取的是**主源节点**的 pts（`TVUOverlayAudioMixerManager.mm:362`）：

```objc
param.pts = local_node->pts;
```

也就是说 **TTS 音频完全挂靠在本地采集（或 DJI / Accsoon）的采集时钟上**：
一个 mic 块配一个 TTS 块，输出块继承 mic 块的 pts。本地生成的音频没有采集时钟这个问题，
是靠「借主源的时钟」解决的，而不是自己造时间戳。

这带来一个**结构性约束**：TTS 的推送速率必须由混音器的消费节拍（≈21.33ms/块，被麦克风采集钉死）
决定，而合成比实时快 30 倍。所以：

- 送不进去就留在 `streamAccum` 里等 500ms 重试（`TVUChatTTSManager.mm:502-510`），
  **绝不加速**；
- 消息间的停顿必须**推等量的零字节**而不是「什么都不推」——
  `scheduleSilence:seq:`（`TVUChatTTSStreamSpeaker.mm:145-159`）本地排静音 buffer 的同时，
  推流侧也推 `blocks` 个 `silenceInterleavedData`。注释 `.mm:142-144` 说明理由：
  > 两边都要，因为我们"合成多快就推多快"而混音器按实时消费，只在本地插静音的话
  > 观众听到的两条消息会比主播那边贴得更近，时间轴会越读越漂。
- 静音块粒度 `kTVUChatTTSSilenceBlockSeconds = 0.1`（`.mm:24`），设置页的停顿档位
  （0.5/1/2/3s）都是它的整数倍，所以排 N 块就是精确时长（sample-accurate）。
  推流侧的静音数据是 `48000 × 0.1 × 2 声道 × 2 字节 = 19200` 字节
  （`.mm:342-350`，`dataWithLength:` 自带清零），**注意这不是 4096 的整数倍**，
  会在 `streamAccum` 里和相邻数据拼接后再切块。
- 停顿刻意用静音帧而不是 `preUtteranceDelay` / 定时器（`.mm:127-131`、
  `TVUChatTTSManager.mm:220-223`）：定时器方案的实际间隔 = 设定值 + 合成耗时，每条都抖。

> 一个可推导的结果：**观众端的朗读会比主播端滞后**。混音器队列 60 块 ≈ 1.28 秒，
> 加上 `streamAccum` 的积压（正常情况下单条长消息会短暂堆到十几秒，`.mm:70` 注释）。
> `kTTSStreamRetryInterval` 从 50ms 改到 500ms 时顺带让队列平均水位从 ~59 块降到 ~48 块，
> 「观众端的滞后少 0.2 秒左右」（`TVUChatTTSManager.mm:61-62`）。具体端到端滞后未实测确认。

### 2.7 消息间隙这一路怎么表现

分两种间隙：

**(a) `preDelay` 停顿（有明确时长）**：推零字节，见 §2.6。混音器照常取到 TTS 节点，
但内容全 0，`mix()` 叠加 0 等于无影响。

**(b) 真正的空档（队列空、没消息可读）**：什么都不推。混音器侧的表现：

1. `activeSources & TTS` 仍然为真（只要 `mixesIntoStream` 没变），所以 `audioMixer()` 照常
   去 `deQueue` TTS 的 workQueue（`.mm:313-316`）。
2. 队列空 → `deQueue` 返回 `NULL`（`.mm:512-520`，只打 debug 日志不打 error）。
3. `tts_node == NULL` → 不进 `others[]`（`.mm:343`），`otherCount` 少一。
4. 两路都空时 `otherCount == 0` → **直接 `memcpy` 主源**（`.mm:351`），**不调 `mix()`**。
   这意味着空档期间连 ducking 都不施加，mic 原样通过。
5. 归还阶段判空跳过（`.mm:374`），避免每 21.33ms 一条 error 日志。

所以空档是**一等公民**，没有任何补偿/填充/超时逻辑 —— 这与 mic 侧「连续 1 秒没数据才丢辅源」
的判定是两件独立的事（前者判主源死活，后者是辅源正常呼吸）。

### 2.8 主动丢弃推流侧积压：`dropPendingStreamAudio`

`TVUChatTTSManager.mm:527-532`，**清两处**（accum + 混音器 workQueue），两个清理放同一个
`streamFeedQueue` block（`.mm:525-526`：drain 也在这条队列上，排在后面的 drain 会看到空 accum）。

调用点：

| 调用点 | 场景 |
|---|---|
| `.mm:337`（`applyMixerState` else 分支） | `mixesIntoStream` 变假 |
| `.mm:687`（`handleEnterBackground`） | 进后台 |
| `.mm:703`（`handleAudioInterruption:` Began） | 来电 / 别的 app 抢音频 |
| `.mm:798`（`skipCurrent`） | 用户跳过当前条 |
| `.mm:812`（`reset`） | 换引擎 / 关朗读 / 换频道 |

**🔴 只丢队列，绝不 `stop(TTS)`**（`.mm:519-523`）：`activeSources` 的 TTS 位同时决定
`threadSuspend`，而进后台/中断时 `_outputMode` 没变、`mixesIntoStream` 仍为真、
`shouldOutputAudioStream` 也仍为真 —— 本地采集还在走「只进混音器、不直接编码」那条路。
这时把混音器挂起，本地音频会被 `addDataToAudioMixer` 开头（`.mm:70-73`）丢掉，
**整条流一点声音都没有**。`stop(TTS)` 只在 `mixesIntoStream` 真的变假时调。

### 2.9 本地播放侧（旁支，不进流）

`TVUAudioEnginePlayer`：`AVAudioEngine` + `AVAudioPlayerNode` 最小播放图
（`TVUAudioEnginePlayer.mm:29-32`），**不碰 `AVAudioSession`**（app 正在采集推流，
改 category / active 有打断采集的风险，`.h:10-11`）。engine 只做输出、没 attach inputNode，
不会抢麦克风。

用 `AVAudioPlayerNodeCompletionDataPlayedBack` 而不是 `DataConsumed`（`.mm:62-66`）：
后者只表示被引擎取走，比真正播完早得多。引擎起不来时也回调 `played`（`.mm:59`），
否则上层等「播完」的状态机会永久卡住。

`AVAudioEngineConfigurationChangeNotification` 里**重连再重启**（`.mm:98-104`）：
路由变化 / 媒体服务重置会让连接失效，不重连的话第一次插拔耳机之后就永久没声音。

「这条读完」的判定 = 合成结束 **且** 排队的都播完（`TVUChatTTSStreamSpeaker.mm:451-458`），
不能在「合成结束」就推进（写模式合成几乎瞬间完成，那样下一条会立刻压上来、几条叠在一起，
`.mm:449-450`）。

---

## 三、Overlay Web Audio 链路

文件：`Transmitter/TVUOverlays/ViewSnapshot/WebViewSnapshot/`
- `TVUWebviewAudioOutputManager.{h,mm}` —— JS 注入脚本 + 原生侧 PCM 处理
- `views/TVUWebSnapshotView.mm` —— WKWebView 创建、脚本装配、message handler
- `TVUWebSnapshotManager.mm` —— 聚合各 overlay 的开关，start/stop 混音器那一路

⚠️ 原生侧的处理逻辑（`getCurrentTimeStamp` / `convertToStereo` / `sendToEncoderWithAudioData:` /
`resampleFloat32ToInt16:`）整段包在 `#if (defined _TVUIRLSDK)` 里
（`TVUWebviewAudioOutputManager.mm:78` ~ `:206`）。**只有 IRL 目标有这条路。**
JS 脚本本身（`audioOutputScript` / `scriptMessageHandlerName`）在宏外，两边都编。

### 3.1 JS 侧注入了什么

`+ (NSString *)audioOutputScript`（`TVUWebviewAudioOutputManager.mm:212-333`）返回一个自执行
IIFE，`window.__AudioInterceptorInjected` 做单次注入守卫（`:215-217`）。三个部分：

**① AudioWorklet 处理器**（`:222-263`，作为字符串塞进 Blob）

```js
class AudioCaptureProcessor extends AudioWorkletProcessor {
    constructor() {
        this.bufferSize = 4096;                    // ← Float32 采样点数，不是字节
        this.buffer = new Float32Array(this.bufferSize);
        this.bufferIndex = 0;
        this.targetSampleRate = 48000;
    }
    process(inputs, outputs) {
        const inputChannel = inputs[0][0];         // ← 只取第 0 声道
        const step = sampleRate / this.targetSampleRate;   // 线性重采样
        let inputIdx = 0;
        while (inputIdx < inputChannel.length) {
            this.buffer[this.bufferIndex++] = inputChannel[Math.floor(inputIdx)];
            if (this.bufferIndex >= this.bufferSize) this.flush();
            inputIdx += step;
        }
        return true;
    }
    flush() { this.port.postMessage({ pcm: new Float32Array(this.buffer).buffer }, [transfer]); }
}
```

要点：
- **重采样在 JS 里做**，最近邻取样（`Math.floor`），注释写「简单线性重采样逻辑: 适配 44.1k → 48k 或 48k 直通」
  （`:238`）—— 实际是最近邻而非线性插值。
- **只取第 0 声道**（`:235`），网页的立体声在这里就被砍成单声道。
- `process` 不写 `outputs`，所以 captureNode 本身输出静音。

**② Base64 编码 + 桥**（`:268-289`）：手写 base64 表，
`window.webkit.messageHandlers.audioHandler.postMessage(base64Data)`（`:286-288`）。
handler 名由 `+ scriptMessageHandlerName` 返回 `@"audioHandler"`（`:334-336`）。

**③ 劫持逻辑**（`:294-329`）—— 两道拦截：

- **代理 `AudioContext` 构造函数**（`:298-305`）：`window.AudioContext` / `window.webkitAudioContext`
  换成 `AudioContextProxy`，构造后立刻 `setupIntercept(context)` 加载 worklet 模块、建
  `AudioWorkletNode`、挂 `port.onmessage` → `sendToOC`、把 captureNode 挂到 `context._captureNode`
  并 `connect(context.destination)`。
- **patch `AudioNode.prototype.connect`**（`:318-329`）：任何节点 `connect(context.destination)`
  时**先额外**连一次 `originalConnect.call(this, context._captureNode)`，再执行原来的连接。
  这样网页的本地播放不受影响（原路径保留），同时抓一份到 captureNode。

> ⚠️ 只覆盖 `AudioContext` 这条路。`<video>` / `<audio>` 元素直接播放（没走 Web Audio 图）
> **抓不到**，`MediaElementAudioSourceNode` 之类要看网页自己是否建了 `AudioContext`。未确认实际
> 覆盖率。

### 3.2 桥回原生

装配在 `TVUWebSnapshotView.mm:134-148`（`initUI`，`#if (defined _TVUIRLSDK)` 内）：

```objc
WKUserContentController *userContentController = [[WKUserContentController alloc] init];
if(self.shouldOutputAudioStream){
    NSString *scriptJS = [TVUWebviewAudioOutputManager audioOutputScript];
    WKUserScript *script = [[WKUserScript alloc] initWithSource:scriptJS
                                                 injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                              forMainFrameOnly:NO];
    [userContentController addUserScript:script];
    TVUWKScriptMessageWeakProxy *weakProxy = [[TVUWKScriptMessageWeakProxy alloc] initWithDelegate:self];
    [userContentController addScriptMessageHandler:weakProxy
                                             name:[TVUWebviewAudioOutputManager scriptMessageHandlerName]];
}
config.userContentController = userContentController;
```

- `AtDocumentStart` + `forMainFrameOnly:NO`（iframe 里的音频也抓）。
- **脚本只在开关为真时注入**，所以切开关必须**重建整个 WKWebView**
  （`needCreatWebview:`，`TVUWebSnapshotView.mm:361-367`；`initUI` 开头 `:101-108` 先
  `removeAllUserScripts` + `removeAllScriptMessageHandlers` 再销毁 webView）。
  原因写在 `:96-100`：「脚本是 webview 初始化时注入，需要重新初始化 webview」。
- `config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone`（`:130`）
  允许自动播放（SPAR-92）。
- 回前台时 `[self.webView reload]` 恢复声音（`:78-91`，SPAR-93：后台音频被挂起、
  回前台不自动恢复）。

接收（`TVUWebSnapshotView.mm:618-625`）：

```objc
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:[TVUWebviewAudioOutputManager scriptMessageHandlerName]]) {
        NSString *base64Str = (NSString *)message.body;
        [TVUWebviewAudioOutputManager.manager receiveScriptMessage:base64Str];
    }
}
```

### 3.3 原生侧转 PCM

```
[主线程 / WK message] receiveScriptMessage:                TVUWebviewAudioOutputManager.mm:44
  → dispatch_async(self.audioWriteQueue)                    .mm:52   "com.tvu.webAudioWriteQueue" 串行
[com.tvu.webAudioWriteQueue]
      → [[NSData alloc] initWithBase64EncodedString:]        .mm:55
      → resampleFloat32ToInt16:                              .mm:57 / 161-204
      → getCurrentTimeStamp × 1000                           .mm:62 / 80-86
      → 漂移检测日志                                          .mm:64-74
      → sendToEncoderWithAudioData:samplerate:channels:dataSize:timestamp:   .mm:75 / 106
          → convertToStereo                                  .mm:143 / 87-96
          → mixer->addDataToAudioMixer(&encodeParam, queueForSource(Overlay))  .mm:154-155
```

**`resampleFloat32ToInt16:`（方法名有误导性，它不重采样）**（`.mm:161-204`）：
只做 Float32 → Int16，`vDSP_vsmul(×32767)` + `vDSP_vfixr16`（`.mm:191-194`）。
**没有 clamp** —— 对照 TTS 那条路有 `vDSP_vclip`（`TVUChatTTSStreamSpeaker.mm:417`，
注释明确说不夹住会回绕成反相大值、听感是尖锐爆音）。网页音频若出现 |x| > 1.0 的样本会回绕。
每次调用 `malloc` 两块（`outputBuffer` / `tempBuffer`）再 `free`（`.mm:169`/`:188`/`:200-201`）。

**攒块与切块**（`sendToEncoderWithAudioData:`，`.mm:106-159`）：

```objc
int needPcmSize = kTVU_WEBAUDIO_SAMPLES_PER_FRAME * sizeof(int16_t) * mRecordeAudioChannel;
                //  1024                          × 2               × 1               = 2048 字节（mono）
const int needSize = kTVU_WebAudioChannels_Output * kTVU_WEBAUDIO_SAMPLES_PER_FRAME * sizeof(int16_t);
                //   2                            × 1024                            × 2  = 4096 字节（stereo）
[self.pcmCacheData appendBytes:mAudioData length:mAudioDataByteSize];
while (self.pcmCacheData.length >= needPcmSize) {
    convertToStereo((int16_t *)data, needPcmSize, (int16_t *)outputData);   // 1024 帧 → 2048 帧交错
    encodeParam.size    = needSize;                     // 4096
    encodeParam.channel = kTVU_WebAudioChannels_Output; // 2
    encodeParam.sampleRate = mRecordeAudioSamplerate;   // 48000
    encodeParam.pts = (Float64)(correct_pts/1000.0);
    encodeParam.external_source_index = -1;
    mixer->addDataToAudioMixer(&encodeParam, mixer->queueForSource(TVUOverlayMixerSourceOverlay));
    [self.pcmCacheData replaceBytesInRange:NSMakeRange(0, needPcmSize) withBytes:NULL length:0];
    correct_pts += need_pcm_pts;
}
```

宏定义（`.mm:13-15`、`:105`）：
`kTVU_WebAudioSampleRate_Default = 48000`、`kTVU_WebAudioChannels_Default = 1`、
`kTVU_WebAudioChannels_Output = 2`、`kTVU_WEBAUDIO_SAMPLES_PER_FRAME = 1024`。

**注意采样率和声道数是硬编码传进来的**（`.mm:75`）：
`samplerate:kTVU_WebAudioSampleRate_Default channels:kTVU_WebAudioChannels_Default`。
原生侧无条件相信 JS 已经重采样到 48k 且是单声道 —— 没有校验。

`outputData` 是 `static uint8_t *` 只 malloc 一次（`.mm:138`，注释 `.mm:133-137`：
「避免占用过多的栈内存，使用 static 手动在堆上创建」）。
`encodeParam` 也是 `static`（`.mm:145`）。

**块规格链路**：JS 一次发 4096 个 Float32（16384 字节 base64）→ 原生转 Int16 得 8192 字节
mono → 攒进 `pcmCacheData` → 每 2048 字节（1024 帧 mono）切一刀 → `convertToStereo` 得
4096 字节 stereo。所以**一次 JS 消息正好产出 4 个混音器块**。

### 3.4 Overlay 侧的 PTS

`encodeParam.pts = (Float64)(correct_pts/1000.0)`（`.mm:150`），其中：

- `timestamp = [self getCurrentTimeStamp] * 1000`（`.mm:62`），
  `getCurrentTimeStamp` = `CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))`（`.mm:80-86`）
  —— **主机时钟秒**，与采集侧同源。
- `remain_pts = samplesPerChannel * 1000 / sampleRate`（`.mm:126`）= 切块前 cache 里
  已有数据的时长；`correct_pts = timestamp - remain_pts`（`.mm:131`）—— 把时间戳回退到
  「cache 头部那个样本对应的时刻」。
- 循环里每送一块 `correct_pts += need_pcm_pts`（`.mm:157`，`need_pcm_pts = 1024 * 1000 / 48000`
  ≈ 21ms）。

**但这个 pts 最终被丢弃** —— 混音器输出取 `local_node->pts`
（`TVUOverlayAudioMixerManager.mm:362`）。和 TTS 一样，overlay 音频也是挂靠主源时钟。

`.mm:41-74` 还有一段**纯日志用**的漂移检测：`timestamp_base` + `total_length * 1000 / 96000`
（96000 = 48000 × 2 字节，mono int16 的字节率）算理论时刻，偏差 > 50ms 或帧间隔 > 100ms 打 error。
三个变量是**文件级 static**（`.mm:41-43`），`timestamp_base` 只在为 0 时初始化一次，
**没有任何地方重置**——overlay 关掉再开、或 webView reload 之后，基线不会重置，
漂移日志会一直报。仅影响日志，不影响音频。

### 3.5 什么条件下 overlay 这一路 start / stop

见 §1.2 表格。链路是：

```
用户在 overlay 设置页拨开关            TVUOverlaySettingVC.mm:650-655   → item.enableAudioStreamOutput
（Preview 模式强制关：:713-714；同时只允许一个：TVUOverlayWindow.mm:510-514）
  → TVUWebSnapshotView setOverlayItem:  TVUWebSnapshotView.mm:267
        shouldOutputAudioStream = enableAudioStreamOutput && viewMode == Live
     → needCreatWebview: 变了就重建 WKWebView   .mm:361-367
  → TVUWebSnapshotManager checkAudioOutputState   TVUWebSnapshotManager.mm:116
        任一 view 为真 → start(Overlay) / 否则 stop(Overlay)   :130 / :132
```

`checkAudioOutputState` 只在三处被调（插入 / 移除 / 重置 snapshot item），
**没有**监听 overlay 显隐或推流状态 —— 与 TTS 那条（六个条件 + 五个事件）复杂度差别很大。

---

## 四、上游改道：`shouldOutputAudioStream`

### 4.1 它是一个**计算属性，从不被写**

声明：`TVUSnapshotManager.h:53`，在 `#if (defined _TVUIRLSDK)`（`:52`）块内：

```objc
@property (nonatomic, assign, readonly) BOOL shouldOutputAudioStream;
```

**非 IRL 构建里这个属性根本不存在**（类存在，属性不存在）。同名属性还出现在
`TVUSnapshotProtocol.h:42`（`@optional`，未加 `#if` 守卫）、
`TVUWebSnapshotManager.h:17`（`atomic`）、`TVUWebSnapshotView.h:17` —— **四个不同类上的四个不同属性**，
只有 `TVUSnapshotManager` 那个被三个音频改道点读取。

`TVUSnapshotManager` 类**只有一份实现**（`TVUSnapshotManager.h:24` / `.m:46`），
`TVUIRLSDK/` 下**没有**第二个 `TVUSnapshotManager` —— 它只是被编进 TVUIRLSDK target，
且相关方法整段包在 `#if (defined _TVUIRLSDK)` 里（`.h:52-62`、`.m:339-366`）。
`TVUIRLSDK.h` 也**没有**把它重新导出。

getter 是唯一实现（`TVUSnapshotManager.m:339-346`）：

```objc
- (BOOL)shouldOutputAudioStream {
    TVUWebSnapshotManager   *webManager = [TVUWebSnapshotManager manager];
    // overlay 要出声，或者聊天那边需要混音（弹幕朗读的 mix 开关）—— 两种情况都需要
    // 本地采集改走混音器。混音器是"以本地采集为节拍、其它源为辅"的：audioMixer() 第一件事
    // 就是看本地队列，空就直接返回，所以本地不进来的话另一路送多少都不会被消费（SPAR-680 mix）。
    return webManager.shouldOutputAudioStream || [TVUWebChatManager manager].needsAudioMixing;
}
```

所以「谁置位」的答案是：**两条独立的上游各自置位自己那一半，OR 起来**。

| 输入 | 唯一写入点 | 条件 |
|---|---|---|
| `TVUWebSnapshotManager.shouldOutputAudioStream`（overlay 那半） | `TVUWebSnapshotManager.mm:125`（`checkAudioOutputState`） | 任一 `TVUWebSnapshotView.shouldOutputAudioStream` 为真 |
| ↳ `TVUWebSnapshotView.shouldOutputAudioStream` | `TVUWebSnapshotView.mm:267`（`setOverlayItem:`） | `enableAudioStreamOutput && viewMode == Live` |
| `TVUWebChatManager.needsAudioMixing`（TTS 那半） | `TVUWebChatManager.m:201`（`syncStreamMixReady` 里装的回调 block） | `= mixerRunning` = `TVUChatTTSManager.mixerRunningForStream` = `isSourceActive(TTS)` |

TTS 那半的完整推送链（每一环都验证过）：

```
TVUChatTTSManager.applyMixerState              .mm:329
  → start/stop(TVUOverlayMixerSourceTTS)        .mm:334 / :336
  → self.mixerStateDidChange(mixerRunningForStream)   .mm:339-341
      → block 在 TVUWebChatManager.m:199-202
          → self.needsAudioMixing = mixerRunning        .m:201
```

`needsAudioMixing` 声明 `readonly`（`TVUWebChatManager.h:59`），在类扩展里改 readwrite
（`.m:64`，注释：「由 TVUChatTTSManager.applyMixerState 写入；音频线程每帧读，atomic 保证跨线程可见性」）。
之所以是**缓存的 atomic 属性**而不是 getter 里现算：音频采集线程每帧读它，
不能在 getter 里走 `[TVUChatTTSManager manager]` 惰性链（init 里有锁和文件 I/O，
`TVUWebChatManager.h:56-58`）。

### 4.2 三个改道点（完整清单，就是这三个）

全仓 grep 确认：`[TVUSnapshotManager manager].shouldOutputAudioStream` 的读取点**只有 3 个**，
没有 KVO、没有 `valueForKey:`、没有字符串访问。三者形状完全同构：

> `if (shouldOutputAudioStream) → overlay 混音器 sourceQueue[LocalCamera(0)]，return;`
> `else → [[TVUAudioEncoderManager manager] encode:]`

**① mic — `aacEncoder.mm:297`（分支起点）/ `:304`（入队）**
所在方法：`int aacEncoder::sendFrameToEncoder(uint8_t*, size_t, int64_t, int)`（`:278`）

```objc
296:#if (defined _TVUIRLSDK)
297:    else if ([TVUSnapshotManager manager].shouldOutputAudioStream){
298:        if (channels == kTVUAudioEncoderMonoChannel) {
299:            convertToStereo((int16_t*)data, length, (int16_t*)stereo_pcm_buffer);
300:            encodeParam.size = (UInt32)length * 2;
301:            encodeParam.channel = kTVUAudioEncoderStereoChannel;
302:            encodeParam.data = stereo_pcm_buffer;
303:        }
304:        TVUOverlayAudioMixerManager::manager()->addDataToAudioMixer(&encodeParam, TVUOverlayAudioMixerManager::manager()->sourceQueue[TVUAudioMixerSourceLocalCamera]);
305:    }
306:#endif
307:    else {
308:        if (streamType == PIP || PBP || (ExternalSource && tvuIsReplaceBackgroundStart)) {
             …单声道先 convertToStereo…
317:            TVUExternalSourceAudioMixerQueueManager::manager()->addDataToAudioMixer(&encodeParam, TVUExternalSourceAudioMixerQueueManager::manager()->sourceQueue[TVUAudioMixerSourceLocalCamera]);
318:        } else {
319:            [[TVUAudioEncoderManager manager] encode:&encodeParam];
320:        }
321:    }
```

要点：
- **是 `else if`**，前一个 `if` 是屏共（`:288` `[TVUScreenRecordingServerSocketManager manager].isReceivingFrame`）
  —— **投屏优先于 overlay/TTS 混音**。这也解释了 SPAR-753 注释里说的「采集真停了（投屏时
  本地音频全走 `tvuSendAudioToScreenShare`）才丢」。
- 单声道**先升双声道再入队**（`:298-303`），所以混音器永远拿到 stereo。
- else 分支里 PIP/PBP/替换背景走的是**另一套混音器** `TVUExternalSourceAudioMixerQueueManager`
  的 `sourceQueue[LocalCamera]`（`:317`，已逐字核对），否则直送 `encode:`。

**② 外部源 / Accsoon — `TVUExtAudioEncoder.mm:35`（SPAR-769）**
所在函数：文件级 static `tvuEncodeOrMixExternalSourceAudio(TVUAudioEncoderData *param)`（`:33`）

```objc
30:/// SPAR-769: 朗读要混进流时把外部源音频改道 overlay 混音器当主源（同 aacEncoder 里 mic 的分叉）。
31:/// 本地 mic 不会来抢主源队列：SeeMo 接管时 TVUIRLAccsoonHandler.parseStart 置了 isLocalFile=true，
32:/// mic 在 isSendAuidoToEncoder 就被丢弃。单独成函数只为把 #if 隔在 switch 外面。
33:static void tvuEncodeOrMixExternalSourceAudio(TVUAudioEncoderData *param) {
34:#if (defined _TVUIRLSDK)
35:    if ([TVUSnapshotManager manager].shouldOutputAudioStream) {
36:        TVUOverlayAudioMixerManager *mixer = TVUOverlayAudioMixerManager::manager();
37:        mixer->addDataToAudioMixer(param, mixer->sourceQueue[TVUAudioMixerSourceLocalCamera]);
38:        return;
39:    }
40:#endif
41:    [[TVUAudioEncoderManager manager] encode:param];
42:}
```

调用点 `TVUExtAudioEncoder.mm:252`（在 `TVUExtAudioEncoder::doencode()`，`:182`），
只在 `streamType == TVUAVStreamExternalSource && !tvuIsReplaceBackgroundStart` 时到达（`:251`）；
PIP/PBP 和替换背景走 `:254` 的另一套混音器、**根本不看这个开关**；
投屏在 `:235-239` 更早短路。

**③ DJI — `RTMPIngestController.mm:417`（SPAR-765）**
所在方法：`- (void)server:didReceiveAudioSampleBuffer:`（`:366`）

```objc
413:    // SPAR-765: 朗读要混进流时改道混音器（与 aacEncoder.mm 里本地 mic 的分叉同构）。增益已在
414:    // 上面施加完，顺序与 mic 一致；混出来那帧的 index 取自主源，仍是 OSMORTMP，编码器收得下。
415:    // 块长对不上时混音器会跳过朗读、把主源原样透传（并打日志说明），音频本身不受影响 ——
416:    // DJI 的块长 = 1024 × 48000/其 AAC 采样率 帧，只有源本身是 48kHz 才和混音器的块规格一致。
417:    if ([TVUSnapshotManager manager].shouldOutputAudioStream) {
418:        TVUOverlayAudioMixerManager *mixer = TVUOverlayAudioMixerManager::manager();
419:        mixer->addDataToAudioMixer(&param, mixer->sourceQueue[TVUAudioMixerSourceLocalCamera]);
420:        return;
421:    }
422:    [[TVUAudioEncoderManager manager] encode:&param];
```

`param.external_source_index = kTVUOSMORTMPSourceIndex`（`:409`）会被混音器保留（§1.7）。
mic 增益在分支之前施加（`:395-398`），顺序与 mic 路一致；投屏在 `:387-390` 更早短路。

⚠️ **`param` 里的 `channel` 和 `sampleRate` 是硬编码的**（`:406-407`）：

```objc
403:    TVUAudioEncoderData param = {0};
404:    param.data = (uint8_t *)pcmPtr;
405:    param.size = (UInt32)pcmLength;                       // ← 真实解码长度，会随源采样率变
406:    param.channel = kTVUAudioEncoderStereoChannel;        // ← 恒 2
407:    param.sampleRate = kTVUAudioEncoderSampleRate;        // ← 恒 48000，不管源实际是多少
408:    param.pts = framePts;
409:    param.external_source_index = kTVUOSMORTMPSourceIndex;
```

所以源非 48k 时，`size` 会偏离 4096 而 `sampleRate` 仍报 48000 —— 混音器只比 `size`
（`.mm:338`/`:344`），能挡住越界读；但**下游编码器拿到的是「声称 48k、实际不是」的块**。
这是 `:415-416` 那条注释背后的真实机制。

> **`:416` 这条注释是本篇最重要的运行时风险提示**：DJI 的块长 = `1024 × 48000/源 AAC 采样率` 帧，
> **只有源本身是 48kHz 才和混音器的 4096 字节块规格一致**。不一致时混音器会跳过两个辅源
> （`TVUOverlayAudioMixerManager.mm:338`/`:344`）、把主源原样透传 —— 也就是
> **DJI 非 48k 时朗读和 overlay 声音都进不了流**，且只有日志能看出来。

### 4.3 SPAR-765 / SPAR-769 与这个开关的关系

**SPAR-680**（弹幕朗读，umbrella ticket）建这条 TTS→推流的混音通路时，假设主音频源是手机自己的 mic，
所以只在 `aacEncoder.mm:297` 加了改道。而外部源接管时 mic 帧在上游就被丢弃、根本到不了
`aacEncoder`，于是 overlay 混音器的主源队列一直空 —— `audioMixer()` 第一件事就是看主源队列
（`TVUOverlayAudioMixerManager.mm:271`），空就 return，**TTS 队列永远不被消费**，
表现是「开着 mix 但观众听不到朗读」。

**SPAR-765（DJI）和 SPAR-769（Accsoon/SeeMo）各自在自己那条音频路径上加同构的分叉**，
把该源的 PCM 喂进 `sourceQueue[LocalCamera]` 当节拍源。

配套的第三处改动在门控侧 —— `TVUWebChatManager.m:213-220`：

```objc
// SPAR-765/769: 外部源（DJI / Accsoon）接管期间这条让开 —— 它防的是「手机喇叭→手机麦克风→进流」
// 的闭环，而接管时进流的是外部设备的麦克风、手机麦克风根本不进流。外部相机离手机近时闭环仍可能
// 成立，所以这是产品权衡：留着的话「外部源 + 外放」永远混不进去，而不戴耳机是常态。
NSString *outputPort = [AVAudioSession sharedInstance].currentRoute.outputs.firstObject.portType;
BOOL externalSourceFeeding = [[TVUIRLSDK manager] isDJIRTMPRunning]
                          || [TVUIRLSDK manager].isAccsoonCameraWorking;
BOOL onBuiltInSpeaker = [outputPort isEqualToString:AVAudioSessionPortBuiltInSpeaker]
                        && !externalSourceFeeding;
```

即：外部源接管时**放开「内建扬声器则不 mix」这条限制**，让 `streamMixReady` →
`needsAudioMixing` → `shouldOutputAudioStream` 能在外放状态下也变真。
状态跳变由 `TVUIRLEventDJIStreamingChanged` / `TVUIRLEventAccsoonCameraWorkingChanged`
驱动重算（`TVUWebChatManager.m:711-717`，注释说明「接管不改变手机的输出路由、路由变化事件兜不住」）。

**三张票的分工**：765/769 补齐了改道的**入口**（主源可以是 DJI / Accsoon 而不只是 mic），
`TVUWebChatManager.m:217-220` 补齐了改道的**门控**（外放不再一律禁 mix），
SPAR-753 修的是改道之后**混音器消费侧**的丢弃判据（`kTVUOverlayMixerLocalSilenceDropMs`，见 §1.5）。

### 4.4 两个「不要用 `TVUSnapshotManager.shouldOutputAudioStream`」的地方

这个属性把 overlay 和 TTS 两路 OR 在一起，所以**任何只关心 overlay 的判断都不能用它**。
仓库里有两处显式注释警告：

| 位置 | 该用什么 | 为什么 |
|---|---|---|
| `TVUSnapshotManager.m:359`（`audioMixStateWillChange:`，`:347`） | `webManager.shouldOutputAudioStream` | 互斥只管 **overlay 之间**；用 OR 后的值会导致「朗读一开，overlay 的音频开关再也打不开」（注释 `:355-358`）。唯一调用方 `TVUOverlaySettingVC.mm:652` |
| `TVUOverlayWindow.mm:510` | `[TVUWebSnapshotManager manager].shouldOutputAudioStream` | 同上；用 OR 后的值还会把 `enableAudioStreamOutput` 误持久化成 `NO`（注释 `:507-509`） |

其余读取点都是各自类的本地属性：
`TVUWebSnapshotManager.mm:120`/`:129`（聚合 + start/stop）、
`TVUWebSnapshotView.mm:79`（回前台 reload 的守卫）、`:135`（决定要不要注入 JS 抓音频脚本）。

---

## 五、三路块规格 / PTS / 启停 汇总表

### 5.1 块规格

| 路 | 字节/块 | 声道 | 采样率 | 帧/块 | 谁保证 |
|---|---|---|---|---|---|
| `[0]` 主源 mic | 4096 | 2（stereo interleaved） | 48000 | 1024 | `aacEncoder.mm`（单声道先 `convertToStereo`）；常量 `kTVUAudioEncoderPCMSize = 4096`（`TVUAudioEncoderManager.h:17`） |
| `[0]` 主源 DJI | **块长 = `1024 × 48000/源 AAC 采样率` 帧**，只有源本身是 48kHz 时才等于 4096 字节 | 未核实 | 随源 | 见左 | `RTMPIngestController.mm:416` 注释明说这一点。⚠️ 源非 48k 时两个辅源会被整块跳过 |
| `[0]` 主源 Accsoon / SeeMo | 未在本篇核实 | 未核实 | 未核实 | 未核实 | 见 A5；混音器只校验「与主源块等长」，主源自己多长都行 |
| `[1]` Overlay | 4096 | 2 | 48000（硬编码信任 JS） | 1024 | `TVUWebviewAudioOutputManager.mm:132`（`needSize`）+ `:140` 的 while 切块 |
| `[2]` TTS | 4096 | 2 | 48000 | 1024 | `TVUChatTTSManager.mm:50`（`kTTSStreamBlockBytes = kTVUAudioEncoderPCMSize`）+ `:462` 的 while 切块 |

校验点：`TVUOverlayAudioMixerManager.mm:338` / `:344`，辅源块长 ≠ 主源块长就**跳过不混**（只打日志）。

### 5.2 PTS

| 路 | 自己填的 pts | 是否被使用 |
|---|---|---|
| `[0]` 主源 mic | `aacEncoder` 的 `encodeParam.pts`（采集时钟） | ✅ **输出块的 pts 就是它**（`TVUOverlayAudioMixerManager.mm:362`） |
| `[0]` 主源 DJI | `CMSampleBufferGetPresentationTimeStamp`，已由 `TVUIRLDecodedPtsAnchor` 重锚到 host time 域、严格单调均匀（`RTMPIngestController.mm:399-401` / `:408`） | ✅ 同上 |
| `[0]` 主源 Accsoon | `encodeParam.pts`（`TVUExtAudioEncoder.mm`，本篇未细究） | ✅ 同上 |
| `[1]` Overlay | 主机时钟 − cache 残留时长，逐块 +21ms（`TVUWebviewAudioOutputManager.mm:131` / `:150` / `:157`） | ❌ 丢弃 |
| `[2]` TTS | 显式写 `0`（`TVUChatTTSManager.mm:479`） | ❌ 丢弃 |

**两个辅源都不产生有效 PTS，全部挂靠主源采集时钟。** 时间轴对齐靠「一个主源块配一个辅源块」
的定长配对来保证，代价是辅源必须按实时速率喂（TTS 的 500ms 重试 + 静音填充就是为此）。

### 5.3 输出 `external_source_index` 取值规则

```cpp
param.external_source_index = local_node->external_source_index;   // 取主源
```
（`TVUOverlayAudioMixerManager.mm:366`）

两个辅源都固定写 `-1`（`TVUWebviewAudioOutputManager.mm:151`、`TVUChatTTSManager.mm:480`），
所以规则等价于「**去向完全由主源决定**」：mic 主源 → `-1`（= `kTVULocalCameraExternalSourceIndex`，
`TVUAudioEncoderManager.h:19`）；DJI 主源 → OSMORTMP 的 index（注释里写 200）。

⚠️ 与 `TVUExternalSourceAudioMixerQueueManager.mm:244` 的「辅源优先」**规则相反**，
新增混音路径时必须先想清楚照抄哪一个。

### 5.4 start / stop 条件

| 路 | start 条件 | stop 条件 | 幂等 |
|---|---|---|---|
| Overlay | 任一 `TVUWebSnapshotView.shouldOutputAudioStream`（= `enableAudioStreamOutput && viewMode == Live`）为真 | 全部为假 | ✅ 按位标记，反复调无害 |
| TTS | `enabled && outputMode == Both && streamMixReady`（六条件） | 任一条件变假 | ✅ 同上 |
| 主源 | **没有 start/stop** —— mic 不在 `TVUOverlayMixerSource` 里（`.h:17`：它是节拍源，没有 overlay 也没有 TTS 时整个混音器都不用） | — | — |

混音线程：第一路 start 时唤醒（`.mm:178-184`），最后一路 stop 时挂起（`.mm:193-194`）。

---

## 六、不确定 / 需运行时验证的点

1. **DJI 源采样率 ≠ 48kHz 时，朗读和 overlay 声音会静默丢失。**
   `RTMPIngestController.mm:416` 已写明「DJI 的块长 = 1024 × 48000/其 AAC 采样率 帧，
   只有源本身是 48kHz 才和混音器的块规格一致」。混音器只校验「辅源 == 主源」
   （`TVUOverlayAudioMixerManager.mm:338`/`:344`），不校验主源是 4096 —— 不一致时
   **跳过辅源、主源原样透传**，只打 error 日志。**需实测**各型号 DJI 设备实际吐的 AAC 采样率，
   以及非 48k 的占比。Accsoon / SeeMo 的块长本篇未核实，见 A5。
2. **Web Audio 的实际覆盖率**。JS 只代理 `AudioContext` 构造函数 + patch
   `AudioNode.prototype.connect`。网页用 `<video>`/`<audio>` 直接播放、或在脚本注入之前
   （`AtDocumentStart` 之前不可能，但 iframe 的时序）已经建好 context 的情况，未验证。
3. **JS 侧重采样质量**。`Math.floor(inputIdx)` 是最近邻，44.1k → 48k 会有可听的
   aliasing。注释自称「简单线性重采样」但实现不是线性插值。未做听感验证。
4. **JS 侧 `sampleRate` 若不是 44.1k/48k**（例如 32k 或 96k）时的行为。`step` 可能 < 1
   导致同一样本被重复取（升采样）或 > 2 大量丢样。未验证。
5. **`resampleFloat32ToInt16:` 缺 clamp** 是否在真实网页音频上触发回绕爆音。
   TTS 那条路有明确注释说合成偶尔给出略微超过 ±1.0 的样本，网页音频（尤其经过 Web Audio
   gain 节点）超出 ±1.0 的概率更高。**未实测**。
6. **`TVUWebviewAudioOutputManager` 的 `timestamp_base` 永不重置**。overlay 关开一轮后
   漂移日志会持续误报。只影响日志，但会掩盖真实的漂移问题。未确认是否有意如此。
7. **`audioMixerThread` 的 `pthread_cond_wait` 没有 while 包裹**（`.mm:261-263`）：
   spurious wakeup 或 `endThread` 的 broadcast 会让线程在 `threadSuspend` 仍为真时
   跑一次 `audioMixer()`。此时主源队列已被 `stop` 清空，所以会走 `.mm:271` 的空队列分支、
   `usleep(20ms)` 后返回 —— 实际无害，但不是显式设计。未确认是否刻意。
8. **`stop()` 之后混音线程可能还在 `audioMixer()` 里跑完一轮**：`stop` 拿到 `mutex` 说明
   `audioMixer()` 已结束，但 `activeSources` 的清位和 `resetWorkQueue()` 之间
   （`.mm:197` 解锁之后、`:201` 之前）线程可能已经开始新一轮并混出一块。未确认实际影响
   （最多多出一块已经在队列里的辅源音频）。
9. **`queueForSource()` 的 `default` 分支把非法值路由到主源队列**（`.mm:154`）。
   目前无调用方传非法值，但传 `Overlay|TTS` 组合值会静默写进 mic 队列。未确认是否需要加断言。
10. **观众端相对主播端的端到端滞后**。可推导的下界是混音器队列 60 块 ≈ 1.28 秒，
    加 `streamAccum` 积压（正常可达十几秒）。`TVUChatTTSManager.mm:61-62` 提到调参后
    「观众端的滞后少 0.2 秒左右」，说明团队测过，但绝对值未见记录。**需实测**。
11. **静音块 19200 字节不是 4096 的整数倍**（`TVUChatTTSStreamSpeaker.mm:344-347`）。
    功能上没问题（`streamAccum` 会拼接后再切），但意味着停顿的块边界和语音的块边界不对齐，
    切出来的块可能一半静音一半语音。未确认这是否有任何听感影响（理论上没有）。
12. **DJI 路 `param.sampleRate` 硬编码 48000**（`RTMPIngestController.mm:407`），
    而 `param.size` 是真实解码长度。源非 48k 时这两者互相矛盾，编码器拿到的是
    「声称 48k、实际不是」的块。未确认编码器对此的实际行为（是按声明的 48k 处理导致变调，
    还是有别的兜底）—— 这条与 §六.1 是同一个根因的两个面。
13. **`TVUChatTTSManager.isFeatureAvailable` 目前恒 `YES`**（`TVUChatTTSManager.mm:288-291`，
    注释说「上线开关——放开 SPAR-680 时改成 YES」，说明已放开）。若需回滚整个功能，
    这是唯一的 kill switch。未确认线上是否另有远端开关覆盖它。
