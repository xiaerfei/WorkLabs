# mpv 时间戳源码深挖 —— 产生 / 异常 / 同步 / 重置

> **调研对象**：mpv `v0.41.0-718-g1d82932cce`（`/Users/tvum4pro/Documents/github/mpv`）
> **性质**：**源码级、纯理解向**深挖。逐函数追 mpv 时间戳的完整生命周期，所有行号均在该提交上实读核对。
> **与现有文档的关系**：`MPV_时间戳与队列设计调研.md` 偏「为 WorkLabs 取经的清单」，覆盖时间戳 + 队列 + 同步全景；本文专注**时间戳本身**，深到具体函数体、字段语义、边界条件与设计哲学。两者互补，本文更细。
> **应用层延伸**：`MPV时间戳_讨论纪要与功能规划.md` —— 本文是「mpv 怎么做」，那篇是「对 WorkLabs 意味着什么 + seek/loop 怎么落地」，本文的「§X」引用即那篇的出处。
> **覆盖四块**：① 产生与归一化 · ② 异常处理 · ③ A/V 同步时钟 · ④ seek/暂停/启动对齐。每章末尾点出对 WorkLabs 的启示，但以理解 mpv 为主。

---

## 0. 时间基础设施（地基）

后面三、四两章的"睡到某个绝对时刻显示"全部建立在两块基础设施上：**单调时钟** 和 **绑定单调时钟的条件变量**。先讲透它们，后文才能直接引用。

### 0.1 单调时钟 `mp_time_ns()`

mpv 内部所有"现在几点"都来自一个单调、永不回绕、恒为正的纳秒时钟：

```c
// osdep/timer.c:43-51
int64_t mp_time_ns(void)
{
    return mp_time_ns_from_raw_time(mp_raw_time_ns());
}

int64_t mp_time_ns_from_raw_time(uint64_t raw_time)
{
    return raw_time - raw_time_offset;   // 减去启动时记录的偏移
}
```

`raw_time_offset` 在初始化时被设为启动那一刻的 `mp_raw_time_ns()`，并断言 `> 0`（`timer.c:34-35`）。因此 `mp_time_ns()` 从 0 附近开始、**严格为正**（`mp_time_ns_add` 里 `mp_assert(time_ns > 0)`，`timer.c:60`）——这让"时间戳为 0/负"可以安全地当作哨兵或非法值。

darwin 实现（关键）：

```c
// osdep/timer-darwin.c:29-52
static double timebase_ratio_ns;

void mp_sleep_ns(int64_t ns)
{
    uint64_t deadline = ns / timebase_ratio_ns + mach_absolute_time();
    mach_wait_until(deadline);            // ★ 睡到绝对 deadline，不累积漂移
}

uint64_t mp_raw_time_ns(void)
{
    return mp_raw_time_ns_from_mach(mach_absolute_time());
}
uint64_t mp_raw_time_ns_from_mach(uint64_t mach_time)
{
    return mach_time * timebase_ratio_ns;  // mach tick → 纳秒
}
void mp_raw_time_init(void)
{
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    timebase_ratio_ns = (double)timebase.numer / (double)timebase.denom;
}
```

- 时钟源是 `mach_absolute_time()`（单调、不受用户改系统时间影响），乘 `mach_timebase_info` 的 numer/denom 比换算成纳秒。
- 睡眠用 **`mach_wait_until(绝对deadline)`** 而非相对 `usleep` ——睡到一个绝对时刻，因此一连串帧的调度不会因"每次相对超时都有微小误差"而累积漂移。

> 这与第 3 章 CoreAudio 回调里用的 host-time 域同源，使得"音频最后样本的预计输出时刻 `end_time_ns`"和"视频下一帧的上屏时刻 `pts`"可以直接相减比较。

### 0.2 绑定单调时钟的条件变量 + 绝对超时唤醒

mpv 的线程不靠轮询，而是用条件变量"睡到某个绝对时刻、有事提前唤醒"。其条件变量在初始化时就绑定到单调时钟：

```c
// osdep/threads-posix.h:135-153
static inline int mp_cond_init(mp_cond *cond)
{
    ...
    cond->clk_id = CLOCK_REALTIME;
#if HAVE_PTHREAD_CONDATTR_SETCLOCK
    if (!pthread_condattr_setclock(&attr, CLOCK_MONOTONIC))
        cond->clk_id = CLOCK_MONOTONIC;     // ★ 改用单调时钟
#endif
    ret = pthread_cond_init(&cond->cond, &attr);
    ...
}
```

绑定 `CLOCK_MONOTONIC` 后，等待超时也不受改系统时间干扰。"睡到绝对时刻"的原语：

```c
// osdep/threads-posix.h:184-204
static inline int mp_cond_timedwait(mp_cond *cond, mp_mutex *mutex, int64_t timeout)
{
    timeout = MPMAX(0, timeout);
    // consider anything above 1000 days as infinity
    if (timeout > MP_TIME_S_TO_NS(1000 * 24 * 60 * 60))
        return pthread_cond_wait(&cond->cond, mutex);   // 超长 → 永久睡眠，零空转
    struct timespec ts;
    clock_gettime(cond->clk_id, &ts);
    ts.tv_sec  += timeout / MP_TIME_S_TO_NS(1);
    ts.tv_nsec += timeout % MP_TIME_S_TO_NS(1);
    ...
    return pthread_cond_timedwait(&cond->cond, mutex, &ts);
}

static inline int mp_cond_timedwait_until(mp_cond *cond, mp_mutex *mutex, int64_t until)
{
    return mp_cond_timedwait(cond, mutex, until - mp_time_ns());   // 绝对 deadline → 相对超时
}
```

- `mp_cond_timedwait_until(cond, lock, until)` 接受**绝对纳秒时刻** `until`，内部转成"还剩多少"再睡。这是第 3 章 VO 线程"睡到下一帧上屏时刻"的底层原语。
- 超过 1000 天的超时直接退化为无限期 `pthread_cond_wait` ——缓冲满/无帧可放时令线程**永久睡眠、零空唤醒**，直到被 `mp_cond_signal` 叫醒。

> **与 WorkLabs 的对照**：WorkLabs 媒体源渲染线程是墙钟 ms + 相对 `usleep(10ms)` 轮询；换成"单调时钟 + condvar 绝对 deadline"是 WorkLabs「渲染线程精确等待」优化的标准答案。

---

## 1. 时间戳的产生与归一化

mpv 内部不使用 FFmpeg 那套「整数 + time_base」的时间戳表示，而是把一切时间戳统一成**以秒为单位的 `double`**。从 FFmpeg 的 `AVPacket` 进入 mpv，到一个带归一化 pts 的 `demux_packet` 离开 demuxer，整条链路只有两件事在发生：**单位转换（time_base → 秒，唯一转换点）** 和 **起始时间归一化（rebase 到 0）**。这两件事被刻意拆开在不同的层完成，且全程用一套「NOPTS 哨兵 + 安全运算宏」保证任何缺失时间戳的运算都不会被污染。

### 1.1 内部时间戳的表示：秒为单位的 double + NOPTS 哨兵

mpv 内部时间戳就是 `double`（秒）。"无时间戳" 用一个特殊的哨兵值表示：

```c
// common/common.h:37-38
// double should be able to represent this exactly
#define MP_NOPTS_VALUE (-0x1p+63)
```

`-0x1p+63` 是十六进制浮点字面量，含义是 `-1 × 2^63 = -9223372036854775808.0`，即 `INT64_MIN` 的浮点形式。选这个值有两点讲究：

- **它能被 `double` 精确表示**（2 的整数次幂，尾数全 0），所以 `x == MP_NOPTS_VALUE` 这种浮点相等比较是可靠的——不会因为精度丢失而比较失败。这是注释 "double should be able to represent this exactly" 的全部含义。
- 它是个极端负值，正常媒体时间戳永远不会撞上，可以安全地当哨兵。

但「秒为单位的 double」配上这个哨兵带来一个隐患：如果不小心，任何对 NOPTS 做算术（比如 `NOPTS + offset`）都会得到一个接近 `-2^63` 的巨大负秒数，并把它当成"真实时间戳"扩散到整条管线。mpv 的解法是：**所有可能碰到 NOPTS 的运算都不直接写，而走一组宏**：

```c
// common/common.h:60-66
// Return "a", or if that is NOPTS, return "def".
#define MP_PTS_OR_DEF(a, def) ((a) == MP_NOPTS_VALUE ? (def) : (a))
// If one of the values is NOPTS, always pick the other one.
#define MP_PTS_MIN(a, b) MPMIN(MP_PTS_OR_DEF(a, b), MP_PTS_OR_DEF(b, a))
#define MP_PTS_MAX(a, b) MPMAX(MP_PTS_OR_DEF(a, b), MP_PTS_OR_DEF(b, a))
// Return a+b, unless a is NOPTS. b must not be NOPTS.
#define MP_ADD_PTS(a, b) ((a) == MP_NOPTS_VALUE ? (a) : ((a) + (b)))
```

逐个看它们如何对 NOPTS 短路：

- **`MP_PTS_OR_DEF(a, def)`**：最基础的原语。`a` 有效就返回 `a`，否则用 `def` 顶上。常见用法是 `MP_PTS_OR_DEF(pts, dts)`——pts 缺失时退化到 dts（见 1.5）。
- **`MP_PTS_MIN/MP_PTS_MAX`**：求两个时间戳的较小/较大值，但**任一为 NOPTS 时直接返回另一个**。技巧在于把 `a`、`b` 互为对方的默认值代入：若 `a` 是 NOPTS，`MP_PTS_OR_DEF(a, b)` 变成 `b`，`MP_PTS_OR_DEF(b, a)` 还是 `b`，于是 `MPMIN(b, b) = b`，哨兵被自然吃掉，不会因为 `-2^63` 永远是最小值而污染结果。
- **`MP_ADD_PTS(a, b)`**：时间戳平移的核心。**`a` 是 NOPTS 就原样返回 NOPTS（不做加法）**，否则做 `a + b`。注释明确要求 `b` 不能是 NOPTS——也就是说"偏移量"本身必须是个确定的数。归一化加偏移、加各种 ts_offset 全靠它，保证「无时间戳的包平移之后仍然是无时间戳」，而不是变成一个巨大负数。

这套宏是整条链路安全性的地基：后面 1.4 的归一化、demuxer 各处的 offset 加减，全部建立在 `MP_ADD_PTS` 之上。

### 1.2 唯一转换点：time_base → 秒 + NOPTS 翻译

FFmpeg 的 time_base 整数时间戳进 mpv，转换只在一个函数里发生：

```c
// common/av_common.c:168-173
// Inverse of mp_pts_to_av(). (The timebases must be exactly the same.)
double mp_pts_from_av(int64_t av_pts, AVRational *tb)
{
    AVRational b = get_def_tb(tb);
    return av_pts == AV_NOPTS_VALUE ? MP_NOPTS_VALUE : av_pts * av_q2d(b);
}
```

这一行做两件互相独立但缺一不可的事：

1. **NOPTS 翻译（关键）**：先判断 `av_pts == AV_NOPTS_VALUE`（FFmpeg 的 `AV_NOPTS_VALUE` 是 `INT64_MIN`），是的话**直接返回 `MP_NOPTS_VALUE`，绝不做乘法**。这一步是整条链路的安全总闸。如果省掉它直接乘 time_base，`INT64_MIN × av_q2d(tb)` 会得到一个数量级巨大的负秒数（不是哨兵、也不等于任何合法时间戳），然后被当成"真实的播放时间"灌进全链路——音视频同步、seek、duration 计算全被污染。所以这里把 FFmpeg 的整数哨兵显式翻译成 mpv 的浮点哨兵，是 FFmpeg 时间戳世界和 mpv 时间戳世界之间唯一的、必须严防的边界。
2. **单位换算**：合法值时 `av_pts * av_q2d(b)`，把"整数 × time_base"换算成秒。`av_q2d` 就是把 `AVRational{num, den}` 算成 `num/den` 的 double。

time_base 的兜底交给 `get_def_tb`：

```c
// common/av_common.c:155-158
static AVRational get_def_tb(AVRational *tb)
{
    return tb && tb->num > 0 && tb->den > 0 ? *tb : AV_TIME_BASE_Q;
}
```

它防三种坏情况：`tb` 指针为空、`num <= 0`、`den <= 0`（包括 `den == 0` 这种会直接除零的非法 time_base）。任何一种都退回到 `AV_TIME_BASE_Q`（即 `1/1000000`，FFmpeg 的微秒级默认 time_base）。这样 `av_q2d(b)` 永远是个有限正数，**杜绝了 `0/0` 或 `x/0` 的除零/NaN**。注意这是"宁可单位错也不要崩"的兜底——拿到非法 time_base 时算出来的秒数可能不对，但至少是个有限数，不会让整个时间轴变成 NaN 而彻底失控。

