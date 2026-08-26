# TVUExternalSource 源码探寻问答记录

> 形式：用户提问 + 逐问核证回答。与 01~07 的结构化文档不同，这里保留探寻过程本身（包括中途推翻的猜测），
> 便于后续再整理成正式文档。
>
> 代码基线：`/Users/tvum4pro/Desktop/workzone/tvuanywhere_ios`，分支见各条记录。
> 所有结论均标注源码位置；凡属 libdispatch/系统实现细节而非本仓事实的，单独标记「实现细节」。

---

## Q1 — 长期占用 `dispatch_async` 队列是否有问题？毕竟不是 Thread

**提问上下文**：`TVUExternalSourceParse::startParseWithPath:andIndex:`
（[TVUExternalSourceParse.mm:147-455](../../../../Desktop/workzone/tvuanywhere_ios/products/TVUTransportIOS/TVUAnywherePro/Transmitter/TVUExternalSource/TVUExternalSourceParse/TVUExternalSourceParse.mm)）

### 1. 先把事实钉住：这里的"队列"到底是什么

`parseQueue` **不是** GCD 全局并发队列，也不是类内部懒加载的，而是**由外部注入**的私有串行队列。
全仓只有两处创建点，写法完全一样：

| 位置 | 代码 |
|---|---|
| `TVUInputSourceParseModule.mm:217` | `parse.parseQueue = dispatch_queue_create("com.externalSourceParseQueue%ld", DISPATCH_QUEUE_SERIAL)` |
| `TVUExternalSourceView.mm:1045` | 同上，`queueName = "com.externalSourceParseQueue%d"` |

两处都在 `parseArray` 懒加载里，循环 `for i = 1; i < 3` —— **只造 2 个** `TVUExternalSourceParse` 实例，
即同一时刻最多 2 条 parse 循环。加上 `thumbImageParseQueue`（`:589`，同样是私有串行队列），
本模块最多 3 条长驻循环。

block 体是 `while (!_isStop) { … }`（`:199`），**这个 block 一旦开始执行就不再返回**，直到 `stopParse` 把 `_isStop` 置 YES。

### 2. 你担心的"占满线程池" —— 在这段代码里不成立

结论：**不会因为占满 GCD 线程池而饿死其它队列**。原因是队列的创建方式。

「实现细节」libdispatch 里 `dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL)` 且不指定 target queue 时，
队列走的是 **overcommit 根队列**（libdispatch 源码注释原话是 "Serial queues default to overcommit"）。
overcommit 的含义就是：不受非 overcommit 线程池名额限制，libdispatch 会**直接为它新开一条内核线程**。

对比会出事的写法：
- `dispatch_async(dispatch_get_global_queue(…), ^{ while(1){} })` —— 占的是**非 overcommit** 池子的名额，
  池子容量有限（历史上常被引用为每个 QoS 桶 64 条，Apple 未做 API 保证），几条这样的死循环就能把池子占空，
  之后所有走全局队列的任务集体挂起 —— 这才是典型的 thread starvation。
- `dispatch_queue_create` 出来的队列 + 死循环 —— 不占池子名额，代价转移到别处（见下节）。

所以：**你的直觉方向是对的（GCD 的设计假设是「短、不阻塞」的工作单元），但这里踩的不是「线程池被占满」这个坑。**

### 3. 真正的四笔代价

#### ① 拿到了线程的成本，丢掉了线程的控制权

既然 overcommit 下每条队列本来就对应一条真线程，那用 GCD 就等于：付了线程的钱（内核线程、栈、上下文切换），
却买不到线程的三样东西 ——

- **优先级不可控**。`dispatch_queue_create` 第二参传 `DISPATCH_QUEUE_SERIAL`（即 `NULL`）→ 队列 QoS 为 unspecified
  → block 的 QoS 由**入队那一刻的调用方**决定。调用点在 `collectionView:didSelectItemAtIndexPath:`
  （`TVUExternalSourceView.mm:2766`）等 UI 回调里，也就是主线程。
  「实现细节」异步提交时 user-interactive 会被降一档到 user-initiated —— 即这条**永不返回**的解析循环，
  实际长期跑在 user-initiated 档上，和 UI 抢 CPU。用 pthread 就是显式设 sched param，一行的事。
  *（需要坐实的话，Instruments 的 Thread State / os_signpost 能直接看到线程 QoS。）*
- **栈大小不可控**。ffmpeg 解码路径栈用量不小，GCD 工作线程栈是 512KB 固定的，pthread 可以 `pthread_attr_setstacksize`。
- **不能 join**。这是最关键的一条，见 ④。

#### ② `usleep` 忙等背压，把线程钉死在原地

`:384-386`：

```objc
while (weakSelf.queueManager->freeQueueLength(...) <= 1 ||
       weakSelf.queueManager->videoDecoder.sortQueueManager->length() >= kTVUExternalSourceSortQueueNodeSize) {
    usleep(TVU_EXTERNAL_SOURCES_GENENAL_SLEEP_INTERVAL * 1000);   // 5ms，TVUConst.h:573
}
```

下游队列满了就 5ms 轮询一次。在 GCD 语境下这是明确的反模式（阻塞工作线程），
在 pthread 语境下则应当是 `pthread_cond_wait` —— 有意思的是，**同一个模块的解码侧就是这么写的**：
`TVUExternalSourceQueueManager::startThread/endThread`（`TVUExternalSourceQueueManager.mm:128-165`）
用的是标准 `pthread_mutex` + `pthread_cond_broadcast` + `pthread_join`。

**同一模块内两套并发模型并存**：解析侧 GCD + 忙等，解码侧 pthread + 条件变量。这才是本题的核心异味。

#### ③ `weakSelf` 形同虚设 —— block 其实强持有 self

block 里写了 `__weak __typeof(self) weakSelf = self;`（`:169`），但循环体内大量**直接访问 ivar**：

```objc
while (!_isStop) { … }                              // == self->_isStop
if (!_formatContext) { break; }                     // == self->_formatContext
avcodec_send_packet(_videoCodecContext, &packet);   // == self->_videoCodecContext
```

ObjC 里 block 内直接写 ivar 等于捕获 `self` **强引用**。所以 `weakSelf` 只在少数几处（`weakSelf.queueManager` 等）生效，
整体上 **block 强持有 self，只要循环不退出，`TVUExternalSourceParse` 就永远不会 dealloc**。

而且这个类**根本没有 `dealloc` 方法**（全文件搜 `dealloc` 无命中）—— 也就是说即便真到了释放时机，
也没有任何"确保循环已停"的兜底。

#### ④ 没有 join，只能靠状态位替代 —— 但这一处写对了

没有 `pthread_join` 就无法确认循环真的退出了。这在 ffmpeg 场景下是致命的：
`stopPreParse` 会 `avformat_close_input(&_formatContext)`，如果此时循环还卡在 `av_read_frame(_formatContext, &packet)`（`:203`），
就是 use-after-free。

代码用 `parseStatus` 当 join 的替身，**而且顺序是对的**：

```objc
- (void)freeObject {
    [self stopPreParse];                                    // 先释放 ffmpeg 上下文
    …
    self.parseStatus = TVUExternalSourceParseStatusFree;    // :897，最后一行才放行
}
```

`freeObject` 在 block 末尾调用（`:452`），跑在 parse 线程上；调用方靠
`if (parse.parseStatus != Free) continue;`（`TVUInputSourceParseModule.mm:58`、`TVUExternalSourceView.mm:1638/2734`）挡重入。
**"释放资源在前、翻状态位在后"这个顺序是正确的**，值得保留。

不过替身终究是替身，两个缺口还在：

- `parseStatus` 是 `nonatomic assign`，parse 线程写、主线程读，没有内存屏障 —— ARM64 上 word 不会撕裂，但主线程可能读到陈旧值。
- `_isStop` 是裸 `BOOL`（`:31`），非 `volatile` 非原子，同样跨线程读写。当前循环体里有大量不透明函数调用逼着编译器重载，
  实践中没出问题，但这是 UB，不是设计。

### 4. 一个顺带发现的时序漏洞

`_isStop = NO` 是在 `dispatch_async` **之前同步执行**的（`:159`）：

```
stopParse   → _isStop = YES        // 循环将在下一次检查时退出
startParse  → _isStop = NO         // ← 如果上一轮循环还没走到检查点，它就被"复活"了
              dispatch_async(...)  // 新 block 排在旧 block 后面，串行队列 → 永远不会执行
```

`parseStatus` 守卫能挡住大部分场景（旧循环没退出时 status 还是 Work），但这个守卫在**调用方**，
`startParseWithPath:` 自己不检查。`TVUExternalSourceView.mm:1644`（DJI 那条）在 `:1638` 有守卫，
`TVUInputSourceParseModule.mm:66` 在 `:58` 有守卫 —— 目前是全的，但属于"靠调用方自觉"，
把守卫下沉进 `startParseWithPath:` 开头会更稳。

### 5. 结论

| 问题 | 判定 |
|---|---|
| 会占满 GCD 线程池吗 | **不会**。私有串行队列走 overcommit，不抢池子名额 |
| 那这么写没问题吗 | **有问题，但不在你担心的地方**。代价是丢失优先级/栈/join 控制权 |
| 应该改成 Thread 吗 | 方向对。而且**同模块解码侧已经是 pthread + cond + join 了**，改造有现成范式可抄 |
| 眼下最该修的 | ③ block 强持有 self（ivar 直访）；其次 ② `usleep` 忙等换条件变量 |
| 已经写对、别动的 | `freeObject` 里"先释放资源、后翻 `parseStatus`"的顺序 |

### 6. 补充核证：两套 `parseArray` 只有一套是活的

`TVUInputSourceParseModule` **全仓没有任何实例化点** —— 唯一引用在 `TVUClipOperationResult.mm:330-332`，
整段被注释掉。而 `TVUExternalSourceView` 在 `MainViewController.mm:5464` 正常实例化。

所以 `TVUInputSourceParseModule` 是尚未接上的重构半成品（或已废弃），
**线上真正生效的 `parseArray` 只有 `TVUExternalSourceView` 那一套** → 长驻解析线程上限 2 条，
加 `thumbImageParseQueue` 共 3 条。数量本身完全无害，进一步印证「问题不在线程数，在控制权」。

> 副产物：`TVUInputSourceParseModule` 整个文件当前是死代码，动它不影响线上行为。

### 待核实

