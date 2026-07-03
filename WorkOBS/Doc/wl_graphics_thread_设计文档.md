# wl_graphics_thread 设计文档

> 创建日期：2026-07-03
> 对标：OBS `obs_graphics_thread`（`libobs/obs-video.c:1161`）
> 上游调研：[OBS_合成tick_音频混音_AV同步](../../Doc/调研/OBS/OBS_合成tick_音频混音_AV同步.md)（第③篇，行号实读核对）
> 状态：设计阶段（§九 有待拍板决策，定稿后动工）

---

## 一、定位与职责

`wl_graphics_thread` 是**全局唯一**的合成节拍线程。注意与 `wl_media_thread` 的根本区别：

| | wl_media_thread | wl_graphics_thread |
|---|---|---|
| 数量 | **per-source**（每个媒体源一条） | **全局一条**（不管多少源） |
| 角色 | 生产者：解码 → pace → 推帧进 async_frames | 消费者：从所有源的 async_frames 挑帧 → 合成 |
| 节奏来源 | 帧自己的 pts（媒体时间） | 固定输出帧率（合成 fps，如 30） |

**一句话职责**：每隔 `1/fps` 秒醒来一次——问每个源"此刻该显示哪帧"（`wl_source_get_frame`）→ 把这些帧合成一幅画面 → 打上此刻的时间戳 → 送下游（preview / 编码）。

```
wl_media_thread A ──▶ source A: async_frames ──┐
wl_media_thread B ──▶ source B: async_frames ──┤   每 tick 逐源 get_frame
camera 回调       ──▶ source C: async_frames ──┴──▶ wl_graphics_thread ──▶ 合成帧(CFR) ──▶ preview / 编码
                                                      （全局，固定节拍）
```

### 为什么是"全局统一节拍"而不是各源自己渲染？

旧 WorkLabs 初版走过"每源独立 render 线程、各自节流后推帧给 mix"的路（输入事件驱动合成），后来改成 tick 驱动。OBS 调研的结论（第③篇 §5.1）：

> OBS 是**单一 graphics 线程统一 tick**：一个 `os_sleepto_ns` 到点 → `tick_sources` 拉动所有源推进 → 合成一帧。好处是合成帧率稳定、所有源在同一时刻被采样、不会出现源 A、源 B 各自抖动叠加。

推模型（源各自推）下合成节奏被 N 个生产者的抖动叠加支配；拉模型（tick 统一拉）下输出节奏只由这一条线程的时钟决定，各源的抖动被各自的 async_frames 吸收。**WorkOBS 从一开始就按拉模型建。**

---

## 二、心智模型：整条链路上的"三次对表"

到这个模块为止，时间控制一共出现三次，全部是**同一个思想——绝对基准法**（固定零点 + 每次从零点重算，误差不累积）：

| 环节 | 谁 | 公式 | 状态 |
|---|---|---|---|
| ① 生产端 pace | media_thread | `target墙钟 = base_wall + (pts − first_pts)`，早了睡 | ✅ 已实现，实测通过 |
| ② 消费端挑帧 | wl_source_get_frame | `target媒体位置 = first_pts + (now − first_sys)`，追赶跳帧 | ✅ 已实现，实测 60→30 通过 |
| ③ 合成节拍 | **wl_graphics_thread（本文档）** | `下一tick墙钟 = video_time + interval`，睡到绝对时刻 | ⬜ 本模块 |

①和②是对偶（一个把 pts 换算成墙钟去睡，一个把墙钟换算成 pts 去挑）；③是给②提供"现在几点"的那个统一时钟源——tick 线程醒来后，把自己的当前时刻传给每个源的 `get_frame`。

**OBS 的 A/V 同步本质**（第③篇 §3.1）也建立在这上面：video/audio 两条线程各自"睡到系统单调时钟的绝对刻度"，源的时间戳在入口归一到同一根墙钟轴，两边天然对齐、无需互相追赶。`wl_graphics_thread` 就是这套体系的视频侧节拍器。

---

## 三、主循环设计

### 3.1 核心流程（伪代码，对标 obs_graphics_thread_loop，obs-video.c:1097）