`mp_pts_to_av`（162-166）是它的逆操作，在 mpv 把包喂回 FFmpeg 解码器/复用器时用，对称地把 `MP_NOPTS_VALUE` 翻回 `AV_NOPTS_VALUE`。这里只关注入向（`mp_pts_from_av`）。

### 1.3 packet 出 demuxer 时的 pts/dts/duration 转换

`mp_pts_from_av` 的调用点在 lavf demuxer 读包的核心函数 `demux_lavf_read_packet` 里。一个 `AVPacket` 被读出来后，转成 mpv 的 `demux_packet`（字段都是秒为单位的 double，见 `demux/packet.h:27-29` 的 `double pts; double dts; double duration;`）：

```c
// demux/demux_lavf.c:1627-1631
dp->pts = mp_pts_from_av(pkt->pts, &st->time_base);
dp->dts = mp_pts_from_av(pkt->dts, &st->time_base);
dp->duration = pkt->duration * av_q2d(st->time_base);
dp->pos = pkt->pos;
dp->keyframe = pkt->flags & AV_PKT_FLAG_KEY;
```

要点：

- **pts 和 dts 各自独立转换，互不强制相等**。两者都走 `mp_pts_from_av`，所以各自带 NOPTS 短路保护——B 帧场景下 pts 和 dts 本就不同，有 B 帧的流 pts 可能缺失只有 dts，反之亦然，任一方为 NOPTS 都被安全保留成 `MP_NOPTS_VALUE`。mpv 在这一层**不做任何 pts/dts 的相互推断或对齐**，原样转成秒交给下游。
- **duration 用的 time_base 是流的 `st->time_base`**（每条 `AVStream` 自己的 time_base），不是容器的。duration 这里直接乘 `av_q2d`，不走 `mp_pts_from_av`——因为 duration 语义上是"时长"不是"时刻"，没有 NOPTS 哨兵的概念（缺失就是 0）。
- 此时 `dp->pts/dts` 是**未归一化**的——它们是相对于容器原始时间轴的绝对秒数。归一化（减去 start_time）发生在更后面的另一层（见 1.4），这里只管单位转换。

紧接着（`demux_lavf.c:1645` 起）有一段 `priv->linearize_ts` 的逻辑，用 `info->ts_offset` 做时间戳线性化，处理拼接流的不连续（discontinuity）。这是针对 `AVFMT_TS_DISCONT` 类格式（如 concat、某些 TS 流）的专门修补，和下面讲的全局 start_time 归一化是两套独立机制，不要混淆——`info->ts_offset` 是 per-stream-info 的线性化补偿，而 1.4 的 `in->ts_offset` 是 per-demuxer 的起始归一化。

### 1.4 起始时间归一化：用固定 start_time 偏移 rebase 到 0

媒体文件的容器时间轴未必从 0 开始（典型如 TS 流第一帧 pts 是个很大的值，或音视频起始 pts 不一致）。mpv 默认把整条时间轴平移，让播放从 0 开始。这是个选项控制的行为，默认开：

```c
// options/options.c:609
{"rebase-start-time", OPT_BOOL(rebase_start_time)},
// options/options.c:1063
.rebase_start_time = true,
```

(对应 `options/options.h:290` 的 `bool rebase_start_time;`。)

**第一步——确定 start_time 来源**。打开文件、`avformat_find_stream_info` 之后，mpv 从容器的 `avfc->start_time` 取起始时间：

```c
// demux/demux_lavf.c:1498-1499
if (avfc->start_time != AV_NOPTS_VALUE)
    demuxer->start_time = avfc->start_time / (double)AV_TIME_BASE;
```

`avfc->start_time` 是 FFmpeg 在 `AV_TIME_BASE`（微秒）单位下给出的、**整个容器所有流综合出来的起始时间**。这里同样先判 `AV_NOPTS_VALUE`（否则又会是个巨大负数污染 start_time），合法才换算成秒存进 `demuxer->start_time`（`demux/demux.h:232` 的 `double start_time;`）。注意这是**容器级**的一个数，不是某条流的第一帧 pts——这是后面"音视频一致"的关键。

**第二步——打开文件时一次性设定偏移**。在 `player/loadfile.c` 里，打开 demuxer 后立刻设置偏移量为 `-start_time`：

```c
// player/loadfile.c:961-962
if (filter != STREAM_SUB && opts->rebase_start_time)
    demux_set_ts_offset(demuxer, -demuxer->start_time);
```

偏移在**文件打开的那一刻就被算死并冻结**：`offset = -start_time`。注意 `filter != STREAM_SUB`——外挂字幕流不参与这个归一化（字幕有自己的时间对齐逻辑）。`demux_set_ts_offset` 的实现极简，就是把偏移记进 demuxer 内部状态：

```c
// demux/demux.c:937-943
void demux_set_ts_offset(struct demuxer *demuxer, double offset)
{
    struct demux_internal *in = demuxer->in;
    mp_mutex_lock(&in->lock);
    in->ts_offset = offset;
    mp_mutex_unlock(&in->lock);
}
```

偏移存在 **`struct demux_internal` 的 `ts_offset` 字段**（不是 `struct demuxer`，是它的私有内部结构 `demuxer->in`）：

```c
// demux/demux.c:254
double ts_offset;           // timestamp offset to apply to everything
```

注释 "apply to everything" 点明它是 **demuxer 级、对这个 demuxer 下所有流统一生效** 的偏移。加锁是因为 demuxer 跑在独立线程，偏移可能在读包线程之外被设置/读取。

**第三步——每个 packet 出 demuxer 时统一加偏移**。包真正交给上层消费时（`dequeue_packet`，`demux/demux.c:2736` 起的函数；调用自 `demux_read_packet_async`），统一加上这个偏移：

```c
// demux/demux.c:2858-2864
pkt->pts = MP_ADD_PTS(pkt->pts, in->ts_offset);
pkt->dts = MP_ADD_PTS(pkt->dts, in->ts_offset);

if (pkt->segmented) {
    pkt->start = MP_ADD_PTS(pkt->start, in->ts_offset);
    pkt->end = MP_ADD_PTS(pkt->end, in->ts_offset);
}
```

- pts、dts 都加 `in->ts_offset`（= `-start_time`），于是 `新pts = 原pts - start_time`，整条时间轴平移到约 0 起点。
- 用 `MP_ADD_PTS` 而非裸 `+`：**NOPTS 的包平移后仍是 NOPTS**，不会被偏移变成一个伪时间戳（呼应 1.1）。
- `segmented` 流（拼接/编辑列表）的 `start`/`end` 边界同样平移，保持一致。
- 反向操作（`-in->ts_offset`）出现在 seek、duration 查询等多处，把上层那套"已归一化"的时间换算回 demuxer 内部"原始容器时间"去定位——可见 `ts_offset` 是上层归一化时间轴和底层原始时间轴之间的统一换算枢纽。

**为什么用"固定 start_time 偏移"而不是"减第一帧 pts"——设计意图**：

这是整节最值得理解的一点。两种思路看似都能 rebase 到 0，但只有前者是对的：

- **偏移在打开文件时就定死，且对所有流共用同一个值**。`avfc->start_time` 是容器综合出的单一起点，`ts_offset` 又是 demuxer 级（"apply to everything"），所以视频流和音频流减的是**同一个** `start_time`。
- 如果改成"每条流各自减自己的第一帧 pts"，问题就来了：视频和音频的第一帧 pts 在容器里往往**不相等**（音频常常比视频早或晚一点起始）。各减各的第一帧，会把这个本应保留的相对时差抹平——结果就是**音视频从此错位**，且这种错位是系统性的、贯穿整个文件。
- 用统一的固定偏移则**完整保留了各流之间的原始相对关系**：平移前视频比音频早多少秒，平移后还是早多少秒，只是整体挪到了 0 附近。a/v 同步因此不受归一化影响。
- 额外好处：偏移是个常量，不依赖"哪一帧先到""seek 后第一帧是谁"这类运行时状态，逻辑稳定、可逆（seek 时反向加 `-ts_offset` 即可换回原始时间定位）。

### 1.5 完整调用链 / 数据流

从 FFmpeg `AVPacket` 进来到带归一化 pts 的 `demux_packet` 出 demuxer：

```
[打开文件 / find_stream_info 阶段，一次性]
avformat_find_stream_info()
  └─ demux_lavf.c:1498  demuxer->start_time = avfc->start_time / AV_TIME_BASE   (容器级起点，秒)
loadfile.c:961         if (rebase_start_time && filter != STREAM_SUB)
loadfile.c:962           demux_set_ts_offset(demuxer, -demuxer->start_time)
                           └─ demux.c:941  in->ts_offset = -start_time          (冻结偏移，demuxer 级)

[每个包，读包线程]
av_read_frame() → AVPacket{ pts, dts, duration : 整数 @ st->time_base }
demux_lavf_read_packet (demux_lavf.c)
  └─ new_demux_packet_from_avpacket()                                            (拷贝数据)
  └─ demux_lavf.c:1627  dp->pts = mp_pts_from_av(pkt->pts, &st->time_base)
  └─ demux_lavf.c:1628  dp->dts = mp_pts_from_av(pkt->dts, &st->time_base)
        └─ av_common.c:172  av_pts==AV_NOPTS ? MP_NOPTS_VALUE : av_pts*av_q2d(tb)  ← 唯一转换+NOPTS翻译
  └─ demux_lavf.c:1629  dp->duration = pkt->duration * av_q2d(st->time_base)
  └─ demux_lavf.c:1645  if (linearize_ts) 用 info->ts_offset 修拼接不连续 (独立机制)
        → demux_packet{ pts, dts, duration : 秒, 但未做 start_time 归一化 }  入内部队列/缓存

[每个包，交给上层消费时]
demux_read_packet_async → dequeue_packet (demux.c:2736)
  └─ demux.c:2858  pkt->pts = MP_ADD_PTS(pkt->pts, in->ts_offset)   ← 归一化:减 start_time
  └─ demux.c:2859  pkt->dts = MP_ADD_PTS(pkt->dts, in->ts_offset)               (NOPTS 安全)
  └─ demux.c:2861  if (segmented) start/end 同步平移
        → demux_packet{ pts, dts : 已归一化、秒为单位、约从 0 起 }  出 demuxer
```

**涉及的关键数据结构与字段**：

- **`struct demux_packet`**（`demux/packet.h`）：`double pts` / `double dts`（27-28，秒，NOPTS 用 `MP_NOPTS_VALUE`）、`double duration`（29）、`double start, end`（仅 `segmented` 时有效）。这是 mpv 在 demuxer 边界之后流通的统一时间戳载体。
- **`struct demuxer`**（`demux/demux.h:232`）：`double start_time`，容器综合起始时间（秒），归一化偏移的来源。
- **`struct demux_internal`**（`demux/demux.c:254`）：`double ts_offset`，"apply to everything" 的 demuxer 级偏移，归一化平移的实际承载者。
- **`AVStream::time_base`**：每条流自己的整数 time_base，`mp_pts_from_av` 的换算因子。
- **`MP_NOPTS_VALUE`** + **`MP_ADD_PTS` / `MP_PTS_OR_DEF`** 等宏：贯穿全链路的 NOPTS 哨兵与安全运算原语。

### 1.6 对 WorkLabs 的启示

WorkLabs 当前在 `WLMediaSource` 直接 `node.pts = frame->pts * time_base`，相比 mpv 少了两道关键防线：(1) 没有 NOPTS 判断——FFmpeg 给出 `AV_NOPTS_VALUE`（`INT64_MIN`）时直接乘 time_base 会得到一个巨大负秒数，污染节流与同步（mpv 用 `mp_pts_from_av` 的显式翻译堵这个口子）；(2) 没有 start_time 归一化——直接用容器原始 pts 作为时间基准，对起点非 0 的流（如 TS）会偏移，且若音视频各自从自己第一帧起算还会错位。可借鉴的最小改动：进来先判 NOPTS（缺失时标记哨兵而非乘出脏值），并在打开文件时取一个**统一的** `start_time` 偏移、对音视频用同一个值平移，而不是各减各的第一帧 pts。

---

## 2. 时间戳的异常处理

视频/音频文件里的时间戳（PTS/DTS）远比想象中脏：可能缺失（`MP_NOPTS_VALUE`）、倒退（B 帧重排序漏、容器损坏）、重复（同 pts 两帧）、巨跳（拼接流、TS 流回绕）、或带 1ms 量级的取整抖动（Matroska）。mpv 的设计目标是「无论时间戳多脏，都不崩、不卡死、不乱跳」。它不是靠某一处神来之笔，而是一条**纵深防护链**：解码侧先做 pts 兜底与插值，播放侧再做帧间隔 clamp，最后用相对积分时钟把单帧异常的影响"吸收"掉、不让它污染整条时间轴。下面逐层拆解。

