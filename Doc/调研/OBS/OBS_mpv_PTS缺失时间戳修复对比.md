# OBS / mpv 缺失时间戳(NOPTS)修复策略对比

> 调研日期：2026-07-01
> 起因：`wl_decoder_receive_video/audio` 里 `av_rescale_q(frame->pts, ...)` 对
> `AV_NOPTS_VALUE`(INT64_MIN)不设防，会换算出一个"看起来正常但完全错误"的
> 时间戳。修复过程中追问"业界怎么处理这个问题"，调研 OBS 与 mpv 源码得到本文。
>
> 结论已落地到 `wl_decoder.c`（按 OBS 方式实现，mpv 更完整的漂移检测记入
> ToDo P4，暂不实现）。

---

## 一、问题本质

`AV_NOPTS_VALUE` 不是特殊标记位，就是普通数字 `INT64_MIN`。`av_rescale_q` 不知道
这个"约定"，拿到它就当成真实数值去做乘除，换算完早就不是 `INT64_MIN` 了——一个
看似正常、实际毫无意义的数字，下游完全无法识别。

时间戳缺失的根本原因：时间戳是**元数据**，必须有人主动写入文件，链路上任何一环
没写（裸流、容器只存 DTS、文件损坏截断、编码器 bug）它就是真的不存在。

---

## 二、FFmpeg 自带的第一道防线

在 OBS / mpv 的自定义逻辑之前，libavformat / libavcodec 本身已经做了一部分工作：

| 机制 | 位置 | 作用 |
|------|------|------|
| 默认 fillin 行为 | `avformat.h: AVFMT_FLAG_NOFILLIN` | 默认**开启**推断缺失值；这个 flag 是用来关掉它的 |
| `AVFMT_FLAG_GENPTS` | `avformat.h:1334` | 更激进：允许向前多读几帧来反推 pts（OBS / mpv 均未启用） |
| `AVFrame.best_effort_timestamp` | `frame.h:593-598` | libavcodec 内部综合 pts/dts 做的"最大努力估计"，`decoding: set by libavcodec, read by user` |
| `AV_ROUND_PASS_MINMAX` | `mathematics.h:85-108` | rescale 系列函数的标志位，让 `INT64_MIN`/`MAX` 原样透传，不参与换算 |

我们最初的 bug 就是没用上最后一条——直接对裸 `pts` 做 `av_rescale_q`，没有任何
针对 `AV_NOPTS_VALUE` 的保护。

---

## 三、OBS 的处理方式

**文件**：`shared/media-playback/media-playback/decode.c`

### 3.1 读取入口（`mp_decode_next`，decode.c:386-407）

```c
int64_t last_pts = d->frame_pts;   // 先存旧值，供 duration 估算用

if (d->in_frame->best_effort_timestamp == AV_NOPTS_VALUE)
    d->frame_pts = d->next_pts;    // NOPTS → 用推算位置顶上
else
    d->frame_pts = av_rescale_q(d->in_frame->best_effort_timestamp,
                                 d->stream->time_base, (AVRational){1, 1000000000});

int64_t duration = d->in_frame->duration;
if (!duration)
    duration = get_estimated_duration(d, last_pts);
else
    duration = av_rescale_q(duration, d->stream->time_base, (AVRational){1, 1000000000});

d->next_pts = d->frame_pts + duration;   // 推进预测值，供下一帧可能的 NOPTS 使用
```

护栏方式：**先判断 `== AV_NOPTS_VALUE` 再决定要不要 rescale**（不是标志位，是手写 if）。

### 3.2 时长三级兜底（`get_estimated_duration`，decode.c:251-265）

```c
static inline int64_t get_estimated_duration(struct mp_decode *d, int64_t last_pts) {
    if (d->audio) {
        return av_rescale_q(d->in_frame->nb_samples,
                             (AVRational){1, d->in_frame->sample_rate},
                             (AVRational){1, 1000000000});
    } else {
        if (last_pts)
            return d->frame_pts - last_pts;          // ① 上一帧位置差值
        if (d->last_duration)
            return d->last_duration;                  // ② 上次估算出的时长
        return av_rescale_q(d->decoder->time_base.num,
                             d->decoder->time_base, (AVRational){1, 1000000000});  // ③ 兜底
    }
}
```