```c
static void *graphics_thread_func(void *arg) {
    wl_graphics_t *g = arg;

    // 时钟锚定：虚拟当前时刻，起点取系统单调时钟（对标 obs->video.video_time）
    g->video_time = now_ns();
    uint64_t interval = 1000000000ULL / g->fps;    // 一个 tick 的标称时长

    while (!should_stop) {

        // ── (1) tick 所有源：逐源按 video_time 挑帧 ──
        //    对标 tick_sources → obs_source_video_tick
        for (each source in g->sources) {
            int64_t pts;
            CVPixelBufferRef frame = wl_source_get_frame(source, g->video_time, &pts);
            // frame 为 borrow；NULL = 该源还没出过帧
        }

        // ── (2) 合成 ──
        //    对标 output_frames → render_video（OBS 全 GPU）
        //    阶段一：stub（仅日志）；阶段二：Metal 合成（M3）
        composite(frames...);

        // ── (3) 输出合成帧，时间戳 = 本 tick 的 video_time ──
        //    对标 output_video_data（timestamp = vframe_info.timestamp）
        output(composited, g->video_time);

        // ── (4) 睡到下一个 tick 的绝对时刻，推进 video_time ──
        //    对标 video_sleep（含丢帧补偿，见 3.2）
        video_sleep(g, &g->video_time, interval);
    }
}
```

时序要点（照抄 OBS）：挑帧/合成用的是**本帧开头**的 `video_time`；合成完成后才在末尾 `video_sleep` 推进到下一帧。

### 3.2 节拍核心：video_sleep（睡到绝对时刻 + 丢帧补偿）

对标 `obs-video.c:805`，这是整个模块最值得逐行搬的函数：

```c
static void video_sleep(wl_graphics_t *g, uint64_t *p_time, uint64_t interval) {
    uint64_t t = *p_time + interval;          // 目标：绝对时刻，不是"睡固定时长"

    if (sleep_to_ns(t)) {                     // 睡到 t；返回 true = 确实睡了
        *p_time = t;                          // 正常：video_time 平滑 +interval
        g->count = 1;
    } else {                                  // t 已是过去 → 本帧合成超时了
        uint64_t diff = now_ns() - *p_time;
        int count = (int)(max(diff, interval) / interval);  // 落后了几个完整 interval
        *p_time += interval * count;          // 一次性把 video_time 跳到该到的位置
        g->count = count;                     // 这一帧"顶 count 帧"
    }

    g->total_frames  += g->count;
    g->lagged_frames += g->count - 1;         // 统计：本轮补出来的滞后帧
}
```

两个关键语义：

- **睡到绝对时刻，不 drift**。目标永远是 `video_time + interval` 这个绝对值：即使本帧合成花了 5ms，下一目标仍是上一目标 + interval，合成耗时不会累积成漂移。与 pace_video 的绝对基准是同一个原理，只是方向反过来（pace 是"帧到点才放行"，这里是"到点才开工下一帧"）。
- **卡顿一次性跳 count 个 interval**。本帧合成超过一个 interval 时，不"装作只过了一帧"，而是算出实际落后几帧、把 video_time 一次跳到位，并记 `count`。下游（编码侧）收到 `count>1` 时把同一帧复制 count 份、时间戳逐帧 +interval——**输出时间轴永远规整连续（CFR），卡顿变成"复帧"而不是"时间空洞"**。`lagged_frames` 是健康度指标（OBS 在统计面板显示的"渲染滞后帧"就是它）。

阶段一（无编码下游）时 `count` 只进统计；接编码器后按上述复帧语义消费。

### 3.3 sleep_to_ns 的 macOS 实现

语义要求：**睡到某个 CLOCK_MONOTONIC 绝对时刻**；目标已过则立即返回 false。

- 候选 ①：`nanosleep(target − now)` 差值实现（够用，精度 ms 级，OBS 的通用 fallback 同思路）
- 候选 ②：`mach_wait_until(absolute)`（macOS 原生绝对时刻等待，精度更高，需 mach_timebase 换算）

