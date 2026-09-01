# WorkOBS 音频链路设计

> 日期：2026-09-01
> 基线：WorkOBS `dev`（M1 主体完成，视频解码 → graphics tick → per-source push 预览已通）
> 范围：**音频全链路**——采集（麦克风/系统音频）· 处理（重采样/环形缓冲/时间戳归一）· 混音 · 输出（扬声器/AAC 编码 → muxer）
> 对标：OBS `libobs/obs-audio.c` + `media-io/audio-io.c` + `obs-source.c` 音频路径 + `plugins/mac-capture`（CoreAudio）+ `plugins/coreaudio-encoder`
> 相关：`Doc/调研/OBS/OBS_合成tick_音频混音_AV同步.md`（第③篇）、`OBS_源异步帧缓冲与时间戳节流.md` §4（第②篇）、`OBS_输出侧_编码_复用_录制推流.md`（第④篇）、`Doc/设计/重构/Video.md`（三元结构）
> 任务来源：`Doc/ToDo.md` A 系列（A1–A6）+ M2（AAC 编码）+ M4（多源混音 / 麦克风）

---

## 0. 结论先行

### 0.1 主线一句话

**源只管把 PCM 投进自己的环形缓冲（带源时基 pts），全局一条混音线程按系统单调钟的固定窗口（1024 帧/拍）主动拉、按时间戳对齐求和，再分发给播放/编码两个消费者。** 与视频侧「graphics tick 单点挑帧」是同一套范式：**推（生产）— 缓冲解耦 — 拉（节拍消费）**，音视频两条节拍线**各自贴墙钟、互不追赶**（OBS 模型，不是 mpv 的"视频伺服音频"）。

### 0.2 全链路图

```
┌─ 生产端（per-source，各自线程）────────────────────────────────────────┐
│                                                                        │
│  媒体文件源 WLMediaSource（解码线程，串行主循环）                        │
│    WLDecoder::ReceiveAudio(AVFrame)                                    │
│        │ 源时基 pts（媒体时间轴）                                       │
│        ▼                                                               │
│    WLResampler（swresample：任意 rate/layout/fmt → 48k·立体声·f32 planar）│
│        │                                                               │
│        ▼                                                               │
│    麦克风源 WLMicSource（CoreAudio HAL 回调线程，M4）                    │
│      AudioUnit 回调 → 格式转换 → 同上（pts = host time）                 │
│        │                                                               │
│        ▼  统一入口                                                      │
│    WLSource::OutputAudio(data, frames, pts_ns)                          │
│        │ ① 时间戳归一：sys_ts = pts + timing_adjust（三档阈值平滑/复位）  │
│        │ ② 到点才投：pts ≤ next_pts_ns（音视频同一条放行线）                │
│        ▼                                                               │
│    WLAudioRing（per-source，2 路 planar float，SPSC 无锁）               │
└────────────────────────────────┬───────────────────────────────────────┘
                                 │  混音线程主动拉（不是生产端推）
┌────────────────────────────────▼───────────────────────────────────────┐
│ WLAudioMixer（全局一条 tick 线程，对标 audio_thread + audio_callback）    │
│   节拍：samples += 1024；audio_time = start + samples→ns；SleepToNs 到点 │
│   每拍：窗口 [prev_time, audio_time)                                    │
│     ① 锁内快照源列表（WLCore::ForeachSource）                           │
│     ② 逐源 src->RenderAudio(mix, 1024, window_start)                    │
│          · start_point = (audio_ts − window_start) 换算成采样偏移         │
│          · 不足 → 补静音；落后 > MAX_LAG → 丢滞后 + 重锚（ignore_audio）  │
│          · 乘 per-source gain / mute → 浮点累加进 mix                    │
│     ③ 削顶 clamp(−1,1)（可选，默认只做 soft-limit 计数）                 │
│     ④ 出锁后分发给 sinks（勿持核心锁跑用户回调）                         │
└──────────┬──────────────────────────────────┬──────────────────────────┘
           │ mix[2][1024] + start_ts（系统钟） │
           ▼                                  ▼
┌──────────────────────────┐      ┌──────────────────────────────────────┐
│ WLAudioOutput（M1 A5）    │      │ WLAudioEncoder（M2/M4）               │
│  interleave → output ring │      │  ring 攒够 1024 → aac_at 编码          │
│  AudioQueue 回调 pull     │      │  pts = cur_pts += 1024（samplerate tb）│
│  3 × 1024 帧 → 扬声器     │      │  start_ts = 首帧系统钟（与视频对齐）    │
└──────────────────────────┘      └──────────────┬───────────────────────┘
                                                 ▼
                                    Interleaver（按 dts_usec 排序/归零/单调）
                                                 ▼
                                       mp4 muxer（M2）/ rtmp（M5）
```

### 0.3 模块清单与 OBS 对照

| WorkOBS 模块 | 目录 | 职责 | OBS 对应 |
|---|---|---|---|
| `WLAudioFormat` | `audio/` | 常量 + 换算（header-only） | `AUDIO_OUTPUT_FRAMES` 等宏 |
| `WLResampler` | `audio/` | swresample 封装：格式/采样率归一 | `audio_resampler_t`（media-io/audio-resampler-ffmpeg.c） |
| `WLAudioRing` | `audio/` | per-source PCM 环形缓冲（SPSC） | `audio_input_buf[MAX_AUDIO_CHANNELS]`（deque） |
| `WLSource`（音频区） | `source/` | `OutputAudio` / `RenderAudio` / 时间戳归一 | `obs_source_output_audio` + `obs_source_audio_render` |
| `WLMediaSource`（改造） | `source/` | 音频解码投喂 + 统一时间映射 + **单一 pace（放行线）** | `mp_media_thread` + `mp_media_next_audio` |
| `WLMicSource`（M4） | `source/` | CoreAudio 采集 → PCM 直投 | `plugins/mac-capture` coreaudio 输入 |
| `WLAudioMixer` | `audio/` | 全局混音节拍 + 窗口对齐 + sink 分发 | `obs_core_audio` + `audio_thread` + `audio_callback` |
| `WLAudioOutput` | `audio/` | AudioQueue 播放（pull） | `audio-monitoring/osx/coreaudio-output.c` |
| `WLAudioEncoder`（M2/M4） | `audio/` | AAC 编码（aac_at）+ 攒帧 | `plugins/coreaudio-encoder` / `obs_encoder`（audio） |

### 0.4 关键决策（⚙ 一次性定死）

| 编号 | 决策 | 选择 | 理由 |
|---|---|---|---|
| **D1** | 内部统一 PCM 格式 | **48 kHz / 立体声 / Float32 / planar** | macOS 设备与 AAC 主流是 48k；48k 天然整除 16k（将来 AEC/WebRTC 好办）；OBS 默认亦 48k。常量化于 `WLAudioFormat`，改 44.1k 只需动一处（A3 阶段可用 44.1k 交叉验证重采样通路） |
| **D2** | 音频解码是否另起线程 | **不另起**，沿用串行主循环 | 与 OBS `mp_media_thread` 一致；VideoToolbox 硬解是异步的，串行不是瓶颈。风险与对策见 §5.4 |
| **D3** | 媒体源 A/V 节流方式 | **单一 pace：整条循环只有一处 sleep，睡的是「下一位出场的帧」**——`next_pts_ns` 放行线（照抄 OBS `mp_media_sleep`，代码见 §4.5 改动点 3） | 视频、音频各 pace 一次会把节奏锁死成 46.875 fps；只 pace 视频则音频 1.28× 超产。OBS 的解法：`next_pts_ns` 是放行线，按 `min(v_pts, a_pts)` **增量**推进，谁到点谁出场 → 生产速率天然 **1.0× 实时**，**根本不需要水位限速**；水位降为异常探针 |
| **D4** | 环形缓冲溢出策略 | **生产端满 → 丢新（保险阀）+ 计数；消费端落后 → 丢旧重锚（主策略）** | 丢新保持 SPSC「单写」不破坏无锁；丢旧由消费端统一执行（= OBS `ignore_audio` 语义），比生产端动读指针安全 |
| **D5** | 环形缓冲同步 | **SPSC lock-free（原子下标）**，不用 mutex | 生产/消费严格各一条线程；M4 CoreAudio 回调有硬 deadline，绝不能因锁产生优先级反转 |
| **D6** | 播放输出模型 | **AudioQueue + pull 回调**（mixer → output ring → 回调取） | 混音与播放解耦，延迟可控（3×1024 帧）；push 模型会把 AudioQueue 内部缓冲变成不可控延迟 |
| **D7** | 混音线程遍历源 | **锁内快照 + 锁外混音/分发** | 我们没有 OBS 的源引用计数；出锁后解引用源是 UAF。锁内把 PCM 拷进本地快照，锁外只碰快照 |
| **D8** | 动态缓冲（OBS `add_audio_buffering`） | **首期不做**，只做 per-source 重锚 | 首期只有本地文件 + 麦克风，抖动小。整条管线后退会引入额外延迟，收益不抵复杂度。留接口位 |

---

## 1. 现状与差距