- [ ] parse 循环的实际线程 QoS（推断为 user-initiated，需 Instruments 实测）
- [x] ~~两套 `parseArray` 是否共存~~ → 否，`TVUInputSourceParseModule` 未被实例化（见 §6）

---

## Q2 — 所以应该使用 pthread

**结论先行：方向对，但"照抄隔壁那套 pthread"只买到一样东西，而且要先纠正我在 Q1 §3① 的一个措辞。**

### 1. 自我纠正：pthread 的"优先级/栈可控"在本仓是理论值

Q1 里我说"用 pthread 就是显式设 sched param，一行的事"。这话本身没错，但**本仓现有的 pthread 范式并没有这么做**：

```objc
// TVUExternalSourceQueueManager.mm:45,48
pthread_create(&threadArray[i].thread, NULL, startVideoDecodeThreadTask, this);
pthread_create(&threadArray[i].thread, NULL, startAudioDecodeThreadTask, this);
//                                     ^^^^ attr = NULL
```

`TVUExternalSourceSortQueueManager.mm:22` 同样是 `NULL`。全模块**没有一处** `pthread_attr_init` /
`pthread_attr_setschedparam` / `pthread_attr_setstacksize`，也**没有一处** `pthread_setname_np`。

`attr = NULL` 就是默认优先级、默认栈（512KB）—— 和 GCD 工作线程拿到的东西一模一样。

所以：**照抄隔壁改造，实际只买到 `pthread_join` 一样东西。**优先级和栈那两条要另外真写 `attr` 才算数。

### 2. 而且会丢一样东西：线程名

GCD 这边队列有 label `com.externalSourceParseQueue1`，crash log 和 Instruments 里直接显示。
隔壁 pthread 没有 `pthread_setname_np`，崩在解码线程上只能看到 `Thread 12`。

**这是 GCD 在本题上唯一强于现有 pthread 范式的地方。**要换就得把 `pthread_setname_np` 一起补上，否则线上排障反而退步。

### 3. 换 pthread 不解决的坑：`@autoreleasepool`

`TVUExternalSourceParse.mm` 全文件**没有任何 `@autoreleasepool`**。

GCD 侧的机制是：worker 线程在开始 drain 时 push 一个 pool，回到线程池（idle）时 pop。
而这个 block **永不返回** → 线程永不 idle → **pool 永不 drain**，autorelease 对象累积整个 parse 生命周期。

换成 pthread 呢？现代 objc runtime 在无 pool 的线程上 autorelease 时会自动装一页
（`AutoreleasePoolPage::autoreleaseNoPage`），同样只在线程退出时才清。
**下场完全一样 —— 既不更好也不更坏。**

隔壁的 `videoDecodeThread` / `audioDecodeThread` 也没有 pool，而它们里面确实调 ObjC
（`videoDecoder`、`audioDecoder` 都是 ObjC 对象）。**这是两边共有的坑，与线程模型正交。**

本文件的热路径（每帧）大多返回标量，累积速度不快；但 `postNotificationName:`
（`:205`、`:235`）会造 `NSNotification`，长循环 + 本地文件反复 seek 场景下会持续攒。

> 顺带：`postNotificationName:` 是同步派发，**所有观察者都跑在 parse 线程上**。这条另开一问再查。

### 4. 那到底改不改？按性价比排

| 优先级 | 动作 | 与线程模型的关系 | 改动量 |
|---|---|---|---|
| **P0** | 循环体内加 `@autoreleasepool { }` | 正交，换不换都要做 | 2 行 |
| **P0** | 消除 block 内 ivar 直访（`_isStop` / `_formatContext` / `_videoCodecContext` …）| 正交 | 改成 `strongSelf->` 或显式局部指针 |
| **P1** | QoS 显式化 —— **不需要换模型** | GCD 一行 attr 即可 | 2 处调用点各 1 行 |
| **P1** | `usleep(5ms)` 忙等 → 条件变量 | 正交（独占线程上阻塞无害） | 中等 |
| **P2** | 真换 pthread | 只为拿 `pthread_join` 的硬保证 | 大 |

P1 的 QoS 一行方案：

```objc
dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
parse.parseQueue = dispatch_queue_create(queueName, attr);
```

队列一旦有显式 QoS，就不再继承调用方（主线程）的 QoS —— Q1 §3① 那个"解析循环跟 UI 抢 CPU"的问题就解决了，
完全不用动线程模型。

### 5. 什么情况下 P2 才值得做

只有当你需要**确定性的"循环已退出"信号**时。目前 `parseStatus` 已经是个顺序正确的替身
（`freeObject` 先 `stopPreParse` 再翻状态位，见 Q1 §3④），够用。

真正会逼出 `pthread_join` 的场景：
- 热切换数据源（stop 旧源 → 立刻 start 新源复用同一个 `TVUExternalSourceParse`）；
- 需要在 `dealloc` 里保证线程已退出（本类目前**根本没有 `dealloc`**）。

在此之前，换 pthread 属于**用大改动换一个当前没被触发的保证**。

### 6. 一句话

> 应该换 pthread 吗 —— 应该，但不是现在，也不是照抄隔壁。
> 先做 P0 的两条（和线程模型无关、改动极小），QoS 用一行 attr 解决；
> 等到真要支持源热切换、需要硬 join 时再换，届时必须一并补 `pthread_attr` 与 `pthread_setname_np`，
> 否则只是把"没控制权的 GCD"换成"没控制权的 pthread"，还丢了线程名。

---

## Q3 — `avformat_seek_file` 这个操作

**位置**：`TVUExternalSourceParse.mm:203-222`，EOF 后本地文件循环播放的重头戏。

```objc
int size = av_read_frame(_formatContext, &packet);
if (size < 0 || packet.size < 0) {
    [[NSNotificationCenter defaultCenter] postNotificationName:kTVUExternalSourceParseFinish object:nil];
    video_frame_index = 0;
    audio_frame_index = 0;
    if (weakSelf.sourceType == TVUExternalSourceLocalFile) {
        //视频播放完成，默认从头开始解析。本地是否循环开关，由kTVUExternalSourceParseFinish通知回调方法完成，若没有打开循环开关，则停止解析
        avformat_seek_file(_formatContext,
                           (int)_videoStream,      // stream_index
                           0,                      // min_ts
                           0,                      // ts
                           _formatContext->streams[_videoStream]->duration,   // max_ts
                           AVSEEK_FLAG_FRAME);     // flags
        avcodec_flush_buffers(_videoCodecContext);
        cycleTimes++;
    }
    continue;
}
```

**总评：这个调用对 mp4/mov 是「碰巧能跑」，不是「设计正确」。** 逐条拆。

### F1 — FFmpeg 自己的头文件写着"别用这个 API"

`3rdparty/ffmpeg/2.6.1/include/libavformat/avformat.h:2426-2428`：

> `@note This is part of the new seek API which is still under construction.`
> `Thus do not use this yet. It may change at any time, do not expect ABI compatibility yet!`

而且本仓 FFmpeg 版本是 **2.6.1（2015 年）**。

### F2 — `AVSEEK_FLAG_FRAME` 与 `max_ts` 单位不一致

同一份头文件 `:2410-2413`：

> If flags contain `AVSEEK_FLAG_FRAME`, then all timestamps are in **frames** in the stream with stream_index
> (this may not be supported by all demuxers).
> Otherwise all timestamps are in units of the stream selected by stream_index。

带了 `AVSEEK_FLAG_FRAME`，那 `min_ts` / `ts` / `max_ts` **三个都应该是帧号**。
代码传的 `max_ts = stream->duration` 是 **time_base 单位的时间戳**。

实践上无害：mp4 的 `duration` 数值通常远大于帧数（例如 time_base = 1/15360），窗口被放得过宽而已。
但这说明作者没有推敲单位 —— 而且 mov/mp4 demuxer 根本没实现 `read_seek2`，
`AVSEEK_FLAG_FRAME` 会退化到通用路径按**时间戳**处理 ts=0，**恰好就是作者想要的效果**。
所以是"侥幸对了"。

想表达"回到开头"，规范写法是：

```objc
av_seek_frame(_formatContext, -1, 0, AVSEEK_FLAG_BACKWARD);
```

### F3 — 返回值不检查，`duration` 异常时会变成紧凑死循环

**可从代码直接确认的部分**：`avformat_seek_file` 的返回值（头文件 `:2424`：`@return >=0 on success, error code otherwise`）
**完全没有被检查**。

「需对 2.6.1 的 `libavformat/utils.c` 核实」该函数开头有 `if (min_ts > ts || max_ts < ts) return -1;`。
若 `stream->duration == AV_NOPTS_VALUE`（即 `INT64_MIN`），`max_ts < ts` 成立 → **立即返回 -1，什么都没做**。

后果链条（这部分只看本仓代码就能推出，与具体 guard 无关 —— 只要 seek 没生效）：

```
seek 失败/无效 → continue → av_read_frame 仍在 EOF → 再 post 一次通知 → 再 seek 失败 → …
```

**紧凑死循环**：在 user-initiated 线程上打满一核，并且**同步派发 NSNotification**（观察者在 parse 线程上跑）。

好消息是现场有现成判据：`:192-196` 已经把 `streams[...]->duration` 读出来算 `max_duration` 并打了日志

```
log4cplus_error("TVUExternalSourceParse", "video_duration:%lf audio:%lf max_duration:%lf", ...)
```

**如果日志里 `video_duration` 是极大负数，就是踩中了这条。**

### F4 — `avcodec_flush_buffers(_videoCodecContext)` 在本地文件路径下是空操作

`_videoCodecContext` 的唯一解码用法是 `avcodec_send_packet(_videoCodecContext, &packet)`（`:245`），
而那行在 **`sourceType == TVUExternalSourceMuticastUrl` 分支里**。

本地文件走的是 `:277` 起的 `else` 分支：packet 经 `av_bitstream_filter_filter` 转 annexb 后
**原样塞进 `queueManager->addDataToDecoder`**，由解码 pthread 走 VideoToolbox 解。
`_videoCodecContext` 在这条路径上只被 `openVideoStream` 打开过，从不 send packet。

**所以循环点 flush 的是一个当前路径下根本没在用的 codec context。**
真正持有跨循环状态的是 `queueManager` 那条解码链 —— 而它没有被 flush。

### F5 — 但"不 flush 解码链"是对的，`cycleTimes` 正是为此存在

```objc
param.pts = packet.pts * av_q2d(time_base) + max_duration * cycleTimes;   // :348
```

每绕一圈把 pts 整体推后一个 `max_duration`（= max(video_duration, audio_duration)，
见 alfredfu 2023-09-12 的注释），于是新一圈的包 pts **恒大于**上一圈残留在队列里的包。

