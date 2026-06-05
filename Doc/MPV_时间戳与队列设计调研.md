# mpv 时间戳与队列设计调研 —— WorkLabs 取经

> **调研对象**：mpv `v0.41`（`/Users/tvum4pro/Documents/github/mpv`）
> **目的**：从 mpv 的时间戳/时钟/同步与队列/背压/唤醒设计中取经，指导 WorkLabs 的同步与队列改造。
> **关联**：`Doc/MPV_调研与预览CPU优化报告.md`（§2 粗略碰过线程/队列；本文深挖时间戳与队列）。承接「时间戳问题」讨论与「优化② 渲染线程精确等待」待办。
> **行号**：基于 v0.41 实读核对，随版本可能微调。

---

## 0. TL;DR

mpv 的时间体系建立在**三块地基**之上，WorkLabs 三块都缺或不同：

| 地基 | mpv | WorkLabs 现状 |
|---|---|---|
| **单调时钟** | `mach_absolute_time` 派生的纳秒单调时钟，全程绝对时刻唤醒 | 用墙钟 `CFAbsoluteTimeGetCurrent`（ms），受系统改时间影响；相对 `usleep` 睡眠 |
| **音频为主时钟，且向设备实测** | `master = written_audio_pts − ao_get_delay()`，实测未播缓冲反推 | 无真正主时钟；各源用 `baseTime + pts` 独立节流 |
| **条件变量 + 绝对超时唤醒** | 全程 `mp_cond_timedwait_until`，稳态零空转 | 渲染线程 `peek + usleep(10ms)` 100Hz 轮询 |

外加**时间戳稳健性三件套**（WorkLabs 完全没有，是真实崩坏隐患）：
1. **NOPTS 哨兵**：`AV_NOPTS_VALUE` 显式翻译为内部哨兵，所有 pts 运算对它短路。
2. **start_time 归一化**：用固定偏移 `ts_offset = −start_time` 把起始时间平移到 0（音视频同偏移）。
3. **帧间隔 clamp**：`frame_time = pts − last_pts`，若 `≤0`（倒退）或 `≥容差`（跳变）则置 0 立即显示，**绝不按异常值 sleep**。

**对 WorkLabs 最直接的两个结论**：
- 「优化②（渲染线程精确等待）」的标准答案就是 mpv 的「condvar + 绝对超时」——见 §4.3、§5。
- 之前讨论的「时间戳问题」，真正的脆弱点是 **WorkLabs 媒体源 `node.pts = frame->pts * time_base` 缺了上面三件套**——遇到非零起始（TS 流）、B 帧缺 pts、pts 倒退的素材会崩（见 §2、§5 P0）。

---

## 1. 时间基础设施

### 1.1 单调时钟（非墙钟）
- `mp_time_ns()`（`osdep/timer.c:43`）返回**单调、永不回绕、恒为正**的纳秒；启动时减去 `raw_time_offset`（`timer.c:34,48-51`）保证 >0。
- macOS：`mp_raw_time_ns = mach_absolute_time() * timebase_ratio`（`osdep/timer-darwin.c:37-53`）。
- 睡眠用 `mach_wait_until(绝对deadline)`（`timer-darwin.c:31-35`）——**绝对时刻**唤醒，不累积漂移。

> WorkLabs 用墙钟 ms + 相对 `usleep`：既受系统改时间影响，又累积漂移。**换单调时钟是后续一切同步的前提**。

### 1.2 单位约定
mpv 内部时间戳统一是 **double 秒**，缺失值哨兵 `MP_NOPTS_VALUE = −2^63`（`common/common.h:38`），配一组安全宏 `MP_ADD_PTS`/`MP_PTS_OR_DEF`/`MP_PTS_MIN/MAX`（`common.h:61-66`）：任何与 NOPTS 的运算都安全短路，绝不把 NOPTS 当 −9.2e18 参与算术。

---

## 2. 时间戳：产生 → 归一化 → 异常处理