| 维度 | 现状（基线） | 缺口 | 目标 |
|---|---|---|---|
| 解码 | `WLDecoder` 已有 `FindAudioStream` / `CfgdAudio` / `ReceiveAudio`（A1 基本完成） | 未打印/暴露音频格式参数 | 补 `SampleRate/Channels/SampleFmt` 查询 + 日志 |
| 主循环 | `WLMediaSource::ThreadLoop` 步骤 3 收到音频帧后只打 `[src A]` 临时日志并 `av_frame_free` | 无输出通路 | 接 `WLResampler` → `source_->OutputAudio()` |
| 重采样 | 无（`WLResample` 在 WorkLabs 侧是空壳） | 解码输出 fmt/rate/layout 各异 | `WLResampler`（A3） |
| 源侧缓冲 | 只有视频 `async_frames` 环形（30 帧，drop-oldest） | 无音频缓冲 | `WLAudioRing` + 壳上音频区（A4） |
| 混音 | 无；`WLAudioMixerDockViewController` 是空壳 UI | 无节拍线程 | `WLAudioMixer`（A5a / M4-1） |
| 输出 | 无 | 听不到声音 | `WLAudioOutput`（A5b） |
| 采集 | 无音频源；`WL_SOURCE_AUDIO` 位已定义在 `WLSource.hpp` | 麦克风源 | `WLMicSource`（M4-2） |
| 编码 | `libwl` 尚无 encoder | AAC | `WLAudioEncoder`（M2/M4-3） |
| A/V 同步 | 视频 `PaceVideo` 用 `base_wall + (pts − first_pts)` 绝对基准 | 音频无时间轴 | 统一映射（§6.1） |

---

## 2. 目标架构

### 2.1 分层

```
UI 层（OBSLabs/）：WLAudioMixerDock（音量推子 / 静音 / 电平表）
        │ WLCore::SetSourceGain / SetSourceMuted / SetAudioSink
────────┼────────────────────────────────────────────────────────
内核层（libwl/src/）
   WLCore ── 拥有 ──► WLGraphics（视频节拍）
         └── 拥有 ──► WLAudioMixer（音频节拍）  ← 新增
                         ├─ 遍历 ──► WLSource（壳）
                         │              ├─ WLAudioRing
                         │              └─ WLSourceProtocol 实现体
                         │                    ├─ WLMediaSource（解码线程产 PCM）
                         │                    └─ WLMicSource（HAL 回调产 PCM）
                         └─ sinks ──► WLAudioOutput（扬声器）
                                  └─► WLAudioEncoder（AAC → muxer）
```

- **`WLCore` 拥有节拍线程**（与拥有 `WLGraphics` 同构）：`Startup` 里 create+start，`Shutdown` 里最先 stop+delete。
- **源只拥有缓冲，不拥有线程混音**：与视频侧「源投帧、tick 挑帧」同构。

### 2.2 数据与控制的流向

- **数据流**：生产线程 →（源内 ring）→ 混音线程 →（sink 回调）→ 输出/编码。**全程单向，无回压到生产端的阻塞**（媒体源靠**单一 pace 放行线**把自己限成 1.0× 实时，无需下游回压；麦克风源天然实时）。
- **控制流**：UI/外部 → `WLCore` 转发 → `WLAudioMixer`（sink 注册）/ `WLSource`（gain、mute、ResetAudioTiming）。**控制不反向依赖数据**：源不存在时混音线程自然跳过。

---

## 3. 数据契约

### 3.1 PCM 格式与单位

| 项 | 约定 | 说明 |
|---|---|---|
| 采样率 | `WL_AUDIO_SAMPLE_RATE = 48000` | D1，常量 |
| 声道 | `WL_AUDIO_CHANNELS = 2` | 单声道源上混（复制）；>2 声道下混（swr 自动 matrix） |
| 样本格式 | `AV_SAMPLE_FMT_FLTP`（float planar） | 与 OBS 内部一致；混音是浮点累加，避免中间格式转换 |
| 内存布局 | `data[ch][frame]`，每路一段连续 float | 与 `AVFrame->data[ch]` / `audio_output_data.data[ch]` 同形 |
| **帧（frame）** | **每声道 1 个样本** | 全文档"N 帧"= N samples/channel。1024 帧 @48k = 21.333 ms |
| 混音批大小 | `WL_AUDIO_TICK_FRAMES = 1024` | 对齐 OBS `AUDIO_OUTPUT_FRAMES`，也是 AAC 一帧长 |
| 字节数 | 1 帧 = 2 ch × 4 B = 8 B（planar 下每路 4 B） | 用于 AudioQueue buffer 尺寸计算 |

### 3.2 时间戳：一把钟、三条时间轴

| 时间轴 | 单位 | 谁在用 | 说明 |
|---|---|---|---|
| **系统单调钟**（唯一真理） | ns，`WLTime::NowNs()` | 混音窗口、视频 `video_time_`、所有 anchor | 与视频同一把尺，差值才有意义 |
| 源时基（媒体 pts / 设备 host time） | ns | 生产端入口 | 只假设"内部单调、间隔正确"，不假设与系统钟同基准 |
| 归一化后（= 源时基 + `timing_adjust`） | ns | `audio_ts_`、`mix` 批时间戳 | **音频与视频在系统钟域天然对齐** |

映射：`sys = src_ts + timing_adjust`，`timing_adjust = 锚定时刻系统钟 − 锚定帧源 ts`（见 §6.1）。

### 3.3 命名与对标

| 本文 | OBS | 含义 |
|---|---|---|
| `audio_ts_` | `source->audio_ts` | 本源下一段待混样本的系统钟时刻 |
| `timing_adjust_` | `source->timing_adjust` | 源时基 → 系统钟偏移 |
| `next_audio_ts_min_` | `source->next_audio_ts_min` | 期望下一批的源时基 ts（抖动平滑用） |
| `RenderAudio()` | `obs_source_audio_render` + `mix_audio` | 按偏移求和进 mix |
| `DiscardAudio()` | `discard_audio` | 混完丢弃已消费样本、推进 `audio_ts_` |
| `start_point` | `mix_audio` 的 `start_point` | 窗口起点到源数据起点的采样偏移 |

---

## 4. 模块设计

### 4.1 `WLAudioFormat`（常量与换算，header-only）

对标 `WLTime.hpp` 的形态（全 static、header-only），**先落地这个文件**——后面所有模块依赖它的常量，避免魔数散落。

```cpp
// audio/WLAudioFormat.hpp
#ifndef WLAudioFormat_hpp
#define WLAudioFormat_hpp

#include <stdint.h>

class WLAudioFormat {
public:
    static const int     kSampleRate   = 48000;  // D1：内部统一采样率
    static const int     kChannels     = 2;      // 立体声
    static const int     kTickFrames   = 1024;   // 每拍样本数（= AAC 一帧）
    static const int64_t kNoTs         = INT64_MIN;  // 未锚定哨兵（0 是合法 ts）

    // 帧数 → 纳秒（用 128 位中间量避免溢出：frames 可能很大）
    static int64_t FramesToNs(int64_t frames) {
        return (int64_t)((frames * 1000000000LL) / (int64_t)kSampleRate);
    }
    // 纳秒 → 帧数（向下取整，用于 start_point 偏移计算）
    static int64_t NsToFrames(int64_t ns) {
        if (ns <= 0) return 0;
        return (int64_t)((ns * (int64_t)kSampleRate) / 1000000000LL);
    }
    // 一帧的字节数（所有声道合计）
    static int FrameBytes() { return kChannels * (int)sizeof(float); }
};

#endif
```

> ⚠ `NsToFrames` 必须向下取整并 clamp 到 `[0, tick_frames]`，否则浮点/整数舍入会让 `audio_ts` 与窗口边界差 1 ns，触发无意义的重锚（OBS 用 `ts->start - 1` 的 1ns 容差吸收，我们直接用取整规避）。

### 4.2 `WLResampler`（swresample 封装）

**职责**：把任意解码输出（`s16/fltp/s32`、8k~192k、mono~7.1）转成统一格式（48k / 立体声 / fltp）。

```cpp
// audio/WLResampler.hpp
class WLResampler {
    SwrContext *swr_;
    bool        configured_;
    int         out_rate_;
    int         out_channels_;

public:
    WLResampler();
    ~WLResampler();

    // 按输入参数（重）配置。参数与上次相同则直接返回 true（不重建）。
    bool Configure(int in_rate, uint64_t in_ch_layout, AVSampleFormat in_fmt);

    // 转换。返回实际写出帧数；<=0 表示失败/无输出。
    // out 需预分配：max_out = EstimateOutFrames(in_frames)
    int  Convert(const uint8_t **in, int in_frames, uint8_t **out, int out_capacity);

    // seek / flush 时排空内部延迟样本（swr 有 ~几十 ms 内部缓冲）
    int  Flush(uint8_t **out, int out_capacity);

    // 输出容量估算：上取整 + swr 延迟（留 32 帧余量）
    int  EstimateOutFrames(int in_frames) const;
};
```

**关键参数与坑**