下游 `TVUExternalSourceSortQueueManager` 是**按 pts 插入排序**（`:328` `if (currentNode->pts < insertNode->pts)`），
单调递增就不需要清队列。

**这是一个有意为之且成立的设计** —— seek 之后不 flush 队列是正确的，`avcodec_flush_buffers` 反倒是多余遗留。

> 代价：`max_duration` 取 max 意味着较短的那条流每圈被注入一个固定 gap
> （video 6.00s / audio 6.05s → video 每圈多 50ms 空档）。用同一个 max 保证了**不累积漂移**，
> 但每圈有一次跳变。这是"宁可有 gap 不要重叠"的取舍。

### F6 — 但 `timingInfo` 没跟上 `cycleTimes`，形成两条时间线

```objc
// :335 —— 没有 cycleTimes
presentationTimeStamp = CMTimeMakeWithSeconds(current_timestamp + packet.pts * av_q2d(tb), fps);
// :348 —— 有 cycleTimes
param.pts = packet.pts * av_q2d(tb) + max_duration * cycleTimes;
```

两个都被带进同一个 `param` 塞进队列（`TVUExternalSourceQueueManager.mm:93,94`）。下游分叉：

| 用途 | 取哪个 | 位置 | 循环后是否单调 |
|---|---|---|---|
| **喂 VideoToolbox 解码** | `param.timingInfo` | `TVUExternalSourceVideoDecoder.mm:423,453` | ❌ 每圈回退到起点 |
| **解码后输出/推流** | `node->pts` | `TVUExternalSourceSortQueueManager.mm:224-225` | ✅ 单调 |

**输出侧是对的，所以推流不受影响。** 解码侧的 PTS 回跳理论上会影响 VideoToolbox 的重排缓冲 ——
对 IPPP 无 B 帧素材无感，对含 B 帧素材则值得观察。

判据：`SortQueueManager.mm:210` 的 `"video pts, abnormal: interval:%f, cur:%f, last:%f"`。

### F7 — 停止循环的开关是异步的，关掉后仍会漏出开头若干帧

注释说"若没有打开循环开关，则停止解析"，但观察者第一件事就是跳线程 ——
`TVUExternalSourceView.mm:1119-1131`：

```objc
- (void)parseFinish {
    ...
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([TVUExternalSourceConfig manager].circulationType == TVUExternalSourceCirculationOnce || isAccsoonIndex) {
            ...
            [weakSelf stopParse];      // ← _isStop = YES 在这里才发生
        } else { ... }
    });
}
```

而 parse 线程发完通知**不等任何人**，立刻 seek + `cycleTimes++` + `continue`。实际时序：

```
parse 线程：EOF → post 通知 → 立即 seek 回开头 → 继续解析第二圈 …
主线程 （一个 runloop tick 之后）：circulationType == Once → stopParse → _isStop = YES
parse 线程：下一次 while 检查 → 退出
```

**这段 hop 延迟内，文件开头的若干帧已经推进流里了。** 主线程越忙漏得越多
（本 app 的 `MainViewController.mm` 7000+ 行，UI 回调密集）。

不是"多播一整圈"那么严重，但"关了循环还看到开头一闪"是可复现的。

### 小结

| # | 判定 | 严重度 |
|---|---|---|
| F1 | 用了 FFmpeg 标注"勿用"的 API，且版本停在 2.6.1 | 提示 |
| F2 | `AVSEEK_FLAG_FRAME` 与 `max_ts` 单位不一致，靠 mp4 demuxer 退化路径侥幸生效 | 低（但脆） |
| F3 | 返回值不检查；`duration == AV_NOPTS_VALUE` 时静默失败 → 紧凑死循环 | **高（条件触发）** |
| F4 | `avcodec_flush_buffers` flush 的是本路径未使用的 context | 低（无效代码） |
| F5 | `cycleTimes` 免 flush 设计成立 | ✅ 别动 |
| F6 | `timingInfo` 缺 `cycleTimes` 偏移，解码侧时间线每圈回跳 | 中（素材相关） |
| F7 | 循环开关异步生效，关闭后漏出开头若干帧 | 中（可复现） |

### 附：正确写法参考（仅为说明成因，不作为待办）

```objc
if (weakSelf.sourceType == TVUExternalSourceLocalFile) {
    int64_t dur = _formatContext->streams[_videoStream]->duration;
    int ret = (dur == AV_NOPTS_VALUE)
        ? av_seek_frame(_formatContext, -1, 0, AVSEEK_FLAG_BACKWARD)      // F3 兜底
        : avformat_seek_file(_formatContext, (int)_videoStream, 0, 0, dur, 0);  // F2 去掉 FRAME 标志
    if (ret < 0) {                                                        // F3 检查返回值
        log4cplus_error("TVUExternalSourceParse", "loop seek failed:%d, stop parse", ret);
        break;                                                            // 别死循环
    }
    cycleTimes++;
}
```

`avcodec_flush_buffers` 可直接删（F4）。F6 若要修，把 `:335` 的 `presentationTimeStamp`
也加上 `max_duration * cycleTimes`。F7 属于设计层面，要改得让 parse 线程在 seek 前同步拿到开关值。

### 待核实

- [ ] 2.6.1 的 `libavformat/utils.c` 里 `avformat_seek_file` 是否确有 `if (min_ts > ts || max_ts < ts) return -1;`
      （本仓只有头文件，无 .c 源码）
- [ ] 实机跑一遍循环播放，看 `video_duration` 日志与 `"video pts, abnormal"` 日志是否出现

---

## Q4 — `cycleTimes` 记录循环次数，用于后续 pts 计算

对。补四条这个设计里不那么显眼的东西。

### 1. 它是 ivar，不是 static —— 这点没问题；但它周围五个 `static` 有问题

```objc
// TVUExternalSourceParse.mm:56-57
//记录本地视频循环播放次数
int cycleTimes;
```

在 `@interface ... {}` 的 ivar 块里，**每个实例一份**。`parseArray` 有 2 个实例并发时互不干扰。✅

但同一个 block 里还有五个**函数局部 `static`**，它们是**全进程一份**：

| 行 | 变量 | 影响面 |
|---|---|---|
| `:229` | `static Float64 currentTime = 0.0;` | 多播超时判定（`time_dur >= PARSE_TIME_OUT` 触发 restart） |
| `:310` | `static char *filter_name = "";` | 决定 `av_bitstream_filter_init` 用 h264 还是 hevc |
| `:353` | `static Float64 last_pts = 0;` | 仅日志 |
| `:370` | `static Float64 base_pts = 0;` | **RTSP 视频 pts 基准，进真实计算** |
| `:413` | `static Float64 base_pts = 0;` | **RTSP 音频 pts 基准，进真实计算** |
| `:928` | `static TVUAudioEncoderData encoderData = {0};` | `decodeAudioWithCodetext:` 的编码数据结构 |

PIP/PBP 双源并发时这些会互相踩。最恶心的是 `filter_name`：
A 源 H264 写入 `"h264_mp4toannexb"`，B 源 HEVC 立刻覆盖成 `"hevc_mp4toannexb"`，
A 源随后 `av_bitstream_filter_init(filter_name)` 就拿到了错的 filter → annexb 转换出垃圾。
窗口很窄但真实存在。

**结论：`cycleTimes` 用 ivar 是对的写法，旁边那五个应该照它改。**

### 2. 这套 offset 设计为什么成立（以及它替代了什么）

```objc
param.pts = packet.pts * av_q2d(time_base) + max_duration * cycleTimes;   // :349 video / :407 audio
```

单调性证明：内容跨度是 `[start_time, start_time + duration)`。

```
第 N 圈首包 pts  = start_time + N·max_duration
第 N-1 圈末包 pts ≈ start_time + duration - frame_dur + (N-1)·max_duration
                 = start_time + N·max_duration - frame_dur      (当 duration == max_duration)
```

差值 = `frame_dur > 0` → **严格单调**。对较短的那条流，`max_duration > 自身 duration`，差值更大 → 仍单调，只是多一个 gap。

**它替代的是"seek 后清空下游队列"。** 下游 `TVUExternalSourceSortQueueManager` 按 pts 插入排序（`:328`），
只要 pts 单调递增，新旧两圈的包混在同一个队列里也不会乱序 —— 所以 seek 之后不需要 flush。
这解释了 Q3-F4 里 `avcodec_flush_buffers` 为什么是多余的。

### 3. offset 有两个地方没覆盖到

**(a) `timingInfo`** —— 已在 Q3-F6 记录：`:335` 的 `presentationTimeStamp` 没加 `max_duration * cycleTimes`，
喂 VideoToolbox 的解码侧时间戳每圈回退到起点。

**(b) 音频 `packet.pts > 0` 过滤器每圈吃掉一包**（`:433`）

```objc
if(packet.pts > 0){
    weakSelf.queueManager->addDataToDecoder(&param, ...);
}else{
    log4cplus_error("TVUExternalSourceParse", "drop audio abnoraml frame pts :%lld", packet.pts);
}
```

判的是**原始 `packet.pts`**，不是加了 offset 的 `param.pts`。每次 seek 回 0 之后，
第一包音频的 pts 就是 0（或 AAC priming 导致的负值）→ **`> 0` 不成立 → 丢弃**。

- AAC 48kHz 一包 1024 samples = **21.3ms**，每圈固定丢至少一包；
- **视频路径没有任何 pts 过滤**，pts==0 的那帧照常入队。

所以每个循环接缝处，音频比视频多缺一包。这个洞叠加在 §2 提到的 `max_duration` gap 之上。

作者自己的注释（`:426-434`，alfredfu 2023-09-21）已经写了"优化了分包算法后，此条件可以去掉"。
**如果要留，至少应该是 `>= 0`** —— 原意是滤掉 pts<0，代码连 pts==0 一起滤了。

### 4. `cycleTimes` 会被 I/O 错误意外递增

```objc
int size = av_read_frame(_formatContext, &packet);
if (size < 0 || packet.size < 0) {     // ← 不区分 AVERROR_EOF 和真实错误
    ...
    cycleTimes++;
}
```

`size < 0` 把 **所有** 错误都当成"播完了"：`AVERROR_EOF`、`AVERROR(EIO)`、`AVERROR(EAGAIN)` 一视同仁。

本 app 的源来自相册（`TVUExternalSourceErrorSourceIsInRecentlyDeletedFolder` 这个错误码就是证据），
iCloud 回源、文件被移动等场景下 `av_read_frame` 出瞬时错误是可能的。一旦发生：

