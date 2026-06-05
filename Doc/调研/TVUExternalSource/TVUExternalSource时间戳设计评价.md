# TVU 时间戳与时钟同步设计评价

> 基于 [TVUExternalSource模块分析.md](./TVUExternalSource模块分析.md) 与 [TVUExternalSource时间戳调研.md](./TVUExternalSource时间戳调研.md) 的工程评估
>
> **目的：** 帮助决策「是否重构、重构哪里、如何维护」

---

## TL;DR

> **这是一套典型的「演化型生产代码」—— 通过 5+ 年的 bug 修复堆出来的鲁棒性，单看每处都有合理性，整体没有理论的优雅但实战可靠。**

| 维度 | 评分 | 说明 |
|---|---|---|
| **正确性** | ⭐⭐⭐⭐ | 单时钟域 + 主从锁定的核心思路是正确的，长期跑下来证明工作 |
| **鲁棒性** | ⭐⭐⭐⭐ | 蓝牙/USB 插拔、NTP 跳变、循环播放、HEVC B 帧、低端机降帧都有处理 |
| **可读性** | ⭐⭐⭐ | 注释保留了 why，但状态散布让代码难追 |
| **可测试性** | ⭐⭐ | `static` + `extern` 全局状态让单元测试几乎不可能 |
| **可演化性** | ⭐⭐ | 同步逻辑散布，改一处怕动一片，重构成本极高 |
| **教科书纯度** | ⭐⭐ | 没有 ClockSync 抽象、没有 PLL，但其实手机端用不上 |

---

## 一、亮点（值得肯定的设计）

### 1.1 **单时钟统一**是整套设计的灵魂

所有源（Camera、Mic、外部文件、RTSP、组播）最终都收敛到 `CMClockGetHostTimeClock` 域，用 `g_vstarttime` 做相对零点。

这避开了多媒体工程里最难的「多时钟漂移补偿」问题：
- 不需要 PLL
- 不需要 PCR 重构
- 不需要 master-slave clock recovery

> 这是个**正确而经济**的选择：手机端没有 SDI 同步、没有 Genlock，host clock 就是事实上的最高精度时基。

### 1.2 AudioMixer 的「主从锁定」很务实

外部源音频混音时直接丢弃自己的 pts，跟随本地 mic 时钟（`AudioMixerQueueManager.mm:243`）：

```objc
param.pts = local_node->pts;  // 用本地 mic 的 pts 作为基准
```

绕开了「外部源音频相对本地音频累积漂移」的问题 —— 用队列阻塞（`external_wait + pthread_cond_wait`）兜底外部源跟不上的情况。

> 比真去算两条音频流的 SRC（采样率转换）+ 漂移补偿简单 10 倍，对直播场景够用。

### 1.3 TVURecorder 的 `audio_base_time` 差分公式有水平

```c
currentTime = audio_base_time + (now_audio_pts - first_audio_pts);
```

这是真懂 AudioUnit 的写法：
- 分离「AudioUnit 内部时钟节奏」和「host clock 绝对值」
- 避免 AudioUnit 与 host clock 单调累积偏差

配合 `filterInvalidAudioSample` 检测蓝牙/USB mic 插拔的 ≥5s 突变，**这块是整个项目里最精细的代码**。

### 1.4 注释保留了「为什么」

```
date: 2023-09-21
purpose: 优化音频的分包逻辑，反复循环播放，pts和1970的时间误差越来越大
reason: 刚开始 parse 的 audio pts <0 ...
reproduce: 6s 的视频，反复循环播放
```

每个奇怪的逻辑都标了 owner + 日期 + bug 编号（SPAR-30、ITA-905、ITA-824、FB-7498...）。

> **这是产品代码该有的样子**，比纯净的代码值钱。

---

## 二、问题（设计上的脆弱点）

### 2.1 **全局可变状态散布太广** ⚠️ 最严重