### 2.1 播放侧帧间隔 clamp（最核心的一道闸）

整条链的核心是 `handle_new_frame()`。它在一帧进入待显示队列时计算「这一帧相对上一帧应该等多久」，即 `frame_time`：

```c
// player/video.c:375-400
static void handle_new_frame(struct MPContext *mpctx)
{
    mp_assert(mpctx->num_next_frames >= 1);

    double frame_time = 0;
    double pts = mpctx->next_frames[0]->pts;
    bool is_sparse = mpctx->vo_chain && mpctx->vo_chain->is_sparse;

    if (mpctx->video_pts != MP_NOPTS_VALUE) {
        frame_time = pts - mpctx->video_pts;
        double tolerance = mpctx->demuxer->ts_resets_possible &&
                           !is_sparse ? 5 : 1e4;
        if (frame_time <= 0 || frame_time >= tolerance) {
            // Assume a discontinuity.
            MP_WARN(mpctx, "Invalid video timestamp: %f -> %f\n",
                    mpctx->video_pts, pts);
            frame_time = 0;
        }
    }
    mpctx->time_frame += frame_time / mpctx->video_speed;
    if (mpctx->ao_chain && !mpctx->ao_chain->delaying_audio_start)
        mpctx->delay -= frame_time;
    if (mpctx->video_status >= STATUS_PLAYING)
        adjust_sync(mpctx, pts, frame_time);
    MP_TRACE(mpctx, "frametime=%5.3f\n", frame_time);
}
```

逐句拆解：

- **`frame_time = pts - mpctx->video_pts`**（`video.c:384`）：帧间隔不是从 pts 绝对值算"目标时刻"，而是算"距上一帧的增量"。`video_pts` 是上一帧已显示的 pts。第一帧时 `video_pts == MP_NOPTS_VALUE`，整段跳过，`frame_time` 保持 0（首帧立即显示）。

- **容差 `tolerance` 的两档取值**（`video.c:385-386`）：
  - `ts_resets_possible && !is_sparse` 为真 → `tolerance = 5`（秒）。即"容器自己声明时间戳可能 reset"（典型是 TS/HLS 这类允许 discontinuity 的流，见 2.2），那么超过 5 秒的跳变就当作不连续来处理，把闸门收紧。
  - 否则 → `tolerance = 1e4`（一万秒）。普通文件不预期会 reset，所以闸门开得极宽，几乎只拦截"非正向"（`<= 0`）的脏值，正常的长间隔（比如稀疏字幕/封面图）不会误伤。
  - `is_sparse` 的作用：稀疏流（静止图、封面图）本来就允许超长帧间隔，所以即便 `ts_resets_possible` 也**不**把容差收紧到 5 秒，避免把"图片显示 10 秒"误判成跳变。

- **判定 + 归零**（`video.c:387-392`）：当 `frame_time <= 0`（pts 倒退或重复）**或** `frame_time >= tolerance`（巨跳）时，认定为不连续，直接 `frame_time = 0`。

这一步是整个设计最关键、也最反直觉的决定，必须讲清"为什么是归零，而不是丢弃、也不是修正"：

- **为什么不按异常间隔 sleep**：如果 pts 突然倒退 -30 秒或跳进 +3000 秒，谁敢按这个数去等？倒退是负数没法 sleep；巨跳会让播放器卡死 50 分钟。归零 = **这一帧立即显示**，绝不依据脏间隔去睡。这是"不卡死"的根本保证。
- **为什么不丢帧**：丢帧会丢内容（尤其关键帧），且无法恢复音画同步参照。mpv 选择"如数显示，只是不为它额外等待"。
- **为什么不"修正" pts**：因为 `frame_time` 是**增量语义**，归零意味着"这一帧紧贴上一帧出"。下一帧再用它自己的 pts 减新的 `video_pts` 算增量。也就是说异常只让这一帧"立即出"，**不改写后续帧的时间基准**——污染被限制在单帧。

- **归零后的去向**（`video.c:394`）：`mpctx->time_frame += frame_time / mpctx->video_speed`。`time_frame` 是"还需要等多久才显示下一帧"的相对计时器。`frame_time=0` 意味着对它零贡献 → 立即可显示。`/ video_speed` 处理变速播放。

### 2.2 `ts_resets_possible` 从哪来

收紧容差的开关来自 demuxer，在 `demux_lavf.c` 里赋值：

```c
// demux/demux_lavf.c:1495-1496
demuxer->ts_resets_possible =
    priv->avif_flags & (AVFMT_TS_DISCONT | AVFMT_NOTIMESTAMPS);
```

注意它**不是 mpv 自己枚举"TS/HLS"这些格式名**，而是直接取 libavformat 给每个 demuxer 标的能力位：

- `AVFMT_TS_DISCONT`（"Format allows timestamp discontinuities"）——MPEG-TS、HLS 这类允许拼接、允许时间戳跳变/回绕的传输流封装会带这个 flag。
- `AVFMT_NOTIMESTAMPS`——裸流（如裸 `h264`/`hevc`/`vvc`）这类根本没有可靠时间戳的格式。

`avif_flags` 本身在 `demux_lavf.c:544` 合成：`priv->avif->flags | priv->format_hack.if_flags`，即"libavformat 原生 flag" OR "mpv 针对个别格式打的补丁 flag"。

传到播放侧的路径：`demuxer->ts_resets_possible` 是 demuxer 结构体上的字段，`handle_new_frame()` 直接读 `mpctx->demuxer->ts_resets_possible`（`video.c:385`）。它还在 demux 缓存/复制时被透传（`demux.c:3102`：`dst->ts_resets_possible = src->ts_resets_possible;`），并影响 seek 逻辑（`playloop.c:341`）。一句话：**容器一旦声明"我可能 reset 时间戳"，播放侧就把跳变容差从一万秒收紧到 5 秒，让 clamp 更敏感地拦住 TS 流的真实回绕**。

### 2.3 解码侧 pts 兜底与插值

在帧到达播放侧之前，解码包装层 `f_decoder_wrapper.c` 已经做了第一道清洗，尽量保证下游拿到的是单调、连续的 pts。

#### (a) `crazy_video_pts_stuff`：缺/坏 pts 用 dts 兜底

```c
// filters/f_decoder_wrapper.c:709-743
static void crazy_video_pts_stuff(struct priv *p, struct mp_image *mpi)
{
    // Note: the PTS is reordered, but the DTS is not. Both must be monotonic.

    if (mpi->pts != MP_NOPTS_VALUE) {
        if (mpi->pts < p->codec_pts)
            p->num_codec_pts_problems++;
        p->codec_pts = mpi->pts;
    }

    if (mpi->dts != MP_NOPTS_VALUE) {
        if (mpi->dts <= p->codec_dts)
            p->num_codec_dts_problems++;
        p->codec_dts = mpi->dts;
    }
    ...
    // If PTS is unset, or non-monotonic, fall back to DTS.
    if ((p->num_codec_pts_problems > p->num_codec_dts_problems ||
        mpi->pts == MP_NOPTS_VALUE) && mpi->dts != MP_NOPTS_VALUE)
        mpi->pts = mpi->dts;
    ...
}
```

要点：PTS 因为 B 帧重排序，本身就**不单调**（这是正常的，不算"问题"）；但 DTS 一定单调。函数分别统计 PTS / DTS 的"非单调次数"。判据是相对的：**当 PTS 的乱序问题比 DTS 还多（说明 PTS 本身坏了，不只是正常重排），或 PTS 干脆缺失**，且有 DTS 可用时，就 `mpi->pts = mpi->dts`——用更可靠的 DTS 顶上。最后还针对"误把 mpeg 风格 DTS 当 avi 时间戳"的历史坑做了 B 帧延迟补偿。

#### (b) `correct_video_pts`：彻底无 pts 时用 `last_pts + 1/fps` 外推

```c
// filters/f_decoder_wrapper.c:804-832
static void correct_video_pts(struct priv *p, struct mp_image *mpi)
{
    mpi->pts *= p->play_dir;

    if (!p->opts->correct_pts || mpi->pts == MP_NOPTS_VALUE) {
        double fps = p->fps > 0 ? p->fps : 25;
        ...
        double frame_time = 1.0f / fps;
        double base = p->first_packet_pdts;
        mpi->pts = p->pts;
        if (mpi->pts == MP_NOPTS_VALUE) {
            mpi->pts = base == MP_NOPTS_VALUE ? 0 : base;
        } else {
            mpi->pts += frame_time;
        }
    }

    p->pts = mpi->pts;
}
```

逐句拆解：

- `mpi->pts *= p->play_dir`：倒放时 `play_dir = -1`，pts 取反，使下游始终按"增大方向"处理。
- 进入兜底分支的条件：**用户关掉了 correct_pts**，或**这一帧经过 (a) 后 pts 仍然缺失**。
- `fps = p->fps > 0 ? p->fps : 25`：拿容器声明帧率算名义帧时长；连帧率都没有就兜底 25fps（一个对绝大多数内容都"不致命"的猜测）。
- 核心外推逻辑：`mpi->pts = p->pts`（`p->pts` 是上一帧最终采用的 pts）：
  - 若 `p->pts` 也没有（说明这是真正的**首帧**且无 pts）→ 用 `first_packet_pdts`（首个 packet 的 pts，没有就用 dts），它也没有就退到 **0**。即"从第一个有意义的时间戳起步，否则从 0 起步"。
  - 否则 → `mpi->pts = last_pts + 1/fps`，按固定帧率**线性外推**。
- `p->pts = mpi->pts`：记录本帧 pts，供下一帧外推。

这样即使整条流一个 pts 都没有，下游也能拿到一串"0, 1/fps, 2/fps, …"的单调虚构时间戳，不会触发播放侧的"无效时间戳"分支。

#### (c) `correct_audio_pts`：累加插值 + 双阈值跳变检测

音频的特殊性在于：每一帧 pts 与其样本数严格对应，可以用"上一帧 pts + 本帧时长"来**插值**，从而无视容器里那些被取整污染的时间戳。

```c
// filters/f_decoder_wrapper.c:834-875
static void correct_audio_pts(struct priv *p, struct mp_aframe *aframe)
{
    double dir = p->play_dir;
    double frame_pts = mp_aframe_get_pts(aframe);
    double frame_len = mp_aframe_duration(aframe);

    if (frame_pts != MP_NOPTS_VALUE) {
        if (dir < 0)
            frame_pts = -(frame_pts + frame_len);
        ...
        double diff = fabs(p->pts - frame_pts);

        // Attempt to detect jumps in PTS. ...
        if (p->pts != MP_NOPTS_VALUE && diff > 0.1) {
            MP_WARN(p, "Invalid audio PTS: %f -> %f\n", p->pts, frame_pts);
            if (diff >= 5) {
                mp_mutex_lock(&p->cache_lock);
                p->pts_reset = true;
                mp_mutex_unlock(&p->cache_lock);
            }
        }

        // Keep the interpolated timestamp if it doesn't deviate more
        // than 1 ms from the real one. (MKV rounded timestamps.)
        if (p->pts == MP_NOPTS_VALUE || diff > 0.001)
            p->pts = frame_pts;
    }

    if (p->pts == MP_NOPTS_VALUE && p->header->missing_timestamps)
        p->pts = 0;

    mp_aframe_set_pts(aframe, p->pts);

    if (p->pts != MP_NOPTS_VALUE)
        p->pts += frame_len;
}
```

这里有三个阈值，物理意义各不相同：

- **`> 0.001`（1ms）= 插值保留阈值**（`video.c:864`）：`p->pts` 是上一帧累加出来的"理想"时间戳。如果容器给的 `frame_pts` 与它偏差 **≤ 1ms**，就**保留插值值、忽略容器值**——这正是为了对抗 MKV 把时间戳取整到 1ms 造成的来回抖动（每帧 ±0.5ms，累积会让音频"忽快忽慢"）。偏差 > 1ms 才相信容器，重置 `p->pts = frame_pts`。
- **`> 0.1`（100ms）= 跳变告警阈值**（`video.c:853`）：偏差超过 100ms，肯定不是取整抖动了，是真实跳变，打 warning。注释明确说：即便最低采样率 + 最差容器取整，这个余量也绰绰有余，不会误报。
- **`>= 5`（5秒）= 判定 reset 阈值**（`video.c:855`）：偏差 ≥ 5 秒，认定是时间戳**重置**（拼接/回绕），置 `p->pts_reset = true`。这个标志会被上层消费（`player/audio.c:893` 的 `mp_decoder_wrapper_get_pts_reset`）触发真正的 reset 流程，而不是在这里硬改。
- 收尾：每帧 `p->pts += frame_len`（`video.c:874`）——这就是"累加插值"的本体；并对"声明无时间戳"的容器兜底 `p->pts = 0`。