**建议先用 ①**（与 media_thread 现有 pace 同款、代码最少），tick 精度实测不够再换 ②。注意与 `wl_source_get_frame` / `pace_video` 共用同一把 `CLOCK_MONOTONIC` 尺（`now_ns()` 可提为共用工具）。

---

## 四、与 wl_source 的接口

### 4.1 挑帧：现有 get_frame 直接可用

`wl_source_get_frame(src, sys_time_ns, &pts)` 已实现并实测（追赶式挑帧、cur_frame borrow、缓冲空重复上一帧）。graphics thread 唯一要做的是**把 `video_time` 作为 `sys_time_ns` 传入**。

与 OBS 的分工对照：OBS 的挑帧逻辑（`ready_async_frame`，第②篇）也在 source 内部，由 graphics thread 的 `obs_source_video_tick(s, seconds)` 统一驱动——**我们与 OBS 分工一致**（节拍在 graphics、挑帧在 source），仅两点简化：

| | OBS | WorkOBS | 影响 |
|---|---|---|---|
| tick 传参 | `seconds`（增量，video_time 的差） | `video_time`（绝对时刻） | 等价。挑帧内部横竖要绝对时钟，直接传绝对值更简单 |
| 时间戳归一 | 源入口 `timing_adjust = os_time − 源ts` 钉到系统钟 | get_frame 首帧锚定 `consume_first_pts/sys` | 等价（都是绝对基准），但我们的锚定点=首次消费 → 启动积压全保留（depth≈13 遗留，见 §七） |

### 4.2 源列表从哪来：wl_core（全局核心，2026-07-03 定稿）

全局核心 `wl_core`（对标 OBS 全局 `obs` 单例 / 旧 WorkLabs `WLStreamsManager`）持有源列表 + graphics 线程，graphics 只消费：

```c
int  wl_core_startup(int fps);    // 注册内置源类型 → 建并启动 graphics（0 源空转）
void wl_core_shutdown(void);      // 停 graphics → 销毁剩余源
wl_source_t *wl_core_add_source(const char *type_id, const char *settings);  // 不自动 start
void         wl_core_remove_source(wl_source_t *src);                        // 出表 + 销毁（core 拥有源）
void         wl_core_foreach_source(void (*fn)(wl_source_t*, void*), void *ctx); // tick 遍历入口
```

**并发**：一把 sources mutex。tick 遍历全程持锁；`remove` 拿同一把锁 → 自然等当前 tick 遍历完成，返回后 tick 保证不再触碰该源——**无引用计数也安全**（真出现多消费者再上 OBS 式 `obs_source_get_ref`）。销毁动作在锁外执行（destroy 要 join 解码线程，可能耗时，别堵 tick）。

z-order / 布局等编排职责 M3 再加（当前 remove 用"尾元素补位"不保序，届时一并处理）。

---

## 五、输出：合成帧的时间戳

- **timestamp = 本 tick 的 `video_time`**（对标 OBS `vframe_info.timestamp`）。合成帧的时间轴是**墙钟 CFR**：起点 = 线程启动时刻，步长 = interval，卡顿处复帧填充。
- 这与旧 WorkLabs `WLVideoMix` 的 `ptsAccum` 思路相同，但多了丢帧补偿的 count 语义（旧版卡顿时时间轴会被拉长，OBS 式是跳+复帧）。
- 下游形态：阶段一日志；阶段二合成出 CVPixelBuffer（Metal）；阶段三对接 preview 与编码。OBS 在合成与编码之间还有一层 video-io 环形缓存（吸收合成/编码速率差，第③篇 §4.1），我们到 M5 输出侧再考虑。

---

## 六、模块骨架

```
libwl/src/core/
├── wl_core.h            ← 全局核心：startup/shutdown + add/remove_source + foreach_source
└── wl_core.c            ← 单例（源列表 + mutex + graphics 实例）
libwl/src/graphics/
├── wl_graphics.h        ← create(fps) / start / stop / free（源列表在 wl_core，不在这里）
└── wl_graphics.c        ← graphics_thread_func + video_sleep
libwl/src/util/
└── wl_time.h            ← wl_now_ns / wl_sleep_to_ns（全库共用一把 CLOCK_MONOTONIC 尺）
```