1. 视频跳回开头重播；
2. `cycleTimes++` → 之后所有包的 pts **整体抬高一个 `max_duration`**（6s 素材就是 6 秒的跳变）。

单调性没破（offset 是往前推的），但下游会看到一个 `max_duration` 量级的时间戳断层。

正确写法是只在真 EOF 时循环：

```objc
if (size == AVERROR_EOF) { /* 循环 */ }
else if (size < 0)       { /* 记错误并决定重试或停止 */ }
```

### 5. 精度/溢出不用担心

- `int cycleTimes`：6s 素材循环到 `INT_MAX` 需要约 408 年。
- `Float64 max_duration * cycleTimes`：连播 1 小时值约 3600，Float64 在该量级的分辨率约 1e-13 s。

两者都远不构成问题。**唯一值得留意的量化点在下游**：
`SortQueueManager.mm:224` 的 `CMTimeMakeWithSeconds(externalSourceBaseTime + node->pts, node->fps)`
用 `fps` 当 timescale，对非整数帧率（29.97 被 `covertFPSToExternalFPS` 归成 30）会引入最大 1/(2·fps) 的量化误差。
「待核实」是否有实际影响，取决于素材帧率。

### 待核实

- [ ] 双源（PIP/PBP）并发时，`:310 filter_name` / `:370,413 base_pts` 的污染是否有线上表现
- [ ] `CMTimeMakeWithSeconds(..., fps)` 对 29.97 素材的量化误差是否可观测

---

## Q5 — `TVUExternalSourceQueueManager` 的解码链

### 0. 链路总览

```
parse 线程 (Q1 的 dispatch_async block)
   │ addDataToDecoder(param, sourceQueue[Video/Audio])
   │   ├─ deQueue(freeQueue) 取一个空节点
   │   ├─ malloc + memcpy 拷贝 data / extraData
   │   └─ enQueue(workQueue)
   ▼
sourceQueue[Video]  ┐                  sourceQueue[Audio]  ┐
 free/work 双队列    │                   free/work 双队列    │
   ▼                │                     ▼                │
videoDecodeThread   │ pthread            audioDecodeThread │ pthread
   └─ decodeVideo() │                     └─ decodeAudio() │
        ▼           │                          ▼           │
  [videoDecoder decode:]                 [audioDecoder decode:]
        ▼                                     ▼
  sortQueueManager (自己还有一条 pthread)   AudioMixerQueueManager
        ▼                                     ▼
  TVUAVStreamManager                     TVUAudioEncoderManager
```

**节点池深度**（`TVUExternalSourceQueue.mm:10-11`、`SortQueueManager.h:12`）：

| 池 | 深度 | 时间当量 |
|---|---|---|
| video free/work | **15** | 0.5s @30fps |
| audio free/work | **120** | 2.5s @AAC 1024/48k |
| sort queue | **4** | 0.13s @30fps |

**背压**分两层：

- parse 侧只对**视频**背压 —— `TVUExternalSourceParse.mm:384` `while (freeQueueLength(video) <= 1 || sortQueue->length() >= 4) usleep(5ms)`；
- 音频没有 parse 侧背压，完全靠 `addDataToDecoder` 里的 `pthread_cond_wait`。因为是同一条 parse 线程，
  视频背压事实上也节流了音频 —— **两者是耦合的**，这一点决定了下面 D1 的触发条件。

---

### D1 — 丢失唤醒：`audio_wait` 在锁外读（**最高**）

生产者（parse 线程，`QueueManager.mm:157-170`）：

```cpp
TVUExternalSourceDecoderQueueNode *node = queue->deQueue(queue->freeQueue);   // ← 锁外
if (node == NULL) {
    ...
    pthread_mutex_lock(&audio_mutex);
    while (node == NULL) {
        audio_wait = true;                       // ← 置位发生在锁内，但检查在锁外发生过了
        pthread_cond_wait(&audio_cond, &audio_mutex);
        node = queue->deQueue(queue->freeQueue);
        audio_wait = false;
    }
    pthread_mutex_unlock(&audio_mutex);
}
```

消费者（audio 解码线程，`QueueManager.mm:259-264`）：

```cpp
sourceQueue[Audio]->resetWorkQueueNode(node);      // 归还节点到 freeQueue
if (node != NULL && audio_wait) {                  // ← audio_wait 在锁外读
    pthread_mutex_lock(&audio_mutex);
    audio_wait = false;
    pthread_cond_broadcast(&audio_cond);
    pthread_mutex_unlock(&audio_mutex);
}
```

交错序列：

```
生产者: deQueue(freeQueue) → NULL                       (还没进 audio_mutex)
                                消费者: resetWorkQueueNode → freeQueue 现在有节点了
                                消费者: if (audio_wait) → false → 不广播
生产者: lock(audio_mutex); audio_wait = true; cond_wait(...)   ← 永远等不到广播
```

**"检查条件"和"进入等待"之间没有被同一把锁保护** —— 教科书级的 lost wakeup。
`resetWorkQueueNode`（`TVUExternalSourceQueue.mm:134-166`）本身也**不广播** `audio_cond`，
所以归还节点这个动作完全不会唤醒等待者。

**触发条件**：audio freeQueue 瞬时归零。稳态下不易发生（音频池 2.5s vs 视频池 0.5s，且被视频背压耦合节流），
但只要 `decodeAudio` 因为墙钟门控（见 D3 说明）多压几拍就可能撞上。属于**低频、后果致命**。

**后果**：parse 线程永久停在 `pthread_cond_wait` → 永不回到 `while (!_isStop)` → `freeObject` 不执行
→ `parseStatus` 永远停在 `Work` → 所有调用方的 `if (parse.parseStatus != Free) continue` 永远跳过它
→ **该外部源槽位永久不可用，直到杀进程**。叠加 Q1-③（block 强持有 self），对象和线程一起泄漏。

---

### D2 — `stopAddDataToDecoder` 不广播 `audio_cond`（**最高**）

```cpp
void TVUExternalSourceQueueManager::stopAddDataToDecoder()
{
    pthread_mutex_lock(&threadArray[Video].mutex);
    pthread_mutex_lock(&threadArray[Audio].mutex);
    threadToSuspend = true;
    pthread_mutex_unlock(&threadArray[Audio].mutex);
    pthread_mutex_unlock(&threadArray[Video].mutex);
    ...
    resetAllWorkQueueNode(sourceQueue[Audio]);      // 节点全还回 freeQueue
    ...                                              // 但没有 pthread_cond_broadcast(&audio_cond)
}
```

`audio_cond` 的**唯一**广播点是 `decodeAudio()` 末尾。而 `threadToSuspend = true` 之后，
audio 解码线程下一轮就进 `pthread_cond_wait` 不再调 `decodeAudio()` → **永远不会再广播**。

所以即使 D1 的竞态没撞上，只要生产者正在 `audio_cond` 上等待时发生 stop，一样永久卡死。
**这是 D1 的确定性版本 —— 不需要竞态，必然发生。**

还有一条独立的确定性路径：`decodeAudio()` 开头

```cpp
if (videoDecoder.sortQueueManager->externalSourceBaseTime == 0.0) { usleep(10*1000); return; }
```

视频还没产出基准时间时，音频解码**一个节点都不消费**。若此刻音频把 120 个节点填满，
生产者进 `cond_wait`，而 `externalSourceBaseTime` 又依赖视频 —— 视频若因任何原因不产出，就是死锁。

**正确写法参考**（仅说明成因）：

```cpp
// addDataToDecoder：等待条件加上退出条件
while (node == NULL && !threadToSuspend) {
    audio_wait = true;
    pthread_cond_wait(&audio_cond, &audio_mutex);
    node = queue->deQueue(queue->freeQueue);
    audio_wait = false;
}
pthread_mutex_unlock(&audio_mutex);
if (node == NULL) return;        // ← 必须加，否则下面 node->param.data 空指针

// stopAddDataToDecoder：置位后广播
pthread_mutex_lock(&audio_mutex);
pthread_cond_broadcast(&audio_cond);
pthread_mutex_unlock(&audio_mutex);
```

顺带把消费者那侧的 `audio_wait` 判断挪进锁内。

---

### D3 — `decodeVideo` 持锁忙等，`stopAddDataToDecoder` 因此阻塞主线程（**高**）

```cpp
void videoDecodeThread() {
    while (!threadToEnd) {
        pthread_mutex_lock(&threadArray[Video].mutex);
        if (threadToSuspend) { pthread_cond_wait(...); }
        decodeVideo();                                  // ← 持锁调用
        pthread_mutex_unlock(&threadArray[Video].mutex);
    }
}

void decodeVideo() {
    while (videoDecoder.sortQueueManager->length() >= kTVUExternalSourceSortQueueNodeSize) {
        usleep(TVU_EXTERNAL_SOURCES_GENENAL_SLEEP_INTERVAL*1000);   // 5ms，持着 Video.mutex
    }
    ...
}
```

而 `stopAddDataToDecoder()` 第一件事就是 `pthread_mutex_lock(&threadArray[Video].mutex)`。

**调用链**：`TVUExternalSourceView::parseFinish` → `dispatch_async(main)` → `[self stopParse]`
（`TVUExternalSourceView.mm:637,656-658`）→ `[parse stopParse]` → `queueManager->stopAddDataToDecoder()`。

**即 stop 跑在主线程上，并且会阻塞到 sort queue 排空为止。**
正常约 4 帧（30fps ≈ 133ms）；下游 `TVUAVStreamManager` 若卡住则**无上限** → 主线程卡死 → watchdog。

成因说明：忙等条件里没有 `threadToSuspend`，所以 stop 无法打断它：

```cpp
while (videoDecoder.sortQueueManager->length() >= kTVUExternalSourceSortQueueNodeSize && !threadToSuspend) {
    usleep(...);
}
```

---

### D4 — `pthread_cond_wait` 用 `if` 而不是 `while`（虚假唤醒）

```cpp
if (threadToSuspend) {
    pthread_cond_wait(&threadArray[i].cond, &threadArray[i].mutex);
}
decodeVideo();
```

`pthread_cond_wait` 允许虚假唤醒，必须 `while (threadToSuspend)`。用 `if` 时一次虚假唤醒就会
在仍处于 suspend 状态下执行一轮 `decodeVideo()` / `decodeAudio()`，消费掉本该留在队列里的节点。
视频、音频两条线程都是这个写法。

---