### 2.1 time_base → 秒 + NOPTS 翻译（唯一转换点）
`mp_pts_from_av()`（`common/av_common.c:169`）：
```c
return av_pts == AV_NOPTS_VALUE ? MP_NOPTS_VALUE : av_pts * av_q2d(tb);
```
- 显式把 `AV_NOPTS_VALUE` 翻成内部哨兵（否则乘 time_base 得到巨大负秒数污染全链路）。
- `get_def_tb`（`av_common.c:155`）兜底非法 time_base → `AV_TIME_BASE_Q`，不除零。
- 应用：`demux_lavf.c:1627-1629`，pts/dts/duration 各自转秒，pts 与 dts **分别保留**不强制相等。

> **WorkLabs 对照**：`node.pts = frame->pts * time_base`（`WLMediaSource.m:216,243`）缺 NOPTS 判断。B 帧/某些容器 `frame->pts == AV_NOPTS_VALUE` 很常见 → WorkLabs 得到 ≈ −9.2e18 秒 → 渲染节流要么瞬间冲完所有帧、要么永久阻塞。

### 2.2 起始时间归一化（rebase 到 0）
- 选项 `rebase_start_time` 默认 **true**（`options/options.c:609,1063`）。
- 打开文件时：`demux_set_ts_offset(demuxer, −demuxer->start_time)`（`player/loadfile.c:961-962`），`start_time` 来自容器 `avfc->start_time`（`demux_lavf.c:1498-1499`）。
- 每个 packet 出 demuxer 时统一 `pkt->pts = MP_ADD_PTS(pkt->pts, ts_offset)`（`demux.c:2858-2859`）。
- **关键**：用「固定 start_time 偏移」而非「减第一帧 pts」——偏移打开文件时就定、对音视频一致，不会各减各的第一帧导致错位。

### 2.3 缺失 / 倒退 / 跳变（最该抄的一段）
播放侧 `handle_new_frame()`（`player/video.c:383-392`）：
```c
frame_time = pts - mpctx->video_pts;
double tolerance = ts_resets_possible && !is_sparse ? 5 : 1e4;
if (frame_time <= 0 || frame_time >= tolerance) {   // 倒退/重复 或 巨跳
    MP_WARN("Invalid video timestamp ...");
    frame_time = 0;                                  // 立即显示，绝不按异常间隔 sleep
}
```
- `ts_resets_possible` 由格式 flag 决定（`demux_lavf.c:1495`，TS 等天生可能跳变 → 容差收紧到 5s）。
解码侧兜底：
- 缺/坏 pts 用 dts（`f_decoder_wrapper.c:730-733` `crazy_video_pts_stuff`）。
- 彻底无 pts 时 `pts = last_pts + 1/fps`（`correct_video_pts`，`f_decoder_wrapper.c:804-832`，首帧用 `first_packet_pdts` 或 0）。
- 音频用累加插值 `pts += frame_len`，与容器 pts 偏差 ≤1ms 保留插值（抗 MKV 取整）、>5s 判 reset（`f_decoder_wrapper.c:834-875`）。

### 2.4 VFR 帧时长
`calculate_frame_duration()`（`player/video.c:953-1006`）：优先相邻帧 `pts1−pts0`（真 VFR），回退容器 `1/fps`；用 ~3ms 容差 + 历史平均消除 MKV 1ms 取整抖动，样本足够且吻合容器帧率时直接采用容器帧率消累积误差。

### 2.5 相对时钟（积分式）vs 绝对锚定
mpv 调度不是「目标 = baseTime + pts」（绝对锚定），而是 `time_frame += frame_time/speed`（`video.c:394`）再 `time_frame −= 真实流逝`（`video.c:1190`）的**相对积分**。好处：单帧 pts 异常（被 §2.3 clamp 成 0 后）只影响那一帧，不会让整条时间轴跳变。

> seek 重置同理：`reset_video_state` 把 `video_pts = NOPTS`、`time_frame=0`（`video.c:107-127`），下一帧 `frame_time` 的 `if` 自动不成立，新时间轴自然重建——**不修正时间戳，而是清零重起**。

---

## 3. A/V 同步：音频为主时钟

### 3.1 默认 audio-sync，主时钟向设备实测
- `--video-sync` 默认 `audio`（视频追音频，`options/options.c:194`）。
- 主时钟读数 `playing_audio_pts = written_audio_pts − audio_speed × ao_get_delay()`（`player/audio.c:624-630`）。
- **`ao_get_delay()`（`audio/out/buffer.c:295-318`）是灵魂**：pull 型 AO（CoreAudio）用「最后已播样本的绝对输出时刻 `end_time_ns − now`」+ 软件队列未送样本数，**实测**还剩多少没播——不假设音频匀速流逝。