| 项 | 取值 | 说明 |
|---|---|---|
| 输出 | `48000` / `AV_CH_LAYOUT_STEREO` / `AV_SAMPLE_FMT_FLTP` | D1 |
| 重采样算法 | `SWR_DITHER_NONE`，默认 `swr_alloc_set_opts2` 的 `SINC` | 首期不调 quality；如需省 CPU 再换 `linear` |
| 内部延迟 | `swr_get_delay()` | **必须在 `EstimateOutFrames` 里算进去**，否则 out_capacity 不够会静默截断 |
| **中途改格式** | 输入 rate/layout/fmt 变化 → `Configure` 内部 `swr_free` + 重建 | 文件少（VFR 音频流切换）；**麦克风源不会变** |
| **Flush 时机** | seek / loop / EOF / 源 destroy | 不 flush 会残留样本导致 seek 后"咔哒" |
| 线程 | 只被**生产线程**调用（解码线程 or HAL 回调） | 无需加锁；`SwrContext` 非线程安全 |

> 麦克风源如果设备格式本来就是 48k/立体声/float，`Configure` 后 `Convert` 仍走 swr（**不 bypass**）——保持单一路径，避免两条代码路径不一致。开销可接受（1024 帧 memcpy 量级）。

### 4.3 `WLAudioRing`（per-source PCM 环形缓冲）

```cpp
// audio/WLAudioRing.hpp
class WLAudioRing {
    float    *buf_[2];        // planar：每声道一段
    int       capacity_;      // 帧数（建议 8192 = 170.7ms @48k）
    // SPSC 无锁：写端独占 write_，读端独占 read_，各自 atomic 读写
    _Atomic int write_;       // 累计写入帧数（单调）
    _Atomic int read_;        // 累计读取帧数（单调）
    _Atomic uint32_t overflow_;   // 生产端丢新计数（诊断）
    _Atomic uint32_t underrun_;   // 消费端补静音计数（诊断）

public:
    WLAudioRing(int capacity_frames);   // 容量向上取到 2 的幂（便于位运算取模）
    ~WLAudioRing();

    // 生产端（单线程）：写入；空间不足 → 丢弃放不下的部分并 overflow_++（D4）
    int  Push(const float *const *data, int frames);

    // 消费端（单线程）：读出；数据不足 → 尾部补 0（静音）并 underrun_++，返回实际真实帧数
    int  Peek(float **out, int frames);

    // 消费端：丢弃已混掉的帧（推进 read_）
    int  Discard(int frames);

    // 消费端：直接丢弃最旧的 n 帧（落后重锚用，= OBS ignore_audio）
    int  DropOldest(int frames);

    int  Available() const;   // read_ → write_ 的可读帧数
    int  FreeFrames() const;  // capacity_ − Available()
    void Reset();             // read_ = write_ = 0（seek/loop/flush）
    uint32_t OverflowCount() const;
    uint32_t UnderrunCount() const;
};
```

**设计要点**

| 项 | 决定 | 理由 |
|---|---|---|
| 同步 | SPSC lock-free：`write_` 只被生产线程写、`read_` 只被消费线程写，读对方用 `atomic_load_explicit(memory_order_acquire)`，写自己用 `release` | D5：HAL 回调不能有锁；临界区只有 memcpy，持锁不划算 |
| 容量 | 8192 帧（170.7 ms），2 路 × 32 KB = **64 KB/源** | 覆盖解码突发（一次 AAC 帧 1024）+ 混音线程抖动；64 源也才 4 MB |
| 溢出 | 生产端丢新 + 计数（保险阀） | D4；正常播放由水位限速保证永不触发 |
| 空读 | 消费端补静音 + 计数 | 音频不可不连续；补静音优于重复样本 |
| 内存 | ctor 里 `calloc`，dtor `free`（Orthodox C++，不用 STL） | 与 `WLSource::frames_` 风格一致 |

### 4.4 `WLSource`（壳）音频区扩展

**条件分配**：`WL_SOURCE_AUDIO` 位置位才分配 ring（与 `WL_SOURCE_ASYNC` 条件分配 `frames_` 同构）。

```cpp
// source/WLSource.hpp 新增成员
    // ── 音频（AUDIO 位条件分配）──
    class WLAudioRing *ring_;      // NULL = 不产音频（与 ASYNC 位同构）
    int64_t  audio_ts_;            // 下一待混样本的系统钟时刻；kNoTs = 未锚定
    int64_t  timing_adjust_;       // 源时基 → 系统钟
    bool     audio_timing_set_;
    int64_t  next_audio_ts_min_;   // 期望下一批源时基 ts（抖动平滑）
    float    gain_;                // 0.0~1.0+（默认 1.0）
    bool     muted_;
    pthread_mutex_t audio_mutex_;  // 护 audio_ts_ / timing / gain（短临界区，不护 ring）
```

```cpp
// source/WLSource.hpp 新增接口
public:
    // ── 音频入口（生产端：实现体在自己的线程调用；对标 obs_source_output_audio）──
    // data[ch][frame]，frames 帧，pts_ns 为源时基时间戳
    void OutputAudio(const float *const *data, int frames, int64_t pts_ns);

    // 显式指定时基偏移（媒体源复用视频的同一个 anchor，见 §6.1）
    void SetAudioTimingAdjust(int64_t adjust_ns);

    // seek / loop / flush / destroy 前调用：清 ring + 复位时基，下一批重新锚定
    void ResetAudioTiming();

    // ── 消费端（仅 WLAudioMixer 调用）──
    // 把本源 [audio_ts_, +frames) 的样本按时间戳偏移叠加进 mix（planar, frames 长）
    // 返回：是否贡献了样本
    bool RenderAudio(float **mix, int frames, int64_t window_start_ns);

    // 混完推进：丢弃本窗口已消费样本，audio_ts_ → window_end_ns
    void DiscardAudio(int64_t window_end_ns);

    // 控制（UI → WLCore → 本壳）
    void SetGain(float g);
    void SetMuted(bool m);
    int  AudioAvailable() const;   // ring 可读帧数（水位限速用）
    bool HasAudio() const { return ring_ != NULL; }
```

**`OutputAudio` 内部流程**（对标 `source_output_audio_data`，OBS `obs-source.c:1572`）：

```
1. 无 ring（未声明 AUDIO 位）→ 直接返回
2. lock(audio_mutex_)
3. 时基归一（详见 §6.2 三档阈值）：
     · 未锚定 → 若有外部 adjust（SetAudioTimingAdjust）用它，否则 adjust = NowNs() − pts
     · |pts − next_audio_ts_min_| < 70ms  → pts = next_audio_ts_min_（抹平小抖动）
     · 70ms ~ 2s                          → 原样（只记日志）
     · > 2s                               → 重锚：adjust = NowNs() − pts，ring_->Reset()
   next_audio_ts_min_ = pts + FramesToNs(frames)
   sys_ts = pts + timing_adjust_ ；若 audio_ts_ 未锚定 → audio_ts_ = sys_ts
4. unlock
5. ring_->Push(data, frames)   ← 无锁，锁外做（缩短临界区）
```

**`RenderAudio` 内部流程**（对标 `obs_source_audio_render` + `mix_audio`）：

```
start = window_start，end = start + FramesToNs(frames)
if (audio_ts_ == kNoTs || audio_ts_ >= end) return false;      // 未来/未锚定：不贡献
start_point = (audio_ts_ > start) ? NsToFrames(audio_ts_ − start) : 0
if (start_point >= frames) return false;
// 落后重锚（D4）：audio_ts_ 早于窗口起点超过 MAX_LAG → 丢掉滞后样本，贴到窗口起点
if (audio_ts_ < start − kMaxLagNs) { ring_->DropOldest(NsToFrames(start − audio_ts_)); audio_ts_ = start; }
n = ring_->Peek(scratch, frames − start_point);                 // 不足自动补静音
for ch: for i: mix[ch][start_point + i] += scratch[ch][i] * (muted_ ? 0 : gain_);
```

> `scratch` 由 `WLAudioMixer` 提供（复用一块 1024 帧缓冲，避免每源每次分配）。

### 4.5 `WLMediaSource`（生产端改造）

**改动点 1：音频通路**（替换现在的 `[src A]` 临时日志）

```
// ThreadLoop 步骤 3
wl_frame_result_t ar = decoder_->ReceiveAudio(&aframe, &apts);
if (ar == WL_FRAME_OK) {
    OutputAudioFrame(aframe, apts);   // 新增
    av_frame_free(&aframe);
    // 注意：音频分支不再 continue（见下）
}
```

```cpp
void WLMediaSource::OutputAudioFrame(AVFrame *f, int64_t pts_ns) {
    // 1) 重采样到统一格式（内部持有 resampler_，常驻复用）
    if (!resampler_->Configure(f->sample_rate, f->channel_layout /*或 ch_layout*/,
                               (AVSampleFormat)f->format)) return;
    int max_out = resampler_->EstimateOutFrames(f->nb_samples);
    // out_buf_ 按需 realloc（Orthodox C++：malloc/realloc + 容量记录）
    int n = resampler_->Convert((const uint8_t **)f->data, f->nb_samples,
                                out_buf_, max_out);
    if (n <= 0) return;

    // 2) 统一时间映射（§6.1）：把"媒体时基 → 系统钟"的常数项交给壳
    source_->SetAudioTimingAdjust(SysOfOffset());   // = base_ts_ns_ − start_ts_ns_ + play_sys_ts_ns_

    // 3) 投喂（仍传媒体时基 pts，壳内部 +timing_adjust 归一 + 70ms/2s 阈值平滑）
    source_->OutputAudio((const float *const *)out_buf_, n, pts_ns);

    // 4) 产量记账（限速判定在循环顶部，见改动点 3）
    audio_produced_frames_ += n;
}
```