### D5 — `decodeVideo` 空队列时不 sleep，`decodeAudio` 会（不对称）

```cpp
// decodeVideo
TVUExternalSourceDecoderQueueNode *node = ...deQueue(workQueue);
if (node == NULL) {
    log4cplus_debug(...);
    return;                    // ← 没有 usleep
}
```

回到 `videoDecodeThread` 立刻重新加锁再调 `decodeVideo()` → **紧凑空转**。
对比 `decodeAudio()`：三条早退路径全部 `usleep(10*1000)` 之后才 return。

**不是持续 100% CPU** —— 稳态下 parse 侧背压把 video work queue 维持在接近满
（`freeQueueLength <= 1` 才放行，即 work ≥ 14），所以空队列窗口很短。
空转主要出现在：启动瞬间（`startThread()` 在 `dispatch_async` 之前调用，队列还空）、
循环接缝、以及下游突然放行后队列被抽干的一瞬。

给 `decodeVideo` 的空路径补一个 `usleep` 即可，与 `decodeAudio` 对齐。

---

### D6 — `threadToSuspend` / `threadToEnd` 无锁无原子

`addDataToDecoder` 开头 `if (threadToSuspend) return;` 是**锁外读**，而 `stopAddDataToDecoder`
是在两把 mutex 保护下写。两条 `while (!threadToEnd)` 同样锁外读。都是普通 `bool`，无 `atomic`、无屏障。

具体危害：

```
parse 线程: 读 threadToSuspend == false（通过）
                          主线程: threadToSuspend = true; resetAllWorkQueueNode(...) 全部清空
parse 线程: enQueue(workQueue, node)      ← 一个陈旧节点在"清空之后"入队
```

下次 `startThread()` 后这个节点会被当成新数据解码 —— 就是"stop 之后画面闪一下旧帧"的成因之一。
改成 `std::atomic<bool>` 即可。

---

### D7~D9 — 次要项

| # | 位置 | 问题 |
|---|---|---|
| D7 | `TVUExternalSourceQueue.mm:89` | `static long nodeIndex = 0;` 是函数局部 static，**4 个队列实例共享**（2 个 parse × video/audio）。`node->index` 目前只写不读，暂无害 |
| D8 | `TVUExternalSourceQueue.mm:76-84` | freeQueue 走 LIFO 头插，`rear` 只在第一个节点时赋值，之后**永远指向最早那个节点**。deQueue 只用 `front`，所以当前无害，但语义已经是垃圾值 |
| D9 | `QueueManager.mm:174-176` | 音频 `param->extraData` 恒为 NULL、`extraDataSize` 恒为 0 → `malloc(0)` + `memcpy(dst, NULL, 0)`。标准里传 NULL 给 memcpy 是 UB（即使 n==0），实践无害 |

另：`deQueue` 在 `pthread_mutex_unlock` **之后**才读 `queue->size` 打日志（`Queue.mm:130`），
是个锁外读，仅影响日志数值。

---

### 小结（严重度排序，仅记录不修复）

| # | 判定 | 后果 | 严重度 |
|---|---|---|---|
| **D1** | `audio_wait` 锁外读 → lost wakeup | parse 线程永久卡死，源槽位不可用 | **最高** |
| **D2** | stop 不广播 `audio_cond` | 同上，且是确定性触发 | **最高** |
| **D3** | `decodeVideo` 持锁忙等 | stop 阻塞主线程，最坏无上限 | **高** |
| D4 | `if` 代替 `while` 包裹 cond_wait | 虚假唤醒下多消费一个节点 | 中 |
| D5 | `decodeVideo` 空路径不 sleep | 短窗口空转烧 CPU | 中 |
| D6 | 两个 bool 无锁无原子 | stop 后混入陈旧帧 | 中 |
| D7-D9 | static 共享 / rear 语义 / memcpy NULL | 当前无害 | 低 |

**D1 + D2 是同一段代码上的同一个问题**，它们是这条链上唯一会导致"功能永久失效"的缺陷。
D3 是唯一会打到主线程的。

### 待核实

- [ ] `sortQueueManager` 的出队线程是否可能长时间不排空（决定 D3 的上界是 133ms 还是无上限）
- [ ] 线上是否有"切走外部源后该槽位再也选不上"的反馈 —— 那就是 D1/D2 的现场表现

---

## Q6 — 手绘逻辑图（`aw.excalidraw.json`）与源码的差异清单

**图的现状**（草稿，72 元素：30 矩形 / 25 文字 / 15 箭头 / 2 波浪线）：

```
上带  ▢▢▢▢▢▢▢ ──▶ 〰videoDecodeThread ──▶ decode ─异步─▶ didDecompress ──▶ addData ──▶ enQueue Sort Nodes ──▶ ▢▢▢▢▢▢▢
      DecoderVideo      "5ms 轮询"                                                                          SortQueue
中带  [Local Video File] ──▶ [FFMpeg Parse] ═V/A═▶ [addDataToDecoder] ═V/A═▶ 上带/下带
      TVUExternalSourceQueueManager ⇢ 引用 ⇢ TVUExternalSourceParse
      TVUExternalSourceQueueManager ⇢ videoDecodeThread / audioDecodeThread（归属虚线）
下带  ▢▢▢▢▢▢▢ ──▶ 〰audioDecodeThread    ← 断在这里
      DecoderAudio
```

**已核对正确的部分**：所有标识符都与源码一致 ——
`didDecompress`（`TVUExternalSourceVideoDecoder.mm:84`，VideoToolbox 回调）、
`addData`（`TVUExternalSourceSortQueueManager.mm:98`）、`addDataToDecoder`、
`videoDecodeThread` / `audioDecodeThread`（`QueueManager.mm:195,207`）。
`decode ⇢异步⇢ didDecompress` 标"异步"准确（`VTDecompressionSessionDecodeFrame` 的回调不在调用线程）。
两条 pthread 归属 `TVUExternalSourceQueueManager` 也对（构造函数里 `pthread_create` ×2）。

### 差异清单（按补上之后的信息增量排序）

| # | 缺口 | 为什么重要 | 源码依据 |
|---|---|---|---|
| **G1** | 队列画成单排 7 格、数据左→右穿过。实际是 **freeQueue + workQueue 双链**，节点在两者间**往回循环** | 缺的正是回还路径 `resetWorkQueueNode → enQueue(freeQueue)`，而 D1/D2 死锁就发生在 freeQueue 取空那一刻。当前画法读起来像传送带，把死锁点隐掉了 | `TVUExternalSourceQueue.mm:134-166` |
| **G2** | V / A 两条支路画得完全一样 | **A 支路会阻塞**（`pthread_cond_wait(&audio_cond)`），V 支路只是 `log + return`。这是整张图上唯一会永久卡死的点 | `QueueManager.mm:157-170` |
| **G3** | 下带断在 `audioDecodeThread` | 后面还有 `[audioDecoder decode:]` → `AudioMixerQueueManager::addDataToAudioMixer` → `TVUAudioEncoderManager`。画布右下有对称空间，补完后能直观看出两带出口不同（视频进 `TVUAVStreamManager`，音频进音频编码器） | `QueueManager.mm:256`、`TVUExternalSourceAudioMixerQueueManager` |
| **G4** | 没有跨带依赖线 | `decodeAudio()` 开头 `if (externalSourceBaseTime == 0.0) return;`，该基准时间由**上带的 sort queue** 产生 → **下带的消费能力取决于上带是否已出帧**。这条虚线是 D2 死锁的成因 | `QueueManager.mm:234-237` |
| **G5** | 三种并发原语框型相同 | `FFMpeg Parse` 是 GCD 上永不返回的 block（Q1/Q2）；两条 decode thread 是 pthread；`didDecompress` 跑在 VideoToolbox 自己的线程。图上都是一样的圆角框 | Q1、Q2 |
| **G6** | `5ms 轮询` 只标了一处 | 源码有两处背压：`decodeVideo()` 里的（图上这个，卡 decode 线程）＋ parse 侧 `:384` 的（卡 parse 线程）。后者按布局应标在 `addDataToDecoder` 之前 | `TVUExternalSourceParse.mm:384`、`QueueManager.mm:221` |
| G7 | 池深度示意为 7 格 | 实际 video **15** / audio **120** / sortQueue **4**。三者比例（0.5s / 2.5s / 0.13s）本身是有信息量的 | `TVUExternalSourceQueue.mm:10-11`、`SortQueueManager.h:12` |
| G8 | `TVUExternalSourceQueueManager` 出现两次 | 同一实例（一次表示被 Parse 引用，一次表示两条线程的宿主），易被读成两个对象 | — |

> 图是草稿，以上仅作为后续细化时的核对清单，不作为待办。

**补记（图的迁移）**：`yuque_diagram.jpg` 上的完整版已迁移进 `aw.excalidraw.json`
（182 元素：50 矩形 / 1 菱形 / 45 箭头 / 86 文本；两个虚线容器 `sortThread` 与 `aacEncoder::doencode`）。
原草稿备份在 `aw-draft-backup.excalidraw.json`。

迁移后的图已覆盖 Q6 里的 **G3**（音频带补完到 `aacEncoder::doencode`）和 **G5** 的一部分
（`VideoToolbox` / 两条 decode thread 用文字标注区分）。**仍未覆盖**：
G1（free/work 双队列与回还路径 —— 图上队列仍是单排 4 格）、G2（A 支路的阻塞语义）、
G4（`externalSourceBaseTime` 的跨带依赖）、G7（池深度 15/120/4）。

---

## Q7 — 从 `externalStartCaptureSession` 往回追：外部源 → 本地相机的切回路径

### 0. 完整调用链与线程

```
TVUExternalSourceView::parseFinish                      (TVUExternalSourceView.mm:1119)
  └─ dispatch_async(main) ───────────────────────────── 主线程
       └─ [self stopParse]                              (:637)
            ├─ for parse in parseArray: [parse stopParse]   ← Q5-D3 在此阻塞
            ├─ [[TVUAudioEncoderManager manager] updateExternalSourceIndex:kTVULocalCameraExternalSourceIndex]
            ├─ TVUAVStreamManager::getInstance()->external_source_index = kTVULocalCameraVideoIndex
            ├─ [self closePIP]
            └─ [self externalStartCaptureSession]           (:533)
                 └─ dispatch_async(TVUMainQueue)            ← TVUConst.h:37 = dispatch_get_main_queue()
                      └─ [[TVUCameraManager manager] startCaptureSession]   (TVUCameraManager.mm:200)
```

`externalStartCaptureSession` 的三重门控：

