# OBS 源码阅读路线：源分类 / async_frames 入队与挑帧 / 合成分流

> 定位：**阅读指南**（按图索骥用），不是知识汇总——各技术点的详细解读与源码摘录见《OBS_采集源技术方案_摄像头_屏幕_图片》§1 与其速查表。
> 读的对象是 WorkOBS 异步帧路径（`WLSource::output_video` / `get_frame`）的直系祖先，读完回看自己的实现会有大量"原来如此"。

---

## 0. 源码环境

- 本地路径：`~/Documents/github/obs-studio`
- **commit 基线：`f2db097`（2026-07-09 master）**——已 checkout 固定，**别 pull**：本文与《采集源技术方案》里的行号都锚在这个 commit 上，更新后行号会漂移。
- 用 Xcode / VS Code 打开本地目录读（函数间跳转频繁，需要"跳到定义"；别用 GitHub 网页）。

## 1. 总地图：跟着一帧数据走完全程

读这块的主线**不是按文件读，而是跟着一帧的生命周期走**：

```
解码/采集线程                          合成线程（每 tick）
────────────                    ─────────────────────────────
obs_source_output_video()       tick_sources()
      │                               │
   cache_video()  ──入队──►  async_frames[]  ──挑帧──  async_tick() → ready_async_frame()
  （拷贝进对象池）                                            │
                                                    render 阶段: render_video()
                                                    ├─ 异步源: 帧→纹理→画
                                                    └─ 同步源: 直接调 video_render 回调
```

四站按此顺序读，总量约 600 行，一个下午可完成。

---

## 2. 第 1 站：分类的"宪法"（约 30 分钟）

**读什么**：
- `libobs/obs-source.h:88-121` —— 5 个 output_flags 宏
- `libobs/obs-source.h:222-351` —— `obs_source_info` 结构体各回调的注释

只看两样：**`OBS_SOURCE_ASYNC` 这一个 bit**（:100，组合宏 `OBS_SOURCE_ASYNC_VIDEO` 在 :113），和每个回调的注释。重点读 `get_width`（:268）注释那句：

> *"Required if this is an input source and has **non-async** video"*

一句注释暴露整个设计：**异步源连宽高都不用报**——一切信息（尺寸/格式/时间戳）都随帧走；同步源没有帧，所以必须自己报尺寸、自己实现 `video_render`。

**对照 WorkOBS**：这一站对应已被虚函数取代的 `wl_source_info_t`。OBS 用 flag 位区分两类源；WorkOBS 目前只有异步一类（M3 图片源会逼出同步类，见《采集源技术方案》§5）。

---

## 3. 第 2 站：入队侧（约 45 分钟）

**读什么**（`libobs/obs-source.c`，调用链三层）：

| 层 | 函数 | 位置 |
|---|---|---|
| 公开 API | `obs_source_output_video` | obs-source.c:3595 |
| 内部转发 | `obs_source_output_video_internal` | obs-source.c:3563 |
| **实际入队** | `cache_video` | obs-source.c:3505 |

**看点：双池结构。**
- `async_cache`：帧对象**内存池**（复用 `obs_source_frame`，避免每帧 malloc；连续 5 tick 未用才真正释放，`MAX_UNUSED_FRAME_DURATION` :3486）
- `async_frames`：**待显示队列**（挑帧从这里取）

以及 `:3511` 的队满策略：`MAX_ASYNC_FRAMES = 30`（:3503），满了**整池丢弃 + last_frame_ts 复位**——不是丢一帧。

> **思考题①**：队满时 OBS 整池丢弃+时钟复位，WorkOBS 的 `output_video` 是 drop-oldest 丢一帧。什么场景下这两种策略会表现出可感知的差异？（提示：持续积压 vs 瞬时抖动——持续积压说明消费端根本追不上，丢一帧只是延缓死亡；瞬时抖动丢整池则会造成一次可见的跳变。）

---

## 4. 第 3 站：挑帧算法（全书最精华，约 1.5 小时）

**读什么**（调用链 + 一个配套宏）：