> WorkLabs 的 AudioQueue 可用 `AudioQueueGetCurrentTime` 或「已入队未播 buffer 样本数 / 采样率」做等价实测。**这是未来多源 A/V 同步的核心**。

### 3.2 delay 桥接 + 比例校正
- `delay`（`core.h:369`）= 「已写音频比已显示视频多出的时长」：写音频 `delay += 样本/真实采样率`（`audio.c:734-736`），移到下一视频帧 `delay −= frame_time`（`video.c:396`）。
- `adjust_sync()`（`video.c:347-370`）比例吸收偏差：`change = av_delay × 0.1`（每次只吃 10%）、单帧封顶 `frame_time × factor`（`video.c:357-364`）——**缓慢吸收不跳变**，避免画面/音频突跳。
- 偏差 >0.5s 打去同步告警（`video.c:660-662`）。

### 3.3 视频「睡到何时显示」
`update_avsync_before_frame()`（`video.c:594-638`）：`time_frame = ao_get_delay() − delay/video_speed`（`video.c:625`）→ `pts = mp_time_ns() + time_frame×1e9`（`video.c:1202`）→ VO 线程睡到该绝对时刻（`vo_is_ready_for_frame` 设 `wakeup_pts`，`vo.c:835-860`；`vo_thread` `mp_cond_timedwait_until`，`vo.c:1214,720`）。

### 3.4 丢帧 / 补帧
- 落后丢帧（解码层）：`check_framedrop`（`video.c:319-336`）用 10ms 容差，`drops = (av_diff − 0.010)/frame_time`。
- VO 兜底：过期帧丢（`render_frame`，`video.c:954-962`），但 **100ms 上限保护**——再落后也降级到 10fps 而非冻屏。

### 3.5 启动对齐 + 暂停冻结
- 启动：音视频缓冲都 ≥READY 才同时起步（`handle_playback_restart`，`playloop.c:1157-1159`）；晚到的流用 `get_sync_pts` 延迟启动 + 裁掉早于起点的样本（`audio.c:840-853`、`clip_timestamps` `audio.c:706`）。
- 暂停冻结：`time_frame −= get_relative_time()` 存剩余等待量，恢复时丢弃暂停期间流逝（`playloop.c:189-191`）——避免恢复瞬间大批丢帧。

### 3.6 （进阶）display-sync
对齐显示器 vsync 消 judder：VO 实测 vsync 间隔（`vo.c:476-531`）、`num_vsyncs = lrint(frame_dur/vsync)` 整数化 + `display_sync_error` 余数反馈累积（`video.c:840-843`）、音频重采样补偿变速（`video.c:741-791`）。复杂度高、需 CVDisplayLink + 可微调速度，**OBS 风格合成器 audio-sync 已够，暂不需要**。

---

## 4. 队列 / 缓存 / 限流 / 背压 / 唤醒

### 4.1 限流：字节 + 时长（非包数）
- 字节硬上限 `demuxer-max-bytes` 默认 150MB（`demux.c:141`），`total_fw_bytes >= max` 停读；前向字节 = `tail_cum_pos − reader_head->cum_pos`（O(1)，`demux.c:473-478`）。
- 时长软目标 `readahead-secs` 默认 1.0s（`demux.c:144`），`last_ts − base_ts < min_secs` 才继续读（`demux.c:2289-2297`）。
- 字节估算把结构体 + overhead + side data 全算进去（`packet.c:234-275`），是真实内存的稳定估计。
- **理由**：一个 4K I 帧与 P 帧字节差几十倍，「包数」无法反映内存/时长；按字节+时长对不同码率/分辨率语义一致。

> **WorkLabs 对照**：视频队列 size=4 / 音频 size=20 按**包数**限流——4K 与 1080p 的「4 包」内存差巨大。

### 4.2 迟滞背压（hysteresis）
`demuxer-hysteresis-secs`（`demux.c:104`）：缓冲填满置 `hyst_active`，**等缓冲跌到低水位才一次性补满**（`demux.c:2294-2305`）——「成块缓冲」，避免在阈值附近「消费1包补1包」的高频抖动。

