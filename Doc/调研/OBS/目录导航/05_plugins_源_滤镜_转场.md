# OBS 目录导航 · plugins 源 / 滤镜 / 转场（内置素材与效果）

> 源码范围：`plugins/obs-filters`、`plugins/obs-transitions`、`plugins/image-source`、`plugins/obs-text`、
> `plugins/text-freetype2`、`plugins/vlc-video`、`plugins/nv-filters` ｜ 源文件 86 个（`.c/.h/.cpp/.m` + `.effect` 着色器，
> 不计 `locale/`、`cmake/`、vendored 的 `rnnoise/`） ｜ 基于 obs-studio commit `f2db097`（2026-07-09）
> 返回总索引：[README.md](README.md)

## 本篇速查

想找什么 → 去哪：

| 我想看… | 去这里 |
|---|---|
| 视频滤镜的统一形状（`obs_source_info` + 着色器链怎么串） | [obs-filters/ 分组说明](#obs-filters) + [`color-key-filter.c`](#color-key-filterc) |
| 音频滤镜怎么写（PCM in-place 处理，无需纹理） | [`noise-suppress-filter.c`](#noise-suppress-filterc) |
| 转场怎么同时拿到 A/B 两路纹理再混合 | [obs-transitions/ 分组说明](#obs-transitions) + [`transition-fade.c`](#transition-fadec) |
| 同步源 vs 异步源的区别（不走异步帧缓冲的源长什么样） | [`image-source.c`](#image-sourcec) |
| 色键 / 亮度键 / 裁剪 / 缩放算法在哪个文件 | [obs-filters 视频滤镜表格](#视频滤镜) |
| 压缩器 / 限制器 / 扩展器 / 降噪等音频动态处理在哪 | [obs-filters 音频滤镜表格](#音频滤镜) |
| Windows GDI+ 文字源 vs 跨平台 FreeType 文字源的取舍 | [obs-text/](#obs-text) 与 [text-freetype2/](#text-freetype2) |
| VLC 播放列表源、NVIDIA 背景移除/降噪 | [vlc-video/](#vlc-video)、[nv-filters/](#nv-filters) |
| 图片/颜色/幻灯片源、v1→v2 新旧版本共存的套路 | [image-source/ 分组说明](#image-source) |

---

## 一句话职责

这一篇覆盖的都是**挂在场景图叶子节点上的"内容提供者"和"效果处理者"**：滤镜（`obs-filters`）挂在某个源上做逐帧加工，
转场（`obs-transitions`）挂在两个场景之间做切换动画，其余几个目录（`image-source`/`obs-text`/`text-freetype2`/`vlc-video`/`nv-filters`）
本身就是输入源，直接生产画面/声音。它们都通过同一份 `obs_source_info` 协议接入 `libobs`——区别只在 `.type` 字段
（`OBS_SOURCE_TYPE_FILTER` / `OBS_SOURCE_TYPE_TRANSITION` / `OBS_SOURCE_TYPE_INPUT`，定义于 `libobs/obs-source.h:34-37`），
以及各自实现哪几个回调。谁调它们：`libobs/obs-source.c` 里的 `render_video`（:2906）按类型和标志位分发到不同渲染路径。

---

## obs-filters/　`plugins/obs-filters/`

**职责**：OBS 内置的全部滤镜，挂在一个源上、串成链，对这个源的输出做二次加工。分两条完全不同的路：
**视频滤镜**走 GPU 纹理（Metal/D3D/GL 之下统一由 `.effect` 着色器描述），**音频滤镜**走 CPU 上的 PCM 浮点数组，
两者共用同一个 `obs_source_info` 协议但填的回调字段不同（`video_render` vs `filter_audio`）。

**视频滤镜链怎么串**：一个源的 `source->filters`（`DARRAY`）按顺序存着挂在它上面的滤镜，每个滤镜的 `filter_target`
指向"链上的下一环"（`libobs/obs-source.c:3076` `obs_source_filter_add` 里 :3105 维护这个指针）。渲染时 `render_video`（:2906）发现
`source->filters.num` 非空就调 `obs_source_render_filters`（:2666），它只管拿到链头第一个滤镜、调
`obs_source_video_render`；每个滤镜自己的 `video_render` 回调里，标准动作是：

1. `obs_source_process_filter_begin(_with_color_space)`（`libobs/obs-source.c:4345` / `:4351`）——把"链上更靠前一环"
   （target，可能是原始源，也可能是上一个滤镜）渲染进一张纹理暂存面 `filter_texrender`；
2. 用自己的 `gs_effect_t` 设置参数、画一遍；
3. `obs_source_process_filter_end`（`:4467`，内部走 `obs_source_process_filter_tech_end` :4430）把结果贴回去。

有个小优化叫 **bypass**（`can_bypass`，:4337）：如果这是链上最后一个滤镜、且父源不需要额外纹理，就直接在父源的
draw 调用里加这个滤镜的着色器，省一次纹理往返——这是"能省一次 pass 就省"的典型 GPU 优化思路。
**音频滤镜**简单得多：`filter_audio` 回调收到 `struct obs_audio_data*`（指向 planar float PCM），原地处理后直接返回
指针即可，不涉及任何纹理/GPU 概念。

滤镜还有个贯穿全组的版本演进套路：同一个 `.id`（比如 `"color_key_filter"`）注册两份 `obs_source_info`，
`version` 字段不同——v1 标 `OBS_SOURCE_CAP_OBSOLETE`（旧工程打开时仍能用旧算法/旧参数范围，不会画面突变），
v2 是当前默认新建时用的版本（通常加了 `OBS_SOURCE_SRGB`，即在线性空间做混合，色彩更准）。`chroma-key` / `color-key` /
`color-correction` / `luma-key` / `mask` / `sharpness` / `noise-suppress` 都是这个模式。

### 视频滤镜

| 文件 | 行数 | 功能 |
|---|---|---|
| `chroma-key-filter.c` | 515 | 绿/蓝/自定义色抠像（比 color-key 多了溢色 spill 抑制），v1/v2 两版 |
| `chroma_key_filter.effect` / `_v2.effect` | 99 / 111 | 上面的着色器：按 YUV/距离模型算 alpha + 去溢色 |
| `color-correction-filter.c` | 733 | 色彩校正：gamma/对比度/亮度/饱和度/色相偏移/颜色相乘叠加，本组行数最大的文件 |
| `color_correction_filter.effect` | 74 | 对应着色器 |
| `color-grade-filter.c` | 509 | LUT 调色（1D/3D CLUT，`.cube` 文件），自带 `data/LUTs/` 预设（灰度/反色/去色等） |
| `color_grade_filter.effect` | 177 | LUT 采样着色器，本组着色器里最长的一个 |
| `color-key-filter.c` ⭐ | 466 | 单色抠像（distance-based），视频滤镜的标准形状代表，见下方展开 |
| `color_key_filter.effect` / `_v2.effect` | 65 / 77 | 对应着色器 |
| `crop-filter.c` | 300 | 按像素/相对值裁剪四边 |
| `crop_filter.effect` | 95 | 裁剪着色器：本质是改 UV 的 `mul`/`add` 变换，`scroll-filter.c` 复用了同一份 |
| `scroll-filter.c` | 335 | 画面滚动/循环平移，**复用 `crop_filter.effect`**（同一套 UV 线性变换，只是参数由滚动速度驱动而非固定裁剪框） |
| `hdr-tonemap-filter.c` | 234 | HDR→SDR 色调映射（Reinhard/MaxRGB 变换） |
| `hdr_tonemap_filter.effect` | 97 | 对应着色器 |
| `sdr-on-hdr-filter.c` | 173 | 反向：SDR 内容混在 HDR 画布里时的 gamma 提升 |
| `sdr_on_hdr_filter.effect` | 69 | 对应着色器 |
| `luma-key-filter.c` | 227 | 亮度键控（按亮度阈值抠像，常用于素材自带黑白遮罩） |
| `luma_key_filter.effect` / `_v2.effect` | 52 / 54 | 对应着色器 |
| `mask-filter.c` | 404 | 图片/颜色蒙版，混合方式可选 alpha 蒙版或乘/加/减混合（动态加载不同 `.effect`） |
| `mask_alpha_filter.effect` / `mask_color_filter.effect` / `blend_{add,mul,sub}_filter.effect` | 54/55/54/54/54 | 5 个着色器按用户选的蒙版类型二选一/多选一加载 |
| `sharpness-filter.c` | 171 | 锐化（USM 风格） |
| `sharpness.effect` | 76 | 对应着色器 |
| `scale-filter.c` | 591 | 缩放到指定分辨率，采样算法（点/双线性/双三次/Lanczos/Area）**不走自带 `.effect`，直接用 `libobs` 内建的 `OBS_EFFECT_BICUBIC` 等基础特效** |
| `gpu-delay.c` | 359 | GPU 侧视频延迟：把已渲染的纹理存进 `deque` 环形队列，按时间戳延后吐出（用 `OBS_EFFECT_DEFAULT` 直接画，无自带着色器） |
| `async-delay-filter.c` | 239 | CPU 侧视频延迟：延迟的是 **`obs_source_frame*`（异步帧）**，作用在异步源的帧队列层，和 `gpu-delay` 延迟的是纹理不是一回事 |
| `color.effect` | 95 | 不被单独加载，是给别的 `.effect` `#include` 的 sRGB 线性/非线性转换公共函数 |

### 音频滤镜

| 文件 | 行数 | 功能 |
|---|---|---|
| `noise-suppress-filter.c` ⭐ | 553 | 降噪：SpeexDSP 传统算法 + RNNoise 神经网络降噪二选一，见下方展开 |
| `compressor-filter.c` | 514 | 压缩器（动态范围压缩），支持侧链（sidechain）输入 |
| `expander-filter.c` | 494 | 扩展器 + 同文件复用出"上扩压缩器"两个 `obs_source_info`（`expander_filter` / `upward_compressor_filter`） |
| `eq-filter.c` | 157 | 三段均衡器（低/中/高频biquad滤波） |
| `limiter-filter.c` | 214 | 硬限幅器（防削波） |
| `noise-gate-filter.c` | 196 | 噪声门（开/关阈值 + 保持/释放时间） |
| `gain-filter.c` | 95 | 简单增益（dB 倍数相乘） |
| `invert-audio-polarity.c` | 48 | 反转声道极性（逐采样取负，用于解决相位抵消问题） |

### 公共代码

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-filters.c` | 78 | 模块入口，`obs_module_load` 里 `extern` 声明并 `obs_register_source` 全部 24 个滤镜（含 v1/v2 双版本、`HAS_NOISEREDUCTION` 条件编译） |
| `obs-filters-config.h.in` | 12 | CMake `configure_file` 生成的编译期开关，只有一个宏 `HAS_NOISEREDUCTION`（决定 noise-suppress 是否参与编译） |

（`rnnoise/` 是完整 vendored 进来的第三方 RNNoise 神经网络降噪库源码（含训练脚本 `rnn_train.py`），只被
`noise-suppress-filter.c` 在 `LIBRNNOISE_ENABLED` 时链接使用，不逐文件展开。）

### ⭐ 重点文件展开

#### `color-key-filter.c`
- **做什么**：按"跟指定颜色的距离"抠像——`similarity`/`smoothness` 控制抠除范围的软硬边缘，`contrast`/`brightness`/`gamma`
  做键控前的色彩预处理。v1（`color_key_filter`，:440）用整数设置和 8-bit 语义；v2（`color_key_filter_v2`，:453）
  改成浮点 0-1 语义并声明 `OBS_SOURCE_SRGB`，渲染前还会跳过 scRGB 扩展色域（`obs_source_skip_video_filter`，v2 渲染
  函数 :292-328 里对 `GS_CS_709_EXTENDED` 的特判）。
- **关键入口**：`color_key_render_v1`（:272）、`color_key_render_v2`（:292）、`color_key_get_color_space`（:421）。
- **看点**：这是本组里"视频滤镜标准形状"最干净的样板——`create` 里加载 `.effect` + 缓存 `gs_eparam_t`，
  `render` 里 `obs_source_process_filter_begin/end` 两行包一个 `gs_effect_set_*` 中间层，`destroy` 对称释放。
  v1/v2 双版本共存、`video_get_color_space` 按上游可用色彩空间协商（而不是写死 sRGB）这两个套路，
  在 `chroma-key`/`luma-key`/`mask`/`color-correction` 里几乎逐字重复，读透这一个文件基本就读懂了这一整类。

#### `noise-suppress-filter.c`
- **做什么**：音频滤镜的标准形状——`filter_audio`（:397）不碰纹理，纯 CPU 处理 planar float PCM。核心技巧是
  **10ms 定长分段**（`BUFFER_SIZE_MSEC`）：输入音频先原样存进按声道分开的 `deque`（`input_buffers[]`），攒够一段
  就 `process()`（:360）跑一次 SpeexDSP 或 RNNoise，处理完的结果再存进 `output_buffers[]`；对外吐出的包大小
  仍按上游原始包的帧数切（用一个单独的 `info_buffer` 记录每个输入包的 `frames`/`timestamp`），所以内部分段处理
  对上下游完全透明。RNNoise 要求固定 48kHz/480 帧，采样率不是 48k 时会即时 resample 两次（`process_rnnoise`，:297）。
- **关键入口**：`noise_suppress_filter_audio`（:397）、`process`（:360）、`process_speexdsp`（:266）、
  `process_rnnoise`（:297）。
- **看点**：`filter_audio` 类回调不需要 `obs_source_process_filter_*` 那套纹理协议，直接原地改数据、返回指针
  （或攒不够时返回 `NULL` 让上游"这次没有输出"）——音频滤镜比视频滤镜简单在这里。另外它是"按能力条件编译"的
  好例子：`LIBSPEEXDSP_ENABLED`/`LIBRNNOISE_ENABLED`/`HAS_NOISEREDUCTION` 三层宏嵌套，某个依赖库缺失时功能优雅降级
  而不是编译失败。

---

## obs-transitions/　`plugins/obs-transitions/`

**职责**：场景切换动画。和滤镜不同，转场不是挂在某一个源上、串行加工它的输出，而是**同时持有两个源**
（A=正在退场的旧场景、B=正在进场的新场景），按进度 `t∈[0,1]` 把两路画面/声音混合成一路输出。

**机制**：转场源的 `.type = OBS_SOURCE_TYPE_TRANSITION`（`libobs/obs-source.h:36`）。核心状态机和纹理拿取都在
`libobs/obs-source-transition.c`（本篇范围外，但转场插件全靠它），最关键的几个入口：

- `obs_transition_start`（:327）——设定 duration、把当前场景存进 `transition_sources[0]`（A）、目标场景存进 `[1]`（B），
  启动进度计时。
- `obs_transition_video_render` / `_video_render2`（:668/:673）——插件的 `video_render` 回调里唯一要调的函数：
  它内部把 A、B 两个子源各自 `render_child` 渲染进各自的中间纹理（:717-720 `render_child` + `get_texture`），
  取到 `tex[0]`/`tex[1]` 后，回调插件传入的 `obs_transition_video_render_callback_t`（形如
  `void(*)(void *data, gs_texture_t *a, gs_texture_t *b, float t, uint32_t cx, uint32_t cy)`），插件在这个回调里
  用自己的 `.effect` 把两张纹理和进度 `t` 混合、画到当前渲染目标——这就是转场插件真正要写的全部逻辑。
- 音频侧对称：`obs_transition_audio_render`（:933）按插件提供的 `mix_a(t)`/`mix_b(t)` 两个权重函数把两路 PCM
  加权混合（交叉淡入淡出音量）。
- 固定时长转场（如 cut）走 `obs_transition_enable_fixed`（:1000），跳过一般的进度插值。

`obs-transitions.c` 里没有滤镜那种 v1/v2 版本演进，7 个转场各自只有一个 `obs_source_info`。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-transitions.c` | 28 | 模块入口，注册 7 个转场：cut/fade/swipe/slide/stinger/fade_to_color/luma_wipe |
| `easings.h` | 11 | 共享的三次缓动函数 `cubic_ease_in_out`，被 slide/swipe 引用 |
| `transition-cut.c` | 76 | 硬切：`obs_transition_enable_fixed(source, true, 0)`，0 时长，不需要自己的着色器 |
| `transition-fade.c` ⭐ | 148 | 经典交叉淡化（crossfade），转场的标准形状代表，见下方展开 |
| `fade_transition.effect` | 98 | 对应着色器：`lerp(a, b, t)`，还处理了线性/非线性色彩空间两种混合路径 |
| `transition-fade-to-color.c` | 213 | 先淡到指定颜色、再从颜色淡出到新场景（比直接交叉淡化更"干净"，常用于转场遮挡瑕疵） |
| `fade_to_color_transition.effect` | 48 | 对应着色器 |
| `transition-swipe.c` | 167 | 硬边缘方向性擦除（一路直接推走另一路，无渐变过渡） |
| `swipe_transition.effect` | 45 | 对应着色器 |
| `transition-slide.c` | 171 | 滑动（两路画面像贴在一起的两张纸一起平移） |
| `slide_transition.effect` | 48 | 对应着色器 |
| `transition-luma-wipe.c` | 230 | 灰度蒙版擦除，`data/luma_wipes/` 内置一批灰度图案预设（形状擦除、百叶窗等） |
| `luma_wipe_transition.effect` | 63 | 按亮度蒙版阈值决定像素属于 A 还是 B，`softness` 控制过渡带宽度 |
| `transition-stinger.c` | 831 | 播放一段视频/带 matte 通道的素材作为转场（比如带 alpha 的动画），本组最大文件，内部管理两个子 `obs_source_t`（媒体源+matte 源） |
| `stinger_matte_transition.effect` | 86 | 用素材自带的亮度/alpha 通道当遮罩合成 A/B |

### ⭐ 重点文件展开

#### `transition-fade.c`
- **做什么**：最简单也最能代表转场"形状"的实现——`fade_video_render`（:92）只做一件事：调
  `obs_transition_video_render2(fade->source, fade_callback, NULL)`，把拿到两路纹理之后"怎么画"的全部逻辑
  丢给 `fade_callback`（:51）。`fade_callback` 里按 `a`/`b` 是否都存在选 3 种 technique
  （`Fade`/`FadeLinear`/`FadeSingle`，对应 `.effect` 里的三个 pixel shader）：两路都在时优先非线性
  （更符合人眼直觉的淡化观感），只有 sRGB 非线性空间时才用这条路，否则退化为线性淡化 `FadeLinear`；
  只有一路存在（转场刚开始/刚结束的边界情况）就退化成单路乘 `fade_val` 的 `FadeSingle`。
- **关键入口**：`fade_video_render`（:92）、`fade_callback`（:51）、`fade_audio_render`（:116）、
  `fade_video_get_color_space`（:123）。
- **看点**：转场插件完全不用关心"怎么把两个子场景渲染成纹理"——那是 `obs_transition_video_render2`
  （`libobs/obs-source-transition.c:673`）的活；插件只管拿到 `tex_a`/`tex_b` 之后的混合算法。
  这种"框架包办取数据，插件只写混合逻辑"的分工，和滤镜里 `obs_source_process_filter_begin/end`
  包办纹理往返、滤镜只管中间的 `gs_effect_set_*` 是同一种设计思路的两次复用。

---

## image-source/　`plugins/image-source/`

**职责**：静态图片、纯色、幻灯片三种最基础的输入源。它们的共同点，也是这个目录被单独拎出来讲的原因：
**都是同步源（非 async），不走异步帧缓冲**，和摄像头/媒体文件那种"独立线程解码、按时间戳推帧、核心按拍子挑帧"的
异步源（`OBS_SOURCE_ASYNC`/`OBS_SOURCE_ASYNC_VIDEO`）走的是完全不同的路径。

**同步源 vs 异步源的区别**：异步源（比如 `vlc-video` 见下文）把解码出来的每一帧通过 `obs_source_output_video`
推给核心，核心存进一个帧队列，渲染节拍到点时按时间戳"挑一帧"出来画（`ready_async_frame`，处理 fps 不匹配、
丢帧/等待）。**同步源完全没有这条队列**：`video_render` 回调本身就在渲染节拍里被直接调用，回调内部想画什么就
现画什么——`image-source.c` 的做法是常驻一张已经解码好的 GPU 纹理（`gs_image_file4_t`），每次 `video_render`
就是一行 `gs_draw_sprite`。没有"这一帧对不对得上当前时间戳"的问题，因为压根没有"帧"的概念，只有一张一直有效的纹理
（GIF 动画的帧号推进也是在 `image_source_tick` 里按挂钟时间自己算的，不经过异步帧队列）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `image-source.c` ⭐ | 407 | 静态图片/GIF 源，同步源代表，见下方展开 |
| `color-source.c` | 180 | 纯色源，`video_render` 直接 `gs_draw` 一个矩形，v1/v2/v3 三版（v3 加 `OBS_SOURCE_SRGB`） |
| `obs-slideshow-mk2.c` | 1176 | 幻灯片源当前版（v2，`slideshow_info_mk2`），内部按需创建/销毁 `image_source` 子源做实际解码 |
| `obs-slideshow.c` | 1071 | 幻灯片源旧版（v1，`OBS_SOURCE_CAP_OBSOLETE`），和 mk2 同一个 `.id = "slideshow"`、靠 `version` 区分 |

### ⭐ 重点文件展开

#### `image-source.c`
- **做什么**：文件在后台线程解码（`file_decoded` 原子标志位）、解码完成后把像素上传成 GPU 纹理
  （`texture_loaded` 标志位，`image_source_load_texture` :59），此后 `image_source_render`（:200）每次调用都只是
  判断纹理是否就绪、就绪则 `gs_draw_sprite(texture, 0, cx, cy)` 画一次——没有时间戳、没有队列、没有"这一帧属于
  谁"的判断。`image_source_tick`（:227）只做两件轻量的事：GIF 动画推进（若纹理未加载则等解码线程）、
  每秒检查一次文件 mtime 有没有变（文件被外部程序覆盖时自动重载）。
- **关键入口**：`image_source_render`（:200）、`image_source_tick`（:227）、`image_source_load`（:88）、
  `image_source_create`（:168）。
- **看点**：`struct obs_source_info image_source_info`（:363）的 `output_flags` 只有
  `OBS_SOURCE_VIDEO | OBS_SOURCE_SRGB`——**没有 `OBS_SOURCE_ASYNC`**，这一个标志位的缺席就是"同步源"身份的全部证据。
  对照组见 `plugins/vlc-video/vlc-video-source.c:1149` 的 `vlc_source_info`，`output_flags` 里明确写了
  `OBS_SOURCE_ASYNC_VIDEO`——同一份 `obs_source_info` 协议，靠这一个位决定核心要不要为它维护一整套帧队列/挑帧逻辑。
  想在 WorkOBS/libwl 里加"图片源"这种不需要独立解码时钟的源时，这个文件就是最省事的参照。

---

## obs-text/　`plugins/obs-text/`

**职责**：Windows 专属的文字源，用系统自带的 **GDI+**（`Gdiplus` 命名空间）渲染文字到位图再传上 GPU，
不依赖 FreeType，字体渲染质量和系统原生输入法/字体渲染保持一致，代价是不跨平台。

| 文件 | 行数 | 功能 |
|---|---|---|
| `gdiplus/obs-text.cpp` | 1195 | 唯一实现文件，`obs_module_load` 里用 C++ lambda 直接构造并注册 3 个版本的 `obs_source_info`（v1/v2 都带 `OBS_SOURCE_CAP_OBSOLETE`，v3 是当前版本、去掉了该标志） |

三版差异很小：v1→v2 只是 `get_defaults` 传的版本号参数变了（:1170-1174），v2→v3 摘掉了 obsolete 标志、
`create` 换成 `legacy=false` 的构造路径（:1176-1181）——同一个滤镜/源反复出现的"渐进式升级、旧版本仍可回放旧工程"
套路在这里又出现了一次。

与 `text-freetype2/` 的关系见下一节。

---

## text-freetype2/　`plugins/text-freetype2/`

**职责**：跨平台文字源，基于 **FreeType2** 库做字形栅格化，`find-font-*` 系列文件负责在不同操作系统上
枚举本机已安装字体（Windows 走注册表/字体目录，macOS 走 Cocoa `NSFontManager`，Linux 走 fontconfig）。

在 macOS 上开发时要认准：`find-font-cocoa.m` 是本目录**唯一的 macOS 专属实现**，其余平台文件互不编译。

| 文件 | 行数 | 功能 |
|---|---|---|
| `text-freetype2.c` | 616 | 源的生命周期 + `obs_source_info` 注册（v1/v2，Windows 上 v2 额外带 `OBS_SOURCE_DEPRECATED`） |
| `text-freetype2.h` | 86 | 上面的公开声明（字形缓存结构 `cacheglyphs` 等定义在此） |
| `text-functionality.c` | 533 | 实际的文字排版/换行/描边/渐变等绘制逻辑 |
| `find-font.c` | 407 | 平台无关的字体列表缓存（序列化到磁盘，避免每次启动都重新扫描字体） |
| `find-font.h` | 41 | 上面的公开声明（`struct font_path_info` 定义在此） |
| `find-font-windows.c` | 261 | Windows 字体枚举实现 |
| `find-font-iconv.c` | 128 | Mac TrueType 内部编码 → 系统码页转换表（`iconv` 版，非 Windows 平台用） |
| `find-font-cocoa.m` | 108 | **macOS 字体枚举**：用 `NSFontManager`/`FT_New_Face` 枚举系统字体并写入共享的 `font_list` |
| `find-font-unix.c` | 73 | Linux fontconfig 字体枚举实现（本文件在这几个平台变体里最短，`free_os_font_list` 甚至是空实现） |
| `obs-convenience.c` | 95 | 顶点缓冲创建/绘制的小工具函数（`gs_vertbuffer_t` 封装） |
| `obs-convenience.h` | 44 | 上面的公开声明 |
| `text_default.effect` | 39 | 文字纹理的绘制着色器（简单的纹理采样+可选顶点色） |

**与 `obs-text/` 的取舍**：`text-freetype2.c` 的 v2 `obs_source_info`（`freetype2_source_info_v2`）在 Windows 上
额外声明了 `OBS_SOURCE_DEPRECATED` 标志（`#ifdef _WIN32` 分支）——即 Windows 上官方建议优先用 `obs-text` 的
GDI+ 实现（原生字体渲染质量更好），FreeType2 版本保留只是为了兼容已有工程；在 macOS/Linux 上，FreeType2 是
**唯一**的文字源实现，没有这个折扣。

---

## vlc-video/　`plugins/vlc-video/`

**职责**：基于系统安装的 **libvlc**（动态加载，非静态链接）实现的播放列表源，能放一串媒体文件/网络流，
支持随机播放、循环、字幕轨道选择。是本篇范围内**异步源**的对照组——直接对照 `image-source.c` 读收获最大。

| 文件 | 行数 | 功能 |
|---|---|---|
| `vlc-video-source.c` | 1170 | 源实现主体：播放列表管理、`libvlc_media_player` 回调转 `obs_source_output_video/audio` |
| `vlc-video-plugin.c` | 244 | 模块入口 + **运行时动态加载 libvlc**（`dlopen`/`LoadLibrary`，不是编译期链接，找不到 libvlc 时插件静默不可用） |
| `vlc-video-plugin.h` | 216 | 上面全部 libvlc 函数指针类型的声明（`typedef` 出的函数指针表） |

`vlc_source_info`（`vlc-video-source.c:1146`）的 `output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_AUDIO |
OBS_SOURCE_DO_NOT_DUPLICATE | OBS_SOURCE_CONTROLLABLE_MEDIA`——`ASYNC_VIDEO` 意味着它和摄像头/媒体文件一样，
自己按 libvlc 的回调节奏把帧推给核心，核心走异步帧缓冲挑帧；`CONTROLLABLE_MEDIA` 则暴露了 `media_play_pause`
等播放控制回调，让它能接入 OBS 的"媒体源"统一播放条 UI。

---

## nv-filters/　`plugins/nv-filters/`

**职责**：Windows 专属，基于 NVIDIA Maxine SDK 的 GPU 加速滤镜——视频侧是绿幕抠像/背景模糊（不需要真绿幕，
神经网络分割人像），音频侧是 AI 降噪，都需要 N 卡 + 对应运行时库，加载失败时优雅跳过注册。

| 文件 | 行数 | 功能 |
|---|---|---|
| `nvidia-videofx-filter.c` | 1270 | 视频滤镜：注册 3 个 `obs_source_info`（绿幕抠像 `nv_greenscreen_filter`、模糊 `nv_blur_filter`、背景虚化 `nv_background_blur_filter`），本组最大文件 |
| `nvidia-audiofx-filter.c` | 901 | 音频滤镜：NVIDIA AI 降噪/去混响（`NVAFX_EFFECT_DENOISER`/`DEREVERB`），结构和 `noise-suppress-filter.c` 神似（同样是攒定长分段喂给 SDK） |
| `nvvfx-load.h` | 749 | NVIDIA VideoFX SDK 全部函数指针类型 + 运行时动态加载声明 |
| `nvafx-load.h` | 290 | NVIDIA AudioFX SDK 对应声明 |
| `nv-filters.c` | 51 | 模块入口，`LIBNVAFX_ENABLED`/`LIBNVVFX_ENABLED` 条件编译，加载 DLL 成功才注册对应滤镜 |
| `nv_sdk_versions.h` | 2 | 只有 SDK 版本号宏，无实际逻辑 |
| `rtx_greenscreen.effect` / `rtx_blur.effect` | 183 / 190 | 抠像/虚化结果和原始画面的合成着色器（推理本身在 SDK 内部完成，这里只做合成） |
| `color.effect` | 95 | 与 `obs-filters/data/color.effect` 内容相同的 sRGB 转换 `#include` helper（各插件各自拷贝一份，不共享） |

---

## 阅读建议

1. 先读 `libobs/obs-source.c:2906` 的 `render_video` 和 `libobs/obs-source-transition.c:668` 的
   `obs_transition_video_render2`——这两处是"滤镜链"和"转场"两套机制的**唯一**分发入口，不读它们、直接看插件代码
   容易只见树木不见森林。
2. 视频滤镜只读一个够：`color-key-filter.c`。读完它，`chroma-key`/`luma-key`/`color-correction`/`mask` 全是同一个
   模子（加载 `.effect` → 缓存 `gs_eparam_t` → `begin`/设参/`end`）换皮肤，不用逐个通读。
3. 音频滤镜同理只读 `noise-suppress-filter.c`；`compressor`/`expander`/`limiter`/`noise-gate` 是同一套
   "定长分段 + 阈值/包络处理"思路的简化版，读完降噪这个最复杂的，其余扫一眼 `filter_audio` 函数体就够。
4. 转场读 `transition-fade.c` + `transition-cut.c` 两个最短的就能建立直觉；`transition-stinger.c`（831 行）
   是特例——它内部管理两个真正的子 `obs_source_t`（媒体源播放转场素材），复杂度来自"转场里还嵌了一个媒体播放器"，
   不是转场机制本身复杂，可以最后再看或直接跳过。
5. `image-source.c` 和 `vlc-video-source.c` 建议对照读：一个完全没有异步帧队列，一个完全依赖它——这组对比
   比读十遍文档更能讲清楚"同步源"和"异步源"到底差在哪。
6. `obs-text/` 和 `text-freetype2/` 不需要都读全；如果只关心 macOS（本项目场景），`text-freetype2.c` +
   `find-font-cocoa.m` 就够，`obs-text.cpp`（Windows-only）和 `find-font-windows.c` 可以跳过。
7. `nv-filters/` 整个目录是 Windows + N 卡专属，macOS 上完全用不到，除非想借鉴"抠像结果与原画面合成"的
   着色器写法（`rtx_greenscreen.effect`），否则可以整体跳过。