| 类型 | 例子 | 风险 |
|---|---|---|
| `extern Float64 g_vstarttime` | 13 个文件读写 | 重启直播的语义靠各 encoder `static BOOL isFirstFrame` 维护，谁先编谁定义零点 |
| 函数内 `static Float64 last_pts` | `sort()`、`encode()`、`pushFrame()`、`Parse` 至少 5 处 | 跨实例共享、跨直播会话共享，单元测试基本不可能 |
| `static Float64 audio_base_time = nowTime` | TVURecorder 函数内 | 初始化只发生一次，重启 mic 不会重置（靠 `isResetAudioBaseTime` 兜底） |

**这套设计的状态隐藏在 .mm 文件内部，新人改一处不知道会破坏哪里**。重构时，重构者需要把所有 `static` 和 `extern` 的语义全部梳清楚才敢动。

### 2.2 **两份「基准 BaseTime」并存且未协调**

- `Parse::current_timestamp` —— 解析启动时取的 host clock，给 timingInfo 用
- `SortQueueManager::externalSourceBaseTime` —— 第一次 sort() 时取的 host clock，给最终 pts 用

两者取值时刻差几十到几百毫秒（看队列堆积情况），互不知晓。

**虽然最终都收敛到 host clock 域不算 bug，但语义上有冗余且依赖隐含假设**（Parse 给的 pts 是「相对量」，所以不管 baseTime 是什么差值都会抵消）。如果有人想优化把 timingInfo 改成绝对值，立刻炸。

### 2.3 **外部源音频的「纯直播路径」是埋着的雷** ⚠️

```c
// TVUExtAudioEncoder::doencode
encodeParam.pts = (Float64)(pframe->timestamp/1000.0);  // FFmpeg 相对秒，比如 0.5
...
case TVUAVStreamExternalSource:
    if (!replaceBackground) {
        [[TVUAudioEncoderManager manager] encode:&encodeParam];  // ❌ 没加 host clock 基准
    }

// TVUAudioEncoderManager::encode
int64_t newPts = (int64_t)((param->pts - g_vstarttime) * 1000);  // 大负数
```

**这分支如果真被走到，编码出的音频 pts 是负数大值**，应该会让接收端时间轴炸掉。

可能的真相：
- 该分支实际不被业务走到（线上从未启用）
- 或者 `g_vstarttime == 0` 时被某处兜底（我没找到）
- 或者**真的有 bug 但表现得太隐晦没人定位到**

> **这种「靠某个 if 兜底」的设计，是熵增式代码的典型味道**，建议核实并修复或显式删除分支。

### 2.4 **`dtsAfter == 0` 兜底硬编码 33ms**

```c
if (dtsAfter == 0) {
    dtsAfter = last_dts + 33;   // 假定 30fps
}
```

对 60fps 流，每次兜底偏移 ~16ms，多次发生会累积。应该是 `1000.0 / current_fps`，但用了硬编码。

### 2.5 **interval 异常的兜底被注释掉了**

```c
if(last_pts != 0 && last_pts == node->pts) {
    log4cplus_error("pts == last pts, please check it!");
    //node->pts = node->pts + 0.030;   // ❌ 兜底被注释
}
```

**只 log 不修复**。这种「调试时禁用、忘了启用」的代码留在生产里，下次出问题排查会绕很多弯。

### 2.6 **错误处理一律 drop，没有平滑**

- 单调性破坏 → drop
- 间距 <10ms → drop
- 蓝牙突变 >5s → drop
- max_duration 与实际帧数不符 → 累积偏移

drop 简单但粗暴，**在高漂移环境（如 4G 网络下的 RTSP）会出现成片丢帧**。更精细的方案应该是「内插一帧」或「时间戳拉伸」。

### 2.7 **缺乏端到端时间戳追踪**

调研时需要跨 7 个文件去拼一个帧的旅程：

```
Parse.pts → DecodeParam → SortQueue.node->pts → SampleBuffer.pts → Encoder.pts → mux.pts
```

每个节点都有自己的 `static last_pts` 打 log，但**没有一个统一的 trace_id 串起来**。一旦出现「视频卡 200ms」的现象，定位时只能凑 log。

### 2.8 **同步逻辑碎片化**

理论上应该有个 `TVUClockSynchronizer` 模块统一管理：
- 基准时间 anchor
- NTP 偏移补偿
- 漂移监控
- 异常检测策略