| 角色 | 函数 | 位置 |
|---|---|---|
| tick 入口 | `async_tick` | obs-source.c:1328 |
| 出队 | `get_closest_frame` | obs-source.c:4175 |
| **核心算法** | `ready_async_frame` | obs-source.c:4087 |
| 跳变阈值 | `MAX_TS_VAR`（2 秒）+ `frame_out_of_bounds` | obs-internal.h:1060-1068 |

**这是 `WLSource::get_frame` 的原型，建议开两个窗口逐行对照读。**

已实现过的部分（读起来会很亲切）：虚拟时钟推进、追赶跳帧（while 循环丢过期帧）。OBS 多出来的四样，每样都值得停下来想为什么：

1. `:4095` **`async_unbuffered` 无缓冲模式**——只留最新帧、其余全丢（直播低延迟用；对应"锚最新帧 vs 锚最旧帧"的缓冲深度决策，WorkOBS 记在 M3）
2. `:4116` **`frame_out_of_bounds` 跳变重锚**——前后帧时间戳差 >2s 直接把虚拟时钟重锚到新帧（seek / loop / 断流自愈）。对比：WorkLabs 主项目的 seek 用 epoch 世代号丢旧帧，是"显式打标"方案；OBS 是"隐式检测"方案，两者可互换
3. `:4133` **差 <2ms 提前 break**——虚拟时钟刚好卡在两帧边界时，不换帧，避免同一帧显示两次造成的帧率毛刺（WorkOBS `get_frame` 目前没有这个平滑窗）
4. **挑帧在 tick 阶段、渲染在 render 阶段**——`async_tick` 选好 `cur_async_frame`，render 时通过 `obs_source_get_frame`（:4199）原子取走。两阶段分离。

> **思考题②**：为什么挑帧要放 tick 而不是渲染时现挑？（提示：一个源可能被多个 scene 引用、一帧内渲染多次——挑帧若在 render 里做，同一 tick 两次渲染可能拿到不同帧，画面撕裂且时钟被推进两次。）

---

## 5. 第 4 站：合成分流（约 45 分钟）

**读什么**：

| 角色 | 函数 | 位置 |
|---|---|---|
| 合成主循环遍历 | `tick_sources` | obs-video.c:32 |
| tick 分流（唯一依据 = ASYNC 位） | `obs_source_video_tick` | obs-source.c:1367 |
| **render 分流 if-else 链** | `render_video` | obs-source.c:2906 |
| 异步帧→GPU 纹理 | `obs_source_update_async_video` | obs-source.c:2514 |
| 纯异步源绘制 | `obs_source_render_async_video` | obs-source.c:2561 |

**看点：一个 bit + 一个回调是否存在，决定两条完全不同的渲染路径。**

- `:1367` 只有带 `OBS_SOURCE_ASYNC` 的源才进 `async_tick` 挑帧
- `:2914` 异步 input 源先把挑好的帧上传成纹理
- `:2933 vs :2942` 有 `info.video_render` 回调 → 调回调（**同步源现画**）；没有 → 画缓存帧纹理（**纯异步源**）

这正是 WorkOBS M3 给 `WLSource` 加同步 `render_texture()` 通道时要抄的分流形状：合成 tick 遍历源，异步走 `get_frame`，同步走 `render_texture`，最终汇到同一个"纹理→画布"合成步骤。

---

## 6. 读法建议

1. **对照读**：第 3 站开 `obs-source.c` 和 `WLSource.cpp` 两个窗口，逐段比对——你写过同款算法，差异点就是学习点。
2. **检验读懂的方式**：每站读完，回头挑《OBS_采集源技术方案》§6.2 对比表的毛病——能指出文档哪里说浅了/说错了，才算读透。
3. 两道思考题的答案想清楚后，值得记回本文档（或直接改进 `WLSource` 的实现——①对应 `output_video` 队满策略，③的 2ms 平滑窗是 `get_frame` 的现成改进点）。

## 7. 读完之后（衔接现有规划）

- **M1 收尾**可顺手带走：2ms 平滑窗、跳变重锚（替代或补充 epoch 方案）
- **M3 合成**直接引用：`render_video` 的同步/异步分流形状、`async_unbuffered` 缓冲深度决策
- 三类新源（摄像头/屏幕/图片）与这套机制的对接方式，见《OBS_采集源技术方案_摄像头_屏幕_图片》§6