```objc
extern kTVUAPPActiveState g_app_active_state;      // :531，在方法上方就地声明
extern bool   g_isMainView;                        // :532
-(void)externalStartCaptureSession{
    if (g_app_active_state != kTVUAPPActiveState_Background && g_isMainView
        && ![[TVUCameraManager manager]isCaptureSessionRunning]) {
        dispatch_async(TVUMainQueue, ^{ [[TVUCameraManager manager] startCaptureSession]; });
    }
}
```

> 这里"先同步查 `isCaptureSessionRunning`、再异步 start"的 check-then-act **不构成问题** ——
> `startCaptureSession` 内部还有一道同样的幂等守卫（`TVUCameraManager.mm:210`），重复入队是安全的。

### C1 — `stopCaptureSession` 在双摄模式下是静默空操作（**最高**）

```objc
- (void)stopCaptureSession                                   // TVUCameraManager.mm:447
{
    if ([TVUMutiCameraManager manager].isStartMut_Cam) {
        [[TVUMutiCameraManager manager]startMuCaptureSession];   // ← start，不是 stop
        return;
    }
    if (![self isCaptureSessionRunning]) { return; }
    [self.captureSession stopRunning];
}
```

而 `startMuCaptureSession` 开头就是 `if ([self isCaptureSessionRunning]) return;`
（`TVUMutiCameraManager.mm:199`）。`isStartMut_Cam == YES` ⇒ 多摄 session 正在跑 ⇒ 守卫命中 ⇒
**直接返回，什么都没做**。

**正确的方法就在同一文件 `TVUMutiCameraManager.mm:287`**：

```objc
- (void)stopMuCaptureSession {
    if (![self isCaptureSessionRunning]) { return; }
    if (@available(iOS 13.0, *)) {
        self.isStartMut_Cam = NO;
        [self.mu_captureSession stopRunning];
        ...
```

**14 个调用点里只有 1 个绕过了这个坑** —— `TVUAnywhere.mm:1021-1026`（后台切换）在调用侧自己判：

```objc
if ([TVUMutiCameraManager manager].isStartMut_Cam) {
    [[TVUMutiCameraManager manager] stopMuCaptureSession];
} else {
    [[TVUCameraManager manager] stopCaptureSession];
}
```

即：问题被知晓过，但修在了调用侧而非方法内。其余 13 处全部踩坑，含
`TVUExternalSourceView.mm:548`（本条路径）、`TVUPartylineSDKJoinViewController.mm:1031`、
`TVUAnywhere.mm:537/949/1025/1135/1622/4892/4901/4913`、
`TVUAnywhere+PartylineSDK.mm:60/65`、`RTMPIngestController.mm:184`。

**后果**：双摄开启时切到外部源 / DJI / Partyline，双摄 session 不停 —— 继续采集、继续往
`TVUCameraQueue` 与 `TVUMutiCameraQueue` 写帧。画面上大概看不出来（合流层有源索引门控，见 05 §七），
但 CPU / 电量 / 热节流全部白付。

> `manualForcedStopCapture`（`:464`）直接 `[self.captureSession stopRunning]`，绕过守卫，
> 但它停的是**单摄** session，同样停不了多摄。

### C2 — start 异步、stop 同步，时序可倒置（**中**）

`externalStartCaptureSession` 把 start 推到下一个 runloop turn；`externalStopCaptureSession` 是同步调用。

```
① 排入 startCaptureSession（下一轮执行）
② 同步 stopCaptureSession → session 确实停了
③ ①排的 start 执行 → isCaptureSessionRunning == NO → 真的起来了
```

`startCaptureSession` 的幂等守卫挡得住"重复 start"，挡不住这个倒置。
两个方法一个异步一个同步，是这条时序的根因。

### C3 — 主线程被连续阻塞两次，且 format 设在 `startRunning` 之后（**中**）

`startCaptureSession` 全程在主线程（由 `dispatch_async(TVUMainQueue)` 送入）。内部两处阻塞：

```objc
[self.captureSession startRunning];                    // :290
[self rotateToInterfaceOrientation:self.interfaceOrientation];
BOOL isEnableHDR = TVUSettingStorage.storage.enableCameraHDR;
[self setVideoHDREnabled:isEnableHDR];                 // :295 → updateActiveFormat:andFrameRate:
```

1. `startRunning` —— Apple 明确说是耗时调用、不应在主队列调。代码里模拟器分支的注释自己承认了：
   *"主线程会卡在 `mach_msg2_trap`"*（`:284-286`）。
2. `setVideoHDREnabled:` → `updateActiveFormat:` —— `activeFormat` 赋值触发 session 重配置。

**顺序问题**：先 `startRunning` 再改 format ⇒ session 以旧格式起来、随即被重配 ⇒
切回相机时的黑帧/闪屏由此而来。format 在 `startRunning` 之前设好即可避免。

**与 Q5-D3 叠加**：`[parse stopParse]` 先阻塞主线程（正常 ~133ms，下游卡住无上限），
阻塞结束后才排 start，下一轮再阻塞一次。
**用户感知的切回耗时 = D3 + startRunning + setActiveFormat，三段串行，全在主线程。**

### C4~C5 — 次要项

| # | 位置 | 问题 |
|---|---|---|
| C4 | `TVUCameraManager.mm:266-269` | QR 扫码模式（`tvuGetShowScanQRCodeInPLModeOnly`）下中途 `return`：曝光/对焦/白平衡/zoom 都已改、`startCameraMultitasking` 也调了，但不 `startRunning`。半配置状态 |
| C5 | `TVUExternalSourceView.mm:645-649` | `stopParse` 早退分支只起相机就 return，跳过 `updateExternalSourceIndex:` 与 `external_source_index` 复位。正常无害（`currentParseIndex == None` 即无活跃 parse），但若撞上 Q5-D1/D2 死锁（`parseStatus` 卡 `Work` 而 `currentParseIndex` 已被别处清零），源索引就回不到本地相机 |

> 已核实**不是**问题：`_device` 的懒加载缓存（`:1838`）会在翻转摄像头时刷新
> （`:694 self.device = new_device`、`:1473`），不存在"USB 设备插入后永远拿不到"的问题。

### 待核实

- [ ] C5 需要列出 `currentParseIndex` 的全部置位点，确认能否与 `parseStatus == Work` 同时成立
- [ ] C1 的实际影响面：双摄 + 外部源是否是有效组合（若 UI 上互斥则退化为纯浪费）

---

## Q8 — 采集回调链：`captureOutput:didOutputSampleBuffer:` 到入队

> 补 05 文档 §三那 25 行。**注意 05 里的行号已过期**（写的是 `TVUAnywhere.mm:4205-4229` / `4413-4438`，
> 现为 `:4375` / `:4417` / `:4436`）。

### 0. 三条编译期出口

```
AVCaptureVideoDataOutput
  └─ TVUCameraManager::captureOutput:didOutputSampleBuffer:      (TVUCameraManager.mm:1915)
       ├─ #if _TVUSDKPartyline
       │    └─ [[TVUPartylineManager manager] tvuConsumePixelBuffer:...]   ← ① delegate 根本不调
       └─ #else
            └─ [self.delegate tvuCaptureOutput:didOutputSampleBuffer:]
                 └─ TVUAnywhere::tvuCaptureOutput:...             (TVUAnywhere.mm:4375)
                      ├─ #if _TVUSDKANYWHERELITE && !_TVUIRLSDK
                      │    └─ [[TVUVideoEncoderManager manager] encode:] ← ② 直送编码，绕过合流层
                      └─ #else
                           └─ sendToEncodeWithSampleBuffer:       (:4417)  ← ③
                                ├─ isOnlyBuildInCameraStream → sendToEncoderWithSamplebuffer(…, TVUAVStreamCamera, TVUAVStreamCamera)
                                └─ 否则 → AddBufferToWorkQueue(…, m_total_queue[TVUCameraQueue])
```

出口 ② 的注释解释了为什么要在那里单独记一次 `setEncVideoPTS` ——
它不走 `sendToEncoderWithSamplebuffer` 那个漏斗，否则该 build 就没有编码前的视频时间戳了。

### E1 — 音视频"互等就绪"握手：两个裸全局 bool（**最高**）

`TVUAnywhere.mm:127-128`：

```objc
bool audioIsReady = false;
bool videoIsReady = false;
```

四个回调各自持有**逐字相同**的闸门，判断条件一致、置位的是自己那一半：

| 侧 | 位置 | 副作用 |
|---|---|---|
| 视频（单摄） | `TVUAnywhere.mm:4377-4381` | `videoIsReady = YES` + 丢帧 |
| 视频（双摄） | `TVUAnywhere.mm:4613-4617` | 同上，逐字复制 |
| 音频（AudioUnit） | `TVURecorder.mm:430-437` | `audioIsReady = YES` + 丢帧 + **清 WebRTC / PartyLine 两个混音队列** |
| 音频（另一回调） | `TVURecorder.mm:743-751` | `audioIsReady = YES` |

```objc
if (audioIsReady == false || videoIsReady == false) {
    log4cplus_error("didOutputSampleBuffer", "audio is not ready");
    videoIsReady = YES;      // 自己宣布 ready
    return;                  // 这一帧丢掉
}
```

语义是"双方都至少收到过一次回调才放行"。每一侧靠**收到第一帧**来宣布自己 ready。

#### 关键不对称：只有音频侧有兜底

`TVURecorder.mm:425-431`：

```objc
#if TARGET_OS_SIMULATOR
    // 模拟器跳过了相机 startRunning，videoIsReady 永不置位，不能拿它当放行条件，否则音频被永久丢弃。
    if (audioIsReady == false) {
#else
    if (audioIsReady == false || videoIsReady == false) {
#endif
```

**这条注释就是这个握手会死锁的直接证据** —— 有人踩过"音频等视频、视频永不来"，
于是在音频侧开了个模拟器豁口。**视频侧没有任何对应豁口。**

所以反方向仍然敞着：`audioIsReady` 永不置位 ⇒ **视频永久丢帧**。
音频回调不来的可能原因：麦克风权限被拒、`AVAudioSession` 配置失败、音频设备热插拔失败。

音频侧还有一个无条件后门（`TVUAudioCaptureManager.mm:114-117`）：

```objc
- (void)startAudioCapture {
    if ([[TVUTalkShowAVAudioPlayerManager sharedInstance]isPlaying] && self.isUseSDKInTVUTalkShow) {
        audioIsReady = YES;   // 音频采集根本不启动，直接宣布 ready
        return;
    }
```