**改动点 2：统一 A/V 时间锚（A6 同步的根）——逐字照抄 OBS**

OBS 里**视频帧与音频帧用同一个公式**，一个字符都不差（`deps/media-playback/media-playback/media.c` 的 `477`（video）与 `388`（audio））：

```c
timestamp = m->full_decode ? d->frame_pts
                           : m->base_ts + d->frame_pts - m->start_ts + m->play_sys_ts - base_sys_ts;
```

四个量的语义：

| 量 | 含义 | 何时变 |
|---|---|---|
| `base_ts` | 媒体时间轴累计平移量（seek/loop 时 `+= 目标 pts`） | seek / loop |
| `start_ts` | 本次播放起点（媒体时基） | 起播 / reset |
| `play_sys_ts` | 本次播放起点的系统钟 `os_gettime_ns()` | 起播 / reset / 暂停恢复 |
| `base_sys_ts` | 进程级零点（首次初始化时的 `os_gettime_ns()`，`media.c:951`） | 不变 |

我们不需要 `full_decode`（那是"不解码直接全速跑"模式）与跨源共享的进程零点，简化为**一个映射函数**：

```cpp
// 媒体时基 → 系统钟。视频帧与音频帧共用，差值恒为 0（不是"接近"，是同一个函数）
int64_t WLMediaSource::SysOf(int64_t pts_ns) const {
    return base_ts_ns_ + pts_ns - start_ts_ns_ + play_sys_ts_ns_;
}

// 起播 / 暂停恢复 / reset 时调用（对标 OBS reset_ts，media.c:769）
void WLMediaSource::ResetTs() {
    play_sys_ts_ns_ = WLTime::NowNs();
    start_ts_ns_    = next_pts_ns_ = MinReadyPts();   // 视频/音频就绪帧里较小的 pts
    next_ns_        = 0;                              // 0 = 下一轮重新锚定
}
```

- 视频帧时间戳与音频帧时间戳都过 `SysOf()` → **天然对齐**；
- `Seek()`：`base_ts_ns_ += 目标 pts`（媒体轴平移，**不动** `play_sys_ts_ns_`）→ 与 OBS `m->base_ts += ...` 一致，`Loop`（L1）同理累加；
- **暂停恢复**：只调 `ResetTs()` —— 音视频是同一个量一起改，这正是 ToDo P2 的落点（§6.5 坑 3 的根治办法）；
- 音频侧：媒体源仍传**媒体时基** pts 给 `OutputAudio`，并用 `SetAudioTimingAdjust(SysOfOffset())` 告诉壳同一条映射 → 壳里 70ms/2s 的阈值平滑照常生效，且与麦克风源（首帧自锚 `timing_adjust_ = NowNs() − pts`）共用一套代码。

**改动点 3：单一 pace = `next_pts_ns` 放行线（D3，照抄 OBS `mp_media_sleep`）**

OBS 的答案既不是"视频 pace + 音频水位"，也不是"两路各 pace"，而是：**整条循环只有一处 sleep，睡的是"下一位出场的帧"——不管它是视频还是音频。**

```c
// media.c:322  下一位出场的是谁？= 视频/音频就绪帧里 pts 较小的那个
static inline int64_t mp_media_get_next_min_pts(mp_media_t *m) { /* min(v.frame_pts, a.frame_pts) */ }

// media.c:529  按"增量"推进 next_ns（绝对基准，不累积漂移）
static void mp_media_calc_next_ns(mp_media_t *m) {
    int64_t min_next_ns = mp_media_get_next_min_pts(m);
    int64_t delta = min_next_ns - m->next_pts_ns;
    if (m->seek_next_ts) { delta = 0; m->seek_next_ts = false; }
    else { if (delta < 0) delta = 0; if (delta > 3000000000) delta = 0; }  // 3s 跳变保护
    m->next_ns += delta;
    m->next_pts_ns = min_next_ns;
}

// media.c:632  唯一一处 sleep
static inline bool mp_media_sleep(mp_media_t *m) {
    if (!m->next_ns) { m->next_ns = os_gettime_ns(); }
    else {
        const uint64_t t = os_gettime_ns();
        if (m->next_ns > t) {
            const uint32_t delta_ms = (uint32_t)((m->next_ns - t + 500000) / 1000000);
            if (delta_ms > 0) {
                static const uint32_t timeout_ms = 200;      // 卡顿保护：最多睡 200ms
                timeout = delta_ms > timeout_ms;
                os_sleep_ms(timeout ? timeout_ms : delta_ms);
            }
        }
    }
    return timeout;
}

// media.c:353  谁到点谁出场（不是"视频到点"也不是"音频到点"）
static inline bool mp_media_can_play_frame(mp_media_t *m, struct mp_decode *d) {
    if (m->full_decode) return d->frame_ready;
    return d->frame_ready && (d->frame_pts <= m->next_pts_ns ||
                              (d->frame_pts - m->next_pts_ns > MAX_TS_VAR));   // 2s 跳变强放
}
```

主循环骨架（`media.c:796` 简化，去掉控制分支）：

```
for (;;) {
    timeout = mp_media_sleep(m);                      // ① 全循环唯一 sleep，睡到 next_ns
    ...
    if (is_active && !timeout) {
        if (m->has_video) mp_media_next_video(m, false);   // ② 到点才放（can_play_frame 判定）
        if (m->has_audio) mp_media_next_audio(m);          // ③ 到点才放
        if (!mp_media_prepare_frames(m)) return false;     // ④ 解码补货：两路都 ready 才返回
        if (mp_media_eof(m)) continue;
        mp_media_calc_next_ns(m);                          // ⑤ 按 min(v,a) 增量推进
    }
}
```

**为什么这样根本不需要水位限速**：`next_pts_ns` 是"当前放行线"，每轮只放行 `pts ≤ next_pts_ns` 的帧，然后按 **min(视频, 音频)** 增量推进。于是一轮里**不会**无条件"视频一帧 + 音频一帧"，谁到点谁走 → 生产速率 = 合并事件序列的速率 = **1.0× 实时**。OBS 的音频 deque 上限（≈23 秒音频）设得那么大，正因为正常播放根本摸不到——它只是防内存爆炸的保险阀。

> 这也纠正了上一版的分析：所谓"音频 1.28× 超产"是**我们现状**（步骤 2/3 谁有帧谁产、只被视频 pts 节流）造成的，不是这个问题的固有属性。OBS 用放行线从根上消除了它。

**我们的改造**（替换现 `PaceVideo`，删掉水位饥饿）：

```cpp
void WLMediaSource::ThreadLoop() {
    while (!atomic_load(&should_stop_)) {
        // 1. 控制检查（pause / stop / seek）——同现状

        // 2. 唯一 sleep：睡到 next_ns_（绝对时刻；0 = 尚未锚定）
        if (next_ns_ == 0) { ResetTs(); continue; }
        bool timeout = !WLTime::SleepToNs(next_ns_);
        // 卡顿保护（对照 OBS 的 200ms）：落后太多时只睡一小段并记日志，别一次性睡死
        if (timeout && WLTime::NowNs() - next_ns_ > 200000000LL) {
            fprintf(stderr, "[media] lag %.1fms\n", (WLTime::NowNs() - next_ns_) / 1e6);
        }

        // 3. 到点才放（视频、音频各自独立判定，互不等待）
        if (v_ready_ && CanPlay(v_pts_)) { OutputVideoFrame(v_frame_, v_pts_); v_ready_ = false; }
        if (a_ready_ && CanPlay(a_pts_)) { OutputAudioFrame(a_frame_, a_pts_); a_ready_ = false; }

        // 4. 解码补货：两路都 ready（或已 eof）才继续 —— 对标 mp_media_ready_to_start (media.c:204)
        while (!(v_ready_ || v_eof_) || !(a_ready_ || a_eof_)) {
            /* ReceiveVideo / ReceiveAudio / Read，同现状的先收后读顺序 */
        }

        // 5. 增量推进放行线
        int64_t min_next = MinReadyPts();
        if (min_next - next_pts_ns_ < 0 || min_next - next_pts_ns_ > 3000000000LL) {
            min_next = next_pts_ns_;                    // 跳变保护（OBS 用 3s）
        }
        next_ns_    += (min_next - next_pts_ns_);
        next_pts_ns_ = min_next;
    }
}
bool WLMediaSource::CanPlay(int64_t pts_ns) const {      // 对标 mp_media_can_play_frame
    return pts_ns <= next_pts_ns_ || (pts_ns - next_pts_ns_ > 2000000000LL);   // 2s 跳变强放
}
```

**三个方案的定量对比**（48 kHz / AAC 1024 帧 = 21.333 ms；60 fps = 16.667 ms）