### 4.3 条件变量 + 绝对超时唤醒（优化②的答案）
- 原语 `mp_cond_timedwait_until(cond, lock, 绝对deadline)`（`osdep/threads-posix.h:201`）。
- demux 线程：缓冲满/无人消费时 `next_cache_update = INT64_MAX` ≈ **永久睡眠、零空唤醒**，直到 `mp_cond_signal`（`demux.c:2661-2673`）。
- VO 线程：睡到下一帧显示时刻，新帧到达提前唤醒（`vo.c:1147-1159,720`）。
- **唤醒去重**：生产者仅在消费者「上次扑空」（`need_wakeup`）时才 signal（`demux.c:865-878,2795`）；消费者取到包会自己回来要下一个、无需唤醒。
- **macOS 关键**：condvar 用 `pthread_condattr_setclock(CLOCK_MONOTONIC)`（`threads-posix.h:135-154`），避免 `CLOCK_REALTIME` 被改时间带乱。

> **WorkLabs 对照**：渲染线程 `peek + usleep(10ms)` 无论有无数据都 100Hz 空醒。

### 4.4 零拷贝引用 + packet pool
- `new_demux_packet_from_avpacket` 用 `av_packet_ref`（`packet.c:109,119`）只增引用、不 memcpy；150MB 缓存存的是引用。
- packet pool（`packet_pool.c`）复用 `demux_packet`/`AVPacket` 结构体；`POOL_GC_BATCH 64` 把「seek 一次性释放上万包」摊销到多次 pop。

> WorkLabs 的 `CVPixelBufferRetain` 本就是零拷贝引用，理念已对齐（自查各阶段是 retain/release 而非拷像素即可）。

### 4.5 解码后帧队列
- `f_async_queue`（`f_async_queue.c`）三维限流（samples/bytes/duration），纯标志驱动 + `mp_filter_wakeup`，无 sleep。默认视频 50帧/512MB/2s、音频 48000采样/1MB/1s（`f_decoder_wrapper.c:73-91`）。
- VO 只缓冲 1 帧（`req_frames` 默认 1，`vo.c:295`）——流式、不囤解码帧。

---

## 5. WorkLabs 取经清单（按优先级 + 现状映射）

### P0 — 地基 + 防崩（强烈建议，成本低）
| # | 取经点 | WorkLabs 落地 | mpv 参照 |
|---|---|---|---|
| 1 | **NOPTS 哨兵** | `node.pts = (frame->pts==AV_NOPTS_VALUE) ? WL_NOPTS : frame->pts*tb;` + 安全运算宏 | `av_common.c:169`、`common.h:38,61-66` |
| 2 | **start_time 归一化** | 打开文件记 `start_time = fmt_ctx->start_time/AV_TIME_BASE`，渲染用 `pts − start_time`（固定偏移，音视频一致） | `demux_lavf.c:1498`、`loadfile.c:961` |
| 3 | **帧间隔 clamp** | 节流前算 `frame_time = pts − last_pts`，`≤0` 或 `≥5s` 则按 0 处理（立即出帧，不 sleep 异常值） | `video.c:383-392` |
| 4 | **单调时钟** | `mach_absolute_time` 封 `now_ns()`，睡眠用绝对 deadline | `timer-darwin.c:31-53` |
| 5 | **渲染线程 condvar（=优化②）** | `WLNodeQueue` 加 condvar，渲染线程算下一帧绝对时刻 `pthread_cond_timedwait`(MONOTONIC) 睡到点，新帧入队 signal | `vo.c:720,1147-1159`、`threads-posix.h:201` |

> **P0 #1/#2/#3 三件套直接回答了「时间戳问题」**——这是 WorkLabs 媒体源当前最容易踩的三类崩坏（NOPTS 污染、非零起始、pts 倒退/跳变卡死），约几十行。

### P1 — 同步与限流（做多源/多轨时的核心）
| # | 取经点 | WorkLabs 落地 | mpv 参照 |
|---|---|---|---|
| 6 | **音频主时钟实测** | `AudioQueueGetCurrentTime` / 未播样本数算 AO 缓冲，`master = written_audio_pts − buffered`；视频对齐到它 | `audio.c:624-630`、`buffer.c:295-318` |
| 7 | **delay 桥接 + 比例校正** | 引入 `delay` 语义，`adjust_sync` 式每次吃 10% + 单帧封顶缓慢吸收偏差 | `video.c:347-370,396`、`audio.c:736` |
| 8 | **限流改字节+时长** | 队列深度按「缓冲秒数 + 字节上限」，弃「包数」；字节用 `CVPixelBufferGetDataSize` | `demux.c:473,2289-2297` |

