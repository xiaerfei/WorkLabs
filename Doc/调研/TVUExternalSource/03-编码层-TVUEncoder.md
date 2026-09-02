# 编码层详细分析 — TVUEncoder（H264/H265 硬编码 + AAC）

> 位置：`products/TVUTransportIOS/TVUAnywherePro/TVUAnywhereSDK/TVUEncoder/`
>
> **走查记录（2026-08-27）**：初版写于 2026-06；本次以 Manager（主线走查）+ H264/H265（两并行子代理）
> 重写视频三节，全部行号为当前真实行号。git 考证：两个编码器最后一次提交是 **d78972e54**
> （author 08-14 / commit 08-21，"Filtering out duplicate bitrate settings for the H.265 encoder"），
> 文件 mtime 08-25 只是集成分支检出时间。§四（AAC）继续指向 07 文档。
> 核心新增：**§三之二 双编码器不对称总表（D1-D12）** —— 修一边忘一边的完整清单。

---

## 一、TVUVideoEncoderManager — 编码调度（400 行，行号未漂）

**结构**：单例；懒加载持有 `h264Encoder`/`h265Encoder`；`mutex_lock` 保护宽高帧率属性；
串行队列 `com.tvu.videoEncoderQueue`（mm:74）承载 start/close（防主线程阻塞，2024-09-02 注释）；
**`encode:` 不换线程**——在合流层 encoderThread（或 LITE 的采集线程）直接进入编码器。

**selectLiveWay 矩阵**（mm:133-150）：`H264Live+H264Record`→仅 H264；`H265Live+H265Record`→仅 H265；
**其它任意组合→双编码器同时跑**（W3，设计如此：直播 H265+录制 H264 时 H264 分支由
`TVURecordMuxHandler::m_mux_lock + isOpenMuxFlag` 守卫，mm:251-260）。

**encode 入口**（mm:240-288）：CBR 旁路（原始帧给 TVUAssetWriterManager，mm:247-249）→
H264 分支（live 直编 / 仅录制时持 mux 锁编）→ H265 分支（转发 isNeedKeyFrame，mm:263-265）→
切源低码率监控（mm:270-284：源索引变化且 ∈{1..4, 100} → live-delay 后起 1s 重复 NSTimer，
连续 3 秒 <100kbps → close+start 重建，mm:367-399）。

### 1.1 问题清单（W 系列）

| # | 问题 | 位置 | 严重度 |
|---|---|---|---|
| W1 | 低码率监控 NSTimer **不持有不去重**：每次切源新建 repeats:YES timer，N 个并发 timer 共享 `static int videoBitrateTooLowCount` → "连续3秒"退化成"任意3次采样"，误触发编码器重启（直播断一下）。注释"0为相机，5为DJI"两处皆错（实为 -1 / 200） | mm:274-284, 367-399 | **高** |
| W2 | H264 仅录制分支**持全局 `m_mux_lock` 调 encode**，与音频侧 addAudioData（07 §7.1）同锁竞争 | mm:255-259 | 中 |
| W3 | liveWay/recordWay 不成对 → 双编码器同跑（双倍 VT 会话），设计特征 | mm:133-150 | 记录 |
| W4 | `setEncoderWidth`/`setEncoderHeight` 两个 setter **各自**回写 UserDefaults → 中间瞬间存储为 {新W,旧H} 撕裂值；且持 `mutex_lock` 期间做存储 IO | mm:337-365 | 低 |
| W5 | `encode:` 无锁读 enableH264/enableH265，切 liveWay 瞬间可能双发/漏发一帧 | mm:251/262 | 低 |
| W6 | **用解码 API 判编码支持**：`VTIsHardwareDecodeSupported(HEVC)` 置 `supportH265Encode`（下游后果见 H265-P10）；`supportRealTimeEncode = sizeof(int*)==8` 为古老遗留 | mm:78-82 | 中 |
| W7 | encode: 开头被注释的 `if(!enableEncoding)` 是冗余而非缺失——活体守卫在 TVUAVStreamManager.mm:2619（已核） | mm:242-244 | 排除 |

> 与 Q14 的闭环：相机钳 fps → K3 编码器跟随 → 本层 `setEncoderFrameRate` setter 再
> `tvuSaveFrameToUserDefaults`（mm:332-335）——降级值经两条路径持久化（K2 的另一半）。

---

## 二、TVUVideoH264Encoder（779 行）

### 2.1 锚点表（当前行号）