```c
// wl_graphics.h
typedef struct wl_graphics wl_graphics_t;

wl_graphics_t *wl_graphics_create(int fps);           // fps = 合成输出帧率
int  wl_graphics_start(wl_graphics_t *g);
void wl_graphics_stop(wl_graphics_t *g);              // 幂等，join
void wl_graphics_free(wl_graphics_t *g);
// tick 内部经 wl_core_foreach_source 拿源（graphics 依赖 core，对标 OBS
// obs-video.c 直接访问全局 obs->data.sources）
```

线程模型与 `wl_media_thread` 同款：pthread + `should_stop`（atomic）+ mutex/cond，stop 幂等、free 内部先 stop。（旧 WorkLabs 的 WLVideoMix 用 dispatch_source 定时器；WorkOBS 内核统一 pthread，与 OBS 及 media_thread 一致，不引入 GCD。）

---

## 七、已知遗留（不在本模块修，但记录关联）

- **消费端锚定造成的 depth 水位**：get_frame 首次锚定在"缓冲最旧帧"，启动相位积压（实测 ~13 帧 ≈ 217ms）成为常驻延迟。播放器语义下合理（完整播放）；直播合成要低延迟需改锚定策略（如锚到最新帧，丢启动积压）。**归属 wl_source 挑帧层**，graphics 落地后按需求做成源级选项（对标 OBS unbuffered）。
- **音频节拍**：OBS 的 audio_thread（1024 采样窗口 + mix_audio 时间对齐累加，第③篇 §2）是独立线程，M4 混音时对标设计，不进本模块。
- **nanosleep 不可中断**：media_thread 的 pace 与本模块的 video_sleep 同有此问题（stop 最坏等一个 interval）。量级小（≤33ms），两处一起留到"可中断 sleep"专项。

---

## 八、分阶段落地

### 阶段一：节拍骨架（本设计的第一个落地目标）

- [ ] `wl_core`：startup/shutdown + add/remove_source + foreach_source（源列表 + mutex + graphics）
- [ ] `wl_graphics` create/start/stop/free；主循环：foreach_source→get_frame → video_sleep（绝对时刻 + count 补偿）
- [ ] `wl_time.h`：wl_now_ns / wl_sleep_to_ns 共用工具（media_thread 的 pace 同步切换）
- [ ] ViewController：删 NSTimer tick，改 wl_core_startup(30) + add_source + start
- [ ] 验收：get_frame 行为与 NSTimer 版一致（advanced=2、show 匀速、结尾兜底）；
      lagged_frames 正常为 0（`[gfx] lag` 不出现）；压主线程不影响 tick（已不在 runloop 上）

### 阶段二：Metal 合成（M3）

- [ ] 单源：CVPixelBuffer → Metal 纹理（CVMetalTextureCache）→ 画到画布 → 合成出帧
- [ ] 多源：持有层（源列表 + z-order + 布局）、逐源叠加
- [ ] 合成帧时间戳按 §五（CFR + count 复帧）

### 阶段三：对接下游

- [ ] preview 显示（见 preview_设计.md，待写）
- [ ] 送编码器（M5，考虑 video-io 式解耦缓存）

---

## 九、决策记录（2026-07-03 定稿）

1. **fps 来源**：`wl_core_startup(int fps)` 参数传入（阶段一调用处硬编 30），配置系统后续再接。
2. **sleep 实现**：nanosleep 差值（`wl_time.h` 的 `wl_sleep_to_ns`），精度不够再换 mach_wait_until。
3. **源列表**：全局核心 `wl_core` 持有（见 §4.2），graphics 只经 foreach 消费；add 不自动 start（显式 `wl_source_start`）；remove = 出表即销毁（core 拥有源生命周期）；graphics 随 startup 启动（0 源空转）。
4. **阶段一验证物**：纯日志（`[get]` 挑帧 + `[gfx] lag` 健康度），存图肉眼验证留给阶段二 Metal。