### 2.4 VFR 帧时长计算

播放侧除了算"等多久（`frame_time`）"，还要算"这一帧本身该显示多久（duration）"，用于显示同步、估算 EOF 末帧时长等。这就是 `calculate_frame_duration()`：

```c
// player/video.c:954-1006
static void calculate_frame_duration(struct MPContext *mpctx)
{
    ...
    double demux_duration = vo_c->filter->container_fps > 0
                            ? 1.0 / vo_c->filter->container_fps : -1;
    double duration = demux_duration;

    if (mpctx->num_next_frames >= 2) {
        double pts0 = mpctx->next_frames[0]->pts;
        double pts1 = mpctx->next_frames[1]->pts;
        if (pts0 != MP_NOPTS_VALUE && pts1 != MP_NOPTS_VALUE && pts1 >= pts0)
            duration = pts1 - pts0;
    }

    // The following code tries to compensate for rounded Matroska timestamps
    // by "unrounding" frame durations ... These formats usually round on 1ms.
    double tolerance = 0.001 * 3 + 0.0001;

    double total = 0;
    int num_dur = 0;
    for (int n = 1; n < mpctx->num_past_frames; n++) {
        // Eliminate likely outliers using a really dumb heuristic.
        double dur = mpctx->past_frames[n].duration;
        if (dur <= 0 || fabs(dur - duration) >= tolerance)
            break;
        total += dur;
        num_dur += 1;
    }
    double approx_duration = num_dur > 0 ? total / num_dur : duration;

    // Try if the demuxer frame rate fits - if so, just take it.
    if (demux_duration > 0) {
        if (fabs(duration - demux_duration) < tolerance &&
            fabs(total - demux_duration * num_dur) < tolerance &&
            (num_dur >= 16 || num_dur >= mpctx->num_past_frames - 4))
        {
            approx_duration = demux_duration;
        }
    }
    ...
}
```

分四步理解：

1. **优先用相邻帧实测间隔**：有前瞻的下一帧（`num_next_frames >= 2`）且两帧 pts 都有效、且 `pts1 >= pts0`（防倒退）时，`duration = pts1 - pts0`。这是**真 VFR**：每帧时长直接由相邻 pts 差给出，不假设恒定帧率。
2. **回退容器帧率**：拿不到相邻 pts 差就退回 `1.0 / container_fps`（容器声明的标称帧率），再没有就是 -1（未知）。
3. **~3ms 容差 + 历史平均消抖**：`tolerance = 0.001*3 + 0.0001 ≈ 3.1ms`。往回扫历史帧（`past_frames`），把"与当前 `duration` 偏差 < 3.1ms 且 > 0"的连续帧累加求平均，得到 `approx_duration`。MKV 的 1ms 取整会让单帧 duration 在真值附近 ±1~2ms 抖动；对一窗口求平均正好把这种零均值抖动抹平，得到平滑的近似时长。一旦某帧偏差越界（outlier，可能是真正的 VFR 切变）就 `break`，不把它算进平均，避免污染。
4. **样本足够且吻合容器帧率时直接采用容器帧率**：如果实测 `duration` 与容器 `demux_duration` 之差 < 3.1ms、且累加的 `total` 与 `demux_duration * num_dur` 之差也 < 3.1ms、**并且**样本够多（`num_dur >= 16` 或几乎覆盖全部历史帧），就干脆 `approx_duration = demux_duration`。理由：这其实就是恒定帧率内容（只是 pts 被取整抖了），与其用"平均出来的近似值"长期累积微小误差，不如直接吃容器标称帧率这个**精确有理数**，彻底消除累积漂移。这是"实测优先、但识别出 CFR 后就回归精确标称值"的精妙折中。

### 2.5 相对时钟 vs 绝对锚定（设计哲学）

前面所有局部修复，最终都依赖一个全局架构决定才能"自愈"：**mpv 用相对积分时钟调度，而不是绝对锚定**。

绝对锚定的写法是：`目标显示时刻 = baseTime + pts`，到点就出帧。它的致命缺陷是——**任何一帧的脏 pts 都会直接变成屏幕上的跳变/长冻结**，因为时间轴被钉死在 pts 绝对值上。

mpv 不这么做。它维护一个相对计时器 `time_frame`，含义是"距下一帧显示还剩多少秒"，靠**两个方向的积分**推进：

- **加上理想增量**（`video.c:394`）：`mpctx->time_frame += frame_time / mpctx->video_speed;` —— `frame_time` 是 2.1 里已被 clamp 过的"相对增量"（异常时为 0）。
- **减去真实流逝**（`video.c:1190`）：
  ```c
  // player/video.c:1190
  mpctx->time_frame -= get_relative_time(mpctx);
  ```
  其中 `get_relative_time()`（`playloop.c:134-140`）返回的是两次调用间墙钟真实经过的秒数（`mp_time_ns()` 差值）。最终在 `video.c:1201-1202` 把 `time_frame` 折算成绝对唤醒时刻 `pts = mp_time_ns() + time_frame*1e9` 交给 VO 等待。

这套"加理想间隔、减真实流逝"的积分式调度带来的好处正是整条防护链的收口：**当某一帧的 pts 异常被 2.1 clamp 成 `frame_time = 0` 后，它对 `time_frame` 的贡献是 0，于是该帧立即显示；下一帧又拿它自己的 pts 减新的 `video_pts` 重新算增量。** 单帧异常只造成"这一帧抢着出来了一下"，绝不会像绝对锚定那样把整条时间轴拽到错误的绝对位置上去跳变或卡死。误差不累积、不传播——这是相对时钟相对绝对锚定的本质优势。

### 2.6 一帧脏 pts 的完整防护链（一条线串起来）

把上面各层按一帧脏 pts 进来的时间顺序串起来：

1. **解码侧第一道**（`crazy_video_pts_stuff`, `f_decoder_wrapper.c:709`）：pts 缺失或乱序 → 用单调的 DTS 顶替。
2. **解码侧第二道**（`correct_video_pts`, `:804` / `correct_audio_pts`, `:834`）：仍无 pts → 视频按 `last_pts + 1/fps` 线性外推（首帧用 `first_packet_pdts` 或 0）；音频按 `last_pts + frame_len` 累加插值，并用 1ms / 100ms / 5s 三阈值区分"取整抖动 / 跳变告警 / 真 reset"。下游因此尽量拿到单调连续的 pts。
3. **播放侧 clamp**（`handle_new_frame`, `video.c:375`）：万一前面没拦住，出现倒退/重复（`frame_time <= 0`）或巨跳（`>= tolerance`，TS 流收紧到 5 秒），直接 `frame_time = 0` —— 该帧立即显示，绝不按脏间隔 sleep。
4. **相对时钟吸收**（`time_frame += frame_time/speed` 再 `-= get_relative_time`, `video.c:394` & `:1190`）：归零的增量对计时器零贡献，异常被限制在单帧；下一帧重新积分，时间轴自愈、不累积误差。
5. **帧时长侧**（`calculate_frame_duration`, `video.c:954`）：与上面正交，用相邻 pts 差 + 3ms 容差历史平均 + CFR 识别，给出平滑且无累积漂移的 VFR 帧时长。

### 2.7 对 WorkLabs 的启示

WorkLabs 的 `WLMediaSource` 当前是**绝对锚定 + 无 clamp**：`node.pts = frame->pts * time_base` 后，渲染线程按 `baseTime + pts` 节流。这正是 2.5 指出的最脆弱写法——一旦 pts 倒退就会算出负的等待（瞬间冲帧/乱序），一旦 pts 巨跳就会按几十分钟去 sleep（卡死）。最小改造方向有二：(1) 借鉴 2.1，把节流改成"相对增量 `frame_time = pts - last_pts`，对 `<=0` 或 `>=容差` 的脏值 clamp 成 0 立即出帧"，并用相对积分时钟（累加理想增量、扣减真实流逝）替代绝对锚定，让单帧异常只影响一帧；(2) 借鉴 2.3，在拿到 `frame->pts == AV_NOPTS_VALUE` 时用 `last_pts + 1/fps` 兜底，而不是直接乘 `time_base` 产出脏值污染后续节流。

---

## 3. A/V 同步时钟（音频为主）

默认 `--video-sync=audio`：**音频自由播放、视频去追音频**。整条链路是：

```
① 音频写入设备队列        → 推进 last_out_pts(=written_audio_pts) 与 MPContext.delay
② 视频帧就绪              → 用 ao_get_delay() 实测「设备里还剩多少音频没播」，
                            算出这一帧「该等多久才显示」 time_frame
③ 折算成绝对时刻          → pts_ns = mp_time_ns() + time_frame*1e9
④ VO 线程睡到 pts_ns      → mp_cond_timedwait_until 睡到点，新帧到达提前唤醒，再上屏
⑤ 偏差用 adjust_sync 缓慢吸收（每次 10%、单帧封顶）；落后太多则在解码层/VO 层丢帧
```

灵魂在 ②：mpv 不假设音频"按理论采样率匀速流逝"，而是**向声卡实测**还剩多少缓冲，从而得到一个真正"准"的音频主时钟。

### 3.1 默认 video-sync 模式

```c
// options/options.c:193-202
{"video-sync", OPT_CHOICE(video_sync,
    {"audio", VS_DEFAULT},
    {"display-resample", VS_DISP_RESAMPLE},
    {"display-resample-vdrop", VS_DISP_RESAMPLE_VDROP},
    {"display-resample-desync", VS_DISP_RESAMPLE_NONE},
    {"display-tempo", VS_DISP_TEMPO},
    {"display-adrop", VS_DISP_ADROP},
    {"display-vdrop", VS_DISP_VDROP},
    {"display-desync", VS_DISP_NONE},
    {"desync", VS_NONE})},
```

模式分两大类：

- **`audio`（默认 / `VS_DEFAULT`）**：音频按设备节奏自由播放，视频对齐到音频时钟。时间基准是"声音真正播到哪了"。本章讲的就是这一支。
- **`display-*` 系列**：以显示器 vsync 为时钟，把视频帧时长重采样到 vsync 网格上，音频反过来做轻微变速/丢补来跟视频。追求"零判断、完美匀速"的画面节奏（消 judder）。
- **`desync` / `display-desync`**：不做 A/V 校正，各跑各的（调试 / 特殊用途）。

本章涉及的音频主时钟逻辑都在 `update_avsync_before_frame()` 里以 `!display_sync_active && video_sync != VS_NONE` 为前提（见 3.5）。

### 3.2 主时钟读数：音频为主时钟

```c
// player/audio.c:615-630
// Return pts value corresponding to the start point of audio written to the
// ao queue so far.
double written_audio_pts(struct MPContext *mpctx)
{
    return mpctx->ao_chain ? mpctx->ao_chain->last_out_pts : MP_NOPTS_VALUE;
}

// Return pts value corresponding to currently playing audio adjusted for AO delay
// and playback speed.
double playing_audio_pts(struct MPContext *mpctx)
{
    double pts = written_audio_pts(mpctx);
    if (pts == MP_NOPTS_VALUE || !mpctx->ao)
        return pts;
    return pts - mpctx->audio_speed * ao_get_delay(mpctx->ao);
}
```

- **`written_audio_pts`** = `ao_chain->last_out_pts`，是"**已经写进 AO 队列的那段音频的尾部 pts**"。注意它是**已写入**，不是"已听到"——数据虽然交给了 AO，但还躺在软件队列/硬件缓冲里没真正出喇叭。
- **`playing_audio_pts`** = `written_audio_pts − audio_speed × ao_get_delay()`。这个减法是音频主时钟的关键直觉：
  ```
  真正听到的 pts = 已写入的 pts − （设备里还没播出去的那段缓冲所对应的时长）
  ```
  `ao_get_delay()` 返回"还剩多少秒音频没播"（输出端秒数）；乘 `audio_speed` 换算回**源时间轴**上的时长（变速时 1 秒输出≠1 秒源时间），再从已写入尾部 pts 里扣掉，就得到"此刻喇叭正在发声的那个采样点对应的源 pts"——真正的主时钟当前值。

`playing_audio_pts` 主要用于显示/统计（如 3.4 的去同步告警）；视频调度本身用更细的 `delay` 桥接 + `ao_get_delay`（见 3.5），但物理含义同源。

### 3.3 `ao_get_delay()` —— 向设备实测延迟（灵魂）

这是整个主时钟"准"的根本。它**不**假设音频以理论采样率匀速流逝，而是问声卡"你那边到底还剩多少没播"：