- **音频**：duration 直接由 `nb_samples / sample_rate` 精确算出，不需要多级兜底。
- **视频**：三级兜底，越往后越不精确，最后一级只有在"第一帧 + duration 缺失"
  这种复合失败场景才会触发。
- **`next_pts` 只在当帧生效**：下一帧只要有真实值就直接用真实值，估算值不会
  覆盖或比对未来的真实时间戳——单次缺失基本不会污染后续时间线。
- OBS **不设** `AVFMT_FLAG_GENPTS`；唯一设置的是 `AVFMT_FLAG_NOBUFFER`（仅在
  关闭缓冲时，`media.c:687`，与本问题无关）。
- 从没有整帧丢弃：缺时间戳只影响"用什么值"，不影响"要不要保留这帧数据"。

---

## 四、mpv 的处理方式（更彻底，但更复杂）

**文件**：`video/decode/vd_lavc.c`、`filters/f_decoder_wrapper.c`、`common/av_common.c`

mpv 甚至**不信任** `best_effort_timestamp`，读的是裸 `frame->pts`（`vd_lavc.c:1292`），
自己重新做一整套修复，分三层：

### 4.1 包级：PTS 缺失退回 DTS（`f_decoder_wrapper.c:980-991`）

```c
if (pkt_pts == MP_NOPTS_VALUE)
    p->has_broken_packet_pts = 1;
if (packet && packet->dts == MP_NOPTS_VALUE && !p->codec->avi_dts)
    packet->dts = packet->pts;
double pkt_pdts = pkt_pts == MP_NOPTS_VALUE ? pkt_dts : pkt_pts;
```

### 4.2 帧级单调性修复（`crazy_video_pts_stuff`，f_decoder_wrapper.c:709-743）

函数名字就叫这个。检测 pts 是否单调递增，"问题"比 dts 还多，或者 pts 本身缺失，
就直接换成 dts：

```c
if (mpi->pts < p->codec_pts) p->num_codec_pts_problems++;
...
if ((p->num_codec_pts_problems > p->num_codec_dts_problems ||
     mpi->pts == MP_NOPTS_VALUE) && mpi->dts != MP_NOPTS_VALUE)
    mpi->pts = mpi->dts;
```

### 4.3 帧级外推（`correct_video_pts`，f_decoder_wrapper.c:804-832）

前两层都没救，用 FPS（拿不到就硬编 25）算帧间隔外推，并**打警告日志**：

```c
MP_WARN(p, "No video PTS! Making something up. Using %f FPS.\n", fps);
...
mpi->pts = (p->pts != MP_NOPTS_VALUE) ? p->pts + frame_time
                                      : (base != MP_NOPTS_VALUE ? base : 0);
```

### 4.4 音频漂移检测（`correct_audio_pts`，f_decoder_wrapper.c:834-875）—— **关键差异点**

这是 OBS 没有的一层。新的真实 pts 出现时，会拿它和"目前靠插值撑着的位置"比较：

```c
double diff = fabs(p->pts - frame_pts);
if (diff > 0.1)  MP_WARN(p, "Invalid audio PTS: %f -> %f\n", p->pts, frame_pts);
if (diff >= 5)   p->pts_reset = true;      // 漂移太离谱，承认估算体系跑飞，重新校准
if (p->pts == MP_NOPTS_VALUE || diff > 0.001)
    p->pts = frame_pts;                     // 差距在容器舍入误差内则忽略，否则重新校准
```

### 4.5 `MP_NOPTS_VALUE` 与 `AV_NOPTS_VALUE` 的转换护栏（`av_common.c:169-173`）