#### 兜底探测也只有单向

`checkTheVideoSourceIsComing`（`TVUAnywhere.mm:939`，由 `:935` 的 `performSelector:afterDelay:2.0` 触发）：

```objc
-(void)checkTheVideoSourceIsComing{
    if (videoIsReady) { return; }
    ...
```

只探测"视频没来"，**没有对称的 `checkTheAudioSourceIsComing`**。

#### 其它三点

- **每次 stop / 进后台都重置**：`:993`、`:998`、`:1011`、`:2226` 四处 `videoIsReady = audioIsReady = false`。
  ⇒ 每次恢复至少丢一帧视频 + 一帧音频，而那帧音频还会连带清空两个混音队列。
- **非原子跨线程**：视频侧写在 capture 队列、音频侧写在 AudioUnit 回调线程，都是裸 `bool`，无屏障。同 Q5-D6 一类。
- **日志文本与实际条件不符**：视频侧打 `"audio is not ready"`、音频侧打 `"video is not ready"`，
  但两边条件都是 `audioIsReady == false || videoIsReady == false`，**看日志无法判断到底哪边没好**。排查时会误导。

### E2 — `sendToEncodeWithSampleBuffer:` 两路不对称（**中**）

```objc
- (void)sendToEncodeWithSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    TVUAVStreamManager::getInstance()->checkUseSystemPreview();          // 每帧调用
    if ([self isOnlyBuildInCameraStream]) {
        responseCaputureMethodWithPts / calculatorCaptureFPS
        [[TVUObjTrackingManager manager] acceptSamplebuffer:sampleBuffer];
        snapImageWithBufferRef(sampleBuffer);                            // ← 仅纯相机路
        sendToEncoderWithSamplebuffer(sampleBuffer, TVUAVStreamCamera, TVUAVStreamCamera);
    } else {
        currentOrientation = [[TVUMutiCameraManager manager] getCurrentOrientation];  // ← 仅合流路
        responseCaputureMethodWithPts / calculatorCaptureFPS
        [[TVUObjTrackingManager manager] acceptSamplebuffer:sampleBuffer];
        [[TVUExternalSourcePictureManager manager] tvuLocalPictreRecieveSampleBuffer:sampleBuffer];  // ← 仅合流路
        AddBufferToWorkQueue(sampleBuffer, m_total_queue[TVUCameraQueue]);
    }
}
```

| 动作 | 纯相机 | 合流 | 备注 |
|---|---|---|---|
| `snapImageWithBufferRef`（抓图） | ✅ | ❌ | 多源/PIP/PBP 下抓图从这条路拿不到帧 —— **待核实合流层是否另有入口** |
| `currentOrientation` 更新 | ❌ | ✅ | 纯相机模式下 `TVUAVStreamManager::currentOrientation` 不刷新，若编码/推流读它会用陈旧值 |
| `tvuLocalPictreRecieveSampleBuffer` | ❌ | ✅ | 合理，图片源必然多源 |

`checkUseSystemPreview()` 每帧一次，需确认是否廉价。

### E3 — `didDropSampleBuffer` 只打日志（**中**）

```objc
- (void)tvuCaptureOutput:...didDropSampleBuffer:... {
    log4cplus_error("TVUCameraManagerDelegate", "drop sample buffer");
}
```

AVFoundation 丢帧的唯一原因是 **delegate 回调太慢**（`alwaysDiscardsLateVideoFrames`）。
也就是说这是"采集流水线过载"的唯一信号，而它被丢掉了 —— 没有计数、没有降帧、
也无法和编码侧的帧数对账。

### 小结

| # | 判定 | 后果 | 严重度 |
|---|---|---|---|
| **E1** | 音视频互等握手用两个裸全局 bool，只有音频侧有豁口 | `audioIsReady` 不置位 ⇒ 视频永久丢帧；日志无法区分哪边没好 | **最高** |
| E2 | 纯相机 / 合流两路动作不对称 | 抓图与 orientation 各缺一路 | 中 |
| E3 | `didDropSampleBuffer` 只打日志 | 过载信号被丢弃 | 中 |

### 待核实

- [ ] 合流路（PIP/PBP/多源）是否另有抓图入口，否则 E2 是功能缺失
- [ ] `TVUAVStreamManager::currentOrientation` 的读取方，确认纯相机路不更新是否有实际影响
- [ ] `checkUseSystemPreview()` 的开销（每帧调用）

---

## Q9 — 为什么相机流没合到 `Local Video File` 那张大逻辑图上

**先承认：能合、也该合。**我用追加式写入（负 y 区另开一带）是为了不冲掉手工编辑，是工具层面的取舍，
不是设计判断。

**但合并前撞到一个硬前提：图上标的汇聚点在 dev1 上不存在。**

### F1 — `sortThread` 的真实出口是 `AddBufferToWorkQueue`，不是编码器

`TVUExternalSourceSortQueueManager.mm:278-281`：

```cpp
if (new_samplebuffer != NULL) {
    TVUAVStreamManager::getInstance()->AddBufferToWorkQueue(
        new_samplebuffer,
        TVUAVStreamManager::getInstance()->m_total_queue[TVUExternalQueue],
        node->external_source_index, node->fps);
    CFRelease(new_samplebuffer);
}
```

即：排序线程把重建了 PTS 的 sampleBuffer **推进合流层的 `TVUExternalQueue`**，而不是直接交给编码器。

### F2 — 图上右半段的方法名全仓不存在

yuque 图（以及已迁移进 `aw.excalidraw.json` 的部分）在 SortQueueManager 容器右半画了：

```
处理 node → [TVUExternalSourceConfig manager].renderView / pushRenderSampleBuffer: → 送到渲染视图
处理 node → TVUVideoEncoderManager / pushSample:andPtsOffset:sourceType:
              → consumePixelBuffer:（送入 agora）
              → h264 pushSample:andPtsOffset:
              → h265 pushSample:andPtsOffset:  → encode → Record Video / 传输
```

全仓核实（`products` + `modules`，排除 build/cache）：

| 标识符 | 命中数 |
|---|---|
| `pushRenderSampleBuffer` | **0** |
| `pushSample` | **0** |
| `andPtsOffset` | **0** |
| `renderView` | 92 —— 但全是 TVUIRL / SDK 里的普通 `UIView *renderView` 属性，不是 `[TVUExternalSourceConfig manager].renderView` |

另查了 12 个分支（`git grep "pushSample:andPtsOffset"`）全部 0 命中。

`TVUVideoEncoderManager` 的真实接口只有一个编码入口（`TVUVideoEncoderManager.h:64`）：

```objc
- (void)encode:(CMSampleBufferRef)sampleBuffer
    isNeedKeyFrame:(BOOL)isNeedKeyFrame
    externalSourceIndex:(int)externalSourceIndex;
```

调用方三处（`grep isNeedKeyFrame:`）：

| 位置 | 含义 |
|---|---|
| `TVUAVStreamManager.mm:2451` | **合流层**四线程的编码出口 |
| `TVUAVStreamManager.mm:2687` | 同上，另一分支 |
| `TVUAnywhere.mm:4407` | `#if _TVUSDKANYWHERELITE` 旁路（Q8 出口②），绕过合流层 |

> 结论：图上那一段大概是从设计稿 / 另一产品线 / 记忆里画的，**不对应 dev1 的代码**。
> 我在迁移时是逐字照搬 jpg 的，所以这批错名现在也在 `aw.excalidraw.json` 里。

### F3 — 真正的汇聚点是 `AddBufferToWorkQueue`，而它已经在图上了

真实的三路汇入：

```
外部源      sortThread ──→ AddBufferToWorkQueue(m_total_queue[TVUExternalQueue])   SortQueueManager.mm:279
相机（合流）           ──→ AddBufferToWorkQueue(m_total_queue[TVUCameraQueue])     TVUAnywhere.mm:4436
相机（直通）           ──→ sendToEncoderWithSamplebuffer(TVUAVStreamCamera)        TVUAnywhere.mm:4432
                                    ↓
                        合流层 TVUAVStreamManager 8 队列 + 四线程（见 02 文档）
                                    ↓
                    [[TVUVideoEncoderManager manager] encode:isNeedKeyFrame:externalSourceIndex:]
                                    TVUAVStreamManager.mm:2451 / :2687
LITE 旁路              ──────────→ 同一个 encode:（跳过合流层）  TVUAnywhere.mm:4407
```

**相机带 NO 支的终点框本来就写着 `AddBufferToWorkQueue(m_total_queue[TVUCameraQueue])`** ——
和外部源那条是同一个函数、只是队列不同。所以汇聚点已经在画布上，只是两处没连起来。

### F4 — 合并成一张图缺的那个框：合流层

图上目前是 `处理 node → TVUVideoEncoderManager`（错名），**把整个合流层折叠掉了**。
一旦补上合流层的框，两条带自然收口：

```
Local Video File ─→ FFMpeg Parse ─→ … ─→ SortQueue ─→ AddBufferToWorkQueue(TVUExternalQueue) ┐
                                                                                              ├→ 合流层 ─→ encode: ─→ 出口
AVCaptureVideoDataOutput ─→ … ─→ sendToEncode… ─┬→ AddBufferToWorkQueue(TVUCameraQueue) ──────┘
                                               └→ sendToEncoderWithSamplebuffer（直通）───────┘
```

也就是说，**合并不是几何问题，是图上缺了一层**。补完这一层，
相机带就不需要独立成带，可以和 `Local Video File` 并成同一张图的两个源。

### 待办（图侧，非代码）

- [ ] 按 F2 把 `pushSample:andPtsOffset:sourceType:` / `pushRenderSampleBuffer:` 换成
      `encode:isNeedKeyFrame:externalSourceIndex:`，并确认渲染侧的真实调用（`renderView` 那条待查）
- [ ] 补合流层框（`TVUAVStreamManager` 8 队列 + 四线程），把两条 `AddBufferToWorkQueue` 连进去
- [ ] 之后相机带可从负 y 区并入主图

**Q9 后续（图已改完）**：三件事都做了，`aw.excalidraw.json` 现 348 个元素。

1. **删掉 37 个错名元素** —— `pushSample:andPtsOffset:sourceType:` / `pushRenderSampleBuffer:` /
   `consumePixelBuffer:`（挂错宿主那份）/ `h264`·`h265` 标注 / `Record Video` / `传输` /
   两条 `addSampleData(sample)` 注释。删除按位置约束（只清 `y>400` 的外部源两带），
   总览面板与相机带不受影响。残留核查：四个错名 grep 全部 0。