```c
// audio/out/buffer.c:295-318
double ao_get_delay(struct ao *ao)
{
    struct buffer_state *p = ao->buffer_state;
    mp_mutex_lock(&p->lock);

    double driver_delay;
    if (ao->driver->write) {
        struct mp_pcm_state state;
        get_dev_state(ao, &state);
        driver_delay = state.delay;
    } else {
        int64_t end = p->end_time_ns;
        int64_t now = mp_time_ns();
        driver_delay = MPMAX(0, MP_TIME_NS_TO_S(end - now));
    }

    int64_t pending = mp_async_queue_get_samples(p->queue);
    if (p->pending)
        pending += mp_aframe_get_size(p->pending);

    mp_mutex_unlock(&p->lock);
    return driver_delay + pending / (double)ao->samplerate;
}
```

返回值 = **设备侧延迟** `driver_delay` + **软件队列里还没送进设备的样本** `pending / samplerate`，两段相加就是"从此刻起，到目前手上所有音频全部播完，还需要的秒数"。

分两种 AO：

- **push 型**（`driver->write` 非空，如 ALSA push 模式）：直接 `get_dev_state` 问驱动当前缓冲延迟 `state.delay`。
- **pull 型**（`driver->write` 为空，**CoreAudio 属于此类**）：用
  ```
  driver_delay = max(0, (end_time_ns − now) / 1e9)
  ```
  其中 `end_time_ns` 是"**最后一次被声卡取走的那批样本，预计播到喇叭的绝对时刻**"。`end_time_ns − now` 就是"已交给硬件的那批，还剩多久播完"——一个**实测的绝对时间差**，而非按样本数累加的理论值。声卡晚回调、缓冲抖动、设备时钟与系统时钟的漂移，全都自动体现在这个差值里。

`end_time_ns` 的写入路径（pull 型）：

```c
// audio/out/buffer.c:178-189
static int ao_read_data_locked(struct ao *ao, void **data, int samples,
                               int64_t out_time_ns, bool *eof, bool pad_silence)
{
    struct buffer_state *p = ao->buffer_state;
    mp_assert(!ao->driver->write);
    int pos = read_buffer(ao, data, samples, eof, pad_silence);
    if (pos > 0)
        p->end_time_ns = out_time_ns;          // 记录这批样本预计的输出截止绝对时刻
    ...
}
```

`out_time_ns` 由具体 AO 在它的实时渲染回调里算好传进来。CoreAudio 的回调：

```c
// audio/out/ao_coreaudio.c:84-100
static OSStatus render_cb_lpcm(void *ctx, AudioUnitRenderActionFlags *aflags,
                              const AudioTimeStamp *ts, UInt32 bus,
                              UInt32 frames, AudioBufferList *buffer_list)
{
    struct ao *ao   = ctx;
    struct priv *p  = ao->priv;
    void *planes[MP_NUM_CHANNELS] = {0};
    for (int n = 0; n < ao->num_planes; n++)
        planes[n] = buffer_list->mBuffers[n].mData;

    int64_t end = mp_time_ns();
    end += p->hw_latency_ns + ca_get_latency(ts) + ca_frames_to_ns(ao, frames);
    ao_read_data(ao, planes, frames, end, NULL, true, true);
    return noErr;
}
```

这里 `end`（即 `out_time_ns`）= 当前系统时刻 `mp_time_ns()` + 三段延迟：

1. `p->hw_latency_ns` —— AudioUnit + 设备的固有硬件延迟（开流时一次性查得）；
2. `ca_get_latency(ts)` —— 本次回调由 CoreAudio 提供的时间戳（`AudioTimeStamp`）换算出的、从现在到这批样本上声卡的额外延迟；
3. `ca_frames_to_ns(ao, frames)` —— 本批 `frames` 个样本本身的播放时长。

后两者的实现：

```c
// audio/out/ao_coreaudio_utils.c:296-313
int64_t ca_frames_to_ns(struct ao *ao, uint32_t frames)
{
    return MP_TIME_S_TO_NS(frames / (double)ao->samplerate);
}

int64_t ca_get_latency(const AudioTimeStamp *ts)
{
#if HAVE_COREAUDIO || HAVE_AVFOUNDATION
    uint64_t out = AudioConvertHostTimeToNanos(ts->mHostTime);
    uint64_t now = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime());
    if (now > out)
        return 0;
    return out - now;
#else
    ... // mach_absolute_time 等价路径
#endif
}
```

- `ca_frames_to_ns` = `frames / samplerate` 秒（这批样本的播放时长）。
- `ca_get_latency` 把 `AudioTimeStamp` 的 host time（`mach_absolute_time` 域）换算成相对当前的纳秒延迟——与 §0.1 的 `mp_time_ns` 同源，可直接相加。

于是 pull 型的 `driver_delay = (end_time_ns − now)/1e9` 天然包含了"硬件固有延迟 + 设备时钟实际进度"，这正是"实测"而非"理论推算"的来源。**对 WorkLabs 的对应**：CoreAudio 的这套 = AudioQueue 下 `AudioQueueGetCurrentTime` 返回的 `mSampleTime` / host time + 设备延迟，二者是等价物（见 3.8）。

### 3.4 `delay` 桥接 + 比例校正

视频调度并不直接用 `playing_audio_pts`，而是用一个增量记账字段 `MPContext.delay` 把"音频写了多少"和"视频显示到哪"桥接起来。

#### 3.4.1 `delay` 字段语义（官方注释）

```c
// player/core.h:366-370
// AV sync: the next frame should be shown when the audio out has this
// much (in seconds) buffered data left. Increased when more data is
// written to the ao, decreased when moving to the next video frame.
double delay;
// AV sync: time in seconds until next frame should be shown
double time_frame;
```

`delay` 的官方定义很精确：**「下一帧应当在 AO 还剩这么多（秒）缓冲数据时显示」**——写音频时增大、推进视频帧时减小。这与 3.5 的核心式 `time_frame = ao_get_delay() − delay/video_speed` 完美咬合：当设备剩余缓冲 `ao_get_delay()` 降到 `delay` 时，`time_frame=0` → 该显示这一帧了。换个视角看，`delay` 也正是"已写音频比已显示视频多出的时长"（写 += / 显示 −=），两个视角等价。

#### 3.4.2 写音频时 `delay` 增长

```c
// player/audio.c:733-737
mpctx->shown_aframes += samples;
double real_samplerate = mp_aframe_get_rate(af) / mpctx->audio_speed;
if (mpctx->video_status != STATUS_EOF)
    mpctx->delay += samples / real_samplerate;
ao_c->last_out_pts = mp_aframe_end_pts(af);
```

- `real_samplerate = 原始采样率 / audio_speed`，是**变速后的有效采样率**。所以 `samples / real_samplerate` = 这批样本在**源时间轴**上的时长（不是输出时长）。变速 1.5x 播放时，同样的 `samples` 折算成更长的源时间。
- 同时 `last_out_pts = mp_aframe_end_pts(af)`，即 3.2 里 `written_audio_pts` 的来源——"已写入音频尾部 pts"。
- 视频 EOF 时不再累加（音频继续放完即可，无需再桥接视频）。

#### 3.4.3 移到下一视频帧时 `delay` 缩减

```c
// player/video.c:394-399（handle_new_frame 末尾，见 2.1）
mpctx->time_frame += frame_time / mpctx->video_speed;
if (mpctx->ao_chain && !mpctx->ao_chain->delaying_audio_start)
    mpctx->delay -= frame_time;
if (mpctx->video_status >= STATUS_PLAYING)
    adjust_sync(mpctx, pts, frame_time);
```

`frame_time` 是相邻两帧 pts 之差（已被 2.1 clamp）。于是：写音频 → `delay += 音频时长`；推进视频一帧 → `delay -= frame_time`。一增一减，`delay` 稳定表征"音频领先视频多少"。

#### 3.4.4 `adjust_sync()` —— 比例吸收偏差

文件本身可能有"音频时间戳与音频包实际时长对不上"的毛病。`adjust_sync` 缓慢地把这种偏差吸收进 `delay`，避免画面/声音突跳：

```c
// player/video.c:347-370
static void adjust_sync(struct MPContext *mpctx, double v_pts, double frame_time)
{
    struct MPOpts *opts = mpctx->opts;
    if (mpctx->audio_status != STATUS_PLAYING)
        return;

    double a_pts = written_audio_pts(mpctx) + opts->audio_delay - mpctx->delay;
    double av_delay = a_pts - v_pts;

    double change = av_delay * 0.1;
    double factor = fabs(av_delay) < 0.3 ? 0.1 : 0.4;
    double max_change = opts->default_max_pts_correction >= 0 ?
                        opts->default_max_pts_correction : frame_time * factor;
    if (change < -max_change)
        change = -max_change;
    else if (change > max_change)
        change = max_change;
    mpctx->delay += change;
    mpctx->total_avsync_change += change;
    ...
}
```

逐句：
- `a_pts = written_audio_pts + audio_delay − delay`：把"已写音频尾部 pts"减去 `delay`，**反推**出"理论上当前视频应当对应的音频 pts"；`audio_delay` 是用户的 `--audio-delay` 手动偏移。
- `av_delay = a_pts − v_pts`：理论音频位置与本帧实际视频 pts 的偏差。
- `change = av_delay × 0.1`：**每次只吃掉偏差的 10%**。`0.1` 是一阶低通/指数收敛——单次校正量很小，需多帧才完全吸收，校正平滑爬升而非阶跃，观众察觉不到突跳。
- `max_change = frame_time × factor`（默认）：**单帧封顶**。`factor` 在偏差小（`<0.3s`）时取 `0.1`、偏差大时取 `0.4`——偏差越大允许稍快收敛，但仍以"帧时长的零点几倍"为硬上限，杜绝任何单帧把时间轴猛拉一下。
- 校正落到 `mpctx->delay += change`：注意它改的是 `delay`，从而**间接**改变下一帧 `update_avsync_before_frame` 算出的等待时间，而不是直接平移时间戳。

#### 3.4.5 去同步告警阈值 0.5s

```c
// player/video.c:654-663
double a_pos = playing_audio_pts(mpctx);
if (a_pos != MP_NOPTS_VALUE && mpctx->video_pts != MP_NOPTS_VALUE) {
    mpctx->last_av_difference = a_pos - mpctx->video_pts
                              + opts->audio_delay + offset;
}
if (fabs(mpctx->last_av_difference) > 0.5 && !mpctx->drop_message_shown) {
    MP_WARN(mpctx, "%s", av_desync_help_text);
    mpctx->drop_message_shown = true;
}
```

`0.5s` 是"人耳/人眼明显能察觉不同步"的工程阈值——正常运行时 `adjust_sync` + 丢帧应把差值压在远小于此的范围，越过它说明系统已经救不回来了（解码太慢/时间戳损坏），于是发一次告警。`last_av_difference` 同时是解码层丢帧的输入（见 3.6）。

### 3.5 视频「睡到何时显示」的调度（核心）

#### 3.5.1 算"这一帧该等多久"：`time_frame`

```c
// player/video.c:594-638（节选）
static void update_avsync_before_frame(struct MPContext *mpctx)
{
    ...
    } else if (mpctx->audio_status == STATUS_PLAYING &&
               mpctx->video_status == STATUS_PLAYING &&
               !ao_untimed(mpctx->ao))
    {
        double buffered_audio = ao_get_delay(mpctx->ao);

        double predicted = mpctx->delay / mpctx->video_speed +
                           mpctx->time_frame;
        double difference = buffered_audio - predicted;
        MP_STATS(mpctx, "value %f audio-diff", difference);

        if (opts->autosync) {
            ... // 默认 autosync=0，不走这里
        }

        mpctx->time_frame = buffered_audio - mpctx->delay / mpctx->video_speed;
    } else {
        if (mpctx->time_frame < -0.2 || opts->untimed ||
            (vo->driver->caps & VO_CAP_UNTIMED))
            mpctx->time_frame = 0;
    }
}
```

默认（`audio` 模式、`autosync=0`）的关键一行：

```c
mpctx->time_frame = buffered_audio - mpctx->delay / mpctx->video_speed;
//                = ao_get_delay()  - delay / video_speed
```

物理含义：
- `buffered_audio = ao_get_delay()` = "设备里还剩多少秒音频要播"——音频时钟距离它当前位置还能往前走多久。
- `delay / video_speed` = "音频已领先视频的量"换算到视频速率下的等价等待时间。
- 两者相减 = **本帧距离"该上屏的那一刻"还要等的秒数 `time_frame`**。

直觉版：音频缓冲里还有 `ao_get_delay()` 秒要播，而视频本来已经落后/领先音频 `delay` 这么多；把这两个量对齐，得到"再等 `time_frame` 秒，这一帧正好对上届时音频会播到的位置"。这正好兑现了 3.4.1 里 `delay` 的官方定义。

`else` 分支（未配音频/AO 是 untimed 等）有个 `−0.2s` 兜底：落后超过 200ms 就不再试图加速追赶，直接 `time_frame=0` 按原速放，防止"为追赶而疯狂快放"。