| 锚点 | 行号 | | 锚点 | 行号 |
|---|---|---|---|---|
| init | mm:57 | | encode: | mm:377 |
| startEncoderWithWidth:height:fps: | mm:73 | | forceInsertKeyFrame | mm:454 |
| startEncoder（VTCreate mm:125，属性段 mm:134-253） | mm:111 | | updateBitRate: | mm:461 |
| applyBitRateConfigurations | mm:299 | | isNeedUpdateBitRate | mm:469 |
| closeEncoder | mm:362 | | setBitRateProperty | mm:508 |
| FAILURE: 标签 | mm:272 | | propertyArray getter | mm:575 |
| videoEncodeCallBack（static C） | mm:598 | | | |

### 2.2 会话属性要点

- **RealTime**：IRLSDK/App 下仅屏共收帧时 true，**其余 false**（mm:140-157；2020-10 注释：RealTime 导致
  切源码率失控。代价：60fps 只能编 ~53fps，mm:138 注释自认）。与 H265 的"无条件 true"相反（D1）。
- ProfileLevel：Lite=Baseline / HIT_ME·SDK=Main / App 按设置（mm:163-182）；非 RealTime 分支恒 Baseline+CAVLC。
- AllowFrameReordering=false（禁 B 帧，mm:236）。
- **GOP**：`MaxKeyFrameIntervalDuration = 600`——单位是**秒**，宏 `(60*10)` 疑为"600 帧/10 秒"之误
  （H265 侧用的正是 600 帧，D3）→ IDR 实际全靠 forceKeyFrame 与编码器自主决策（P7）。
- 建成后 `HttpOutThread::SetFormatInput(w,h,fps,interlace)` 通告输出层（mm:260）。

### 2.3 码率两阶段

- **建会话** `applyBitRateConfigurations`（mm:299-361）：`bitRate<=0` → 打日志 **return noErr**（无码率
  约束建成，P8）；H265Live 时固定 5120000；DataRateLimits=[bitRate>>3 字节, 1 秒]（近似 CBR 的唯一手段）。
- **每帧** `setBitRateProperty`（mm:508-573）：非实时设备 0.5s 窗口平滑（static lastTime + bitRatesArray
  取均值）；H265Live 覆盖 5120000；**4K+录制中 → self.bitRate 直接改写 20480000**（4K 地板，仅 H264 有，D8）；
  **节流键 self.bitRate vs 实际下发 tmp 不一致**（P9=D9）；**先记账后设置，失败不重试**（D10）。

### 2.4 encode 与回调

encode 闸门：锁外读 session/encoderError（P5）→ 首帧 arm `g_vstarttime/g_tvustartcaptureTime`（进程级
一次性）→ NTP faultTolerance 加 pts → **static lastPts 单调闸门**（回退帧全丢，跨会话不清零，P2）。
`kVTInvalidSessionErr` → 原线程自动 startEncoder 重建；其它错误 → closeEncoder + delegate failured。

回调（VT 内部线程，**全程不取 mutex_lock**，P4）：status 检查 → dts=(pts−g_vstarttime)*1000 +
static last_dts 补偿（==0→+33、相等→+1）→ DependsOnOthers 判关键帧 → **SPS/PPS 每会话仅提取一次**
（static 缓冲长期持有；会话重建时重 malloc **不 free 旧块**，P3）→ AVCC→AnnexB 就地改写 →
三出口：帧传输 `TVULiveMediaCenter::muxFrameWithStremId`（SEI+头+帧）/ live `AVFormatControl::addH264Data`
/ 录制 `TVURecordMuxHandler::addVideoData`。

### 2.5 问题清单（P 系列，子代理走查 + 交叉核对）