| 方案 | 后果 |
|---|---|
| **① 视频、音频各 pace 一次** | 每轮取 `max(k·16.67, k·21.33)` → 墙钟被锁死成 46.875 fps（= 48000/1024），**视频慢 22%**，落后量 `k·4.67ms` 持续累积 |
| **② 只 pace 视频 + 水位 sleep** | 音频 1.28× 超产，每 ~0.3 s 触发一次 42.7 ms 的 sleep ≈ **卡 2.6 个视频帧** |
| **③ 只 pace 视频 + 水位饥饿** | 视频零影响，但稳态有 ~21% 的轮次要跳过音频，逻辑绕、且音频生产"锯齿" |
| **④ 单一放行线 `next_pts_ns`（选定，= OBS）** | **只有一个 pace**：60fps + 48k 的合并事件序列是 `{0, 16.67, 21.33, 33.33, 42.67, 50, …}`，放行线按它推进。视频帧 k 的出帧时刻 ≈ `SysOf(k·16.67)`，与"只给视频 pace"完全一致 → **视频零影响**；音频帧 j 同理 → **音频也不超产**。无饥饿、无水位限速 |

**水位降为保险阀**：`WL_AUDIO_WATERMARK_HIGH`（4096 帧）保留，但语义改为"异常探针"——正常永不触发；一旦触发说明放行线推进失准（时间戳跳变 / 解码异常），记日志并丢最旧 + 重锚。不再是主策略。

**改动点 4：seek / loop / EOF 时的音频处理**

- `Seek()`：`decoder_->Flush()` 之外，补 `resampler_->Flush()`（把 swr 残留样本投完）+ `source_->ResetAudioTiming()`；
- `Loop`（L1）：`base_ts_ns_ += 上一段总时长`（**不重锚** `play_sys_ts_ns_`），音视频随之连续——与 OBS `m->base_ts += ...` 同构；
- EOF drain：`ReceiveAudio` 返回 `WL_FRAME_EOF` 后不再有数据，ring 自然排空，混音端补静音。

### 4.6 `WLAudioMixer`（全局混音节拍）

```cpp
// audio/WLAudioMixer.hpp
// 混音结果消费者（sink）：播放 / 编码。在混音线程被调用，勿阻塞、勿回头改源列表。
// mix[ch][frame]（planar，WL_AUDIO_CHANNELS 路，frames 帧）
// start_ts_ns = 本批第一个样本"应被听到"的系统钟时刻
typedef void (*wl_audio_mix_cb)(const float *const *mix, int frames,
                                int64_t start_ts_ns, void *ctx);

class WLAudioMixer {
    pthread_t   thread_;
    bool        thread_running_;
    atomic_bool should_stop_;

    int64_t start_time_ns_;   // 时钟起点（= Start 时的 NowNs）
    int64_t samples_;         // 累计样本数（每拍 +1024）
    int64_t prev_time_ns_;    // 上一窗口起点

    // sinks（护 cb 指针的读写，同 WLGraphics::output_mutex_ 形状）
    struct { wl_audio_mix_cb cb; void *ctx; } sinks_[WL_AUDIO_MAX_SINKS];
    int              sink_count_;
    pthread_mutex_t  sink_mutex_;

    float *scratch_[2];       // 逐源渲染暂存（1024 帧/路）
    float *mix_[2];           // 本拍混音结果（1024 帧/路）

    static void *MixerThreadFunc(void *arg);
    void ThreadLoop();
    void TickOnce(int64_t window_start_ns, int64_t window_end_ns);
    void AudioSleep();        // samples_ += 1024；SleepToNs(start + samples→ns)

public:
    WLAudioMixer();
    ~WLAudioMixer();          // 幂等 Stop（join 混音线程）

    int  Start();
    void Stop();

    // 注册/注销消费者（线程安全，可在运行时调用）
    void AddSink(wl_audio_mix_cb cb, void *ctx);
    void RemoveSink(wl_audio_mix_cb cb, void *ctx);

    // 诊断：最近一拍参与混音的源数 / 补静音次数 / 重锚次数
    void Stats(uint32_t *out_underrun, uint32_t *out_reanchor) const;
};
```

**每拍流程**（对标 `audio_thread` + `audio_callback`）

```
TickOnce(start, end):
  memset(mix_, 0, 1024*4*2)
  count = 0
  // ① 锁内：快照源列表 + 逐源渲染（解引用只在锁内，D7）
  WLCore::ForeachSource(CollectAndRender, &ctx)   // ctx 里带 mix_/scratch_/start/end
  // ② 锁外：分发给 sinks
  for i in sinks_: cb((const float**)mix_, 1024, start, ctx)
  // ③ 锁外：逐源 Discard（推进 audio_ts_）——需要源列表，故在①的锁内另存指针数组快照，
  //    但出锁后源可能已被 delete → 见下方"⚠ 生命周期"的处理
```

⚠ **生命周期问题**（我们没有 OBS 的源引用计数）：出锁后源可能已被 `RemoveSource` 删除。处理方式——**把 `DiscardAudio` 也放进锁内**（它只是推进 `audio_ts_` 和 ring 读指针，O(1)，不阻塞），**只把 sink 分发放锁外**（sink 是用户回调，可能阻塞）。即：

```
锁内：快照源指针数组 → 逐源 RenderAudio → 逐源 DiscardAudio
解锁：sinks 分发（只碰本地 mix_ 缓冲）
```

这与 `WLGraphics::ThreadLoop` 的"锁内挑帧、锁外 push"同构，只是粒度不同（音频无 owned 引用可借，只能拷贝）。

**节拍实现**（对标 `audio_thread`，`audio-io.c:205`）

```cpp
void WLAudioMixer::AudioSleep() {
    samples_ += WLAudioFormat::kTickFrames;                       // 每拍固定 1024
    int64_t audio_time = start_time_ns_ + WLAudioFormat::FramesToNs(samples_);
    WLTime::SleepToNs(audio_time);        // 睡到绝对时刻 → 误差不累积（与 VideoSleep 同原理）
    // 卡顿（audio_time 已过去）：不补帧，直接推进（音频不能"复帧"，落后部分由补静音/重锚吸收）
}
```

> 与视频 `VideoSleep` 的差异：**视频卡顿要 `count` 复帧保持 CFR；音频卡顿只能"认账"**——落后的窗口已经被墙钟跳过，靠 `RenderAudio` 的重锚把源拉回当前窗口（丢掉滞后样本），绝不能把旧样本迟到地播出来。

**动态缓冲（D8，首期不做）**：OBS 的 `add_audio_buffering`（整条管线后退给慢源让路）需要在 `TickOnce` 前判断 `min_ts < window_start`。接口位置预留：在 `TickOnce` 开头加 `bool NeedMoreBuffering(int64_t *out_new_window)`，首期直接 `return false`。

### 4.7 `WLAudioOutput`（AudioQueue 播放，A5）

```cpp
// audio/WLAudioOutput.hpp
class WLAudioOutput {
    AudioQueueRef        queue_;
    AudioQueueBufferRef  buffers_[3];
    WLAudioRing         *ring_;        // interleaved Float32（AudioQueue 直接吃的格式）
    bool                 running_;
    _Atomic uint32_t     underrun_;    // 回调取不到数据的次数

    static void AQCallback(void *user, AudioQueueRef aq, AudioQueueBufferRef buf);

public:
    WLAudioOutput();
    ~WLAudioOutput();

    int  Start();   // 建 queue + 3 buffer，预填静音，水位到 2×1024 后 AudioQueueStart
    void Stop();    // AudioQueueStop(true) + Reset + ring_->Reset()
    void Flush();   // seek/pause：清 ring，保留 queue

    // mixer 的 sink：interleave 后写入 ring（非阻塞）
    void Push(const float *const *mix, int frames, int64_t start_ts_ns);
};
```

**ASBD（关键参数）**

| 字段 | 值 | 说明 |
|---|---|---|
| `mSampleRate` | 48000 | = `WLAudioFormat::kSampleRate` |
| `mFormatID` | `kAudioFormatLinearPCM` | — |
| `mFormatFlags` | `kAudioFormatFlagIsFloat \| kAudioFormatFlagIsPacked` | **交错（非 NonInterleaved）**；AudioQueue 输出走交错最稳 |
| `mChannelsPerFrame` | 2 | — |
| `mBitsPerChannel` | 32 | float |
| `mFramesPerPacket` | 1 | PCM |
| `mBytesPerFrame` | 8 | 2ch × 4B |
| `mBytesPerPacket` | 8 | — |

**缓冲与延迟**

| 项 | 值 | 说明 |
|---|---|---|
| 缓冲数 × 大小 | 3 × 1024 帧（各 8 KB） | 总 24 KB → **64 ms** 设备侧延迟 |
| 起播水位 | ring ≥ **2 × 1024 帧**（42.7 ms） | 抗一次抖动；首次达到才 `AudioQueueStart` |
| underrun 处理 | 回调取不到 → 写静音 + `underrun_++` | 连续超阈值记日志（排查 pacing/限速是否失准） |
| 端到端延迟 | ≈ ring LOW(42.7ms) + AQ(64ms) ≈ **107 ms** | 与 OBS 监听同量级；要更低可把 AQ 缓冲降到 2 × 512 |

**为什么 pull 而不是 push（D6）**：mixer 每拍把 1024 帧写进 output ring，AudioQueue 回调按设备节奏取。设备缓冲与混音节拍解耦，混音线程永不阻塞在设备上；push 模型（`AudioQueueEnqueueBuffer` 直接由 mixer 调）会让 queue 内部积压不可控。