#### 3.5.2 折算成绝对时刻

```c
// player/video.c:1190-1207（节选）
mpctx->time_frame -= get_relative_time(mpctx);   // 扣掉自上次以来已流逝的真实时间
update_avsync_before_frame(mpctx);               // 重算 time_frame（3.5.1）
...
double time_frame = MPMAX(mpctx->time_frame, -1);            // 下限 −1s，防止异常大负值
int64_t pts = mp_time_ns() + (int64_t)(time_frame * 1e9);    // ★ 绝对上屏时刻（纳秒）

// wait until VO wakes us up to get more frames
if (!vo_is_ready_for_frame(vo, mpctx->display_sync_active ? -1 : pts))
    return;
```

`pts = mp_time_ns() + time_frame*1e9`：以当前单调时钟（§0.1）为基准，加上还要等的 `time_frame`，得到这一帧**应显示的绝对纳秒时刻**。`MPMAX(time_frame, -1)` 把过期帧的等待量钳在 −1s。随后 `vo_is_ready_for_frame(vo, pts)` 把这个绝对时刻交给 VO 线程；返回 false 表示 VO 还没准备好接帧（还在睡/队列满或时刻未到），本轮先返回，下次再来。

#### 3.5.3 VO 线程睡到点显示

`vo_is_ready_for_frame` 把上屏时刻记进 VO 内部状态，并据"是否已到点"决定就绪与否：

```c
// video/out/vo.c:830-859
// next_pts is the exact time when the next frame should be displayed. If the
// VO is ready, but the time is too "early", return false, and call the wakeup
// callback once the time is right.
// If next_pts is negative, disable any timing and draw the frame as fast as possible.
bool vo_is_ready_for_frame(struct vo *vo, int64_t next_pts)
{
    struct vo_internal *in = vo->in;
    mp_mutex_lock(&in->lock);
    bool r = vo->config_ok && !in->frame_queued &&
             (!in->current_frame || in->current_frame->num_vsyncs < 1);
    if (r && next_pts >= 0) {
        // Don't show the frame too early ... render at earliest the given
        // offset before target time.
        next_pts -= in->timing_offset;
        next_pts -= in->flip_queue_offset;
        int64_t now = mp_time_ns();
        if (next_pts > now)
            r = false;                              // 还没到点 → 未就绪
        if (!in->wakeup_pts || next_pts < in->wakeup_pts) {
            in->wakeup_pts = next_pts;              // 记录需要被唤醒的最近时刻
            if (!r)
                wakeup_locked(vo);                  // 更新 vo 线程定时器
        }
    }
    mp_mutex_unlock(&in->lock);
    return r;
}
```

VO 线程主循环取 `wakeup_pts` 作为本轮睡眠 deadline，用 §0.2 的绝对超时原语睡到点；有新帧/事件则被提前唤醒：

```c
// video/out/vo.c:714-722（vo_wait_default：通用 VO 的等待实现）
void vo_wait_default(struct vo *vo, int64_t until_time)
{
    struct vo_internal *in = vo->in;
    mp_mutex_lock(&in->lock);
    if (!in->need_wakeup)                                       // 唤醒去重：已被要求唤醒就不睡
        mp_cond_timedwait_until(&in->wakeup, &in->lock, until_time);  // 睡到绝对时刻
    mp_mutex_unlock(&in->lock);
}

// video/out/vo.c:1152-1214（vo_thread 主循环节选）
//   if (in->wakeup_pts) { if (in->wakeup_pts > now) wait_until = MPMIN(wait_until, in->wakeup_pts);
//                         else in->wakeup_pts = 0; }
//   ...
//   wait_vo(vo, wait_until);     // 睡到下一帧上屏时刻（或更早的事件）
```

`mp_cond_timedwait_until` 是"睡到某个**绝对时刻**"（§0.2），底层 darwin 走 `mach_wait_until`，因此多帧调度不会因相对超时累积误差而漂移。睡眠期间一旦有新帧到达或事件发生，`mp_cond_signal(&in->wakeup)` 立刻把 VO 线程叫醒重新评估。到点后 VO 把帧交给驱动渲染上屏——这一帧就显示在了"对齐音频时钟"的那个绝对时刻。

### 3.6 丢帧 / 补帧

当解码/渲染跟不上时，靠两层丢帧把"越落越多直至冻屏"降级为"掉帧但时间轴不崩"。

#### 3.6.1 解码层：落后丢帧 `check_framedrop`

```c
// player/video.c:319-336
static void check_framedrop(struct MPContext *mpctx, struct vo_chain *vo_c)
{
    struct MPOpts *opts = mpctx->opts;
    if (mpctx->video_status == STATUS_PLAYING && !mpctx->paused &&
        mpctx->audio_status == STATUS_PLAYING && !ao_untimed(mpctx->ao) &&
        vo_c->track && vo_c->track->dec && (opts->frame_dropping & 2))
    {
        float fps = vo_c->filter->container_fps;
        // it's a crappy heuristic; avoid getting upset by incorrect fps
        if (fps <= 20 || fps >= 500)
            return;
        double frame_time =  1.0 / fps;
        // try to drop as many frames as we appear to be behind
        mp_decoder_wrapper_set_frame_drops(vo_c->track->dec,
            MPCLAMP((mpctx->last_av_difference - 0.010) / frame_time, 0, 100));
    }
}
```

- 只在"正常播放 + 有定时音频 + 用户开启了 `--framedrop` 含 decoder 位（`& 2`）"时生效；`fps` 越界（≤20 或 ≥500）时不信任，跳过。
- 丢帧数 = `(last_av_difference − 0.010) / frame_time`，钳在 `[0,100]`：
  - `last_av_difference` 是 3.4.5 算出的当前 A/V 差（音频领先视频多少秒）；
  - **`0.010`（10ms）是容差**：落后在 10ms 以内不丢，避免对正常抖动过度反应、引起无谓丢帧；
  - 超过容差的部分除以单帧时长 `frame_time`，就是"我落后了几帧"，对应丢几帧让解码器跳过 B/P 帧快速追上（**解码层**丢帧，让解码器少干活），上限 100 帧防止一次性请求过多。

#### 3.6.2 VO 层：兜底丢过期帧 + 100ms 上限保护

VO 在真正渲染前还有一道兜底——过期帧（`end_time < now`）标记可丢，但用一连串 `&=` 收紧条件，其中最关键的是 **100ms 上限**：

```c
// video/out/vo.c:947-961（render_frame 节选）
int64_t now = mp_time_ns();
int64_t pts = frame->pts;
int64_t duration = frame->duration;
int64_t end_time = pts + duration;
...
// "normal" strict drop threshold.
in->dropped_frame = duration >= 0 && end_time < now;       // 过期帧
in->dropped_frame &= !frame->display_synced;
in->dropped_frame &= !(vo->driver->caps & VO_CAP_FRAMEDROP);
in->dropped_frame &= frame->can_drop;
// Even if we're hopelessly behind, rather degrade to 10 FPS playback,
// instead of just freezing the display forever.
in->dropped_frame &= now - in->prev_vsync < MP_TIME_MS_TO_NS(100);   // ★ 100ms 上限
in->dropped_frame &= in->hasframe_rendered;
```

注释把意图写得很白：`in->dropped_frame &= now - in->prev_vsync < 100ms` —— 即便系统已**绝望地落后**，只要距上一次实际刷新已超过 100ms，就**强制不丢、必须渲染一帧**。这等价于显示节奏最差也只降级到约 **10fps**，而**不会**因为试图一次性补上几秒的落后而长时间不刷新（冻屏）。体验上是卡顿而非画面定格。

### 3.7 关键数据结构与字段速查

| 字段 / 量 | 位置 | 含义 |
|---|---|---|
| `MPContext.delay` | `player/core.h:369` | 下一帧应在 AO 还剩这么多（秒）缓冲时显示；写音频 `+= 样本/真实采样率`，推进视频帧 `-= frame_time` |
| `MPContext.time_frame` | `player/core.h:370` | 距下一帧应显示还要等的秒数；`update_avsync_before_frame` 覆写为 `ao_get_delay() − delay/video_speed` |
| `ao_chain->last_out_pts` | 由 `audio.c:737` 写 | 已写入 AO 队列音频的尾部 pts，即 `written_audio_pts()` |
| `MPContext.video_pts` | `player/video.c` | 当前正在/即将显示帧的 pts，A/V 差比对的视频侧基准 |
| `MPContext.last_av_difference` | `video.c:656` | 实时 A/V 差（`playing_audio_pts − video_pts + …`），驱动 0.5s 告警与解码丢帧 |
| `buffer_state.end_time_ns` | `buffer.c:187` 写 | （pull 型 AO）最后被取走那批样本预计上喇叭的绝对时刻；`ao_get_delay` 用 `end−now` 实测剩余延迟 |
| `vo_internal.wakeup_pts` | `vo.c:851/884` | VO 线程下次该醒来显示帧的绝对时刻 |
| 绝对上屏 `pts` | `video.c:1202` | `mp_time_ns() + time_frame*1e9`，传给 `vo_is_ready_for_frame` / VO 线程睡到点 |
| 系数 `0.1` | `video.c:357` | `adjust_sync` 每次只吃 10% 偏差，平滑收敛不跳变 |
| 容差 `0.010` (10ms) | `video.c:334` | 解码丢帧的落后容差，小抖动不丢帧 |
| 阈值 `0.5` (s) | `video.c:660` | A/V 去同步告警阈值 |
| 上限 `100ms` | `vo.c:960` | VO 兜底丢帧的过期量上限，最差降级到 ~10fps 而非冻屏 |

### 3.8 对 WorkLabs 的启示

mpv 的精髓是：**有一个唯一的主时钟（音频"真正听到的位置"），其值不是按理论采样率累加，而是向声卡实测**（pull 型用"最后样本预计输出的绝对时刻 − 现在 + 软件队列未送样本数"）；视频再据此算出每帧"睡到哪个绝对时刻"显示，偏差只用 `adjust_sync` 缓慢（每次 10%、单帧封顶）吸收，落后则分两层丢帧（解码层 10ms 容差、VO 层 100ms 上限保底）。

WorkLabs 目前各源是 `baseTime + pts` 各自独立节流、**没有统一主时钟**，源间会逐渐漂移，也没有"视频对齐音频"的概念。若要对齐 mpv：

- WorkLabs 用 **AudioQueue**，可用 **`AudioQueueGetCurrentTime`**（返回 `mSampleTime` + host `AudioTimeStamp`）配合"已入队但未播样本数"，构造一个与 mpv `ao_get_delay()` 等价的**实测音频延迟**；据此得到 `playing_audio_pts = 已写入尾部pts − 未播时长`，即一个真实的音频主时钟。
- 各视频/相机源的上屏时刻改为对齐到这个主时钟（类似 `time_frame = 音频剩余缓冲 − 已领先量`，再折算成 `mach_absolute_time` 绝对时刻去等待），而非各自的 `baseTime + pts`。
- 偏差用 mpv 式的比例吸收（小步收敛、单帧封顶）避免突跳；落后时丢帧降级而非堆积。

---

## 4. seek / 暂停 / 启动对齐时的时间戳重置

这一章讲透 mpv 在三个时刻如何处理时间轴：**seek**（跳转）、**pause/resume**（暂停恢复）、**playback restart**（启动 / seek 完成后重新起步）。核心结论先行——mpv 在 seek 后**不去"修正"旧时间戳，而是把整套计时状态清零，让下一帧自然重建一条新时间轴**；暂停时则**冻结"剩余等待量"而非依赖墙钟**。这两条设计哲学是本章的主线。

### 4.0 涉及的核心状态字段

理解后面所有逻辑，先认清 `MPContext` 上这几个字段：

- `video_pts` —— 当前已经"消费"的视频帧 pts（上一帧的时间戳锚点）。`MP_NOPTS_VALUE` 表示"还没有锚点"。
- `time_frame` —— **距离下一帧应显示时刻还要等待的秒数**（相对量，不是绝对时间）。playloop 每轮用它换算 sleep；这是暂停冻结的关键。
- `delay` —— 音视频同步用的 A/V 偏差累积量（视频每前进一帧 `delay -= frame_time`，音频每送出一批样本 `delay += samples/rate`）。
- `audio_status` / `video_status` —— 两条流各自的播放状态机，取值是一个**可数值比较**的枚举：

```c
// player/core.h:225-232
enum playback_status {
    // code may compare status values numerically
    STATUS_SYNCING,     // seeking for a position to resume
    STATUS_READY,       // buffers full, playback can be started any time
    STATUS_PLAYING,     // normal playback
    STATUS_DRAINING,    // decoding has ended; still playing out queued buffers
    STATUS_EOF,         // playback has ended, or is disabled
};
```

