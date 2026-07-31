# OBS 目录导航 · libobs/graphics（图形抽象层与特效系统）

> 源码范围：`libobs/graphics/`（含 `libobs/graphics/libnsgif/`）｜ 源文件 42 个（本目录 40 + libnsgif 2）｜ 基于 obs-studio commit `f2db097`（2026-07-09）
> 返回总索引：[README.md](README.md)

## 本篇速查

想找什么 → 去哪：

| 我想看… | 去这里 |
|---|---|
| 图形调用怎么转发到 OpenGL / D3D11 / Metal 后端 | [`graphics-internal.h`](#graphics-internalh) + [`graphics-imports.c`](#graphics-importsc) |
| `gs_*` 公开 API 全清单、纹理格式/色彩空间枚举 | `graphics.h` |
| 图形子系统创建、线程上下文、矩阵栈、立即模式画顶点 | [`graphics.c`](#graphicsc) |
| `.effect` 文件怎么被解析成后端能吃的 shader | [`effect-parser.c`](#effect-parserc) |
| 运行时 `gs_effect_set_texture` / `technique / pass` 循环 | [`effect.c`](#effectc) |
| 后端把 HLSL 风格 shader 翻成 GLSL/MSL 时用的公共 lexer | [`shader-parser.c`](#shader-parserc) |
| CPU 内存 → 纹理上传、纹理 → CPU 回读（暂存 stage） | `graphics.c:1187` / `graphics.c:1902`，见[第 3 组](#3-渲染资源对象纹理上传与暂存) |
| 渲染到纹理（离屏合成，OBS 里到处在用） | [`texture-render.c`](#texture-renderc) |
| macOS 上 `gs_texture` 怎么接 IOSurface / CVPixelBuffer | [macOS 专项](#macos-专项gs_texture-与-iosurface--cvpixelbuffer-的对接点) |
| PNG/JPEG/静态图解码、动图 GIF 播放 | [`image-file.c`](#image-filec) + `graphics-ffmpeg.c` + `libnsgif/` |
| 向量/矩阵/四元数/AABB 数学 | [第 4 组 数学库](#4-数学库vec--matrix--quat--) |
| sRGB 传输函数、premultiply alpha 的标量实现 | `srgb.h` |

---

## 一句话职责

`libobs/graphics/` 是 **图形抽象层（graphics abstraction layer）**：它定义 `gs_*` 这套与显卡 API 无关的公开接口
（纹理、顶点缓冲、shader、渲染目标、混合状态、矩阵栈），**但它自己一行 GPU 代码都不写**。
真正的实现在三个平级的兄弟目录里：`libobs-opengl/`（C，跨平台）、`libobs-d3d11/`（C++，Windows）、
`libobs-metal/`（Swift，macOS）。上层（`libobs/obs-*.c`、所有滤镜/源插件）只 include `graphics.h`，
调 `gs_draw_sprite()` 这种函数；本目录负责把调用**转发**给当前加载的那个后端。

绑定机制不是虚函数表也不是编译期宏，而是**运行时 `dlopen` + `dlsym` 填一张函数指针表**：
`obs.c:490` 用配置里的模块名（`"libobs-opengl"` / `"libobs-d3d11"` / `"libobs-metal"`）调 `gs_create()`，
`gs_create()`（`graphics.c:198`）`os_dlopen` 该动态库，再由 `load_graphics_imports()`（`graphics-imports.c:40`）
把 **190 个符号**（实测：157 个 `GRAPHICS_IMPORT` 必需 + 33 个 `GRAPHICS_IMPORT_OPTIONAL` 可选，含各平台分支）
逐个 `os_dlsym` 塞进 `struct gs_exports`（`graphics-internal.h:30`-`:285`）。
后端那侧的符号声明分两半：`device_*` / `gpu_*` 这 101 个由 `device-exports.h` 统一 `EXPORT` 出来（后端 include 它对齐签名）；
而 `gs_texture_destroy` / `gs_shader_set_bool` 这类**对象方法族**不在 `device-exports.h` 里——
它们的签名直接取自 `graphics.h`，**函数名与抽象层的公开 API 完全同名**（见下文 [`graphics-imports.c`](#graphics-importsc) 的看点）。

本目录里另有一块**跟 GPU 无关**的自研成果：`.effect` 特效文件的**语言前端**（`effect-parser.c` + `shader-parser.c`）。
它把一个 `.effect` 拆成"每 technique 每 pass 一对 vertex/pixel shader 文本"，交给后端各自翻译。

---

## libobs/graphics/ 分组导览

### 1. 图形子系统门面与设备抽象

**职责**：整个图形层的入口和"电话交换机"。持有唯一的 `graphics_subsystem` 对象（设备句柄 + 函数指针表 +
矩阵栈/视口栈/混合状态栈 + effect 缓存链表），并把上层 `gs_xxx()` 调用逐个翻译成
`graphics->exports.device_xxx(graphics->device, ...)`。同时自己实现了一批**纯 CPU 侧的便利层**：
矩阵栈、立即模式（immediate mode）顶点累积、sprite 顶点缓冲复用、四边形绘制辅助。

| 文件 | 行数 | 功能 |
|---|---|---|
| `graphics.c` ⭐ | 3312 | 全部 `gs_*` 公开函数的实现体：设备创建/销毁、线程上下文进出、矩阵栈、立即模式、sprite 绘制、纹理上传，以及对 `exports` 表的逐一转发 |
| `graphics.h` | 1025 | 公开 API 与全部枚举/结构体：`gs_color_format`（:56）、`gs_color_space`（:82）、`gs_blend_type`（:108）、纹理 flags `GS_DYNAMIC`/`GS_RENDER_TARGET`（:462-469）、所有不透明句柄 typedef（:285-303） |
| `graphics-internal.h` ⭐ | 335 | **函数指针表 `struct gs_exports`（:30）** 与 **`struct graphics_subsystem`（:300）**；平台分支在 `#ifdef __APPLE__`（:221）/ `_WIN32`（:228）/ Linux（:262）段内 |
| `graphics-imports.c` ⭐ | 259 | 唯一的绑定逻辑：`GRAPHICS_IMPORT` 宏（:23）逐符号 `os_dlsym`，缺一个就整体失败；`GRAPHICS_IMPORT_OPTIONAL`（:35）允许缺失（用于 NV12/P010、adapter 枚举等可选能力） |
| `device-exports.h` | 177 | 后端必须导出的 `device_*` / `gpu_*` 符号声明清单，共 101 条 `EXPORT`（`EXPORT const char *device_get_name(void);` …）。后端 include 它来对齐签名。⚠️ **不含** `gs_texture_destroy` 那类对象方法 |
| `input.h` | 34 | 空壳。文件头就写着 `/* TODO: incomplete/may not be necessary */`，只声明了一个 `input_getbuttonstate`，无实现。可直接跳过 |

### 2. 特效 / 着色器系统（`.effect` 语言）

**职责**：OBS 自研了一套 HLSL 方言 `.effect`（`libobs/data/*.effect` 有 21 个，全仓库 52 个），
一个文件里同时装参数、sampler_state、结构体、函数、以及 `technique { pass { vertex_shader = …; pixel_shader = …; } }`。
这一族做两件事：**(a) 解析 `.effect` 并为每个 pass 拼出一份自包含的 shader 文本**（`effect-parser.c`）；
**(b) 运行时按 technique/pass 切换 shader 并上传参数**（`effect.c`）。
`shader-parser.c` 是"下半场"——**给后端用的**公共 lexer，三个后端都靠它把 HLSL 风格文本翻成自己的语言。

| 文件 | 行数 | 功能 |
|---|---|---|
| `effect-parser.c` ⭐ | 1972 | `.effect` → 每 pass 一对 shader 文本的编译器。上半 `ep_parse_*` 建 AST，下半 `ep_write_*`/`ep_compile_*` 按依赖闭包重新拼装 shader 源码 |
| `effect-parser.h` | 290 | `ep_param`/`ep_struct`/`ep_sampler`/`ep_pass`/`ep_technique`/`ep_func` 中间表示，以及 `struct effect_parser`（:253，内嵌 `cf_parser`）。文件头 :35-38 有作者写的设计说明 |
| `effect.c` ⭐ | 556 | 运行时侧：`gs_effect_loop`（:60）、`gs_technique_begin/end`（:101/:112）、`gs_technique_begin_pass`（:195）、参数 setter 全家（`gs_effect_set_texture` 等）、`upload_shader_params`（:146）脏标记上传 |
| `effect.h` | 190 | `gs_effect_param`（:47）/ `pass_shaderparam`（:89）/ `gs_effect_pass`（:94）/ `gs_effect_technique`（:121）/ `gs_effect`（:146）的真实结构体（对外只是不透明句柄）。`gs_effect_param` 带 `cur_val`/`default_val`/`changed` 三件套 |
| `shader-parser.c` ⭐ | 717 | **后端共用**的 shader 词法/语法分析：抽出 uniform、sampler_state、结构体成员的 semantic 映射（`POSITION`/`TEXCOORD0`…）、函数签名。`shader_parse`（:691）是入口 |
| `shader-parser.h` | 273 | `shader_var`（:48）/`shader_struct`/`shader_func`/`shader_sampler` 与 `struct shader_parser`；`get_shader_param_type` / `get_sample_filter` / `get_address_mode` 三个字符串→枚举转换也在这里导出（:27-:29）。文件头 :32-:36 有作者的定位说明 |

### 3. 渲染资源对象、纹理上传与暂存

**职责**：⚠️ 与直觉相反——**这个目录里没有 `texture.c` / `vertexbuffer.c` / `stagesurf.c` / `samplerstate.c` / `zstencil.c`**。
所有资源对象的"创建/销毁/查询"在 `graphics.c` 里只是薄薄一层转发（做完空指针校验和少量 CPU 侧准备就交给后端），
真正的对象定义在 `libobs-opengl/gl-texture2d.c`、`libobs-d3d11/d3d11-texture2d.cpp`、`libobs-metal/metal-texture2d.swift`。
本组唯一独立成文件的，是**渲染到纹理**这个高频组合操作。

| 文件 | 行数 | 功能 |
|---|---|---|
| `texture-render.c` ⭐ | 151 | `gs_texrender_*`：把"建 render target 纹理 + 切换 target/zstencil + 存取旧 target"打包成一个可复用对象，OBS 里每个滤镜、每个源的缓存渲染都走它 |
| （资源对象的转发层） | — | 都在 `graphics.c`：纹理 `:1384/:1506/:1537`、zstencil `:1549`、暂存面 `:1559`、sampler `:1569`、shader `:1579/:1589`、顶点缓冲 `:1599`、索引缓冲 `:1643`、GPU 计时器 `:1658` |
| （上传 / 回读入口） | — | `gs_texture_set_image`（`graphics.c:1187`，CPU→GPU，逐行 memcpy 并处理 flip）；`gs_stage_texture`（`:1902`）+ `gs_stagesurface_map`（`:2629`）（GPU→CPU）；`gs_copy_texture[_region]`（`:1880/:1890`，GPU→GPU） |

### 4. 数学库（vec / matrix / quat / …）

**职责**：一套朴素的 3D 数学，`vec3`/`vec4` 用 `__m128` 联合体做 SSE 对齐。整套是"够用就好"的自研实现，
没有依赖 GLM 之类。绝大部分函数以 `static inline` 写在头文件里，`.c` 只放不便内联的部分——所以**看头文件就够了**。

| 文件 | 行数 | 功能 |
|---|---|---|
| `vec2.h` / `vec2.c` | 148 / 51 | 2D 向量（`x, y`）。UV、屏幕坐标常用 |
| `vec3.h` / `vec3.c` | 224 / 87 | 3D 向量，内部实为 4 float + `__m128 m`；另有针对 `plane`/`matrix3`/`matrix4`/`quat` 的一组变换函数 |
| `vec4.h` / `vec4.c` | 241 / 41 | 4D 向量，同样 `__m128`；`gs_clear` 的颜色、shader 的 float4 参数都用它 |
| `quat.h` / `quat.c` | 170 / 215 | 四元数。头部注释点明用途：旋转插值且不受万向锁（gimbal lock）影响 |
| `axisang.h` / `axisang.c` | 65 / 38 | 轴角（axis-angle）表示，主要作为四元数的输入形式 |
| `matrix3.h` / `matrix3.c` | 98 / 138 | 「3x4 矩阵」（注释原话）：3 个基向量 + 1 个平移向量，共 4 个 `vec3` |
| `matrix4.h` / `matrix4.c` | 102 / 333 | 4x4 矩阵，4 个 `vec4`。`graphics.c` 的矩阵栈、view/proj 都是它 |
| `plane.h` / `plane.c` | 85 / 151 | 平面（法向 + 距离），配合 AABB 做相交测试 |
| `bounds.h` / `bounds.c` | 108 / 314 | 轴对齐包围盒 AABB（注释原话 "Axis Aligned Bounding Box"）：相交、包含、变换、与射线/平面求交 |
| `math-defs.h` | 45 | `close_float` 等浮点比较小工具、`M_PI` 之类常量 |
| `math-extra.h` / `math-extra.c` | 61 / 131 | 作者自己都说"不知道放哪儿"的杂项：极坐标↔笛卡尔、`calc_torque`（平滑趋近，做动画缓动用）、`get_percentage`、`rand_float` |
| `half.h` | 100 | 半精度 float16 ↔ float32 转换。**来自 Microsoft 的 MIT 授权代码**（文件头第二段版权块），HDR/P010 路径要用 |
| `basemath.hpp` | 3 | 只有 `#pragma once` 和 `/* TODO: C++ math wrappers */`。空文件，跳过 |

### 5. 图像与素材加载

**职责**：把磁盘上的图片文件变成一块 CPU 内存（或一张纹理）。分工是：`graphics-ffmpeg.c` 用 FFmpeg 解**静态图**
（PNG / JPEG 等，凡 FFmpeg 该 build 能解的都行；Windows 上另有一条 WIC 路径专门处理 HDR），`libnsgif/` 解**动画 GIF**，
`image-file.c` 是给上层（`image-source` 插件、场景背景等）用的门面 + GIF 逐帧播放的时间轴。

| 文件 | 行数 | 功能 |
|---|---|---|
| `image-file.c` ⭐ | 420 | `gs_image_file[2/3/4]_*` 门面：静态图走 `gs_create_texture_file_data*`，GIF 走 `init_animated_gif`（:72）预解码+帧缓存，`tick`（:346）按 elapsed 算当前帧、`update_texture`（:390）才真正上传 |
| `image-file.h` | 124 | `gs_image_file` → `2`（加内存占用统计）→ `3`（加 alpha 模式）→ `4`（加 `gs_color_space`）的四层套娃结构，典型的**ABI 兼容式版本演进**：老结构体永远是新结构体的第一个成员 |
| `graphics-ffmpeg.c` | 787 | FFmpeg 静态图解码：`gs_create_texture_file_data`（:567）/`2`（:754）/`3`（:761）；含 EXIF 方向纠正 `ffmpeg_image_orient`（:296）、格式/色域重整 `ffmpeg_image_reformat_frame`（:337）；`#ifdef _WIN32` 段另有 WIC 路径处理 PQ→scRGB（:593/:624） |
| `libnsgif/libnsgif.c` | 1291 | **第三方 vendored 库**：NetSurf 浏览器的渐进式动画 GIF 解码器（MIT）。API 只 4 个：`gif_create` / `gif_initialise` / `gif_decode_frame` / `gif_finalise`（`libnsgif.h:133`-`:136`）。OBS 侧的胶水是 `image-file.c:26-56` 那一组 `bi_def_bitmap_*` 位图分配回调（未与上游逐行 diff，未见 OBS 改动解码逻辑的痕迹） |
| `libnsgif/libnsgif.h` | 142 | 上面那份的接口；`gif_animation` 结构体被直接嵌进 `struct gs_image_file` |
| `libnsgif/LICENSE.libnsgif`、`.clang-format` | — | 授权文本；`.clang-format` 用于把第三方代码排除在 OBS 格式化规则之外 |

### 6. 其它小工具

| 文件 | 行数 | 功能 |
|---|---|---|
| `srgb.h` | 177 | 纯 `static inline` 的色彩工具箱：sRGB 传输函数（:27/:32）、u8↔float（:37/:50）、premultiply alpha 的标量 + `__restrict` + 批量循环各种版本（:91-172）。CPU 侧处理带 alpha 图片时会热到 |

---

## ⭐ 重点文件展开

### `graphics.c`

- **做什么**：整个图形层的**唯一实现文件**（3312 行里大半是格式化得极规整的转发样板）。
  持有 `static THREAD_LOCAL graphics_t *thread_graphics`（`:37`）——**当前线程的图形上下文**，
  所有 `gs_*` 函数都从这个 TLS 拿 `graphics`，所以调用者不必传句柄。
  典型转发体长这样（以 `gs_draw` 为例，`:1932`）：取 `thread_graphics` → `gs_valid()` 校验 → 调 `exports.device_draw(...)`。
- **关键入口**：
  - `gs_create`（`:198`）：`os_dlopen(module)`（`:206`）→ `load_graphics_imports`（`:212`）→ `exports.device_create`（`:215`）→ `graphics_init`（`:160`）。
    `graphics_init` 里预建了四个复用顶点缓冲（immediate、sprite、flipped sprite、subregion，见 `:95` 与 `:117`）并设定默认混合
    `SRCALPHA/INVSRCALPHA + ONE/INVSRCALPHA`（`:180`）——**这就是 OBS 全局默认的预乘友好混合状态**。
  - `gs_enter_context` / `gs_leave_context`（`:275`/`:295`）：互斥锁 + 引用计数 + TLS 三合一。
    进同一个 context 可重入（`ref` 自增），进另一个 context 会先把当前的退干净。渲染线程外要碰 GPU 必须先包一层。
  - 矩阵栈 `gs_matrix_push/pop/mul/…`（`:388`-`:566`）：CPU 侧维护 `DARRAY(struct matrix4)`，OpenGL 固定管线时代的写法保留至今。
  - **立即模式（immediate mode）** `gs_render_start`（`:576`）/ `gs_vertex3f` / `gs_render_stop`（`:609`）/ `gs_render_save`（`:670`）：
    往 `DARRAY(vec3) verts` 里攒顶点，最多 `IMMEDIATE_COUNT`＝512 个（`:69`），`stop` 时 flush 进预建的 `immediate_vertbuffer` 再 draw。
    UI 画选框、辅助线全靠它。`gs_render_save` 则把攒好的顶点固化成一个持久 vertbuffer。
  - `gs_draw_sprite` / `gs_draw_sprite_subregion` / `gs_draw_quadf`（`:1080`/`:1085`/`:1039`）：
    重建预建 sprite 缓冲的 4 个顶点后 `device_draw`。**OBS 里 99% 的画面合成就是在画带纹理的四边形**。
  - `gs_effect_create_from_file`（`:838`）：**effect 按文件路径全局缓存**，见 `find_cached_effect`（`:825`）——
    单向链表 `graphics->first_effect` 线性查找，命中直接返回同一个 `gs_effect *`。所以多个滤镜实例共享一份编译产物，
    也意味着 **effect 参数是每帧重设、不能跨帧持有**（`gs_technique_end` 会把所有 `cur_val` 清空，见 `effect.c:112`）。
- **看点**：这是一份"薄门面 + 运行时函数指针"抽象的教科书样本。值得学的三个取舍：
  ①用 TLS 保存上下文，换来了极干净的无句柄 API，代价是跨线程用图形必须显式 enter/leave；
  ②所有转发前统一走 `gs_valid_p*` 宏（`:60`-`:67`，底层是 `gs_obj_valid` `:40` 与 `gs_valid` `:50`）做空指针与上下文校验，失败只 `blog(LOG_DEBUG)` 不崩——
  对插件生态友好，但也会掩盖 bug；③把矩阵栈、立即模式、sprite 这类**纯 CPU 逻辑上提到抽象层**，
  三个后端就不用各写一遍。你做 WorkOBS 时，这一层的边界划法可以直接照抄。

### `graphics-internal.h`

- **做什么**：定义 `struct gs_exports`（`:30`-`:285`）——**后端契约的机器可读形式**，以及
  `struct graphics_subsystem`（`:300`-`:335`）——图形层的全部状态。
- **关键入口**：
  - `gs_exports` 按类别分段：`device_*`（设备与全局状态，约 95 个）、`gs_swapchain_*`、`gs_texture_*`、
    `gs_cubetexture_*`、`gs_voltexture_*`、`gs_stagesurface_*`、`gs_zstencil_*`、`gs_samplerstate_*`、
    `gs_vertexbuffer_*`、`gs_indexbuffer_*`、`gs_timer_*`、`gs_shader_*`，末尾是平台分支。
  - **平台分支**：`#ifdef __APPLE__`（`:221`-`:226`）段只有 4 个字段——
    **`device_texture_create_from_iosurface`**（`:223`）、`device_texture_open_shared`（`:224`）、
    **`gs_texture_rebind_iosurface`**（`:225`）、`device_shared_texture_available`（`:226`）；
    `#elif _WIN32`（`:228`）段有 20+ 个（GDI 纹理、DXGI 桌面复制 duplicator、共享句柄、设备丢失回调）；
    Linux 段（`:262`）是 dmabuf/pixmap/syncobj。
  - `struct graphics_subsystem`（`:300`）字段值得逐个看：`module`+`device`+`exports` 是后端三件套；
    `viewport_stack`/`matrix_stack`/`blend_state_stack` 是三个状态栈；
    `sprite_buffer`/`flipped_sprite_buffer`/`subregion_buffer`/`immediate_vertbuffer` 是复用顶点缓冲；
    `first_effect` + `effect_mutex` 是 effect 缓存；`linear_srgb`（`:334`）是全局线性 sRGB 开关。
- **看点**：注意 macOS 分支只有 4 个字段——**Apple 平台的零拷贝共享全部收敛到 IOSurface 这一个概念上**，
  比 Windows 那套（GDI / NT handle / keyed mutex / duplicator）干净得多。这对你在 macOS 上做合成是好消息。

### `graphics-imports.c`

- **做什么**：259 行、只有一个函数 `load_graphics_imports`（`:40`），把后端动态库里的符号逐个 `os_dlsym`
  填进 `gs_exports`。**这就是"抽象层 ↔ 后端"的全部绑定机制，没有别的**。
- **关键入口**：
  - `GRAPHICS_IMPORT(func)` 宏（`:23`）：`exports->func = os_dlsym(module, #func)`，
    取不到就 `success = false` 并打 `LOG_ERROR` 报出缺失符号名。**必需符号，缺一个整个后端加载失败**。
  - `GRAPHICS_IMPORT_OPTIONAL(func)` 宏（`:35`）：只赋值，不检查。给可选能力用：
    `gpu_get_driver_version`/`gpu_get_renderer`/`gpu_get_dmem`/`gpu_get_smem`（`:45`-`:48`）、
    `device_enum_adapters`（`:50`）、`gs_texture_is_rect`（`:134`）、
    NV12/P010 四件套（`:199`-`:202`）、`gs_get_adapter_count`（`:209`）。
    调用点必须先判空——见 `graphics.c:3006` 那种 `if (!graphics->exports.device_texture_create_from_iosurface) return NULL;`。
  - 平台段与 `graphics-internal.h` 严格对应：`#ifdef __APPLE__` 在 `:212`，
    macOS 的 4 个符号是 `:213`-`:216`（**注意都用 `GRAPHICS_IMPORT` 即必需**，Metal 和 OpenGL 后端都必须实现）。
- **看点**：**关键细节一：符号名就是字段名**——`#func` 字符串化，所以 `gs_exports` 的成员名必须与后端导出的 C 符号
  逐字相同。这也解释了 `libobs-metal` 为什么满屏 `@_cdecl("device_texture_create_from_iosurface")`（Swift 侧强制 C 符号名）。
  这套设计的代价是**完全没有编译期检查**：字段名拼错、签名改了忘改后端，都要等运行时 `dlsym` 或崩溃才发现，
  `device-exports.h` 就是为了缓解这点而存在的"人工对齐用"头文件——但它只盖住了 101 个 `device_*`，其余靠自觉。
- **关键细节二（很容易看晕）：`gs_texture_destroy` 这类名字同时存在两份实现**。
  一份在 `graphics.c:2418`（抽象层，转发给 `exports.gs_texture_destroy`），一份在后端
  （`libobs-opengl/gl-texture2d.c:131`、`libobs-d3d11/d3d11-subsystem.cpp:2712`、
  `libobs-metal/metal-texture2d.swift:115`，都是同名 C 符号）。因为分属不同动态库、靠 `dlsym` 按名取，
  所以不冲突：libobs 内部调用解析到自己那份，`dlsym(module, "gs_texture_destroy")` 取到后端那份。
  **你 grep 一个 `gs_xxx` 得到两个定义时，别以为看错了。**

### `effect-parser.c`

- **做什么**：`.effect` 语言的编译器前端 + 代码生成器。输入一个 `.effect` 文本，输出**若干份自包含的 shader 源码**
  （每 technique 的每个 pass 各一份 vertex + 一份 pixel），并把参数元数据挂到 `gs_effect` 上。
  注意它**不做 GPU 编译**——生成的文本交给 `gs_vertexshader_create` / `gs_pixelshader_create`，
  由后端各自翻译（GLSL / HLSL / MSL）。词法与预处理器复用 `libobs/util/cf-parser.h`（C-family lexer，不在本目录）。
- **关键入口**：
  - `ep_parse`（`:1369`）——总入口。**先做一件很关键的事**（`:1373`-`:1383`）：
    调 `gs_preprocessor_name()` 拿当前后端的名字，用 `cf_preprocessor_add_def` **注入成一个预处理器宏**。
    三个后端返回值分别是 `"_OPENGL"`（`libobs-opengl/gl-subsystem.c:214`）、
    `"_D3D11"`（`libobs-d3d11/d3d11-subsystem.cpp:946`）、
    `"_Metal"`（`libobs-metal/libobs-metal-Bridging-Header.h:32`）。
    于是 `.effect` 里可以写 `#ifdef _Metal ... #endif` 做后端分支。
    （实测：当前仓库自带的 52 个 `.effect` 里没有一个用到它，grep 无命中；机制留给插件/第三方 shader。）
    然后主循环按顶层关键字分派：`struct` / `technique` / `sampler_state` / 其它（参数或函数）。
  - **两阶段结构**是这个文件最值得学的地方：
    - **阶段一 解析**：`ep_parse_struct`（`:254`）、`ep_parse_technique`（`:533`）、`ep_parse_sampler_state`（`:628`）、
      `ep_parse_function`（`:842`）、`ep_parse_param`（`:1101`）。解析函数体时不做语义分析，
      只把 token 原样存进 `ep_func::contents`，同时用 `ep_process_struct_dep`/`_func_dep`/`_sampler_dep`/`_param_dep`
      （`:785`-`:809`）**记录这个函数用到了哪些结构体/函数/sampler/参数**——即建一张依赖图。
    - **阶段二 生成 + 编译**：`ep_compile`（`:1945`）→ `ep_compile_technique`（`:1917`）→ `ep_compile_pass`（`:1889`）
      → `ep_compile_pass_shader`（`:1821`）→ **`ep_makeshaderstring`（`:1696`）**。
      `ep_makeshaderstring` 从 pass 里写的入口函数名出发，沿依赖图做**闭包展开**，按
      `ep_write_param`（`:1434`）→ `ep_write_sampler`（`:1475`）→ `ep_write_struct`（`:1531`）→
      `ep_write_func`（`:1585`，递归先写被依赖函数）→ `ep_write_main`（`:1655`，生成 `main()` 包装）的顺序
      拼出一份**只含这个 pass 真正用到的东西**的 shader 文本。`ep_reset_written`（`:1683`）负责重置"已写入"标记，
      让下一个 pass 重新展开。
  - `ep_compile_pass_shader`（`:1821`）随后调 `gs_vertexshader_create(shader_str.array, location.array, &errors)`
    （`:1851`，pixel 侧在 `:1858`），拿回 `gs_shader_t *` 存进 `pass->vertshader`；再由 `ep_compile_pass_shaderparams`（`:1795`）
    把 effect 参数与 shader 参数**按名字配对**成 `pass_shaderparam{eparam, sparam}` 数组——
    这就是运行时"设一次 effect 参数、自动喂到当前 pass 的 shader uniform"的桥。
  - 调试：`_DEBUG && _DEBUG_SHADERS` 下会把重排后的 shader 全文和参数默认值 dump 到日志
    （共 11 处 `#if`，主要在 `:1415`-`:1419`、`:1425`-`:1427`、`:1869`-`:1874`，
    打印函数 `debug_print_string` 在 `:1336`、`debug_param` 在 `:1269`）。**移植时先把这个宏打开，比什么都省事。**
- **看点**：这是一个"**不做优化、只做依赖闭包重排**"的极简语言前端——没有类型检查，没有 IR，
  函数体连 token 都不解析，纯靠字符串搬运。1972 行就换来了"一个文件写多 pass 多后端 shader"的能力，
  投入产出比非常高。踩过的坑体现在两处：一是必须注入后端宏才能处理平台差异（阶段一之前，`:1373`）；
  二是 `used_params` 数组要贯穿整个生成过程，避免同一参数被写两遍（`ep_write_param` 的 `used_params` 去重）。
  **你复刻时，如果只打算支持 Metal，可以砍掉后端宏注入和 `shader-parser.c` 整层，
  直接让 `.effect` 生成 MSL——但保留"依赖闭包展开"这个核心，它是多 pass 复用函数的关键。**

### `effect.c`

- **做什么**：`.effect` 的**运行时**部分。管理 technique/pass 的切换、参数的脏标记与上传、纹理绑定。
- **关键入口**：
  - `gs_effect_loop`（`:60`）：OBS 上层最常见的写法 `while (gs_effect_loop(effect, "Draw")) { ... }`
    背后就是它——**用一个函数同时完成"开始/推进/结束"三态**：首次调用 `gs_technique_begin` 并置 `looping`，
    之后每次先 `gs_technique_end_pass` 再 `gs_technique_begin_pass(loop_pass++)`，pass 用尽则 `gs_technique_end`
    并返回 false 退出循环。状态存在 `effect->looping` / `effect->loop_pass`。
  - `gs_technique_begin_pass`（`:195`）→ `gs_load_vertexshader/gs_load_pixelshader` + `upload_parameters`（`:173`）。
  - `upload_shader_params`（`:146`）：遍历 `pass_shaderparam` 配对表，`changed_only` 为真时只上传 `changed` 的参数
    （**脏标记优化**）；参数没设过值就 `gs_shader_set_default`。
  - `gs_technique_end`（`:112`）：**把所有参数的 `cur_val` 清空、`changed` 置 false、`next_sampler` 清空**。
    这是前面说的"effect 参数不能跨帧持有"的根因。
  - `gs_technique_end_pass`（`:244`）→ `clear_tex_params`（`:230`）：把纹理参数解绑（置 NULL），防止悬垂引用。
  - `gs_effect_set_texture` / `gs_effect_set_texture_srgb`（`:473`/`:481`）：**注意这两个是不同函数**——
    后者告诉后端"采样时做 sRGB→linear 解码"，是 OBS 线性工作流的关键开关，配合 `gs_set_linear_srgb`
    （`graphics.c:1868`）和 `gs_enable_framebuffer_srgb`（`graphics.c:1838`）使用。
  - `effect_setval_inline`（`:368`）：所有 setter 的公共实现，`memcmp` 比较后才置 `changed`——**值没变就不标脏**。
- **看点**：参数系统的三层映射值得画个图：`gs_eparam`（effect 级，跨 pass 共享，有 `cur_val`/`default_val`/`changed`）
  →`pass_shaderparam`（配对表，按名字绑定）→`gs_sparam`（后端 shader 级 uniform）。
  上层只碰第一层，中间层由 `effect-parser.c:1795` 在编译期建好。你要做 per-source 滤镜参数时可以直接照搬这个分层。

### `shader-parser.c`

- **做什么**：**给三个后端用的**公共 shader 分析器（不被 `effect-parser.c` 调用）。头文件注释原话点得很准：
  "允许为不同的库重排 shader，通常只被图形库使用"。
  它把 HLSL 风格的 shader 文本拆成 uniform 列表、sampler_state 列表、结构体（带 `POSITION`/`TEXCOORD0` 等 semantic 映射）、
  函数签名，让后端知道**该建什么 input layout、该绑哪些 uniform 到哪个 slot**。
- **关键入口**：`shader_parse`（`:691`）是唯一入口；
  `shader_sampler_convert`（`:99`）把解析出的 `sampler_state` 块转成 `gs_sampler_info`；
  `get_address_mode`（`:83`）/ `get_sample_filter` / `get_shader_param_type` 是字符串→枚举。
  `shader_var::gl_sampler_id`（`shader-parser.h:38`）注释写着 "optional: used/parsed by GL"——**抽象层里留了个 GL 专属字段**。
- **三个后端的消费方式不同，这是最值得注意的一点**：
  - **OpenGL**：`libobs-opengl/gl-shaderparser.c:762` 调 `shader_parse`，然后**整份重写成 GLSL**（改类型名、
    改内建函数、把 semantic 转成 `layout(location=)`）。
  - **D3D11**：`libobs-d3d11/d3d11-shaderprocessor.cpp:237` 调 `shader_parse`，但**只取元数据**
    （`BuildInputLayoutFromVars` `:107`、参数/sampler 列表）；shader 文本原样丢给
    `D3DCompile`（`d3d11-shader.cpp:281`）——因为 `.effect` 本来就是 HLSL 方言。
  - **Metal**：`libobs-metal/OBSShader.swift:138` 调 `shader_parse`，在 Swift 侧建 `OBSShaderFunction`/
    `OBSShaderVariable`/`OBSShaderStruct` 中间表示（1603 行），**重写成 MSL** 后交给 `MTLLibrary` 编译。
- **看点**：**这是 `.effect` 在 macOS 上真正的编译落点**——你在 macOS 追一个 shader 编译错误，
  链路是 `.effect` 文件 → `effect-parser.c` 拼文本 → `gs_pixelshader_create` → `metal-shader.swift`
  → `OBSShader.swift:138 shader_parse`（本目录的 C 代码）→ OBSShader 生成 MSL → `MTLDevice.makeLibrary`。
  中间跨了 C→Swift→Metal 三层，报错信息经常在 `MetalError.OBSShaderParserError`（`MetalError.swift:84`）那里被包一层。

### `texture-render.c`

- **做什么**：`gs_texrender_*` 这一小组 helper。文件头注释原话：
  "一组 helper，让渲染到纹理不必到处复制同样的代码"。对象内部同时缓存 `target`/`prev_target`/`zs`/`prev_zs`/`prev_space`，
  所以 `begin`/`end` 能正确嵌套。
- **关键入口**：`gs_texrender_create`（`:39`）、`gs_texrender_begin`（`:88`）、
  `gs_texrender_begin_with_color_space`（`:93`，HDR 路径要用）、`gs_texrender_end`（`:123`）、
  `gs_texrender_reset`（`:137`，标记内容失效但保留纹理）、`gs_texrender_get_texture`（`:143`）。
- **看点**：**尺寸变了才重建纹理，否则整帧复用**——`begin` 里比对 `cx/cy`，这就是 OBS 滤镜链能做到每帧
  零分配的原因。`reset` 与 `destroy` 分离的设计（内容失效 ≠ 释放显存）值得照搬，你在 WorkLabs 里遇到的
  "滤镜内存高水位"问题本质上就是这个 reset/destroy 边界没划清。

### `image-file.c`

- **做什么**：静态图 + 动画 GIF 的统一门面。静态图直接调 `gs_create_texture_file_data*`（实现在 `graphics-ffmpeg.c`）；
  GIF 走 `libnsgif`，并在这里实现帧缓存和播放时钟。
- **关键入口**：`gs_image_file_init`（`:216`，实际逻辑在 `gs_image_file_init_internal` `:181`）、
  `init_animated_gif`（`:72`）、`gs_image_file_init_texture`（`:262`，第一次上传纹理）、
  `calculate_new_frame`（`:287`，按 elapsed_ns 和循环次数算目标帧）、`decode_new_frame`（`:311`）、
  `gs_image_file_tick_internal`（`:346`）、`gs_image_file_update_texture_internal`（`:390`）。
- **看点**：两处设计值得注意。①**tick 与 upload 分离**：`tick` 只在 CPU 侧算帧、置 `frame_updated`，
  真正 `gs_texture_set_image` 发生在 `update_texture`——因为后者必须在图形上下文里跑。
  这和 OBS 整体的 `video_tick` / `video_render` 两相分离是同一个模式。
  ②GIF 可以**全量预解码到 `animation_frame_cache`**（`get_full_decoded_gif_size` `:58` 估算，
  `alloc_mem` `:63` 统计 `mem_usage`）——用内存换 CPU，因为 GIF 是帧间差分格式，随机 seek 代价高。

---

## macOS 专项：`gs_texture` 与 IOSurface / CVPixelBuffer 的对接点

抽象层这边只有**两个** macOS 专属函数，都在 `graphics.c` 文件末尾的 `#ifdef __APPLE__` 段（`:2997`-`:3043`）：

| 函数 | 位置 | 说明 |
|---|---|---|
| `gs_texture_create_from_iosurface(void *iosurf)` | `graphics.c:3000`（声明 `graphics.h:823`） | 把一个 `IOSurfaceRef` 包成 `gs_texture_t *`，**零拷贝** |
| `gs_texture_rebind_iosurface(gs_texture_t *, void *iosurf)` | `graphics.c:3012`（声明 `graphics.h:824`） | 让**已有纹理对象**改指向新的 IOSurface，避免每帧重建纹理 |

后端实现：
- Metal：`libobs-metal/metal-texture2d.swift:477` / `:500`（`@_cdecl` 导出，内部走 `MTLDevice.makeTexture(descriptor:iosurface:plane:)`）
- OpenGL：`libobs-opengl/gl-cocoa.m:466` / `:566`（走 `CGLTexImageIOSurface2D`）

**CVPixelBuffer 怎么进来**：`libobs/graphics/` 里**完全不认识 CoreVideo**——转换发生在插件侧，模式统一是
`CVPixelBufferGetIOSurface(pixelBuffer)` 取出 IOSurface 再交给上面两个函数。参考实现（都值得读）：

| 位置 | 场景 |
|---|---|
| `plugins/mac-avcapture/OBSAVCapture.m:1273` + `plugins/mac-avcapture/plugin-main.m:175`/`:177` | **摄像头**：`CMSampleBuffer` → `CVImageBuffer` → IOSurface → 首帧 `create`、后续 `rebind` |
| `plugins/mac-capture/mac-sck-common.m:261` + `mac-sck-video-capture.m:341`/`:343` | **ScreenCaptureKit 屏幕采集**，同样的 create/rebind 二选一 |
| `plugins/mac-capture/mac-display-capture.m:382`/`:384` | 旧版显示器采集 |
| `plugins/mac-syphon/syphon.m:158` | Syphon 跨进程共享 |
| `plugins/obs-browser/browser-client.cpp:435`/`:492` | CEF 浏览器源的共享纹理 |
| `plugins/mac-virtualcam/src/obs-plugin/OBSDALMachServer.mm:131` | **反向**：OBS 输出的 CVPixelBuffer 取 IOSurface 发给虚拟摄像头 |

⚠️ 注意 `plugin-main.m:39`、`mac-display-capture.m:260`、`mac-sck-video-capture.m:295` 都有
`if (gs_get_device_type() == GS_DEVICE_OPENGL)` 分支——**IOSurface 的纹理格式/翻转在 GL 与 Metal 后端下不一致**，
插件要自己分叉。你只做 Metal 的话可以省掉这层。

CPU 内存路径（拿不到 IOSurface 时）则是 `gs_texture_create(..., GS_DYNAMIC, ...)` + `gs_texture_set_image`
（`graphics.c:1187`，内部 `gs_texture_map`/`unmap` 逐行 memcpy）；回读用 `gs_stage_texture`（`:1902`）
配 `gs_stagesurface_map`（`:2629`）。

---

## 阅读建议

1. **先读 3 个文件建立骨架，顺序别乱**：`graphics-internal.h`（看 `gs_exports` 有哪些能力、
   `graphics_subsystem` 存了什么状态）→ `graphics-imports.c`（看绑定机制，259 行 10 分钟读完）
   → `graphics.c:198-330`（看 `gs_create` 和上下文管理）。读完这三段，"抽象层怎么接后端"就通了，
   `graphics.c` 剩下的 3000 行是重复样板，**按需 grep 即可，不要顺读**。
2. **特效系统按"运行时先、编译期后"读**：先 `effect.c`（556 行，看 `gs_effect_loop` 那个三态循环和参数三层映射），
   建立"上层怎么用"的直觉；再回头读 `effect-parser.c` 的**阶段二**（`:1696` `ep_makeshaderstring`
   和 `:1821` `ep_compile_pass_shader`，约 250 行），这是全篇技术含量最高的地方；
   **阶段一那 1300 行手写递归下降解析可以跳过**——是标准的 cf-parser 套路，读了收获很低。
3. **macOS 开发者的必读小路径**：`graphics.c:2997-3043`（两个 IOSurface 函数）
   → `graphics-internal.h:214-220`（Apple 分支只有 4 个字段）
   → `plugins/mac-avcapture/plugin-main.m:170-180`（create/rebind 的正确用法）。
   十分钟看完，比读任何文档都清楚。追 shader 编译问题则去 `libobs-metal/OBSShader.swift`。
4. **数学库只看头文件**，`.c` 文件（`vec3.c` 87 行、`quat.c` 215 行…）都是无法内联的边角。
   整套 12 个文件加起来的信息量不如 `graphics.h` 的枚举定义大。
5. **可以直接跳过的**：`input.h`（TODO 空壳）、`basemath.hpp`（3 行 TODO）、
   `half.h`（微软的 float16 转换，除非做 HDR）、`libnsgif/*`（第三方 GIF 解码，只有 `image-file.c:26-56`
   那几个回调是 OBS 自己的胶水）、`math-extra.c`（杂项工具）。
6. **给 WorkOBS 的取舍建议**：`libobs/graphics/` 里真正必须复刻的是
   ①`gs_exports` 式的后端契约（哪怕只有一个 Metal 后端，留住这层边界也值——它同时是"图形上下文"的语义锚点）、
   ②`texture-render.c` 的 begin/end/reset 三分设计、③`effect.c` 的参数三层映射与脏标记。
   可以大胆砍掉的是矩阵栈、立即模式、cube/vol 纹理、GPU 计时器、以及整套 `shader-parser.c` 翻译层
   （直接写 `.metal` 或让 `.effect` 直出 MSL）。