**线程**：`Push` 在混音线程，`AQCallback` 在 AudioQueue 内部的高优先级线程 → `ring_` 必须无锁（复用 `WLAudioRing`，但存的是**交错**数据：`ring_` 用 1 路逻辑、每"帧" 8 字节）。> 实现细节：`WLAudioRing` 按 `float* buf_[2]` 设计；交错模式可令 `buf_[0]` 指向 8 字节粒度缓冲并把"帧数"按 `frames*2` 换算，或给 ring 加一个 `interleaved` 构造开关。**建议后者**（`WLAudioRing(int capacity, int channels, bool interleaved)`），避免魔数换算。

### 4.8 `WLAudioEncoder`（AAC，M2/M4）

```cpp
// audio/WLAudioEncoder.hpp
class WLAudioEncoder {
    AVCodecContext *ctx_;
    AVFrame        *frame_;
    AVPacket       *pkt_;
    float          *acc_[2];        // 攒帧缓冲（>=1024）
    int             acc_frames_;
    int64_t         cur_pts_;       // 编码 pts（samplerate timebase，+= 1024）
    int64_t         start_ts_ns_;   // 首帧系统钟（与视频 encoder 对齐用）
    bool            started_;

public:
    // 参数为统一格式（48k/2ch/fltp），失败返回非 0
    int  Open(int bitrate_kbps);
    void Close();
    // 喂一批混音结果；内部攒够 frame_size 编一包，回调吐出
    int  Encode(const float *const *mix, int frames, int64_t start_ts_ns,
                void (*on_packet)(AVPacket *pkt, int64_t start_ts_ns, void *ctx), void *ctx);
    // 排空（录制停止前）
    int  Flush(void (*on_packet)(...), void *ctx);
    int  FrameSize() const;         // 1024
    int64_t StartTsNs() const;      // 供输出层做 a/v 对齐
};
```

**关键参数**

| 项 | 值 | 说明 |
|---|---|---|
| 编码器 | **`aac_at`**（AudioToolbox）为主，失败降级 FFmpeg 原生 `aac` | ToDo M2 已定 `aac_at` |
| sample_rate / channels / fmt | 48000 / 2 / `AV_SAMPLE_FMT_FLTP` | 与内部格式一致，**不再重采样** |
| bitrate | **128 kbps**（立体声）；可选 96/160/192 | OBS 默认 160k；128k 对语音/一般音源足够 |
| profile | `FF_PROFILE_AAC_LOW`（AAC-LC） | 兼容性最好；HE-AAC 首期不做 |
| time_base | `{1, 48000}` | pts 单位=采样点，与 OBS 一致 |
| 帧长 | **1024**（`ctx->frame_size`） | 攒够才 `send_frame`（OBS `receive_audio` 的 `framesize_bytes` 逻辑） |
| pts | `cur_pts_ += 1024`（从 0 自增） | 与视频 encoder 的 `cur_pts` 同构；系统钟另存 `start_ts_ns_` |

**与视频的 a/v 对齐（输出层）**：录制/推流时在 muxer 前复用第④篇的三件套——
1. **discard**：首个视频关键帧之前的音频包丢弃（`discard_unused_audio_packets`）；
2. **共同起点 + 归零**：`audio_start_ts` 强制取视频 `start_ts`（OBS `buffer_audio`：`encoder->start_ts = paired_encoder->start_ts`，早于视频起点的样本按采样率换算字节数丢弃）；
3. **按 `dts_usec` 排序 + 单调交错送出**：`dts_usec = start_ts/1000 + packet_dts_usec(pkt) − offset_usec`。

> 这层应做成**独立 Interleaver 组件**，录制 mp4（M2）与 RTMP 推流（M5）共用，不要两条路径各写一份。

### 4.9 `WLMicSource`（CoreAudio 采集，M4）

```cpp
// source/WLMicSource.hpp
class WLMicSource : public WLSourceProtocol {
    WLSource      *source_;
    AudioUnit      unit_;          // kAudioUnitSubType_HALOutput，bus 1 输入
    WLResampler   *resampler_;
    bool           running_;

    static OSStatus InputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioFlags,
                                  const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                                  UInt32 inNumberFrames, AudioBufferList *ioData);
    void Deliver(const AudioBufferList *abl, int frames, const AudioTimeStamp *ts);

public:
    // settings: 设备 UID（NULL = 系统默认输入设备）
    int  Start() override;
    void Stop() override;
    // ...
    static void RegisterType();
};
```

**关键参数与要点**

| 项 | 值/做法 | 说明 |
|---|---|---|
| 采集单元 | AudioUnit `kAudioUnitSubType_HALOutput`，**enable bus 1（input）、disable bus 0（output）** | OBS `mac-capture` 同路；比 `AVCaptureAudioDataOutput` 延迟更低、可控 |
| 流格式（采集侧） | 设备原生（通常 48k 或 44.1k / 单声道或立体声 / Float32 或 SInt16），按 `kAudioUnitProperty_StreamFormat` 设置**设备侧**格式，`kAudioUnitProperty_SetRenderCallback` 拿数据 | 拿到后交给 `WLResampler` 归一（**不要求设备等于内部格式**） |
| IO buffer | `kAudioUnitProperty_MaxFramesPerSlice` / 期望 1024 帧；实际回调帧数由系统决定（常见 512/1024） | 回调里**不假设固定帧数**，`Deliver` 按实际 frames 走 |
| 时间戳 | `inTimeStamp->mHostTime` → 纳秒（用 `mach_timebase_info` 换算）；**首期简化**：用 `WLTime::NowNs()` 回调入口时刻 | 麦克风是实时源，首帧锚定误差只是固定延迟，不影响 A/V 相对关系 |
| 回调纪律 | **只做 `AudioUnitRender` + 重采样 + `OutputAudio`**，不加锁、不 malloc、不打日志、不调 ObjC | 音频回调有硬 deadline；`Push` 是无锁 SPSC 正是为此（D5） |
| 输出 flags | `WL_SOURCE_AUDIO`（**不带** ASYNC：无视频） | 与 `media_file` 的 `ASYNC_VIDEO \| AUDIO` 分流依据一致 |
| 权限 | `NSMicrophoneUsageDescription` + entitlement `com.apple.security.device.audio-input` | M4 首次接入时加进 `project.yml` / Info.plist |

**系统音频（桌面内录，更低优先）**：macOS 13+ 走 `SCStreamConfiguration.capturesAudio`（ScreenCaptureKit，M3 屏幕采集同一栈）；更底层的虚拟声卡（如 BlackHole）方案不纳入。接口上与麦克风完全一致（同一个 `OutputAudio`），只是源的 `type id` 不同。

---

## 5. 线程模型与同步

### 5.1 线程清单

| 线程 | 数量 | 职责 | 唤醒方式 | 阻塞点 | 退出 |
|---|---|---|---|---|---|
| 媒体解码线程（`WLMediaSource`） | per-source | read → decode → 投音视频帧 | 循环（**全循环仅一处 sleep**：`SleepToNs(next_ns_)`） | 唯一 pace = 放行线 `next_pts_ns_`（音视频合一，D3） | `should_stop_` + `ctrl_cond_` → join |
| CoreAudio HAL 回调（`WLMicSource`） | 1/设备 | 采 PCM → `OutputAudio` | 系统回调 | **不可阻塞** | `AudioUnitUninitialize` |
| **混音线程（`WLAudioMixer`）** | **全局 1** | 每 1024 帧拉所有源混音 → sinks | `SleepToNs` 绝对时刻 | 仅短暂持源锁 | `should_stop_` → join（下一拍即醒） |
| AudioQueue 输出线程 | 1（系统） | 从 output ring 取 → 设备 | 设备回调 | 无（取不到就补静音） | `AudioQueueStop` |
| graphics 线程（`WLGraphics`） | 全局 1 | 视频节拍/合成（既有） | `SleepToNs` | 仅短暂持源锁 | 既有 |
| 编码器线程（M2） | per-encoder | 编码 + 送 interleaver | 队列/sem | 等包 | 既有设计 |

### 5.2 锁与顺序

```
锁层级（严格自上而下，禁止反向）：
  L1  WLCore 源列表锁（g_core.mutex）
        └─ L2  WLSource::audio_mutex_（护 audio_ts_/timing/gain，短临界区）
              └─（不再向下；ring 是无锁的）

另有独立锁（不与 L1/L2 嵌套）：
  WLAudioMixer::sink_mutex_（护 sinks 数组）
  WLAudioOutput 内部 queue 相关（AudioQueue 自带）
```

**契约**

1. `WLCore::ForeachSource` 全程持 L1：回调内**禁止** add/remove 源（与既有 graphics tick 同约束）；混音线程在 L1 内完成 `RenderAudio` + `DiscardAudio`，**sink 分发必须在 L1 外**。
2. `OutputAudio`（生产端）只拿 L2，**环形缓冲的 `Push` 在锁外**（无锁，且 memcpy 不该被 L2 拖住）。
3. `RemoveSource` / `Shutdown` 的 `delete` 在 L1 **外**执行（既有设计）；因此混音线程只要在 L1 内完成所有对源的解引用，就不会 UAF。
4. ring 的 SPSC 前提：**生产端单线程、消费端单线程**。一个源同时只能有一条生产线程（媒体源 = 解码线程；麦克风 = HAL 回调），不可两条。

### 5.3 启动 / 退出顺序