关键在于"枚举可比大小"：`STATUS_SYNCING(0) < READY(1) < PLAYING(2) < DRAINING(3) < EOF(4)`。大量判断写成 `status < STATUS_READY`（还没填满缓冲）、`status >= STATUS_PLAYING`（已经在正常播了）这种区间比较。各状态语义：
- **SYNCING**：刚 seek 完，正在解码、寻找一个可以续播的位置（找起始 pts、裁早到样本）。
- **READY**：缓冲已填满，随时可起步——这是"对齐闸门"的等待点。
- **PLAYING**：正常播放，时间轴在走。
- **DRAINING / EOF**：解码结束 / 播放结束。

### 4.1 seek 时的视频状态重置：清零重建，而不是修正

seek 的入口 `mp_seek()` 在完成 demuxer 跳转、清空音频输出缓冲后，调用 `reset_playback_state()`（`player/playloop.c:405`），后者把三条流全部 reset（`player/playloop.c:241-247`）：

```c
// player/playloop.c:241-247
void reset_playback_state(struct MPContext *mpctx)
{
    ...
    reset_video_state(mpctx);
    reset_audio_state(mpctx);
    reset_subtitle_state(mpctx);
```

视频侧的 `reset_video_state()` 是本章最关键的一段：

```c
// player/video.c:98-127
void reset_video_state(struct MPContext *mpctx)
{
    if (mpctx->vo_chain) {
        vo_chain_reset_state(mpctx->vo_chain);     // 丢弃 VO 里排队的帧、清 underrun 标志
        ...
    }

    for (int n = 0; n < mpctx->num_next_frames; n++)
        mp_image_unrefp(&mpctx->next_frames[n]);   // 清空"未来帧"窗口
    mpctx->num_next_frames = 0;
    mp_image_unrefp(&mpctx->saved_frame);

    mpctx->delay = 0;                              // A/V 偏差归零
    mpctx->time_frame = 0;                         // 剩余等待量归零
    mpctx->video_pts = MP_NOPTS_VALUE;             // ★ 时间锚点失效
    mpctx->last_frame_duration = 0;
    mpctx->num_past_frames = 0;                    // 清空"历史帧"（算 duration 用）
    mpctx->total_avsync_change = 0;
    mpctx->last_av_difference = 0;
    mpctx->mistimed_frames_total = 0;
    mpctx->drop_message_shown = 0;
    mpctx->audio_drift_compensation = 0;
    mpctx->avd_filtered = 0;
    mpctx->display_sync_error = 0;
    mpctx->display_sync_active = 0;

    mpctx->video_status = mpctx->vo_chain ? STATUS_SYNCING : STATUS_EOF;  // 回到 SYNCING
}
```

**在做什么**：把所有跟"时间轴推进"和"A/V 同步"相关的状态一律推回原点——未来帧窗口（`next_frames`）和历史帧窗口（`past_frames`）清空、计时器（`time_frame`）和锚点（`video_pts`）失效、同步误差累积全部归零，状态机退回 `STATUS_SYNCING`。

**为什么是"清零重建"而不是"修正"**：seek 后第一帧的 pts 是一个全新的、与之前毫无连续性的值（可能往前跳、往后跳、甚至文件本身时间戳就会回绕）。如果想"修正"——比如给所有后续 pts 减去一个偏移让它接上旧时间轴——就要维护偏移量、处理回绕、处理多流各自的偏移，复杂且脆弱。mpv 的选择是：**根本不接旧轴**。把锚点 `video_pts` 置成 `MP_NOPTS_VALUE`，于是下一帧进入 `handle_new_frame()`（见 2.1）时 `if (mpctx->video_pts != MP_NOPTS_VALUE)` 这段逻辑自动短路：`frame_time` 保持 0 → `time_frame` 不前进、`delay` 不变。

换句话说，**新时间轴的"第一帧"被当作"间隔为 0 的起点"自然落地，谁也不用去算偏移**。等这帧被消费、`video_pts` 被赋成它自己的 pts 后，下一帧才开始用"差值"正常推进——新时间轴就这样从这一帧无缝重建起来。

这同时把它和"异常处理"逻辑统一了：**正常播放途中遇到时间戳跳变（discontinuity）走的也是同一条 `frame_time` 归零路径**（2.1 的 `if (frame_time <= 0 || frame_time >= tolerance)`）。也就是说 mpv 把"seek 后的第一帧"和"播放中遇到坏时间戳"用同一套机制兜底：都让 `frame_time = 0`，计时器不乱跳，等下一帧重新建立连续性。这就是"清零重起"哲学的完整闭环：**不修正、只清零，让自然差值机制自己长回正确的时间轴**。

### 4.2 seek 时的音频状态重置：与视频协同

音频侧对称地有 `reset_audio_state()`：

```c
// player/audio.c:219-241
static void ao_chain_reset_state(struct ao_chain *ao_c)
{
    ao_c->last_out_pts = MP_NOPTS_VALUE;
    ao_c->out_eof = false;
    ao_c->start_pts_known = false;       // ★ "起始对齐 pts 是否已知"清掉
    ao_c->start_pts = MP_NOPTS_VALUE;    // ★ 起始 pts 失效
    ao_c->untimed_throttle = false;
    ao_c->underrun = false;
    ao_c->delaying_audio_start = false;  // 不再处于"延迟起音频"状态
}

void reset_audio_state(struct MPContext *mpctx)
{
    if (mpctx->ao_chain) {
        ao_chain_reset_state(mpctx->ao_chain);
        ...
    }
    mpctx->audio_status = mpctx->ao_chain ? STATUS_SYNCING : STATUS_EOF;  // 回 SYNCING
    mpctx->delay = 0;                    // 与 video reset 一致，A/V 偏差归零
    mpctx->logged_async_diff = -1;
}
```

**在做什么、为什么**：音频和视频共享同一个 `delay` 字段，两边 reset 都把它清成 0——这是协同点：seek 后 A/V 同步从"零偏差"重新开始累积，而不是带着旧的累积误差。音频侧额外清掉的 `start_pts` / `start_pts_known` 是"音频该从哪个 pts 开始播"的对齐信息（4.4 会用到），seek 后必须重新计算。两条流 reset 后都落在 `STATUS_SYNCING`——这就把它们送进了 4.4 的"启动对齐闸门"，等双方都缓冲满再一起起步。注意 seek 流程里在 reset 之前还调了 `clear_audio_output_buffers()`（`player/playloop.c:402-403`，除非带 `NOFLUSH`），把已经送到 AO 的旧音频也丢掉——这是"清零"哲学贯彻到输出端的一环。

### 4.3 暂停 / 恢复：冻结"剩余等待量"而不是依赖墙钟

这是第二个核心哲学。先看时间基准函数：

```c
// player/playloop.c:134-140
double get_relative_time(struct MPContext *mpctx)
{
    int64_t new_time = mp_time_ns();
    int64_t delta = new_time - mpctx->last_time;   // 距上次调用真实流逝了多久
    mpctx->last_time = new_time;
    return delta * 1e-9;
}
```

`get_relative_time()` 返回**自上次调用以来真实墙钟流逝的秒数**，并把 `last_time` 推进到现在——它是一个"读取并清零"式的秒表。playloop 的视频路径正是用它把 `time_frame`（还要等多久显示下一帧）随真实时间消减：每轮 `time_frame -= get_relative_time()`（`player/video.c:1190`），减到 ≤0 就该显示帧了。

暂停 / 恢复的处理在 `set_pause_state()`：

```c
// player/playloop.c:187-192
        if (internal_paused) {
            mpctx->step_frames = 0;
            mpctx->time_frame -= get_relative_time(mpctx);   // ★ 暂停：结算并冻结剩余等待量
        } else {
            (void)get_relative_time(mpctx); // ignore time that passed during pause
        }
```

**这两行是整个暂停机制的灵魂**：

- **暂停瞬间** `time_frame -= get_relative_time()`：先把"从上一轮到现在这一小段真实流逝"结算进 `time_frame`，得到**暂停那一刻还剩多少等待量**，然后这个值就被冻在那里不动了（playloop 暂停后不再推进它）。比如下一帧还有 12ms 才该显示，暂停时 `time_frame` 就停在约 0.012。
- **恢复瞬间** `(void)get_relative_time()`：注释说得很直白——**ignore time that passed during pause**。这一句**只调用、丢弃返回值**，作用是把 `last_time` 一把推到"现在"，从而**吞掉暂停期间流逝的全部墙钟时间**。下一轮 `get_relative_time()` 算出的 delta 就只包含"恢复之后"的真实流逝。

**为什么必须这么做**：`time_frame` 是用墙钟消减的相对量。假设没有这两行——你暂停 30 秒再恢复，恢复后第一次 `time_frame -= get_relative_time()` 会一口气减掉 30 秒，`time_frame` 瞬间变成一个很大的负数，playloop 会判定"下一帧早就该显示了，而且后面一大批帧也全过期了"，于是**恢复瞬间疯狂丢帧/快进**。mpv 用"暂停时冻结剩余量、恢复时丢弃暂停期间的墙钟"把这个坑彻底填上：恢复后就好像时间从没流逝过，那帧还是欠 12ms，**一帧都不丢**。这就是"冻结剩余等待量"哲学——**计时基于"还欠多少"这个相对量，而暂停只是把这个相对量挂起，不让真实时间污染它**。

### 4.4 启动 / restart 对齐：两条流都 READY 才同时起步

seek 完成后或首次播放时，两条流都处于 `STATUS_SYNCING`，各自解码填缓冲。当任一条填满它就升到 `STATUS_READY`。真正的"同时起步"闸门在 `handle_playback_restart()`：

```c
// player/playloop.c:1153-1181
static void handle_playback_restart(struct MPContext *mpctx)
{
    if (mpctx->audio_status < STATUS_READY ||
        mpctx->video_status < STATUS_READY)
        return;                              // ★ 任一条还没 READY，直接返回，谁都不准起步

    handle_update_cache(mpctx);

    if (mpctx->video_status == STATUS_READY) {
        mpctx->video_status = STATUS_PLAYING;
        get_relative_time(mpctx);            // 重置秒表基准，从此刻开始计时
        mp_wakeup_core(mpctx);
    }

    if (mpctx->audio_status == STATUS_READY) {
        // 若起步前又来了新 seek，则不真正起音频，立即去处理那个 seek
        if (mpctx->seek.type && mpctx->video_status == STATUS_PLAYING) {
            handle_playback_time(mpctx);
            mpctx->seek.flags &= ~MPSEEK_FLAG_DELAY;
            execute_queued_seek(mpctx);
            return;
        }
        audio_start_ao(mpctx);               // 尝试起音频（可能还要再延迟，见下）
    }
    ...
```

**在做什么、为什么**：开头那个 `if (... < STATUS_READY) return;` 就是对齐闸门——**只要有一条流缓冲还没就绪，函数立刻返回，两条流都按住不动**。等到双方都至少 READY，才在同一次调用里把视频切 `STATUS_PLAYING` 并 `get_relative_time()` 重置秒表（让计时从"真正起步这一刻"开始），随后尝试起音频。这样保证 A/V 从同一时刻、以一致的时间基准启动，而不是谁先解码好谁先跑。

但"视频先 PLAYING、音频此刻才起"还不够——音频的解码起点 pts 不一定正好等于视频起点。这里有两个机制把晚到的流对齐到同一个起始 pts：

**(1) 用 `get_sync_pts()` 求出统一的起始 pts，必要时延迟起音频**：

```c
// player/audio.c:802-827
static bool get_sync_pts(struct MPContext *mpctx, double *pts)
{
    *pts = MP_NOPTS_VALUE;
    if (!opts->initial_audio_sync)
        return true;
    bool sync_to_video = mpctx->vo_chain && mpctx->video_status != STATUS_EOF &&
                         !mpctx->vo_chain->is_sparse;
    if (sync_to_video) {
        if (mpctx->video_status < STATUS_READY)
            return false;                                 // 视频 pts 还不知道，先等
        if (mpctx->video_pts != MP_NOPTS_VALUE)
            *pts = mpctx->video_pts - opts->audio_delay;  // ★ 以视频 pts 为对齐基准
    } else if (mpctx->hrseek_active) {
        *pts = mpctx->hrseek_pts;                         // 纯音频/hr-seek：以 seek 目标为基准
    } else {
        *pts = mpctx->playback_pts;
    }
    return true;
}
```