### P2 — 省电与鲁棒性（顺手做）
| # | 取经点 | mpv 参照 |
|---|---|---|
| 9 | **迟滞背压**（高/低双水位成块缓冲） | `demux.c:2294-2305` |
| 10 | **唤醒去重**（消费者扑空才 signal） | `demux.c:865-878,2795` |
| 11 | **丢帧 100ms 上限保护**（某源卡顿不拖垮合成节奏，降级而非冻屏） | `video.c:954-962` |
| 12 | **多源启动对齐**（新源对齐当前主时钟 pts、裁早于该 pts 的数据，而非从头播） | `playloop.c:1157-1159`、`audio.c:840-853` |

### 用不上 / 暂不做
- **多范围缓存 `demux_cached_range[]`**（`demux.c:306`）：为可 seek 回放复用旧 packet 设计；WorkLabs 实时合成无随机 seek，单队列即可。
- **backward demuxing / disk cache**：倒放、超大网络流落盘，合成器无关。
- **display-sync**（§3.6）：消 judder 但复杂度高，audio-sync 已够，留作后续。
- **packet pool GC 摊销**：WorkLabs 队列只有几个节点，简单 freelist 足矣（若 profiling 显示 `WLNode` 分配是热点再做）。

---

## 6. 与 WorkLabs 现有设计的关系

### 6.1 「墙钟录制」vs「音频主时钟」——两者并存、各管一段
- **录制/推流**（`WLEncoder` `(void)pts` 用墙钟 epoch，`WLEncoder.m:121`）：对实时合成录制是**合理的**——录的是「实时所见」，墙钟即真实经过时间，多源各自 pts 基准不可比，统一墙钟反而正确。**这条不需要改。**
- **媒体源播放/预览节奏 + 未来多源 A/V 同步**：应引入 mpv 式的「时间戳稳健处理（P0 三件套）+ 音频主时钟实测（P1 #6）」。这才是「时间戳问题」的正解方向。
- 二者不冲突：源内部按 pts 稳健节流出帧（输入侧正确）→ 录制按墙钟打戳（输出侧实时）。

### 6.2 与「优化②」的关系
优化②（渲染线程精确等待）= P0 #5 的直接落地。§6.2 调研里设计的「`deQueueWithTimeout` 阻塞 + 分段睡」是可行的过渡方案；本文给出更彻底的目标形态：**condvar(MONOTONIC) + 绝对 deadline + 唤醒去重**，稳态零空唤醒，且帧呈现时刻更准。

### 6.3 关键文件速查
**mpv**：时钟 `osdep/timer-darwin.c`；时间戳转换 `common/av_common.c:169`、归一化 `player/loadfile.c:961`+`demux/demux.c:2858`、异常 clamp `player/video.c:383`；音频主时钟 `player/audio.c:624`+`audio/out/buffer.c:295`；delay/同步 `player/video.c:347,594,1034`；队列限流 `demux/demux.c:2262,473`、迟滞 `:2294`、唤醒 `:2661`+`osdep/threads-posix.h:201`。
**WorkLabs**：pts 产生 `WLMediaSource.m:216,243`（缺三件套）；渲染节流 `WLMediaSource.m:296-340`（usleep 轮询）；队列 `WLNodeQueue`（按包数限流）；录制墙钟 `WLEncoder.m:121`。

---

## 7. 建议落地顺序

1. **P0 #1/#2/#3（时间戳三件套）** —— 几十行，消除当前最易踩的崩坏，直接回应「时间戳问题」。先做。
2. **P0 #4/#5（单调时钟 + 渲染线程 condvar）** —— 落地「优化②」，CPU 空转→0、呈现更准。
3. **P1 #6/#7/#8** —— 等真正做「多源 A/V 同步 + 多轨混音」时引入音频主时钟。
4. **P2** —— 省电/鲁棒性，顺手做。