```cpp
int WLCore::Startup(int fps) {
    ...
    g_core.mixer = new WLAudioMixer();      // 新增
    if (g_core.mixer->Start() != 0) { delete g_core.mixer; g_core.mixer = NULL; return -1; }
    g_core.graphics = new WLGraphics(fps);
    ...
}

void WLCore::Shutdown() {
    // ① 先停两条节拍线程（join）——之后没人再遍历源列表
    delete g_core.mixer;    g_core.mixer = NULL;
    delete g_core.graphics; g_core.graphics = NULL;
    // ② 快照源列表 → 锁外 delete（既有逻辑不变）
    ...
}
```

> 输出（`WLAudioOutput`）由 UI 层通过 `WLCore::AddAudioSink(...)` 注册到 mixer；app 退出时先 `RemoveSink` 再 `Shutdown`（顺序反了也只是少几拍声音，不崩）。

### 5.4 D2 的风险与对策（不拆解码线程）

| 风险 | 表现 | 对策 |
|---|---|---|
| 音频解码拖慢视频 | 视频帧被延迟，掉帧 | 单一 pace（D3）：音频不单独 sleep，只由放行线决定"到点才投"，与 OBS 同构 |
| 单次 `ReceiveAudio` 耗时尖峰 | 视频卡顿 | 首期先测：若实测 >2ms/次，把音频解码挪到独立线程（ring 已是 SPSC，生产端换成解码线程即可，其它模块零改动） |
| swr 重采样耗时 | 同上 | 1024 帧重采样 ~0.1ms 量级，可忽略；性能验收时看 `lagged_frames` |

---

## 6. 时间戳与 A/V 同步

### 6.1 归一化模型（= OBS 的公式，音视频逐字相同）

OBS 里视频帧与音频帧用**同一个式子**（`deps/media-playback/media-playback/media.c` 的 `477`（video）与 `388`（audio））：

```
sys = base_ts + frame_pts − start_ts + play_sys_ts − base_sys_ts
```

WorkOBS 简化掉 `full_decode` 与进程级零点 `base_sys_ts` 后：

```
SysOf(pts) = base_ts_ns_ + pts − start_ts_ns_ + play_sys_ts_ns_

视频帧时间戳 = SysOf(v_pts)  ──► 由放行线决定"何时出帧"，并与 graphics tick 的墙钟同基准
音频帧时间戳 = SysOf(a_pts)  ──► OutputAudio 归一后写入 audio_ts_ ──► 混音窗口对齐
```

- **媒体源**：音视频过**同一个** `SysOf()`，两者差值恒为 0（不是"接近"）→ 天然对齐。
  - `base_ts_ns_`：媒体轴平移量，只在 **seek / loop** 时 `+= 目标 pts`（`play_sys_ts_ns_` 不动）——对应 OBS `m->base_ts += ...`；
  - `start_ts_ns_` / `play_sys_ts_ns_`：本次播放的媒体起点与墙钟起点，只在 `ResetTs()`（起播 / 暂停恢复 / reset）时重设。
- **实时源（麦克风）**：没有媒体时间轴，走壳侧 `OutputAudio` 的 `timing_adjust_ = NowNs() − pts`（OBS `reset_audio_timing` 同款），`SysOf` 不参与。

### 6.2 入口三档阈值（`OutputAudio`，对标 OBS）

| 偏差 `|pts − next_audio_ts_min_|` | 处理 | 物理含义 |
|---|---|---|
| **< 70 ms**（`TS_SMOOTHING_THRESHOLD`） | `pts = next_audio_ts_min_`（**强制抹平**） | 容器舍入/抖动；音频按 ts 精确摆放，小 gap/overlap 会"咔哒"，必须抹平 |
| 70 ms ~ 2 s | 原样放入（记 debug 日志） | 中等异常，罕见 |
| **> 2 s**（`MAX_TS_VAR`） | **重锚**：`timing_adjust = NowNs() − pts` + `ring->Reset()` + `audio_ts_ = kNoTs` | seek / 回绕 / 断流重连；硬复位防卡死 |

> 视频侧已有对应机制：`frame_out_of_bounds` ±2s（`WLSource` 挑帧的追赶逻辑）。两边阈值一致（2 s）。

### 6.3 消费端对齐（`RenderAudio` / `DiscardAudio`）

```
窗口 [start, end)，宽度 = 1024 帧
 audio_ts_ < start − MAX_LAG  → 丢滞后样本，贴到 start（重锚，计数）
 start ≤ audio_ts_ < end      → start_point = NsToFrames(audio_ts_ − start)，从偏移处累加
 audio_ts_ ≥ end              → 本拍不贡献（数据在未来；下一拍再来）
 DiscardAudio(end)            → 丢弃本窗口已用样本，audio_ts_ = end
```

`MAX_LAG` 建议 **3 拍 = 64 ms**（`@48k`：3 × 21.33 ms）。小于它按补静音处理（人耳可接受），大于它判定为"源已严重掉队"，直接跳到当前窗口。

### 6.4 同步验收方法（对应 A6）

| 场景 | 判据 |
|---|---|
| **播放（M1）** | 对嘴素材看口型；并在日志里对比 `video_pts 映射后墙钟` vs `audio_ts` vs `NowNs()` 三者差值**无漂移趋势**（跑 5 分钟，差值应稳定在 ±1 个视频帧间隔内） |
| **混音延迟一致性** | 混音窗口 `start_ts` 与 `NowNs()` 的差应稳定（= 输出延迟 ≈ 107 ms），不随时间增长 |
| **录制（M2）** | muxer 收到的首包 `dts` 从 ~0 起；用 `ffprobe` 看 a/v 流 duration 差 < 1 帧；播放成品对嘴 |
| **诊断计数** | `overflow_` / `underrun_` / 重锚次数在稳定播放时应**恒为 0**（除起播与 seek 瞬间） |

### 6.5 常见坑（写进代码注释的级别）

1. **不要用 `NowNs()` 当"当前播放位置"**：它含输出延迟（~107 ms）。播放位置 = `audio_ts_ − 输出延迟`，或直接看 `audio_ts_`。
2. **`NsToFrames` 的舍入**：统一向下取整，别用 `round`，否则 `audio_ts_` 与窗口边界反复差 1 ns 会触发假重锚。
3. **暂停（P1）**：恢复时必须 `ResetAudioTiming()` 或把 `adjust += 暂停时长`（与 P2 `baseTime += 暂停时长` 必须**同步改同一个量**），否则音频会一次性"补播"或跳一段。
4. **设备采样率 ≠ 内部采样率**：AudioQueue 会自动转换，但那是**额外一路重采样**（延迟 + CPU）。D1 统一 48k 正是为了减少这类隐式转换。
5. **seek 后残响**：`WLResampler` 内部有延迟样本，seek 不 `Flush()` 会把上一段的尾巴带进新位置。

---

## 7. 关键参数配置表

| 分类 | 参数 | 值 | 位置 | 可调性 / 理由 |
|---|---|---|---|---|
| 格式 | 采样率 | 48000 | `WLAudioFormat::kSampleRate` | D1；改 44.1k 只需改此处 |
| 格式 | 声道 | 2（立体声） | `kChannels` | 单声道上混 / 多声道下混由 swr 处理 |
| 格式 | 样本格式 | Float32 planar（`AV_SAMPLE_FMT_FLTP`） | — | 混音是浮点累加；AudioQueue 输出前才 interleave |
| 节拍 | 每拍帧数 | 1024（21.333 ms） | `kTickFrames` | = OBS `AUDIO_OUTPUT_FRAMES` = AAC 帧长 |
| 缓冲 | per-source ring 容量 | 8192 帧（170.7 ms） | `WLAudioRing` ctor | 64 KB/源 |
| 限速 | 水位 HIGH（异常探针） | 4096 帧（85.3 ms） | `WLMediaSource` | **正常永不触发**；触发 = 放行线推进失准 → 丢最旧 + 重锚 + 记日志 |
| pace | 放行线跳变保护 | 3 s | `WLMediaSource` | 单次 `delta > 3s` 视为跳变，本轮不推进（OBS `media.c:543` 同值） |
| pace | 强放阈值 | 2 s（`MAX_TS_VAR`） | `WLMediaSource` | `pts − next_pts_ns_ > 2s` 的帧强制放行（OBS `can_play_frame`） |
| pace | 卡顿 sleep 上限 | 200 ms | `WLMediaSource` | 落后过多时最多睡 200 ms（OBS `mp_media_sleep` 同值） |
| 对齐 | MAX_LAG（落后重锚阈值） | 3 拍 = 64 ms | `WLAudioMixer` | 超过即丢滞后样本 |
| 阈值 | TS_SMOOTHING_THRESHOLD | 70 ms | `WLSource::OutputAudio` | 小抖动抹平（OBS 同值） |
| 阈值 | MAX_TS_VAR（重锚阈值） | 2 s | 同上 | seek/回绕判定（OBS 同值） |
| 输出 | AudioQueue 缓冲 | 3 × 1024 帧（64 ms） | `WLAudioOutput` | 要更低延迟可改 2 × 512 |
| 输出 | 起播水位 | 2 × 1024 帧 | `WLAudioOutput` | 抗一次抖动 |
| 输出 | ASBD | 48k / 2ch / Float32 / Packed(交错) | `WLAudioOutput` | 见 §4.7 表 |
| 编码 | 编码器 | `aac_at`（失败降级 `aac`） | `WLAudioEncoder` | ToDo M2 已定 |
| 编码 | 码率 | 128 kbps（立体声） | `Open(bitrate)` | 可选 96/160/192 |
| 编码 | profile | AAC-LC（`FF_PROFILE_AAC_LOW`） | 同上 | 兼容性优先 |
| 编码 | time_base | `{1, 48000}` | 同上 | pts 单位 = 采样点 |
| 编码 | 帧长 | 1024（`ctx->frame_size`） | 同上 | 攒够才 send |
| 混音 | 音量 | per-source `gain_`（默认 1.0）+ `muted_` | `WLSource` | UI 推子接 `WLCore::SetSourceGain` |
| 混音 | 削顶 | 首期 clamp(−1.0, 1.0) 并计数 | `WLAudioMixer` | 后续可换 limiter；**必须计数**，削顶说明增益配置有问题 |
| 采集 | 麦克风 IO buffer | ≥ 512 帧（系统决定） | `WLMicSource` | 回调不假设固定帧数 |
| 采集 | 权限 | `NSMicrophoneUsageDescription` + audio-input entitlement | `project.yml` / Info.plist | M4 |