```c
// player/audio.c:832-854 (audio_start_ao 节选)
void audio_start_ao(struct MPContext *mpctx)
{
    ...
    double pts = MP_NOPTS_VALUE;
    if (!get_sync_pts(mpctx, &pts))
        return;                                  // 同步 pts 还算不出来，本轮先不起
    double apts = playing_audio_pts(mpctx);
    if (pts != MP_NOPTS_VALUE && apts != MP_NOPTS_VALUE && pts < apts &&
        mpctx->video_status != STATUS_EOF)
    {
        // 音频实际可起点 apts 晚于对齐目标 pts → 视频要先单独播一会儿
        double diff = (apts - pts) / mpctx->opts->playback_speed;
        if (!get_internal_paused(mpctx))
            mp_set_timeout(mpctx, diff);          // 让 playloop 等这个差值
        ...
        ao_c->delaying_audio_start = true;        // 标记：音频处于"延迟起步"
        return;
    }
    ...
    ao_start(ao_c->ao);
    mpctx->audio_status = STATUS_PLAYING;
    ...
}
```

`get_sync_pts()` 给出"所有流应当对齐到的那个起始 pts"：有视频时就以 `video_pts`（减去用户设的 `audio_delay`）为准，纯音频或 seek 场景以 seek 目标 pts 为准。`audio_start_ao()` 再比较音频"实际能开始的 pts"`apts` 与这个目标：如果音频起点比目标晚，就先不真正 `ao_start`，而是让 playloop 等 `diff` 秒、打上 `delaying_audio_start` 标记——**让先到的流先走、把另一条流"等"齐到同一起点**。

**(2) 用 `clip_timestamps` 裁掉早于起点的样本**：当音频帧里有一部分样本早于对齐起点 `start_pts`，直接整帧丢会丢过头，mpv 是**按样本裁切**：

```c
// player/audio.c:704-713
        double startpts = mpctx->audio_status == STATUS_SYNCING ?
                                            ao_c->start_pts : MP_NOPTS_VALUE;
        mp_aframe_clip_timestamps(af, startpts, endpts);   // ★ 裁掉 < startpts 的样本

        int samples = mp_aframe_get_size(af);
        if (!samples) {                                    // 整帧都早于起点 → 丢弃、继续
            mp_filter_internal_mark_progress(f);
            mp_frame_unref(&frame);
            return;
        }
```

`ao_c->start_pts` 正是 4.2 里 seek 时被清掉、之后在 SYNCING 期间由 `get_sync_pts()` 重新算出并写回的（写回逻辑在 `fill_audio_out_buffers()` 的 `audio_status == STATUS_SYNCING` 分支：`get_sync_pts()` 成功后置 `start_pts_known=true; start_pts=pts;` 并升到 `STATUS_READY`）。只在 `STATUS_SYNCING` 阶段才用 `start_pts` 去裁——一旦进入正常播放就不再裁。`mp_aframe_clip_timestamps` 把音频帧里 pts 早于 `start_pts` 的那些样本**精确裁掉**（晚于 `endpts` 的也裁），裁完没样本就丢弃整帧并继续要下一帧。

**多流如何对齐到同一个起始 pts，串起来看**：seek/启动 → 两流回 `STATUS_SYNCING` → 各自解码填缓冲，缓冲满升 `STATUS_READY` → `handle_playback_restart()` 闸门等两边都 READY → 视频切 PLAYING 并重置秒表 → `get_sync_pts()` 用视频 pts（或 seek 目标）定出统一起点 → 晚到的音频要么被 `mp_set_timeout` 延迟到对齐点起步，要么用 `mp_aframe_clip_timestamps` 把早到的样本裁掉，从对齐点精确开播。结果就是无论两条流解码进度差多少，最终都从同一个起始 pts 整齐起跑。

### 4.5 seek 整体流程入口（简述）

把上面三段在时间上串起来：用户触发 seek → 排入 `mpctx->seek`，playloop 调 `execute_queued_seek` → `mp_seek()`（`player/playloop.c:290`）。`mp_seek()` 依 seek 类型（ABSOLUTE / RELATIVE / FACTOR / FRAMESTEP / CHAPTER）算出 `seek_pts`，决定是否精确 seek（`hr_seek`），调 `demux_seek()` 让 demuxer 跳到目标附近的关键帧（本章不深挖 demuxer 内部），随后 `clear_audio_output_buffers()` + **`reset_playback_state()`**（`player/playloop.c:402-405`）触发 4.1/4.2 的全部清零。精确 seek 还会置 `hrseek_active / hrseek_pts` 并让解码器丢弃早于目标 pts 的帧。清零完成后两流进入 SYNCING，由后续 playloop 轮次走完 4.4 的对齐起步——`hrseek_pts` 正是 `get_sync_pts()` 在纯音频/对齐时用的那个目标 pts，闭环就此合上。

### 4.6 对 WorkLabs 的启示

WorkLabs 是实时合成、没有随机 seek，上述机制不能照搬，但有三点思路值得借鉴：

1. **"清零重建时间轴"对"切源 / 重连"有直接参考价值**。当某个 `WLMediaSource` 重新打开文件、或摄像头/网络源断线重连时，与其去"修正"新流的时间戳让它接上旧轴（要维护偏移、处理回绕，复杂且易错），不如学 mpv：把该源的本地计时锚点（类似 `video_pts`）置为无效、清空帧队列、让"第一帧间隔记为 0"自然重建本地时间轴——`WLMediaSource` 现有的 `baseTime + pts` 节流模型，正好可以在重连时重置 `baseTime`，等价于 mpv 的清零重起。同时 mpv 把"seek 第一帧"和"播放中坏时间戳"用同一条 `frame_time` clamp 路径兜底，提示 WorkLabs 的时序代码也可以用一个统一的"间隔异常→归零"clamp 来同时防御断流和坏 pts。

2. **多流起步对齐对未来多源同步是模板**。WorkLabs 已是多源合成，若将来要做"多源严格同步起播"，mpv 的"双流都 READY 才同时起步 + 用统一 `start_pts` + 按样本 `clip_timestamps` 裁早到内容"是成熟范式：各源先各自缓冲就绪，再以一个统一起始 pts 对齐，先到的等齐、早到的内容精确裁掉，而不是谁解码好谁先上画面。

3. **"暂停冻结剩余等待量"**虽然实时合成一般不暂停，但凡是用"墙钟消减相对等待量"来做节流的逻辑（`WLMediaSource` 的渲染线程节流即是），都要警惕"挂起后墙钟仍在走 → 恢复瞬间误判大批帧过期"这个坑——mpv 的解法（挂起时结算并冻结剩余量、恢复时丢弃挂起期间流逝的真实时间）是可直接套用的正确做法。

---

## 5. 关键文件与行号索引（v0.41.0-718-g1d82932cce）

| 主题 | 文件:行 | 内容 |
|---|---|---|
| **基础设施** | | |
| 单调时钟 | `osdep/timer.c:43,50` | `mp_time_ns` = raw − offset，单调严格正 |
| darwin 时钟/睡眠 | `osdep/timer-darwin.c:31,37,47` | `mach_wait_until` 绝对 deadline；`mach_absolute_time × timebase` |
| condvar 单调时钟 | `osdep/threads-posix.h:147,201` | `setclock(CLOCK_MONOTONIC)`；`mp_cond_timedwait_until(until)` |
| **① 产生与归一化** | | |
| time_base→秒 + NOPTS 翻译 | `common/av_common.c:155,169` | `get_def_tb`（防除零）、`mp_pts_from_av`（唯一转换点） |
| NOPTS 哨兵 + 安全宏 | `common/common.h:38,61-66` | `MP_NOPTS_VALUE`、`MP_ADD_PTS`/`MP_PTS_OR_DEF`/`MIN`/`MAX` |
| packet pts/dts/duration 转换 | `demux/demux_lavf.c:1627-1629` | pts/dts 各自转秒、不强制相等 |
| rebase 选项 | `options/options.c:609,1063` | `rebase_start_time` 默认 true |
| start_time 来源 | `demux/demux_lavf.c:1498` | `demuxer->start_time = avfc->start_time/AV_TIME_BASE` |
| 设偏移 | `player/loadfile.c:961` | `demux_set_ts_offset(-start_time)` |
| 偏移存储 | `demux/demux.c:254,937` | `in->ts_offset`（"apply to everything"） |
| packet 出 demuxer 加偏移 | `demux/demux.c:2858` | `MP_ADD_PTS(pts, ts_offset)` |
| **② 异常处理** | | |
| 帧间隔 clamp | `player/video.c:375-392` | `handle_new_frame`：`<=0` 或 `>=容差` → `frame_time=0` |
| ts_resets_possible | `demux/demux_lavf.c:1495` | `AVFMT_TS_DISCONT \| AVFMT_NOTIMESTAMPS` → 容差收紧到 5s |
| pts 用 dts 兜底 | `filters/f_decoder_wrapper.c:709` | `crazy_video_pts_stuff` |
| 无 pts 外推 | `filters/f_decoder_wrapper.c:804` | `correct_video_pts`：`last_pts + 1/fps` |
| 音频累加插值 | `filters/f_decoder_wrapper.c:834` | `correct_audio_pts`：1ms/100ms/5s 三阈值 |
| VFR 帧时长 | `player/video.c:954` | `calculate_frame_duration`：相邻 pts 差 + 3ms 容差 + CFR 识别 |
| 相对积分时钟 | `player/video.c:394,1190` | `time_frame += frame_time/speed` 再 `-= get_relative_time` |
| **③ A/V 同步时钟** | | |
| video-sync 默认 | `options/options.c:193` | 默认 `audio` |
| 音频主时钟 | `player/audio.c:617,624` | `written_audio_pts`、`playing_audio_pts` |
| 实测设备延迟 | `audio/out/buffer.c:295` | `ao_get_delay`（灵魂） |
| end_time_ns 写入 | `audio/out/buffer.c:178` + `ao_coreaudio.c:84` | pull 型最后样本预计输出时刻 |
| CoreAudio 延迟换算 | `audio/out/ao_coreaudio_utils.c:296,301` | `ca_frames_to_ns`、`ca_get_latency` |
| delay 字段 | `player/core.h:369` | 「下一帧应在 AO 还剩这么多缓冲时显示」 |
| 写音频 delay+= | `player/audio.c:733` | `delay += samples/real_samplerate` |
| 比例校正 | `player/video.c:347` | `adjust_sync`：每次 10%、单帧封顶 |
| 去同步告警 | `player/video.c:654` | 0.5s 阈值 |
| 算 time_frame | `player/video.c:594,625` | `time_frame = ao_get_delay() − delay/video_speed` |
| 折算绝对时刻 | `player/video.c:1202` | `pts = mp_time_ns() + time_frame*1e9` |
| VO 睡到点 | `video/out/vo.c:835,714,1214` | `vo_is_ready_for_frame`、`vo_wait_default`、`wait_vo` |
| 解码层丢帧 | `player/video.c:319` | `check_framedrop`：10ms 容差 |
| VO 丢帧 + 100ms 上限 | `video/out/vo.c:951-960` | `render_frame`：降级 10fps 而非冻屏 |
| **④ seek/暂停/启动** | | |
| 状态机枚举 | `player/core.h:225` | SYNCING<READY<PLAYING<DRAINING<EOF |
| 视频 reset | `player/video.c:98` | `reset_video_state`：`video_pts=NOPTS`、`time_frame=0` |
| 音频 reset | `player/audio.c:219,230` | `reset_audio_state`：清 `start_pts`、`delay=0` |
| reset 总入口 | `player/playloop.c:241` | `reset_playback_state` |
| 暂停冻结 | `player/playloop.c:187-191` | `time_frame -= get_relative_time`；恢复丢弃流逝 |
| 秒表 | `player/playloop.c:134` | `get_relative_time` |
| 启动对齐闸门 | `player/playloop.c:1153` | `handle_playback_restart`：两流都 READY 才起步 |
| 统一起始 pts | `player/audio.c:802,832` | `get_sync_pts`、`audio_start_ao` |
| 按样本裁切 | `player/audio.c:706` | `mp_aframe_clip_timestamps` |
| seek 入口 | `player/playloop.c:290,402` | `mp_seek` → `reset_playback_state` |

---

## 6. 三条最值得记住的设计哲学

1. **NOPTS 哨兵贯穿始终**：FFmpeg 整数哨兵在唯一转换点 `mp_pts_from_av` 翻译成浮点哨兵，之后所有运算走 `MP_ADD_PTS`/`MP_PTS_OR_DEF` 短路——缺失时间戳永远不会被算成一个巨大负数污染全链路。
2. **相对积分时钟 + clamp，而非绝对锚定**：调度用"加理想增量、减真实流逝"的 `time_frame`，对脏 pts 一律 clamp 成 0。单帧异常只影响一帧，绝不让整条时间轴跳变或卡死；seek/暂停只是清零或冻结这个相对量。
3. **主时钟向设备实测，不靠理论推算**：音频主时钟 = 已写入尾部 pts − 向声卡实测的剩余缓冲（`ao_get_delay`）；视频据此算"睡到哪个绝对时刻"，用绑定单调时钟的 condvar 睡到点、有帧提前唤醒。准、且稳态零空转。