| # | 问题 | 位置 | 严重度 |
|---|---|---|---|
| P1 | propertyArray"支持位"门**从不读 boolValue**（判对象非 nil 恒真）；反向：数组首次构建于无会话时 → nil → 所有门恒假、**全部属性静默不设**；数组终身不随会话重建 | mm:575-597 及 12 处调用 | **高** |
| P2 | static 群不清零：`lastPts`（源切换 pts 基线变小 → **每帧静默丢到追上历史水位**，DJI↔相机场景）、`last_dts`、`isFirstFrame`、`lastTime`、`spsppsNALBuff`、`idrDataFrame` —— d78972e54 只修了同模式的 lastBitRate 一个 | mm:386/411/478/638/656/720 | **高** |
| P3 | `spsppsNALBuff` 每次会话重建 malloc 覆盖不 free（叠加 W1 的自动重启 → 持续累积） | mm:671 | 中 |
| P4 | 回调与主路径零互斥（回调不取 mutex_lock，读写 finishH264NALUHeaderState/encoderError/static 群） | mm:598-777 | 中 |
| P5 | encode 门在锁外 + 重建窗口无锁 → 停流并发时对已 NULL 会话 EncodeFrame → **误发一次 tvuVideoEncoderFailured** | mm:379-384 | 中 |
| P6 | FAILURE 不清理半建会话（session 悬挂到下次 start/close） | mm:272-280 | 低 |
| P7 | GOP 单位错误（见 2.2） | mm:245-247 | 中 |
| P8 | bitRate<=0 静默 return noErr → 无码率约束直播 | mm:302-306 | 中 |
| P9 | 节流键与实际下发值不一致 → H265Live+H264Record 模式下重复设置未被消除（d78972e54 的残留缝隙） | mm:535-538 vs 517-519 | 中 |
| P10 | 建会话与首帧重复设一次码率（轻微，备查） | mm:299 vs 508 | 低 |
| P11 | 帧传输模式 IDR 可**无日志整帧丢弃**（spspps 未就绪时无 else） | mm:718-719 | 中 |
| P12 | `CFArrayGetValueAtIndex(attachments,0)` 不判空；`blockBufferLength<4` 时 size_t 下溢 → 越界写 | mm:650/707 | 低（崩溃点） |
| P13 | 时间基全局 `g_vstarttime` 有三个写者（本层首帧、H265 首帧、TVUAVStreamManager.mm:2815），进程级一次性 | mm:386-395 | 记录 |
| P14 | 无 dealloc（mutex 不 destroy；实例进程级存活，事实记录） | — | 记录 |

---

## 三、TVUVideoH265Encoder（892 行）

### 3.1 锚点表

| 锚点 | 行号 | | 锚点 | 行号 |
|---|---|---|---|---|
| init | mm:52 | | encode:isNeedKeyFrame: | mm:428 |
| startEncoderWithWidth | mm:69 | | forceInsertKeyFrame | mm:517 |
| startEncoder（VTCreate mm:134-138） | mm:107 | | updateBitRate: | mm:524 |
| applyBitRateConfigurations | mm:325 | | isNeedUpdateBitRate | mm:532 |
| enableHDRCompressionSessionConfig | mm:375 | | setBitRateProperty | mm:571 |
| closeEncoder | mm:402 | | propertyArray getter | mm:639 |
| FAILURE: 标签 | mm:309 | | static isHDRFormat | mm:662 |
| videoEncodeCallBack | mm:675 | | | |

### 3.2 与 H264 的同与异

**逐字同构**（差异仅日志 tag/枚举）：startEncoderWithWidth / forceInsertKeyFrame / updateBitRate /
isNeedUpdateBitRate / propertyArray / encode 的时间基·单调闸门·ForceKeyFrame·错误分支 /
回调的 dts 补偿·关键帧判定·AnnexB 改写·帧传输骨架。P1/P2/P4/P5/P12 类问题**两侧同款**。

**H265 独有**：`AllowOpenGOP=false`（iOS12+，mm:238-245）；HDR 全套（§3.3）；encode 带
isNeedKeyFrame 参数（锁外写 needForceInsertKeyFrame，mm:431-433）；锁内复查 session 非空
（mm:444-447，SPAR-556 配套）；`isStartingEncoder` 标志**只写不读**（读者全被注释，死状态）；
两段被注释的自愈逻辑（首帧重启相机 / pps_id_error 重启）。

**H265 特有问题**：
| # | 问题 | 位置 | 严重度 |
|---|---|---|---|
| H1 | 帧传输关键帧守卫笔误 `vpsSize && vpsSize && ppsSize` —— **spsSize 漏查**（H264 对应处是对的）→ SPS 提取失败时拼出缺 SPS 的畸形 IDR 头下发 | mm:815 | **高** |
| H2 | 关键帧回调 malloc `vpsspsppsNALBuff` 后若走 dataPointer==NULL 早退，free 被跳过 → 每次泄 12+ 字节 | mm:765/792/865 | 低 |
| H3 | init 期码率播种**硬编码 5120000**、忽略 self.bitRate（H264 用真值）；首帧即被纠正，窗口短 | mm:29/337-342 | 低 |
| H4 | VPS/SPS/PPS **每个关键帧全量重提**（原闸门被 `if(1/*…*/)` 短路）+ malloc/memcpy/free；对照 H264 的每会话一次 | mm:750-768 | 中（固定开销） |
| H5 | `isSupportH265Encode`（W6 的解码 API）为 NO 时提取段被跳过 → mm:777 以 NULL+12 长度下发（理论边界） | mm:756/777 | 低 |
| H6 | HDR 的 isHDR 标志只随 live 路 addH264Data 携带，**录制路 addVideoData 签名无此参数被丢弃** | mm:777/858 vs 861 | 中 |