实际上这些散在 SortQueueManager、AudioMixer、各 Encoder、TVURecorder、TVUAnywhere 主类里。**改一处补偿策略，得在 10 个地方同步改**。

---

## 三、整体定位

### 3.1 我会怎么对待这套代码？

| 策略 | 建议 |
|---|---|
| **维护** | 保持现状，每加一个特性，按既有 owner/date/purpose 注释模板留痕 |
| **不要轻易重构** | 除非要做大架构升级（如多机位同步、Genlock、回放可寻址），否则收益不如风险 |
| **如果真要重构**，只动两件事 | 1. 抽出 `TVUClockService` 单一类，把 `g_vstarttime` / NTP offset / baseTime 全部封装<br/>2. 替换函数内 `static` 为类成员，让每个直播会话独立状态 |
| **现在可以做的小修补** | • `dtsAfter += 33` 改成 `1000.0/fps`<br/>• 验证「纯外部源音频不混音」分支是否真的不走，要么去掉要么补 host clock<br/>• 把被注释的 `+ 0.030` 兜底配上 flag 启用或彻底删 |

### 3.2 一个非常细微但重要的观察

整套设计的隐含哲学是：

> **「相信 host clock，怀疑一切外部时间」**

具体体现：

| 时间来源 | 处理方式 | 信任级别 |
|---|---|---|
| AudioUnit 的 `mHostTime` | 用差分（不直接相信） | ⚠️ 半信半疑 |
| AVCaptureSession 的 pts | 直接用 | ✅ 信任 |
| FFmpeg 的 packet.pts | 当相对量（不当绝对） | ⚠️ 仅作偏移 |
| 外部源服务器时钟 | 不追踪（懒得管） | ❌ 忽略 |
| NTP 偏移 | 主动补偿（怕跳变） | ⚠️ 监控+补偿 |
| 蓝牙/USB 插拔 | 主动过滤（怕突变） | ❌ 不信任 |

**这个哲学是对的**。在没有专业同步硬件的手机直播场景下，host clock 是唯一可信的本地参考系，所有外部时间都该被「投影」到 host clock 域。

> 这套代码用大量边界处理把这个哲学贯彻得很彻底，**虽然不漂亮，但抓住了问题的本质**。

---

## 四、给 Review 者的提问清单

如果要 review 这套设计或决策是否重构，建议先回答以下问题：

### 业务层
1. 「纯外部源直播（无 mic 混音）」分支线上是否真的启用？如果是，§2.3 的潜在 bug 必须立刻验证
2. 长时间 RTSP 直播（>2 小时）的实际漂移有多大？业务能容忍多少？
3. 4K@60 / HEVC 场景下，§2.4 的 `+33ms` 累积影响是否在容忍范围内？

### 工程层
4. 是否要引入端到端时间戳 trace（如打 trace_id 串起来）？
5. 是否要把 `g_vstarttime` + `audio_base_time` + `externalSourceBaseTime` 收敛到一个 `TVUClockService`？
6. 函数内 `static` 变量列表能否在一次 PR 里全部转成类成员（这是单测/多实例的前提）？

### 架构层
7. 多直播会话（一次启停、再启）的状态重置是否完备？现在依赖各 encoder `static BOOL isFirstFrame`，可靠性可疑
8. 多机位同步（Genlock-like）是否在路线图？如果是，现在的「单 host clock」会成为瓶颈

---

## 五、结论

✅ **这套设计能跑、跑了多年、踩过坑都修了，值得尊重。**

⚠️ **但它已经接近这套架构的复杂度上限**：状态散布、同步逻辑碎片化、`static`/`extern` 满天飞，任何中等以上的特性变更都需要谨慎评估副作用。

🔧 **重构建议保守**：先做「外科手术式」修补（§3.1 的「小修补」清单），不要动大手术，除非有明确的业务驱动（如多机位同步）。

📐 **如果做新模块，请避免重蹈覆辙**：
- 时钟基准必须有显式的服务/对象，禁用 `extern Float64` 全局变量
- 时间戳跨模块传递必须带 trace 元信息
- 状态必须可重置（绑定到「直播会话」实例，而不是 `static`）