```c
double mp_pts_from_av(int64_t av_pts, AVRational *tb) {
    AVRational b = get_def_tb(tb);
    return av_pts == AV_NOPTS_VALUE ? MP_NOPTS_VALUE : av_pts * av_q2d(b);
}
```

同样是"先判断哨兵，再换算"——和我们的修复、OBS 的手写 if 本质一致。

---

## 五、三方对比

| | 我们的修复 | OBS | mpv |
|---|-----------|-----|-----|
| 换算前判断哨兵 | ✅ `AV_ROUND_PASS_MINMAX` | ✅ 手写 if | ✅ `mp_pts_from_av` |
| 信任 `best_effort_timestamp` | ✅ | ✅ | ❌ 自己重做一套 |
| 缺失时外推（而非直传 NOPTS） | ✅（已实现，OBS 式） | ✅ `next_pts` | ✅ 更激进 |
| 时长估算兜底 | 视频三级 / 音频精确算 | 视频三级 / 音频精确算 | 基于 FPS 假设 |
| 漂移检测（估算值 vs 后续真实值的偏差） | ❌ 未实现 | ❌（未见） | ✅ `correct_audio_pts` |
| 整帧丢弃 | ❌ 从不丢 | ❌ 从不丢 | ❌ 从不丢 |

**共识**：三家都在换算前判断哨兵，都不会为了"没时间戳"丢弃已解码的数据。

**分歧**：mpv 多一层"漂移检测"——连续多帧都靠外推撑着时，估算误差会累积，
等真实时间戳重新出现可能已经反超，形成时间线非单调。OBS 的模型没有这层回收
机制，简单但有这个残留风险；我们目前跟随 OBS，风险评估见下节。

---

## 六、`wl_decoder` 的实现与两个和 OBS 不同的细节

代码位置：`wl_decoder.c` 的 `wl_decoder_receive_video` / `wl_decoder_receive_audio`。
整体策略照抄 OBS（`best_effort_timestamp` + `next_pts` 外推 + 时长三级兜底），
但两处做了更严谨的处理：

1. **字段名踩了一个 FFmpeg 版本坑**：OBS 代码里的 `frame->duration` 是新版
   libavutil（59+）才有的字段；我们 vendor 的是 libavutil 57.28，只有旧字段
   `pkt_duration`（语义相同：`duration of the corresponding packet, expressed
   in AVStream->time_base units, 0 if unknown`）。如果直接照抄 `->duration`
   会编译报错——写代码前先查了本地头文件才发现。
2. **状态初值用 `AV_NOPTS_VALUE` 而不是 OBS 的 truthy 判断**：OBS 用
   `if (last_pts)`，把 `pts == 0` 也当成"没有上一帧"，这在实践中几乎不会出问题
   （只有第一帧本来就是这个语义，之后的帧几乎不可能真的 pts=0）。我们的
   `video_last_pts_ns` / `video_next_pts_ns` / `audio_next_pts_ns` 初值设为
   `AV_NOPTS_VALUE` 而非 calloc 默认的 `0`，用哨兵值严格区分"真的还没有上一帧"
   和"上一帧 pts 恰好是 0"，成本和 truthy 判断一样低，但没有这个歧义。

---

## 七、遗留风险与后续（见 ToDo P4）

**连续多帧丢时间戳时的漂移**：如果 duration 估算哪怕有一点点偏差，`next_pts`
每次外推都会累积误差；真实时间戳重新出现时，前面靠外推撑着的帧的时间戳可能已经
反超后面的真实帧，形成非单调时间线。

- 单帧偶尔丢失：风险低，下一帧真实值出现即自动重新校准，误差不会传递。
- 连续多帧丢失：风险随连续帧数增加而累积，mpv 的 `correct_audio_pts` 漂移检测
  正是为了兜住这种情况。

当前 M1 只处理本地完好文件，这种复合失败场景概率很低，故先按 OBS 方式实现，
mpv 式的漂移检测（比较外推值与新真实值的偏差，超阈值则判定漂移并重新校准）
留到后续按需补上。