### 3.3 HDR 配置（H265 独有，mm:375-401）

触发：`TVUSettingStorage.enableCameraHDR` 在 startEncoder 一次性读取（无动态切换，改开关需重建会话）。
ProfileLevel：HDR 开 → iOS≥15.4 用 `Main42210_AutoLevel`（ITA-1207：Main10 在 iOS18 报 -12902）、
否则 `Main10`；HDR 关 → `Main`。色彩五连：`HDRMetadataInsertionMode=Auto`（**返回值未检查**）→
PreserveDynamicHDRMetadata → ColorPrimaries=BT.2020 → TransferFunction=**HLG**（非 PQ）→
YCbCrMatrix=BT.2020；四处失败只打日志不致命。输出侧 `isHDRFormat()` 仅比对 ColorPrimaries==BT.2020。

---

## 三之二、双编码器不对称总表（D 系列，交叉核对核心产出）

| # | 维度 | H264 | H265 | 判定 |
|---|---|---|---|---|
| D1 | RealTime | 默认 **false**（2020-10：防切源码率失控） | 无条件 **true**（防 4k60 丢帧） | 两次修复方向相反，注释理由互斥——历史决策未统一 |
| D2 | **closeEncoder 锁模型** | **整段持锁 teardown** | SPAR-556（2026-06-24）：锁内摘指针、**锁外 Invalidate**（防后台挂起死锁拖死相机队列） | **修了 H265 忘了 H264** |
| D3 | GOP 键 | `MaxKeyFrameIntervalDuration`=600（**秒**） | `MaxKeyFrameInterval`=600（**帧**≈10s@60fps） | H265 正确、H264 用错键；且 H265 的支持位查的还是 Duration 槽位 |
| D4 | 参数集提取 | 每会话一次，static 缓冲不 free（P3 泄漏） | 每关键帧重提+当次 free（H4 开销 / H2 早退泄漏） | 策略相反，各有各的洞 |
| D5 | init 期码率 | self.bitRate 真值 | 硬编码 5120000（H3） | 不一致 |
| D6 | 4K 录制码率地板 20.48Mbps | 有 | **无**（H265 录制吃 live 自适应码率） | 修了 H264 忘了 H265 |
| D7 | setBitRateProperty 失败处理（d78972e54 同一提交改出） | 先记账后设置，**失败永久跳过**直到值变化 | 失败不记账、**下帧重试** | 同一提交两侧行为不同 |
| D8 | 帧传输 IDR 守卫 | `spsppsNALBuff && spsSize && ppsSize` ✔ | `vpsSize && vpsSize && ppsSize` ✘（H1 笔误） | copy-paste 笔误 |
| D9 | encode 锁内复查 session | 无（与其持锁 close 模型自洽） | 有（mm:444-447） | 随 D2 派生 |
| D10 | isNeedKeyFrame 参数 | 无（Manager 不传） | 有 | 接口不对称 |
| D11 | HDR | 零引用 | 全套 | 设计如此 |
| D12 | 录制头部下发条件 | `H265Live && H264Record` 复合 | `H265Record` 单条件 | 语义近似但组合覆盖不同，切模式边界值得测 |

---

## 四、TVUAudioEncoderManager — AAC 编码

> 📌 **本节是简版。** 完整分析见 [07-音频编码器-TVUAudioEncoderManager.md](./07-音频编码器-TVUAudioEncoderManager.md)
> （基线 `736863f1f`，晚约 1473 个 commit）：8 个生产者、10 道闸门、index 守门三分支、
> 二次混音、4 路出口、并发模型与 10 条已核实风险。**冲突时以 07 为准**——本节的
> 「优先硬件 codec」「异源过滤 mm:243-265」「来源：TVURecorder / 混音输出」三处已过时，
> 差异表在 07 的第十节。

### 4.1 编码器参数（TVUAudioEncoderManager.h:13-18, mm:562-646）