2. **补上合流层容器**（依据 `TVUAVStreamManager.mm`）：

   | 框 | 依据 |
   |---|---|
   | `AddBufferToWorkQueue` 8 路队列（汇入点） | `m_total_queue[…]` |
   | `sendToEncoderWithSamplebuffer`（相机直通入口） | `mm:2460` |
   | Handle / Render / Encoder / AutoPan 四线程 | `mm:3177-3186` |
   | `[preview displaySampleBuffer:]` | `mm:2173`（`renderWithSamplebuffer()` `mm:2050`） |
   | `tvuConsumePixelBuffer:` → Agora | `mm:2389`（`encoderWithSamplebuffer()` `mm:2322`） |
   | `encode:isNeedKeyFrame:externalSourceIndex:` | `mm:2451`；`TVUVideoEncoderManager.h:64` |
   | ① `AVFormatController::addH264Data` → `AVFormatHttp::Product_Data_Packet` → `CTVUTransporterT::callback_data_in` | 04 §2.4 |
   | ② `TVULiveMediaCenter::muxFrameWithStremId` | 04 §3.1 |
   | ③ `TVURecordMuxHandler::addVideoData` / `AVRecorder::recordData` → .asf | 04 §一 |

   音频侧两条注释同步改成真名：`AVFormatControl::addAACData`（ASF）/ `TVULiveMediaCenter`（帧传输）/
   `TVUAudioRecorderManager → TVURecordMuxHandler::addAudioData`（07 §7）。

3. **三路汇入连通**（相机带不再是孤立的带）：

   | 来源 | 落点 | 边标签 |
   |---|---|---|
   | 外部源 `AddBufferToWorkQueue(TVUExternalQueue)`（新增框，`SortQueueManager.mm:279`） | 合流层汇入点 | 外部源 |
   | 相机 `AddBufferToWorkQueue(m_total_queue[TVUCameraQueue])` | 合流层汇入点 | 相机·合流 |
   | 相机 `sendToEncoderWithSamplebuffer(TVUAVStreamCamera)` | `sendToEncoderWithSamplebuffer` 直通入口 | 相机·直通 |

   `SortQueueManager` 容器同时收窄到 x 2420..3600（原先 2250 宽里有一半是错画进去的合流层内容）。

---

## Q10 — `isOnlyBuildInCameraStream` 的条件组合

### 0. 名字骗人：它判的是"是否在用系统预览"

`TVUAnywhere.mm:1891-1901`：

```objc
- (BOOL)isOnlyBuildInCameraStream {
#if (defined TVU_HIT_ME) || (defined _TVUSDKANYWHERE)
  #if (defined _TVUIRLSDK)
    return _isRenderWithSystemView && ![TVUScreenRecordingServerSocketManager manager].isReceivingFrame;
  #else
    return _isRenderWithSystemView;
  #endif
#else
    return _isRenderWithSystemView && ![TVUScreenRecordingServerSocketManager manager].isReceivingFrame;
#endif
}
```

**主条件是 `_isRenderWithSystemView`** —— 一个"当前是否用 `AVCaptureVideoPreviewLayer` 系统预览"的 UI 状态位，
不是"只有内置相机在推流"的结构事实。两者的等价关系由 `checkUseSystemPreview()` **每帧异步纠正**维持，
不是不变式。

`_isRenderWithSystemView` 只有三个写点：

| 位置 | 值 | 线程 |
|---|---|---|
| `TVUAnywhere.mm:318`（init） | **YES** | 构造 |
| `tvuUseSystemPreview`（`:1905-1912`） | YES | `dispatch_async(main)` |
| `tvuUseCustomPreview`（`:1915-1922`） | NO | `dispatch_async(main)` |

### 1. 真正的条件组合在 `shouldUseSystemPreview()`

`TVUAVStreamManager.mm:2274-2290`（与 `checkUseSystemPreview` 内联的那份逐字同源）：

**分支 A —— `_TVUIRLSDK`，或既非 `TVU_HIT_ME` 又非 `_TVUSDKANYWHERE`（即主 app / IRL）：6 条全 AND**

```objc
streamType == TVUAVStreamCamera
&& ![[TVUExternalSourcePictureManager manager] tvuGetIsOpenLiveWithLocalPicture]   // 无本地图片源
&& ![[TVUBeautyManager manager] isBeautyState]                                     // 无美颜
&& ![[TVUAnywhere manager] tvuIsLowPerformanceMode]                                // 非低性能模式
&& ![[TVUAnywhere manager] tvuIsReplaceBackgroundStart]                            // 未开换背景
&& ![[TVUAnywhere manager] tvuIsReplaceBgBlurStart]                                // 未开背景模糊
```

**分支 B —— `TVU_HIT_ME` / `_TVUSDKANYWHERE` 且非 IRL：只 3 条**

```objc
streamType == TVUAVStreamCamera
&& !tvuGetIsOpenLiveWithLocalPicture
&& !tvuIsLowPerformanceMode
```

> **美颜 / 换背景 / 背景模糊三个条件在分支 B 里被去掉了。**
> 这些 build 开着美颜也会判定为"系统预览 + 直通编码"，而直通是绕过合流层的 ——
> 「待核实」美颜在这些 build 里是否在别处做，否则等于开了不生效。

### C1 — 初始值是 YES，切换是异步的（**高**）

`_isRenderWithSystemView` 初始化为 **YES**（`:318`），而两个切换方法都是 `dispatch_async(main)`。所以：

- **启动瞬间** `isOnlyBuildInCameraStream == YES` → 采集回调走直通分支，即使实际已是多源；
- **切到多源时**，`checkUseSystemPreview` 检测到变化 → `tvuUseCustomPreview` → 异步置 NO。
  主线程执行前的若干帧仍走直通，被送进编码器而不进合流层合成。

代码自己承认这个异步性 —— `TVUAVStreamManager.mm:2152` 注释：

> 系统预览切换是异步的（checkUseSystemPreview→tvuUseSystemPreview→0.2s 后才显示）…

`checkUseSystemPreview` 里那个 `dispatch_after(0.2s)` 才调 `hiddenSystempreviewOrNot`，即**预览层隐藏还要再等 200ms**。

### C2 — 四个合流层线程都用它做空转节流，一轮 200ms（**高**）

`TVUAVStreamManager.mm:248 / 269 / 291 / 313`（handle / render / encoder / autoPan 四线程逐字相同）：

```cpp
if ([[TVUAnywhere manager] isOnlyBuildInCameraStream]) {
    usleep(TVU_EMPTY_TASK_MS*1000);          // 200ms，:235
} else {
    if (processTime < 10) { usleep(10*1000); }
}
```

纯相机时四条线程各睡 200ms/轮 —— 这就是 02 文档说的"纯相机模式 200ms 空转"。

**副作用**：从纯相机切到多源时，四线程可能正睡在 200ms 里，**最坏要等 200ms 才开始处理第一帧**。
叠加 C1 的异步切换延迟和 Q7-C3 的主线程阻塞，构成"切源时卡一下"的完整解释链。

### C3 — `checkUseSystemPreview` 的 6 个函数局部 static 跨线程（**中**）

```cpp
void TVUAVStreamManager::checkUseSystemPreview() {
    static TVUAVStreamType lastStreamType = TVUAVStreamNone;
    static BOOL lastIsLocalPicture = NO;
    static BOOL lastBeautyState = NO;
    static BOOL lastIsLowPerformanceMode = NO;
    static BOOL lastReplaceBGisOpen = NO;
    static BOOL lastIsReplaceBGBlur = NO;
```

两个调用点，线程不同：

| 位置 | 上下文 | 线程 |
|---|---|---|
| `TVUAnywhere.mm:4418` | `sendToEncodeWithSampleBuffer:` 首行 | AVFoundation capture 队列 |
| `TVUAVStreamManager.mm:2801` | `AddBufferToWorkQueue` 内（`queue->type` 非 Encoder/Render/Camera 时） | 入队方线程（parse / 屏录 socket / DJI …） |

第二个调用点是补丁，注释写明了成因（`:2795-2799`）：

> fix bug ITA-1209 … 由于切换到双镜的时候，单镜头回调不执行，所以检测 是否使用系统渲染的flag没有重置过来。

**也就是说这个 flag 的异步维护已经漏过一次**（双摄下单摄回调停了 → flag 卡住 → 预览冻结），
补法是在另一条线程上再调一次同一个函数 —— 于是 6 个 static 变成跨线程共享。

### C4 — 屏共检查的编译分支不一致（**中**）

`isOnlyBuildInCameraStream` 的三个分支里，中间那个（`(TVU_HIT_ME || _TVUSDKANYWHERE) && !_TVUIRLSDK`）
**不检查 `isReceivingFrame`**。按 07 文档的编译矩阵，`TVUAnywhereSDK` target 定义 `_TVUSDKANYWHERE`
且不定义 `_TVUIRLSDK` → 正好落在这个分支。

后果：屏共正在收帧时，该 build 仍可能 `isOnlyBuildInCameraStream == YES`
→ 相机帧直通编码器，绕过本该合成屏共画面的合流层 → **屏共内容不进流**。

「待核实」`TVUAnywhereSDK` build 是否支持屏共；若不支持，这个分支就是合理裁剪而非缺陷。

### 旁证 — 编码闸门里又一对跨实例 static

顺手看到的（`TVUAVStreamManager.mm:2291-2320`，`checkSampleBufferPTSForEncode`）：

```cpp
static Float64 last_pts = 0;
static int last_externalSourceIndex = -2;
```

规则是"同 index pts 间隔 <10ms 丢帧；不同 index 间隔 < 1/fps 丢帧"（2022.8.11 @Harry，
修"码率过低无法恢复"）。同样是函数局部 static，与 Q4 §1 记录的那批同类。

### 小结

| # | 判定 | 严重度 |
|---|---|---|
| — | 名字与语义不符：判的是"用系统预览"，靠每帧异步纠正维持等价 | 认知陷阱 |
| C1 | 初始值 YES + 异步切换 → 启动与切源瞬间走错分支 | **高** |
| C2 | 四线程 200ms 空转节流 → 切源最坏多等 200ms | **高** |
| C3 | 6 个函数局部 static 跨两条线程；补丁本身就是"再调一次" | 中 |
| C4 | 屏共检查在 `_TVUSDKANYWHERE` 非 IRL 分支缺失 | 中 |
| — | 分支 B 少了美颜/换背景/模糊三条件 | 待核实 |