---

## 8. 落地步骤

> 与 `Doc/ToDo.md` A 系列一一对应，每步 ≤20 min、可编译、有客观验证点。

| # | 步骤 | 改动 | 验证点 |
|---|---|---|---|
| **A1** | 解码器音频参数暴露 | `WLDecoder` 加 `AudioInfo(rate, channels, fmt)`；日志打印 | 日志见采样率/声道/格式；`ReceiveAudio` 帧数持续增长 ✅（主体已具备） |
| **A3** | `WLAudioFormat` + `WLResampler` | 新建 2 个文件 | 单测/日志：输入 44.1k·s16·mono → 输出 48k·f32·立体声；**转换后累计时长 ≈ 播放时长**（误差 < 1 帧） |
| **A4** | `WLAudioRing` + 壳音频区 + `OutputAudio` | 新建 ring；改 `WLSource` | 读写字节平衡；`overflow_`/`underrun_` 计数在正常播放时为 0 |
| **A2** | `WLMediaSource` 音频通路 + 单一 pace | 改 `ThreadLoop` 为「睡一次 → 到点各放一帧 → 补货 → 增量推进放行线」；加 `SysOf/ResetTs/MinReadyPts/CanPlay`；**删 `[src A]` 临时日志** | 音视频**总产出 ≈1.0× 实时**（用"累计音频帧数 × 21.33ms vs 墙钟"验证）；ring 水位长期不涨（< 1 个 tick）；**视频 `lagged_frames` 不因接入音频而上升**（关键回归点） |
| **A5a** | `WLAudioMixer`（单源直通） | 新建；`WLCore` 拥有并启动 | 日志：每拍 1024 帧、窗口起点单调、`audio_ts_` 与窗口起点贴合（差 < 1 帧） |
| **A5b** | `WLAudioOutput`（AudioQueue pull） | 新建；注册为 sink | **能听到声音**；`underrun_` 稳定为 0；插拔耳机不崩 |
| **A6** | A/V 同步验收 | — | 对嘴无偏差；三时间戳对比日志无漂移趋势；清本批临时日志 |
| **A7**（新增，可选） | 音量/静音 + 诊断显示 | `WLSource::SetGain/SetMuted`；接 `WLAudioMixerDock` | 推子实时生效；静音后电平为 0 |
| **M2-3** | `WLAudioEncoder` + Interleaver | 新建 encoder；Interleaver 独立组件 | 录出的 mp4 有声；`ffprobe` 双流 duration 差 < 1 帧；成品对嘴 |
| **M4-1** | 多源混音 | `WLAudioMixer` 多源求和 + gain + clamp 计数 | 两个媒体源同时出声；音量线性叠加不爆；一路 seek 不影响另一路 |
| **M4-2** | `WLMicSource` | 新建；权限配置 | 麦克风 + 媒体源同时出声；无爆音；Stop 后无残留回调 |
| **M4-3** | 编码侧接入混音 | `WLAudioEncoder` 接 mixer sink | 录制文件含麦克风混音 |

---

## 9. 文件改动清单

| 文件 | 动作 | 说明 |
|---|---|---|
| `libwl/src/audio/WLAudioFormat.hpp` | **新建** | 常量 + 换算（header-only，先落地） |
| `libwl/src/audio/WLResampler.hpp` / `.cpp` | **新建** | swresample 封装 |
| `libwl/src/audio/WLAudioRing.hpp` / `.cpp` | **新建** | SPSC 无锁 PCM 环（支持 planar / interleaved） |
| `libwl/src/audio/WLAudioMixer.hpp` / `.cpp` | **新建** | 全局混音节拍 + sink 分发 |
| `libwl/src/audio/WLAudioOutput.hpp` / `.cpp` | **新建** | AudioQueue 播放（pull） |
| `libwl/src/audio/WLAudioEncoder.hpp` / `.cpp` | **新建**（M2/M4） | AAC 编码 + 攒帧 |
| `libwl/src/source/WLMicSource.hpp` / `.cpp` | **新建**（M4） | CoreAudio 采集源 |
| `libwl/src/source/WLSource.hpp` / `.cpp` | 改 | 加音频区（条件分配 ring + 时基状态 + `OutputAudio`/`RenderAudio`/`DiscardAudio`/gain）；**dtor 里 ring 的释放在 `delete backend_` 之后**（与现 frames_ 同位置） |
| `libwl/src/source/WLMediaSource.cpp` / `.hpp` | 改 | 音频通路 + 统一时间映射（`SysOf`/`SysOfOffset`/`ResetTs`/`MinReadyPts`）+ 单一 pace（放行线 `next_pts_ns_` + `CanPlay` + 唯一 `SleepToNs`）+ resampler 成员 |
| `libwl/src/decoder/WLDecoder.hpp` / `.cpp` | 改 | 加 `AudioInfo()` 查询（A1） |
| `libwl/src/core/WLCore.hpp` / `.cpp` | 改 | 拥有 `WLAudioMixer`（Startup/Shutdown）；转发 `AddAudioSink` / `SetSourceGain` |
| `libwl/src/util/WLTime.hpp` | 改 | 加 `CondSleepTo(deadline, mutex, cond, &stop_flag)` 可中断等待（与 ToDo P1 共用） |
| `OBSLabs/project.yml` | 改 | `dependencies` 加 `AudioToolbox.framework`、`CoreAudio.framework`；M4 加 `INFOPLIST_KEY_NSMicrophoneUsageDescription` |
| `OBSLabs/OBSLabs/Docks/WLAudioMixerDockViewController.*` | 改（A7） | 接音量/静音/电平 |

---

## 10. 待定项与风险

| # | 待定项 | 倾向 | 触发再决的条件 |
|---|---|---|---|
| ⚙1 | 48k vs 44.1k（D1） | **48k** | 若实测设备/AAC 组合下 AudioQueue 频繁隐式重采样 → 改常量验证 |
| ⚙2 | 音频解码是否拆线程（D2） | **首期不拆** | 性能验收时若 `lagged_frames` 明显上升 → 拆（ring 已是 SPSC，改动局部） |
| ⚙3 | ring 溢出策略（D4，ToDo A4 原建议 drop-oldest） | **生产端丢新 + 消费端丢旧重锚** | 若要严格 drop-oldest，ring 必须改用 mutex（放弃无锁），代价是 HAL 回调存在优先级反转风险 |
| ⚙4 | 是否上 OBS 式动态缓冲（D8） | **首期不上** | 接入网络拉流源（M6）后，慢源抖动明显时再上 |
| ⚙5 | 输出用 AudioQueue 还是 AudioUnit（HAL output） | **AudioQueue**（先跑通） | 若要 <30 ms 监听延迟或需要设备热切换 → 换 AudioUnit |
| ⚙6 | 混音削顶策略 | clamp + 计数 | 若多源场景常触发 → 加 limiter / 自动增益 |
| ⚙7 | 麦克风时间戳用 hostTime 还是 NowNs() | **首期 NowNs()** | 若发现采集与播放有固定偏移（AEC 场景才敏感）→ 换 hostTime 精确换算 |
| ⚙8 | 电平表（VU）接口 | 预留 `wl_audio_level_cb`（每拍算 RMS/peak） | A7 做 dock 时定 |

**主要风险**

1. **音频不可见的失败**：听不到声音时最难排查。对策：A3–A5 每步都有计数/日志（水位、overflow、underrun、窗口贴合度），并把"累计输出帧数 vs 应输出帧数"做成一行日志。
2. **A/V 差一个固定偏移**：根因几乎总是两个 anchor 不一致（§6.1）。对策：`adjust` 只有一个来源（`base_wall − first_pts`），音频侧不自己算。
3. **P1 暂停与音频的耦合**：暂停恢复若只改视频 `baseTime` 不改音频 `adjust`，会出现音画错位（§6.5 坑 3）。P1/P2 落地时必须连带改 `ResetAudioTiming()`。
4. **CoreAudio 回调优先级反转**（M4）：任何在 HAL 回调里的加锁/分配都会导致爆音。ring 无锁即为此；`WLMicSource` 的 ctor 里把 resampler 与缓冲全部预分配好。