| 参数 | 值 |
|---|---|
| API | **AudioToolbox `AudioConverterRef`**（`AudioConverterNewSpecific`，优先硬件 codec） |
| 输入 | PCM s16、48000 Hz、双声道（`kTVUAudioEncoderSampleRate = 48000`） |
| 输出 | AAC-LC、`FramesPerPacket = 1024` |
| 码率 | 固定 128 kbps（`kTVUAudioEncoderBitRate`） |
| 质量 | Medium（主产品）/ Low（Lite） |

### 4.2 输入与预处理（mm:92-320）

来源：`TVURecorder` / 本地 mic 采集，以及外部源音频混音输出（`TVUExternalSourceAudioMixerQueueManager`，见 01 文档 §4.8）。入参结构 `TVUAudioEncoderData {data, size, pts, channel, sampleRate, external_source_index}`。

编码前依次：

1. **异源过滤**（mm:243-265）：`param->external_source_index != self.external_source_index` 的帧丢弃（Accsoon 内置音频例外），与视频侧的索引过滤对称。
2. **单声道→双声道**（mm:185-192, 711-722）：逐 sample 复制 L=R。
3. **会议混音**（mm:267-312）：Partyline（Agora）优先、VOIP（屏幕录制）次之，混入 PCM 后再编码。

### 4.3 时间戳与输出（mm:180-181, 350-399）

```objc
int64_t newPts = (int64_t)((param->pts - g_vstarttime) * 1000);   // 与视频共用同一基准
```

输出路径与视频完全对称：

```objc
if (isEnableTransfer) {
    [[TVULiveMediaCenter center] muxFrameWithStremId:TVU_LIVE_STREAM_ID_A
                                         andKeyFrame:1 andPts:newPts ...];   // mm:384
} else {
    AVFormatControl::GetInstance()->addAACData(data, size, newPts,
                                               param->channel, param->sampleRate);  // mm:393
}
```

> **音视频同步的本质**：视频 `dtsAfter` 与音频 `newPts` 减的是同一个 `g_vstarttime`，且都来自 HostTime 时钟域——这正是 [方案/RTMP聚合转发方案](./方案/RTMP聚合转发-时间戳重算与PLL方案.md) §7 主张的"单一全局锚点"，本链路天然满足。

---

## 五、错误处理与恢复链

| 错误（TVUVideoEncoderManager.h:18-23） | 触发 | 恢复 |
|---|---|---|
| CreateSessionFailured | VTCompressionSessionCreate 失败 | delegate 上抛，由 TVURecorder 重启编码器+相机 |
| EncodeFrameFailured | EncodeFrame 失败（非 InvalidSession） | closeEncoder + delegate |
| EncodeCallbackFailured | 回调 status != noErr | delegate（**会话不重建**；`encoderError` 只在 startEncoder 成功路径清零 → 此后 encode 门永久拒帧，恢复全靠外部动作） |
| （特例）kVTInvalidSessionErr | 后台切换等导致会话失效 | **encode 内原地 startEncoder 重建**（H264 mm:440-442 / H265 mm:504；在采集线程同步重建，H265-P15） |

另有 `TVUCheckAbnormalTool`（H264 mm:620-624 / H265 mm:709-717）持续比对编码 PTS 与系统时间，做异常检测与 Frame Transfer 模式的 CMTime offset 计算。

---

## 六、编译开关速查

| 宏 | 影响 |
|---|---|
| `TVU_HIT_ME` / `_TVUSDKANYWHERE` | RealTime 按 isReceivingFrame；Profile Main；CheckAbnormal 行为 |
| `_TVUSDKANYWHERELITE` | H264 固定 Baseline；AAC 质量 Low |
| `_TVUSDKPartyline` | 禁用 SEI / TVULiveMediaCenter 出口（H264 mm:707） |

---

## 七、参数速查表

| 参数 | 默认/取值 |
|---|---|
| 编码分辨率 | 默认 1280×720（kTVUVideoEncoderDefault*，.h:14-16），支持到 4K |
| FPS | 默认 30 |
| B 帧 | 禁用（双编码器一致） |
| I 帧间隔 | 600 秒（事实上由业务事件驱动） |
| H264 码率（H265 直播时） | 5,120,000 bps（仅供录制） |
| AAC | 48kHz / stereo / 128kbps / 1024 frames/packet |
| 视频 dts | `(pts - g_vstarttime)*1000` ms，兜底 +33/+1 |
| 音频 pts | `(pts - g_vstarttime)*1000` ms |
