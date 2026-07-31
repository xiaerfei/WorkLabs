# OBS 目录导航 · 图形后端实现（Metal / OpenGL / D3D11 / WinRT）

> 源码范围：`libobs-metal/`（35）、`libobs-opengl/`（24）、`libobs-d3d11/`（14）、`libobs-winrt/`（4）｜ 源文件 77 个 ｜ 基于 obs-studio commit `f2db097`（2026-07-09）
> 返回总索引：[README.md](README.md)

## 本篇速查

想找什么 → 去哪：

| 我想看… | 去这里 |
|---|---|
| 后端与抽象层怎么对接、符号名怎么定的 | [绑定机制](#抽象层--后端的绑定机制符号名就是契约) |
| macOS 上默认跑哪个后端、怎么切 | [平台可用性](#各后端的平台可用性与-macos-默认值) |
| **CVPixelBuffer / IOSurface → `MTLTexture`** | [`MetalTexture.swift`](#metaltextureswift) + [`CVPixelFormat+Extensions.swift`](#5-桥接与类型转换extensions--bridging-header) |
| Metal 后端**还有哪些 API 没实现** | [未实现项](#6-未实现项metal-unimplementedswift) |
| Metal 的 `device_*` 导出函数在哪个文件 | [第 1 组](#1-设备状态与导出函数总表) 的分布表 |
| `.effect` 怎么变成 MSL、报错在哪一层 | [`OBSShader.swift`](#obsshaderswift) |
| Metal 怎么做 clear（没有 clear 命令怎么办） | [`MetalDevice.swift`](#metaldeviceswift) |
| 预览为什么会卡顿 / `CAMetalLayer` 的 drawable 预算 | [`metal-subsystem.swift`](#metal-subsystemswift) 看点 + [README 摘要](#libobs-metal-readmemd-的关键结论) |
| macOS 上 OpenGL 的 `NSOpenGLContext` / 呈现路径 | [`gl-cocoa.m`](#gl-cocoam) |
| GL 后端为什么用 `GL_TEXTURE_RECTANGLE` | [`gl-cocoa.m`](#gl-cocoam) 看点 |
| D3D11 的设备丢失重建（device loss） | [`d3d11-rebuild.cpp`](#libobs-d3d11windows-direct3d-11-后端) |
| Windows.Graphics.Capture 封装 | [`libobs-winrt/`](#libobs-winrt并不是图形后端) |
| 同一个 gs 概念在三个后端各对应哪个文件 | [三后端文件对照表](#三后端文件对照表) |

---

## 一句话职责

这四个目录里，**前三个是 `libobs/graphics/` 抽象层的三种可替换实现**，第四个（`libobs-winrt/`）根本不是图形后端。

`libobs/graphics/` 只定义 `gs_*` 公开 API 并把调用转发给一张函数指针表；
`libobs-opengl/`（C，跨全平台）、`libobs-d3d11/`（C++，Windows）、`libobs-metal/`（Swift，macOS/Apple Silicon）
各自实现**一整套同名的 `device_*` / `gs_*` 导出符号**，编译成三个独立动态库，运行时按配置 `dlopen` 其中一个。
三者互不引用、互不知道对方存在——**只共享两份契约头（`graphics.h` + `device-exports.h`）和一份公共 shader lexer（`shader-parser.c`）**。

`libobs-winrt/` 是给 `plugins/win-capture/` 用的 C 封装库，把 C++/WinRT 的 `Windows.Graphics.Capture` 包成
纯 C 接口（`winrt-capture.h`），因为 libobs 主体是 C、不能直接吃 C++/WinRT。放在这一层只是因为它同样是"顶层动态库"。

### 抽象层 ↔ 后端的绑定机制：符号名就是契约

绑定完全靠**运行时 `dlsym` 按名字取符号**，没有虚表、没有编译期检查（细节见 02 篇，这里只补后端侧视角）：

- `graphics-imports.c:40` 的 `load_graphics_imports()` 用 `GRAPHICS_IMPORT(func)` 宏（`:23`）做
  `exports->func = os_dlsym(module, #func)`。**`#func` 字符串化 ⇒ `gs_exports` 的字段名必须与后端导出的 C 符号逐字相同**。
  共 157 个必需 + 34 个可选（含各平台分支）。
- 后端侧的对齐依据是 `device-exports.h`（101 条 `EXPORT`）。⚠️ 它只覆盖 `device_*` / `gpu_*`；
  `gs_texture_destroy` / `gs_shader_set_vec4` 这类**对象方法族不在里面**，签名要自己去 `graphics.h` 对。
- macOS 专属的 4 个符号在 `graphics-imports.c:212`-`:216`（`#ifdef __APPLE__` 段），
  **全部是 `GRAPHICS_IMPORT` 即必需**：`device_shared_texture_available`、`device_texture_open_shared`、
  `device_texture_create_from_iosurface`、`gs_texture_rebind_iosurface`。
  声明侧只有前两个在 `device-exports.h:136`-`:139`，后两个仍靠 `graphics.h`。
- 三后端的自我标识（`.effect` 里可 `#ifdef` 的宏名 / `gs_get_device_type()` 的返回值）：

| 后端 | `device_get_name` | `device_preprocessor_name` | `device_get_type` |
|---|---|---|---|
| OpenGL | `"OpenGL"` | `"_OPENGL"`（`gl-subsystem.c:212`） | `GS_DEVICE_OPENGL`=1（`gl-subsystem.c:207`） |
| D3D11 | `"Direct3D 11"` | `"_D3D11"`（`d3d11-subsystem.cpp:946`） | `GS_DEVICE_DIRECT3D_11`=2（`:941`） |
| Metal | `"Metal"`（常量在 `libobs-metal-Bridging-Header.h:31`） | `"_Metal"`（`libobs-metal-Bridging-Header.h:32`） | `GS_DEVICE_METAL`=3（`metal-subsystem.swift:54`） |

（`GS_DEVICE_*` 的数值定义在 `libobs/graphics/graphics.h:501`-`:503`。）

Swift 后端怎么导出 C 符号：靠 `@_cdecl("device_xxx")` 注解，**实测 145 个**（`grep -c '@_cdecl' libobs-metal/*.swift` 求和）。
Swift 侧不需要手写 C 头——`libobs-metal/CMakeLists.txt:50` 用 `-emit-objc-header` 自动生成
（⚠️ 同文件 `:50` 那一行 `set_property(SOURCE OBSMetalRenderer.swift ...)` 指向的文件在本目录里**并不存在**，
看起来是重命名后遗留的死配置；导出实际靠 `@_cdecl` 本身生效）。

### 各后端的平台可用性与 macOS 默认值

编译期由顶层 `CMakeLists.txt:22`-`:30` 决定编哪几个：

```
if(OS_WINDOWS)  add_subdirectory(libobs-d3d11); add_subdirectory(libobs-winrt)   # :23-:26
add_subdirectory(libobs-opengl)                                                  # :27  ← 无条件，全平台都编
if(OS_MACOS)    add_subdirectory(libobs-metal)                                   # :28-:30
```

运行期由前端选：`frontend/OBSApp.cpp:1155` 的 `OBSApp::GetRenderModule()`

- Windows（`:1157`-`:1160`）：配置 `Video/Renderer` == `"Direct3D 11"` → `DL_D3D11`，否则 `DL_OPENGL`。
- **macOS 且 `__aarch64__`**（`:1161`-`:1164`）：`Video/Renderer` == `"Metal"` → `DL_METAL`，否则 `DL_OPENGL`。
  注意 `&& defined(__aarch64__)`——**Intel Mac 上连选项都没有**，Metal 后端只给 Apple Silicon。
- 其它平台（`:1166`）：硬编码 `DL_OPENGL`。

`DL_OPENGL` / `DL_METAL` / `DL_D3D11` 三个宏不是写在头文件里的，而是 `frontend/CMakeLists.txt:84`-`:95`
按 target 是否存在**生成的编译定义**（值＝对应动态库的 soname；target 不存在就定义成空串）。

**macOS 当前默认仍是 OpenGL**，依据是 `frontend/OBSApp.cpp:308`-`:310`：

```c
#if defined(__APPLE__) && defined(__aarch64__)
	// TODO: Change this value to "Metal" once the renderer has reached production quality
	config_set_default_string(appConfig, "Video", "Renderer", "OpenGL");
```

设置界面里 Metal 明确标成实验性——`frontend/settings/OBSBasicSettings.cpp:1451` 用
`QTStr("Basic.Settings.Video.Renderer.Experimental").arg("Metal")` 拼下拉项文案。

### 三后端的能力落差（可选符号实测）

`GRAPHICS_IMPORT_OPTIONAL` 的 34 个符号里，**Metal 只实现了 1 个**（`device_texture_open_shared`，且它在 macOS 分支里本就是必需的）。
Metal 后端缺失的可选能力中，与 macOS 相关且值得注意的是：

| 缺失符号 | 后果 |
|---|---|
| `gpu_get_driver_version` / `gpu_get_renderer` / `gpu_get_dmem` / `gpu_get_smem` | 日志与统计里没有 GPU 名称/显存信息（GL 后端有，`gl-subsystem.c:217`/`:222`/`:228`） |
| `device_nv12_available` / `device_p010_available` / `device_stagesurface_create_nv12` / `_p010` | 没有 GPU 侧 NV12/P010 多平面纹理路径。GL 后端在非 Windows 上返回 `true`（`gl-subsystem.c:1506`，注释原话：总是拆成 R8 + R8G8 两张纹理） |
| `gs_texture_is_rect` | 恒为 false（`graphics.c:2487` 判空后走默认）。**这其实是好事**，见下条 |
| `device_enum_adapters` / `gs_get_adapter_count` | 无多显卡枚举（Apple Silicon 只有一个 device，`metal-subsystem.swift:80` 的注释直接说 `adapter` 参数被忽略） |

`gs_texture_is_rect` 那条是 macOS 开发者最该记住的差异：**GL 后端把 IOSurface 绑成
`GL_TEXTURE_RECTANGLE_ARB`（`gl-cocoa.m:511`），UV 坐标是像素而非 0~1**，所以
`gs_draw_sprite` 要在 `graphics.c:1066` 判 `gs_texture_is_rect` 来决定 UV 缩放；Metal 用普通 `.type2D`，
没这个坑。这也是插件里 `if (gs_get_device_type() == GS_DEVICE_OPENGL)` 分支存在的根因。

---

## `libobs-metal/`　全 Swift 的 Metal 后端（Apple Silicon 专属）

**职责**：本篇重点。35 个源文件（34 `.swift` + 1 桥接头，8525 行）实现了 145 个 `@_cdecl` 导出函数。
命名有一条**很清晰的约定，认准它就能快速定位**：

- **小写连字符 `metal-*.swift`＝面向 libobs 的导出层**：文件里几乎全是 `@_cdecl` 函数，做指针拆包、参数换算、然后转调 Swift 对象。
- **大驼峰 `Metal*.swift` / `OBS*.swift`＝纯 Swift 实现层**：真正的类与逻辑，不含任何 `@_cdecl`。
- **`*+Extensions.swift`＝类型转换胶水**：`gs_*` 枚举 ↔ `MTL*` 枚举、`OSType` ↔ `MTLPixelFormat` 等。

这个"导出层 / 实现层"二分是它和 GL、D3D11 后端最大的结构差异（那两个是导出函数和实现混在同一文件）。

### 1. 设备、状态与导出函数总表

**职责**：持有唯一的 `MetalDevice`（对应 libobs 的 `gs_device_t *` 不透明指针），把 OpenGL/D3D11 那种
"全局魔法状态机"翻译成 Metal 的"不可变管线对象 + 命令缓冲"模型。核心手法是
**把所有"当前状态"攒在 `MetalRenderState` 里，等到真正 `device_draw` 时才现算 pipeline 并缓存**。

| 文件 | 行数 | 功能 |
|---|---|---|
| `metal-subsystem.swift` ⭐ | 985 | 41 个 `@_cdecl`：设备创建/销毁、混合/深度/模板/裁剪/剔除全套状态设置、渲染目标切换、`device_draw`、`device_clear`、`device_present`/`flush`、`ortho`/`frustum`/投影栈、HDR 查询。另有全库共用的 `unretained`（`:23`）/`retained`（`:28`）/`OBSLog`（`:33`）三个工具 |
| `MetalDevice.swift` ⭐ | 784 | `MTLDevice` + `MTLCommandQueue` 的包装类。pipeline 缓存（`:39`）、depth-stencil state 缓存（`:40`）、`CVDisplayLink`（`:42`）、`draw`（`:349`）、模拟 clear 的 `clear`（`:207`）、`blitSwapChains`（`:149`）、纹理拷贝/暂存（`:602`-`:773`） |
| `MetalRenderState.swift` | 79 | 纯 `struct`，文件头注释说得很准："模仿 `ID3D11DeviceContext` 那样的状态对象"。存 view/proj 矩阵、当前渲染目标（含 sRGB 变体）、顶点/索引缓冲、两个 shader、viewport、cull、`textures`/`samplers` 数组（`GS_MAX_TEXTURES` 长）、当前 `MTLCommandBuffer`、`inFlightRenderTargets`（`:78`） |
| `MetalError.swift` | 126 | 6 组 `Error` 枚举 + `CustomStringConvertible`：`MTLCommandQueueError`(`:19`)、`MTLDeviceError`(`:30`)、`MTLCommandBufferError`(`:59`)、`MetalShaderError`(`:70`)、`OBSShaderParserError`(`:84`)、`OBSShaderError`(`:107`)。**追 shader 报错先看这里的 description 文案** |
| `libobs+SignalHandlers.swift` | 34 | 只接一个 OBS 信号：`"video_reset"`（`:21`，枚举 `MetalSignalType` 在 `:20`）。回调把 `CVDisplayLink` 停掉再启动（`MetalDevice.swift:110`-`:118`），因为改分辨率/帧率后要重新对齐屏幕刷新 |
| `Sequence+Hashable.swift` | 25 | 一个 `unique()` 去重扩展。给 `OBSShader` 收集 texture/sampler 列表去重用 |

`device_*` 导出函数的**文件分布**（找某个 `device_xxx` 时按这张表定位）：

| 文件 | `@_cdecl` 数 | 覆盖范围 |
|---|---|---|
| `metal-subsystem.swift` | 41 | 设备 + 全局渲染状态 + 绘制 + 呈现 |
| `metal-shader.swift` | 25 | shader 创建/加载 + `gs_shader_set_*` 参数全家 |
| `metal-texture2d.swift` | 22 | 2D/cube 纹理 + map/unmap + copy/stage + **IOSurface 三兄弟** |
| `metal-unimplemented.swift` | 16 | 空壳（见第 6 组） |
| `metal-indexbuffer.swift` / `metal-swapchain.swift` | 8 / 8 | 索引缓冲 / 交换链 |
| `metal-stagesurf.swift` | 7 | GPU→CPU 暂存面 |
| `metal-texture3d.swift` / `metal-vertexbuffer.swift` | 6 / 6 | 3D（volume）纹理 / 顶点缓冲 |
| `metal-samplerstate.swift` / `metal-zstencilbuffer.swift` | 3 / 3 | 采样器 / 深度模板 |

### 2. 着色器：`.effect` → MSL 转译

**职责**：libobs 传进来的是 `effect-parser.c` 已经拼好的**单个 pass 的 HLSL 方言文本**。
这一族要做的事是：用抽象层的公共 lexer（`libobs/graphics/shader-parser.c`）重新分析它，
建一套 Swift 侧中间表示，**转译（transpile）成 Metal Shader Language**，再交 `MTLDevice.makeLibrary` 编译，
同时算出 uniform 在常量 buffer 里的**字节偏移/对齐**（MSL 基于 C++14，struct 有对齐规则，顺序是"承重"的）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `OBSShader.swift` ⭐ | 1603 | 转译器本体。`shader_parse`（`:138`）→ `analyzeUniforms`/`analyzeParameters`/`analyzeFunctions` → `transpileUniforms`/`transpileStructs`/`transpileFunctions` → `buildMetadata`（`:184`）。入口 `transpiled()`（`:155`） |
| `MetalShader.swift` | 287 | 编译产物包装：`MTLFunction` + `uniforms: [ShaderUniform]`（`:25` 内部类，带 `currentValues`/`defaultValues`/`hasUpdates` 脏标记）+ `MTLVertexDescriptor` + `samplers`。`uploadShaderParameters`（`:233`）把攒好的 uniform 字节塞进 render encoder |
| `metal-shader.swift` | 593 | 导出层：`device_vertexshader_create`（`:40`）/`device_pixelshader_create`（`:109`）串起 `OBSShader → transpiled() → MetalShader`；其余 23 个是 `gs_shader_set_bool/float/vec4/matrix4/texture/val/default/next_sampler` 等参数 setter |
| `MetalShader+Extensions.swift` | 27 | 给 `MetalShader` 加 `Equatable`：按 **source 字符串 + functionType** 比较。用于避免重复加载同一 shader |

### 3. 资源对象：纹理 / 缓冲 / 暂存面 / 深度模板 / 采样器

**职责**：Metal 的资源对象是不可变的（immutable），而 libobs 沿用 D3D11 的心智模型
（`map` 拿指针写、`unmap` 提交、纹理可以"rebind"到新数据源）。这一组的活儿基本都是**模拟**：
用 `MTLBuffer` 暂存 + blit 编码器模拟 map/unmap，用"换一个 `MTLTexture` 实例但保持外层包装对象不变"模拟 rebind。

| 文件 | 行数 | 功能 |
|---|---|---|
| `MetalTexture.swift` ⭐ | 433 | **`MTLTexture` 包装类**。4 个构造器（`:80` descriptor / `:100` **IOSurface** / `:127` 现成 MTLTexture / `:144` 占位空壳）、`rebind`（`:169`）、`updateSRGBView`（`:184`，建 sRGB `makeTextureView`）、`download`/`upload`（`:215`/`:234`）、模拟 D3D11 的 `map`/`unmap`（`:326`/`:369`） |
| `metal-texture2d.swift` | 528 | 导出层：`device_texture_create`（`:38`）、`device_cubetexture_create`（`:82`）、`device_load_texture[_srgb]`（`:145`/`:167`）、`device_copy_texture[_region]`（`:262`/`:199`）、`device_stage_texture`（`:286`）、`gs_texture_map/unmap`（`:347`/`:393`），末尾是 **IOSurface 四件套**（`:463`/`:476`/`:499`/`:519`） |
| `metal-texture3d.swift` | 113 | volume 纹理（3D LUT 滤镜用）。文件头注释提醒：要生成 mipmap 会**阻塞等待 blit 编码器**完成 |
| `MetalBuffer.swift` | 308 | 顶点/索引缓冲基类 + `MetalVertexBuffer`（`:95`）/`MetalIndexBuffer`（`:253`）。**关键点在 `:158`**：把 libobs 打包成 `UInt32` 的顶点色**在建 buffer 时就展开成 `SIMD4<Float>`**——因为 MSL 的 `[[stage_in]]` 不支持这种解包 |
| `metal-vertexbuffer.swift` / `metal-indexbuffer.swift` | 115 / 158 | 上面两个类的导出层（create/destroy/load/flush/flush_direct/get_data） |
| `MetalStageBuffer.swift` | 65 | 暂存面的真身：一个 `.storageModeShared` 的 `MTLBuffer`（`:28`），长 = w×h×bytesPerPixel |
| `metal-stagesurf.swift` | 130 | 导出层。文件头注释点明用途：GPU→CPU 回读，最常见是把视频输出纹理 blit 到暂存面再下载 |
| `metal-samplerstate.swift` | 100 | `gs_sampler_info` → `MTLSamplerDescriptor`（`:26`）。注意导出的是**descriptor 而非 state 对象**，实际 `MTLSamplerState` 由 `MetalDevice` 按需生成 |
| `metal-zstencilbuffer.swift` | 69 | 深度模板附件，实现上就是一张特殊格式的 `MetalTexture`（`:28`） |

### 4. 交换链与呈现：`CAMetalLayer` + `CVDisplayLink`

**职责**：macOS 上应用不能自己管交换链——`CAMetalLayer` 才是唯一出口，而它**最多只给 3 个 drawable**，
用尽就阻塞。OBS 的渲染帧率往往和屏幕刷新率不一致，直接向 drawable 渲染会把整个 OBS 渲染线程拖住。
所以这里的设计是：**OBS 永远渲进自己的离屏纹理，另开一条 `CVDisplayLink` 回调，在屏幕刷新节拍上把纹理 blit 进 drawable**。
两条线用 `MTLFence` 同步。这是本目录最"不像别的后端"的一块，也是 README 里唯一被单独写一节讨论的已知问题。

| 文件 | 行数 | 功能 |
|---|---|---|
| `OBSSwapChain.swift` | 125 | 伪交换链：一个 `CAMetalLayer`（`framebufferOnly = false`，`:45` 附近）+ 离屏 `renderTarget` + `MTLFence`（`:38`）+ `colorRange`（sdr/hdrPQ/hdrHLG，`:24`）+ `edrHeadroom`。`updateView`（`:65`）把 layer 挂上 `NSView` |
| `metal-swapchain.swift` | 269 | 导出层。`device_swapchain_create`（`:37`，标了 `@MainActor`——**必须主线程**）、`device_resize`（`:72`）、`device_get_size/width/height`、`device_load_swapchain`（`:165`，**HDR 判定 + 离屏 RT 懒建都在这里**）、`gs_swapchain_destroy`（`:264`，只置 `discard` 标记，真删在 blit 循环里） |

呈现链路（想追预览卡顿就沿这条走）：
`device_load_swapchain`（`metal-swapchain.swift:165`，标记进入 display render stage）
→ libobs 画几十个小 draw call
→ `device_end_scene`（`metal-subsystem.swift:451`）→ `MetalDevice.finishDisplayRenderStage()`（`MetalDevice.swift:554`，`updateFence`）
→ 另一侧 `CVDisplayLink` 回调 → `MetalDevice.blitSwapChains()`（`:149`，`waitForFence` + `copy` + `present(drawable)`）。

### 5. 桥接与类型转换（Extensions + Bridging Header）

**职责**：Swift 要认识 libobs 的 C 类型（`gs_color_format`、`shader_parser`、`cf_token`…），靠桥接头一次性 import；
反过来 libobs 的枚举要变成 `MTL*` 枚举，靠一堆小扩展。这一组每个文件都很短，**看名字就知道管什么**。

| 文件 | 行数 | 功能 |
|---|---|---|
| `libobs-metal-Bridging-Header.h` | 32 | 唯一的 C ↔ Swift 桥：import `util/base.h`、`util/cf-parser.h`、`util/cf-lexer.h`、`obs.h`、`graphics/graphics.h`、`device-exports.h`、`vec2/matrix3/matrix4.h`、**`graphics/shader-parser.h`**；另在 `:31`/`:32` 定义 `device_name`/`preprocessor_name` 两个常量 |
| `libobs+Extensions.swift` | 486 | **libobs 类型 → Metal 类型的总转换表**：`strref.getString()`（`:29`）、`cf_parser` 迭代（`:55`）、`gs_shader_param_type` 的 `size`/`mtlSize`/`mtlAlignment`（`:99`/`:120`/`:141`，**MSL 对齐规则就落在这里**）、`gs_color_format.mtlFormat`/`sRGBVariant`（`:176`/`:165`）、`gs_color_space`（`:220`）、`gs_depth_test`（`:246`）、`gs_stencil_op_type`（`:271`）、`gs_blend_type`（`:292`）、`gs_blend_op_type`（`:323`）、`gs_cull_mode`（`:342`）、`gs_draw_mode`（`:355`） |
| `CVPixelFormat+Extensions.swift` | 51 | **`OSType.mtlFormat`**（`:23`）：CoreVideo/IOSurface 像素格式 → `MTLPixelFormat`。**只支持 11 种**（见下方专项） |
| `MTLPixelFormat+Extensions.swift` | 406 | 反方向 + 格式元数据：`is8Bit`/`is16Bit`/`is32Bit`/`isPacked32Bit`/`is64Bit`/`is128Bit`、`isSRGB`（`:129`）、**`isEDR`（`:149`）**、`isCompressed`、`isDepth`/`isStencil`、`componentCount`、`gsColorFormat`（`:255`）、`bitsPerPixel`/`bytesPerPixel`（`:295`/`:312`）、`colorSpace`（`:349`，→ `CGColorSpace`）、`init?(osType:)`（`:371`）、`videoPixelFormat`（`:380`） |
| `MTLTextureDescriptor+Extensions.swift` | 93 | 一个便利构造器：`(type, width, height, depth, gs_color_format, levels, flags)` → descriptor，把 libobs 的 `GS_DYNAMIC`/`GS_RENDER_TARGET` 位域翻成 `usage`/`storageMode` |
| `MTLTexture+Extensions.swift` | 76 | `getRetained`/`getUnretained`（`:24`/`:32`，交给 C 侧的不透明指针）+ `size`/`region`/`descriptor` 便利属性 |
| `MTLTextureType+Extensions.swift` | 36 | `MTLTextureType` → `gs_texture_type`（2D/3D/Cube，其余 nil） |
| `MTLCullMode+Extensions.swift` | 33 | `MTLCullMode` → `gs_cull_mode` |
| `MTLViewport/MTLSize/MTLRegion/MTLOrigin +Extensions.swift` | 31/25/25/25 | 各加一个 `@retroactive Equatable`。存在的理由：`MetalRenderState` 要靠 `==` 判断状态有没变、以及给 pipeline 缓存算 hash |

### 6. 未实现项（`metal-unimplemented.swift`）

**这是本篇信息密度最高的 97 行**：16 个 `@_cdecl` 空壳函数，`return` 什么都不做。
它们必须存在，否则 `load_graphics_imports` 少一个符号就整个后端加载失败。**实测清单**（`metal-unimplemented.swift`）：

| 空壳符号 | 行 | 为什么可以空 |
|---|---|---|
| `device_load_default_samplerstate` | `:18` | Metal 里 sampler 由 `MetalShader` 按 uniform 直接绑，没有"默认 sampler 槽"概念 |
| `device_enter_context` / `device_leave_context` | `:23` / `:28` | **Metal 没有线程上下文**。GL 那边这两个是 `CGLLockContext` + `makeCurrentContext`（`gl-cocoa.m:359`/`:366`），Metal 完全不需要——对复刻很有参考价值 |
| `device_timer_create`、`device_timer_range_create`、`gs_timer_destroy/begin/end/get_data`、`gs_timer_range_destroy/begin/end/get_data` | `:33`-`:80` | **GPU 计时器（GPU timer / disjoint query）整族没做**，10 个函数全空，`gs_timer_get_data` 恒返回 false。⇒ OBS 统计面板里的 GPU 渲染耗时在 Metal 下拿不到真值 |
| `device_debug_marker_begin` / `device_debug_marker_end` | `:82` / `:87` | 没接 `MTLCommandBuffer.pushDebugGroup`。Xcode GPU 抓帧时看不到 OBS 自己的分组标签 |
| `device_set_cube_render_target` | `:92` | 渲染到 cube map 面未实现（OBS 主流水线不用） |

另外，前面「能力落差」表里那 33 个**可选符号 Metal 干脆没导出**（`gpu_get_*`、NV12/P010、`gs_texture_is_rect`、
adapter 枚举、以及全部 Windows 专属的 GDI/duplicator/NT-handle/device-loss 族），
和这 16 个空壳不同——它们靠 `GRAPHICS_IMPORT_OPTIONAL` 的"允许缺失"通过，调用点自己判空。

### `libobs-metal/README.md` 的关键结论

83 行，作者 Patrick Heyer。**必读**，因为它把设计取舍讲得比代码注释更集中。要点：

- **定位**：alpha 质量，**仅 Apple Silicon、仅 Metal 3**，两条都写明"by design"（`:10`-`:11`）。
  实现全 Swift，C 接口靠 `-emit-objc-header` + `@_cdecl` 生成（`:8`-`:9`）。
- **已支持**：全部默认源类型（含 SCK 采集、浏览器源、采集卡）、全部默认转场、全部默认滤镜、
  VideoToolbox 编码录制推流、多预览/投影仪/多视图。**sRGB 感知渲染默认开启**；
  EDR 屏幕上支持 HDR 输出，但**OBS 不做 tone mapping**——有 EDR 就按原格式直出（`:39`-`:43`）。
- **已知问题**：预览可能卡顿或掉帧、性能未优化、编码器配置未全测（`:45`-`:49`）。
- **预览那一节（`:51`-`:63`）** 是全篇最有价值的：`CAMetalLayer` 最多 3 个 drawable 在飞，
  OBS 渲染快于系统合成器就会被阻塞 ⇒ 现方案是**渲染与呈现解耦**（OBS 渲自己的纹理，回调里 blit 进 drawable），
  代价是 blit 依赖投影仪渲染完成，两边节拍不齐就"choppy"。作者原话点明 `CAMetalLayer` 的工作方式与
  `DXGISwapChain` **正好相反**，所以 Metal 后端要多得多的资源管理。
- **性能（`:65`-`:73`）**：Release 下与 OpenGL 后端在 M1 上 CPU 与渲染耗时相当（且尚未优化）。
  瓶颈在**晚期生成 pipeline / buffer 与频繁 CPU↔GPU 上下文切换**；理想做法是大批量上进 `MTLHeap`，
  但**与 OBS 现有渲染器的工作方式不兼容**（一堆小 draw call）。
- **必要的 workaround（`:75`-`:84`，四条，复刻时会一模一样踩到）**：
  1. **MSL 比 HLSL/GLSL 严格，不允许类型双关（type punning）和隐式转换**。libobs 的 shader 依赖
     "float4 隐式转 int 传给纹理 `Load`"，转译器必须**强制转成无符号整型向量**（MSL 里是 `read`）。
  2. **Metal 没有 BGRX/RGBX 格式**，颜色必须 float4。部分 libobs pixel shader 只返回 `float3`（假定 BGRX），
     转译后统一补成 alpha=1.0 的 `float4`。
  3. **`[[stage_in]]` 不能把 `UInt32` 解包成 float4**（vertex fetch 做不到），
     所以顶点色在**建 GPU buffer 时就展开**（对应 `MetalBuffer.swift:158`）。
  4. **Metal 没有显式 clear 命令**——clear 是 render pass 加载 tile 时的 load action，没有 pass 就不会执行。
     OBS 依赖"clear 真的把纹理清了"，所以必须**排一个轻量 draw call** 强制 load/clear/store（对应 `MetalDevice.swift:207`）。

---

## ⭐ 重点文件展开

### `metal-subsystem.swift`

- **做什么**：985 行、41 个 `@_cdecl`，是 Metal 后端**面向 libobs 的正门**。绝大多数函数的形状一模一样：
  `let device: MetalDevice = unretained(device)` 拆包 → 改 `device.renderState.xxx` → 返回。
  真正干活的转调 `MetalDevice` 的方法。文件顶部三个工具函数（`unretained` `:23`、`retained` `:28`、`OBSLog` `:33`）
  被全目录使用——**`unretained` 出现在几乎每个导出函数第一行，认识它就能扫得很快**。
- **关键入口**：
  - `device_create`（`:80`）：先 `NSProtocolFromString("MTLDevice")` 探测支持（`:82`），
    `MTLCreateSystemDefaultDevice()`（`:89`），打印设备名/统一内存/光追/架构，
    建 `MetalDevice` 后 **`Unmanaged.passRetained` 交给 C 侧**（`:110`）并顺手
    `signal_handler_connect(...)`（`:115`，连的是 `"video_reset"`）。
    注释明说 `adapter` 参数被忽略——Apple Silicon 只有一个 device。
  - `device_destroy`（`:134`）：用 `retained()` **把所有权拿回 Swift**，并强调必须先跑
    `MetalDevice.shutdown()`（`MetalDevice.swift:774`）再让 libobs 清理，因为 libobs 那边的清理顺序不是内存安全的。
  - `device_begin_frame`（`:275`）：每帧第一个被调的图形函数，用来**清掉上一帧的残留状态**
    （`useSRGBGamma`、`renderTarget`、`swapChain`、`isInDisplaysRenderStage` 四个字段置空）。
  - `device_set_render_target` / `_with_color_space`（`:322`/`:356`）、
    `device_enable_framebuffer_srgb`（`:395`）：sRGB 走的是**同一块显存两个 texture view** 的路子（见 `MetalTexture`）。
  - `device_draw`（`:475`）→ `MetalDevice.draw`；`device_clear`（`:513`）→ `MetalDevice.clear`。
  - `device_begin_scene`（`:433`）/ `device_end_scene`（`:451`）：后者是"display render stage 结束"的信号，
    会去 `finishDisplayRenderStage()` 打 fence。
  - `device_is_present_ready`（`:577`）**恒返回 `true`**，注释写明理由：
    "目前没有办法查询还剩几个 drawable"——所以无法让 libobs 跳过这一帧稍后再试。**这就是预览卡顿的机制性根源之一。**
  - `device_present`（`:589`）与 `device_flush`（`:602`）**实现完全相同**，都只是 `finishPendingCommands()`。
    因为真正的 present 不在这里，而在 `CVDisplayLink` 那一侧。
  - `device_is_monitor_hdr`（`:976`）：Metal 后端会真查 EDR；GL 后端直接 `return false`（`gl-cocoa.m:453`）。
- **看点**：这个文件是"**把状态机 API 适配到无状态 API**"的完整案例。libobs 的每个
  `device_enable_blending` / `device_depth_function` / `device_stencil_op` 都只是往
  `renderState.pipelineDescriptor` / `depthStencilDescriptor` 上记一笔，**一个 GPU 调用都不发**；
  等到 `device_draw` 才把 descriptor 哈希一下查缓存。你在 WorkLabs 里如果也要保留"OBS 式状态设置 API"，
  这套"descriptor 攒状态 + hash 缓存 pipeline"是可以直接照抄的最小方案。
  另外注意 `device_present`/`device_flush` 同实现这个细节——它说明**在 Metal 下"呈现"这个语义被彻底搬走了**。

### `MetalDevice.swift`

- **做什么**：784 行的实现层核心。持有 `MTLDevice` + 唯一的 `MTLCommandQueue`（`:45`）、
  两张缓存字典（pipeline `:39`、depth-stencil state `:40`）、`CVDisplayLink`（`:42`）、
  `swapChains` 数组（`:47`）与保护它的 `swapChainQueue`，以及可变的 `renderState`（`:46`）。
- **关键入口**：
  - `init(device:)`（`:50`）：建 command queue、`fallbackVertexBuffer`、`nopVertexFunction`（给模拟 clear 用的空顶点着色器）、
    `setupSignalHandlers()`（`:110`）、`setupDisplayLink()`（`:123`）。
  - **`clear(state:)`（`:207`）**：整个后端最能体现"Metal 与 OBS 心智模型冲突"的函数。
    文档注释解释得很清楚：M/A 系列是 tile-based 延迟渲染 GPU，clear 是 tile **load action** 的副产物，
    没有 render pass 就什么都不会发生；而 OBS 依赖"切到空场景时画面真的被清掉"。
    解法是排一个**最轻量的 pipeline**：只有一个恒返回 0 的 vertex function、**没有 fragment shader**、
    只跑 load + store。作者自评"确实比原生做法低效，但这是唯一能与 libobs 渲染系统对齐的办法"。
  - **`draw(...)`（`:349`）**：注释讲透了 pipeline 缓存的动机——OBS 的混合/滤镜/格式转换会被用户随时改，
    shader × blend × attachment 的组合会不断变，逐 draw 重建 pipeline 太贵，所以**按 descriptor 的
    `hashValue` 缓存 `MTLRenderPipelineState`**，命中就复用。
  - `ensureCommandBuffer()`（`:535`）：懒建 command buffer——**一帧里的多个 draw 共用一个 buffer**。
  - `finishPendingCommands()`（`:576`）：`commit()` 之后把 `inFlightRenderTargets` 里所有纹理的
    `hasPendingWrites` 清掉并清空集合。**这套"脏写集合"是纹理拷贝正确性的关键**：
    `copyTexture`（`:602`）/`stageTexture`（`:635`）开头都会检查 `source.hasPendingWrites`，
    为真就先 `finishPendingCommands()`，保证 blit 排在 draw 之后。
  - `finishDisplayRenderStage()`（`:554`）：单独开一个
    `makeCommandBufferWithUnretainedReferences()` 只为 `encoder.updateFence(swapChain.fence)`。
  - **`blitSwapChains()`（`:149`）**：`CVDisplayLink` 回调里跑。先过滤掉 `discard` 的交换链，
    然后对每个交换链 `layer.nextDrawable()`；**尺寸/格式不匹配就整帧跳过**（`:165` 附近的三重 guard）——
    这也是 resize 瞬间会闪的原因。匹配则 `waitForFence` → `copy(from:to:)` → `present(drawable)`。
  - `stageTextureToBuffer`（`:668`）/ `stageBufferToTexture`（`:704`）：GPU↔CPU 的两个方向，
    配合 `MetalStageBuffer` 完成 `gs_stagesurface_map` 那套语义。
- **看点**：三条可直接搬进 WorkLabs 的经验：①**pipeline / depth-stencil state 用 descriptor hash 做缓存**，
  是把"状态机 API"套到 Metal 上的最小代价方案；②**clear 必须靠一次空 draw 强制**，
  不然空场景/空画布会留上一帧残影——这个坑不看这份代码几乎必踩；
  ③**用 `hasPendingWrites` + `inFlightRenderTargets` 显式管"写后读"依赖**，
  比到处 `waitUntilCompleted` 便宜得多。反面教训是 `swapChains` 用数组 + `swapChainQueue.sync` 手动同步，
  而 `blitSwapChains` 里的过滤和遍历并不在同一个同步块内——多投影仪频繁开关时这块看着不太稳。

### `MetalTexture.swift`

**读者最需要的一块：CVPixelBuffer / IOSurface 怎么变成 `MTLTexture`。**

- **做什么**：`MTLTexture` 的包装类，同时持有**两个** texture 对象——`texture`（线性）和
  `sRGBtexture`（sRGB 变体的 texture view，`:48`），外加可选的 `stageBuffer`（`:50`）和
  `hasPendingWrites` 脏标记。libobs 拿到的 `gs_texture_t *` 其实就是这个类的不透明指针。
- **IOSurface → MTLTexture 的完整路径**（三步，没有中间拷贝）：
  1. **插件侧**：`CVPixelBufferGetIOSurface(pixelBuffer)` 取出 `IOSurfaceRef`
     （libobs 与后端都完全不认识 CoreVideo；参考 `plugins/mac-avcapture/OBSAVCapture.m:1273`，见 02 篇的表）。
  2. **抽象层**：`gs_texture_create_from_iosurface` / `gs_texture_rebind_iosurface`
     （`graphics.c:3000`/`:3012`）转发给后端。
  3. **Metal 后端**：`device_texture_create_from_iosurface`（`metal-texture2d.swift:476`）
     → `MetalTexture(device:surface:)`（`MetalTexture.swift:100`）
     → **`MetalTexture.bindSurface`（`:57`）**，也就是真正的转换点，只有 4 步：
     ```
     IOSurfaceGetPixelFormat(surface) → MTLPixelFormat.init(osType:)   // 格式映射，失败即 assert + nil
     MTLTextureDescriptor.texture2DDescriptor(pixelFormat:width:height:mipmapped:false)
     descriptor.usage = [.shaderRead]                                  // 只读，不能当渲染目标
     device.device.makeTexture(descriptor:iosurface:plane:0)           // ← 零拷贝绑定，plane 恒为 0
     ```
- **关键入口**：
  - `bindSurface`（`:57`，`private static`）：如上。**注意 `plane: 0` 是硬编码**——
    ⇒ **多平面（biplanar）的 IOSurface（如 `420v`/`420f` NV12、`x420` P010）在 Metal 后端拿不到 UV 平面**，
    只会当成第 0 平面。配合下面的格式清单，这是本篇最实用的一条限制。
  - `MTLPixelFormat.init(osType:)`（`MTLPixelFormat+Extensions.swift:371`）→
    `OSType.mtlFormat`（`CVPixelFormat+Extensions.swift:23`）。**实测只支持 11 种**：
    `OneComponent8/16Half/32Float`、`TwoComponent8/16Half/32Float`、`32BGRA`、`32RGBA`、
    `64RGBAHalf`、`128RGBAFloat`、`ARGB2101010LEPacked`（→ `.bgr10a2Unorm`）。
    **其余（含所有 YUV / 420 系列）返回 `nil`，纹理创建直接失败。**
  - `rebind(surface:)`（`:169`）：注释原话点明——"rebind 是 OpenGL 时代的做法，Metal 里没有"。
    实现是**建一个新的 `MTLTexture` 换掉 `self.texture`**，外层 `MetalTexture` 指针不变，
    所以 libobs 那边可以一直握着同一个 `gs_texture_t *`。之后必须 `updateSRGBView()` 重建 sRGB view。
  - `updateSRGBView()`（`:184`）：`isFramebufferOnly` 的纹理直接放弃；否则按
    `bgra8Unorm→bgra8Unorm_srgb`、`rgba8Unorm→…`、`r8Unorm`、`rg8Unorm`、**`bgra10_xr→bgra10_xr_srgb`**
    五种映射建 `makeTextureView(pixelFormat:)`，其余 `nil`。
    **这就是 Metal 后端实现"sRGB 感知渲染"的全部机制**——同一块显存两个视图，
    绑哪个由 `MetalShader.updateUniform`（`MetalShader.swift:166`，看 `gs_shader_texture.srgb` 标志）决定。
    ⇒ **Metal 后端并不真正使用 `device_load_texture_srgb`**（那函数确实在 `metal-texture2d.swift:167` 有实现，
    但它不在 `gs_exports` 里、也不被 Metal 自己调用；D3D11 与 GL 是从各自的 shader 参数上传处调它的，
    见 `d3d11-shader.cpp:345`、`gl-shader.c:499`）。
  - `map(mode:mipmapLevel:)`（`:326`）/ `unmap`（`:369`）：**模拟 D3D11 的 map/unmap**。
    文档注释把 D3D11 语义（写模式给 CPU 指针、读模式先把纹理拷到 CPU、期间 GPU 被阻塞、可能隐式 flush）
    一条条列出来再说明 Metal 没有对应物，只能显式模拟——**但不阻塞 GPU 访问**。
    `:338` 留了个 TODO：还没评估"blit 到共享 `contents` 指针的 `MTLBuffer`"是否更快。
  - `download`（`:215`）/ `upload`（`:234`）：两处文档注释都用 `> Important` 警告
    **不做任何同步保护**，draw call 与它并发时结果不可预期，要调用方自己先同步。
- **看点**：对你在 macOS 做合成，这个文件给出三条硬结论：
  ①**零拷贝路径只有 `makeTexture(descriptor:iosurface:plane:)` 这一条**，
  且必须是上面 11 种像素格式之一——所以摄像头/解码器输出务必配成 `32BGRA` 或 `ARGB2101010LEPacked`，
  否则要么走 CPU 上传，要么自己做 YUV→RGB 的 shader 并**自己按 plane 建两张纹理**（OBS 的 Metal 后端没做这件事）。
  ②**"rebind" 的正确语义是"换 MTLTexture、保外层句柄"**，不是真的改绑定——照抄这个包装层能省掉上层每帧重建纹理。
  ③**sRGB 用 texture view 而不是 sampler 状态或 shader 里手算**，这是 Metal 上最省的做法，值得直接采用。

### `OBSShader.swift`

- **做什么**：1603 行的 `.effect`（HLSL 方言）→ **MSL** 转译器，`libobs-metal` 里最大的单文件。
  输入是 `effect-parser.c` 拼好的单 pass shader 文本，输出一份完整的 MSL 源码字符串 + 一份
  `MetalShader.ShaderData` 元数据（uniform 布局、vertex descriptor、sampler 列表）。
- **关键入口**：
  - `init(type:content:fileLocation:)`（`:122`）：只接受 `.vertex` / `.fragment`；
    调抽象层的 C 函数 **`shader_parse`（`:138`）** 做词法/语法分析，
    warning 也当 `ShaderError.parseError` 抛（比 GL 后端严格——GL 那边只 `blog(LOG_WARNING)`，
    见 `gl-shaderparser.c:760`-`:772`）。
  - `transpiled()`（`:155`）：六步流水线，顺序固定
    → `analyzeUniforms`（`:421`）→ `analyzeParameters`（`:477`）→ `analyzeFunctions`（`:638`）
    → `transpileUniforms`（`:738`）→ `transpileStructs`（`:771`）→ `transpileFunctions`（`:857`）
    → 最后 `buildMetadata`（`:184`），拼成 `[header, uniforms, structs, functions]`。
    MSL 头就两行（`MSLTemplates.header` `:85`）：`#include <metal_stdlib>` + `using namespace metal;`。
  - `buildMetadata()`（`:184`）：注释里点出了最容易踩的坑——
    **MSL 没有全局变量，uniform 必须打包成 struct 走 buffer，而 MSL 基于 C++14，struct 有 size/stride/alignment**，
    所以**uniform 的声明顺序是"承重"的（load-bearing）**，字节偏移必须按同样顺序算出来
    （对齐规则在 `libobs+Extensions.swift:120`/`:141` 的 `mtlSize`/`mtlAlignment`）。
  - `transpileFunctionContent`（`:1110`）：函数体逐 token 重写。**四条 workaround 就落在这附近**——
    `:1211`-`:1216` 能看到把纹理 `Load` 的参数硬转成 `int2(...)`/`int(...)` 的代码。
  - `convertToMTLType`（`:1244`）：HLSL 类型名 → MSL 类型名；
    `convertToMTLMapping`（`:1300`）：`POSITION`/`TEXCOORD0` 等 semantic → MSL 属性（`[[position]]`/`[[attribute(n)]]` 等）。
  - 中间表示是三个 `private struct`：`OBSShaderFunction`（`:42`）、`OBSShaderVariable`（`:57`）、`OBSShaderStruct`；
    变量归类用位掩码 `VariableType`（`:29`：uniform/struct/structMember/input/output/texture/constant）。
- **看点**：**macOS 上 shader 出错的完整链路就是这里**：
  `.effect` 文件 → `effect-parser.c` 拼 pass 文本 → `gs_pixelshader_create`
  → `metal-shader.swift:109` → `OBSShader.init`（`shader_parse`）→ `transpiled()`
  → `MetalShader.init`（`MTLDevice.makeLibrary`）。
  报错分三类且**文案前缀不同**，据此就能判断卡在哪一层：`OBSShaderParserError`（C lexer 阶段）、
  `OBSShaderError.transpileError`（Swift 转译阶段）、`MetalShaderError`（MSL 编译阶段），
  枚举都在 `MetalError.swift:84`/`:107`/`:70`。
  对 WorkLabs 的启示：**如果只做 Metal 后端，这 1603 行是可以整体砍掉的**——
  直接写 `.metal` 文件让 Xcode 编译，或让自己的 effect 格式直出 MSL。
  但如果想沿用 OBS 那 21 个自带 `.effect`（滤镜/转场都在里面），这一层就是必须付的税，
  而且**上面那四条 workaround 一条都躲不掉**。

### `gl-cocoa.m`

- **做什么**：616 行，OpenGL 后端的 **macOS 平台层**（对应 Windows 的 `gl-windows.c`、Linux 的 `gl-nix.c`）。
  管三件事：`NSOpenGLContext` 的创建与 current 切换、交换链（`NSView` + FBO）的建立与呈现、
  **IOSurface → GL 纹理**。这是**当前 macOS 上 OBS 默认真正在跑的代码**，比 Metal 后端更该先读。
- **关键结构**（都在文件头）：`gl_windowinfo`（`:24`：`NSView` + 自己的 `NSOpenGLContext` + 一张纹理 + 一个 `fbo`）、
  `gl_platform`（`:31`，只有一个共享用的主 context）、`OBSFrameBufferUpdateData`（`:35`，跨线程传参用的值类型）。
- **关键入口**：
  - `gl_context_create`（`:44`）：`NSOpenGLPFADoubleBuffer` + **`NSOpenGLProfileVersion3_2Core`**，
    也就是 macOS 上封顶的 GL 3.2 Core（`GL_SILENCE_DEPRECATION` 在 `libobs-opengl/CMakeLists.txt:49` 里加的）。
  - `gl_platform_create`（`:70`）：建主 context、`makeCurrentContext`、**`swapInterval = 0`（关垂直同步）**。
  - **`gl_platform_init_swapchain`（`:105`）**：每个预览/投影仪一个**独立 context**（与主 context share），
    并且**不直接渲到窗口**——建一张 `GS_RENDER_TARGET` 纹理（`:121`）+ 一个 FBO（`:146`），
    用 `glFramebufferTexture2D` 把纹理挂到 `GL_COLOR_ATTACHMENT0`（`:153`）。
    全过程用 `CGLLockContext` 两把锁（主 context + swap context）包住，`goto init_swapchain_cleanup` 统一收尾。
    ⇒ **和 Metal 后端一样是"离屏渲染 + 后续 blit"，只是这里的中转是 FBO 而非 `CAMetalLayer` 的离屏纹理。**
  - `gl_windowinfo_create`（`:213`）：设 `wantsBestResolutionOpenGLSurface = YES`（Retina）、
    并**把窗口 colorSpace 强制成 `NSColorSpace.sRGBColorSpace`**（`:227`）——GL 后端不做 HDR 的原因之一。
  - `gl_update`（`:322`）→ `updateSwapchainFramebuffer`（`:246`）：resize 时重建 FBO 纹理。
    注意它是 **`dispatch_async(dispatch_get_main_queue(), ...)`**（`:345`），并手动 `retain`/`release` 两个 context——
    因为 `setView:` 一族必须在主线程。
  - `device_enter_context`（`:359`）/ `device_leave_context`（`:366`）：**GL 有线程上下文，Metal 没有**。
    这里是 `CGLLockContext` + `makeCurrentContext`；leave 时 `glFlush` + `clearCurrentContext`
    并把 device 的 6 个 "cur_*" 字段全部置空。对照 `metal-unimplemented.swift:23`/`:28` 那两个空壳看，一目了然。
  - **`device_present`（`:402`）**：呈现的真身。`glFlush` → 换到 swap context →
    `glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo)` + `DRAW_FRAMEBUFFER = 0` →
    **`glBlitFramebuffer(0,0,w,h, 0,h,w,0, ...)`**（`:437`，注意 dst 的 y 是 `h→0`，**上下翻转**）
    → `[swapChainContext flushBuffer]` → 恢复原 context。
  - `device_is_present_ready`（`:397`）**恒 true**、`device_is_monitor_hdr`（`:453`）**恒 false**。
  - **`device_texture_create_from_iosurface`（`:466`）**：GL 侧的零拷贝。
    只认**两种**像素格式（`metal` 那边认 11 种但只用 plane 0，这边更窄）：
    `ARGB2101010LEPacked` → `GS_R10G10B10A2`；`32BGRA` → `GS_BGRA`。
    **另外还专门收了 `case 0`**（`:491`）——注释解释：2dc6d31 之前的 Syphon 给出的 IOSurface 像素格式是 0，
    严格说是无效的，但实际上都是 32BGRA，而 OBS 历史上有个 bug 把无效格式当 32BGRA 处理，
    为了不弄坏 Syphon，**这个"错误"行为被故意保留**。绑定用
    `CGLTexImageIOSurface2D`（`:524`），target 是 **`GL_TEXTURE_RECTANGLE_ARB`**（`:511`）。
  - `gs_texture_rebind_iosurface`（`:566`）：**真正的 rebind**——同一个 GL 纹理名，
    重新 `CGLTexImageIOSurface2D` 指向新 surface（对比 Metal 是换 `MTLTexture` 对象）。
  - `device_texture_open_shared`（`:552`）：`IOSurfaceLookupFromMachPort` 后转调 create，
    并且**记得 `CFRelease(ref)`**（Metal 版 `metal-texture2d.swift:519` 没有这一步，
    且文档注释自己警告 32 位 handle 在 64 位系统上可能不够宽）。
- **看点**：三条：①**`GL_TEXTURE_RECTANGLE_ARB` 是 macOS GL 后端一切"坐标不对"问题的根**——
  UV 是像素而非归一化，所以有 `gs_texture_is_rect`（`gl-texture2d.c:244`）、
  有 `graphics.c:1066` 的 sprite UV 分叉、有插件里的 `GS_DEVICE_OPENGL` 分支。
  换到 Metal 这些全部消失，**这是 Metal 后端最实在的一个好处**。
  ②`glBlitFramebuffer` 那次上下翻转（`:437`）说明**GL 后端的整条流水线是 Y 轴翻转的**，
  你如果照抄 OBS 的滤镜/合成公式又用 Metal，要注意翻转是在这一层补的、不在 shader 里。
  ③GL 后端**每个预览一个 context**、靠 `CGLLockContext` 串行化；Metal 后端**一个 device 一个 command queue**、
  靠 fence 与 `CVDisplayLink`。两种并发模型都在这一个仓库里，对照读一遍收获很大。

---

## `libobs-opengl/`　OpenGL 后端（C，唯一全平台）

**职责**：唯一无条件参与编译的后端（顶层 `CMakeLists.txt:27`），也是 macOS 与 Linux 的实际默认。
结构是**"公共 GL 代码 + 平台层"**：`gl-subsystem.*` 与各资源对象文件跨平台通用，
`gl_platform_*` / `gl_windowinfo_*` / `device_enter_context` / `device_present` 这一组由平台文件各自实现
（macOS: `gl-cocoa.m`；Windows: `gl-windows.c`；Linux/BSD: `gl-nix.c` 再分发到 x11-egl / wayland-egl）。
GL 函数加载靠 `deps/glad`（`libobs-opengl/CMakeLists.txt:6`-`:7`，第三方 loader，不在本篇范围）。

### 公共层

| 文件 | 行数 | 功能 |
|---|---|---|
| `gl-subsystem.c` | 1627 | 后端主体：`device_create`（`:263`）、`device_destroy`（`:327`）、渲染目标切换（`:873`/`:896`）、`device_draw`（`:1101`）、`device_clear`（`:1168`）、混合/深度/模板/视口全套、`convert_sampler_info`（`:171`）、GL 调试回调 `gl_debug_proc`（`:34`）、扩展探测 `gl_init_extensions`（`:132`）、`device_nv12_available`（`:1506`，非 Windows 恒 true） |
| `gl-subsystem.h` | 677 | 后端内部头：`gs_texture`/`gs_texture_2d`/`gs_shader`/`gs_program`/`gs_device` 等全部结构体；`convert_gs_format`/`convert_gs_internal_format` 等格式转换 `static inline`（从 `:35` 起）；`enum copy_type`（ARB / NV / FBO_BLIT 三种纹理拷贝路径） |
| `gl-shaderparser.c` | 773 | HLSL 方言 → **GLSL** 重写器。`gl_shader_parse`（`:760`）先调抽象层 `shader_parse`（`:762`）再 `gl_shader_buildstring`（`:720`）。内建函数逐个改写：`gl_write_mad`（`:271`）、`gl_write_mul`（`:295`）、`gl_write_sincos`（`:316`）、`gl_write_saturate`（`:360`）、纹理采样 `gl_write_texture_code`（`:410`）；semantic → attribute 由 `gl_rename_attributes`（`:696`）收尾 |
| `gl-shaderparser.h` | 88 | 文件头注释原话点明定位：把 shader 解析成 GLSL，"几乎等同 HLSL model 5，所以需要不少改写"。定义 `gl_parser_attrib`（`:29`）与 `gl_shader_parser`（`:45`） |
| `gl-shader.c` | 763 | GL 侧 shader/program 对象：`shader_create`（`:238`）、`device_vertexshader_create`（`:263`）/`device_pixelshader_create`（`:272`）、参数与 sampler 收集（`:62`/`:100`）、attribute 处理（`:120`/`:146`）、`gs_program_create`（`:601`，**GL 特有：vs+ps 要链接成 program**）、参数上传处 `:499` 调 `device_load_texture_srgb` |
| `gl-texture2d.c` | 267 | 2D 纹理：`device_texture_create`（`:76`）、`gs_texture_destroy`（`:131`）、`map`/`unmap`（`:183`/`:213`，走 PBO：`create_pixel_unpack_buffer` `:45`）、**`gs_texture_is_rect`（`:244`）** |
| `gl-stagesurf.c` | 230 | GPU→CPU 暂存面，用 pixel pack buffer（`:20`）；`device_stage_texture` **有两份实现**（`:113` 与 `:158`，按是否支持某扩展条件编译）；`gs_stagesurface_map`（`:202`） |
| `gl-vertexbuffer.c` | 257 | VBO + attribute 绑定：`create_buffers`（`:21`）、`load_vb_buffers`（`:234`，把 program 的 attrib 与 buffer 对上） |
| `gl-indexbuffer.c` | 114 | IBO，最简单的一个文件 |
| `gl-zstencil.c` | 84 | 深度模板 renderbuffer；`get_attachment`（`:37`）决定挂 DEPTH 还是 DEPTH_STENCIL |
| `gl-texture3d.c` / `gl-texturecube.c` | 169 / 120 | volume 纹理（3D LUT）/ cube 纹理 |
| `gl-helpers.c` / `gl-helpers.h` | 152 / 224 | 错误码转字符串 `gl_error_to_str`（`.h:20`）、`gl_success`/`gl_gen_textures`/`gl_bind_texture` 一族带错误检查的包装宏、纹理拷贝 `gl_copy_texture`（`.c:94`，内部可退化成 `gl_copy_fbo` `:54`）、buffer 创建与更新（`:118`/`:133`） |

### 平台层

| 文件 | 行数 | 平台 | 功能 |
|---|---|---|---|
| `gl-cocoa.m` ⭐ | 616 | **macOS** | `NSOpenGLContext`（3.2 Core）、每交换链一个 context + FBO、`glBlitFramebuffer` 呈现、`CGLTexImageIOSurface2D` 绑 IOSurface。详见上方展开 |
| `gl-windows.c` | 605 | Windows | WGL：dummy 窗口 + pixel format 协商（`:74`/`:97`/`:118`）、`gl_init_context`（`:156`）、必需扩展检查（`:232`） |
| `gl-nix.c` | 208 | Linux/BSD | **薄分发层**：按 `obs-nix-platform` 选 x11-egl 或 wayland-egl 的 vtable（`init_winsys` `:27`），其余函数全是一行转发 |
| `gl-nix.h` | 86 | Linux/BSD | `struct gl_winsys_vtable`（`:25`）——平台层的函数表契约 |
| `gl-x11-egl.c` / `.h` | 666 / 22 | Linux X11 | EGL over X11：`get_egl_display`（`:142`）、context 创建（`:168`）、XCB 取窗口几何（`:91`） |
| `gl-wayland-egl.c` / `.h` | 476 / 22 | Linux Wayland | EGL over Wayland：`egl_context_create`（`:133`）、平台创建（`:177`） |
| `gl-egl-common.c` / `.h` | 581 / 46 | Linux 共用 | **dmabuf / EGLImage 零拷贝**（Linux 的 IOSurface 等价物）：`create_dmabuf_egl_image`（`:90`）、`gl_egl_create_texture_from_eglimage`（`:177`）、`gl_egl_create_texture_from_pixmap`（`:269`）、dmabuf 格式与 modifier 查询（`:300`/`:329`）、adapter 枚举（`:202`）、以及 syncobj timeline 同步一族 |

---

## `libobs-d3d11/`　Windows Direct3D 11 后端

**职责**：Windows 默认后端（C++，14 个文件 7296 行）。与前两者最大的结构差异是它**必须处理设备丢失（device loss）**——
驱动崩溃/更新/远程桌面切换后 D3D11 设备会失效，OBS 要在不丢会话的前提下把所有 GPU 资源重建一遍。
这就是 `d3d11-rebuild.cpp` 存在的理由，也是 `gs_exports` 里那一堆 Windows 专属可选符号
（`device_register_loss_callbacks` 等）的来源。macOS 开发者可以整目录跳过，但**"每个资源类都实现 `Rebuild()`"这个模式值得知道**。

| 文件 | 行数 | 功能 |
|---|---|---|
| `d3d11-subsystem.cpp` | 3435 | 后端主体：设备/适配器枚举、全套状态、draw、共享纹理/GDI 纹理/NT handle、`device_register_loss_callbacks`（`:3395`）；`device_get_name`/`_type`/`_preprocessor_name` 在 `:936`/`:941`/`:946` |
| `d3d11-subsystem.hpp` | 1046 | 全部资源类定义（`gs_texture_2d`、`gs_vertex_buffer`、`gs_shader`、`gs_swap_chain`、`gs_device` `:962`…），**每个类都有 `Rebuild(ID3D11Device*)`**（16 处） |
| `d3d11-rebuild.cpp` | 605 | 设备丢失恢复：各资源 `Rebuild()` 实现 + `gs_device::RebuildDevice()`（`:418`），逐个回调 `loss_callbacks`（`:427`/`:596`）。触发点在 `d3d11-subsystem.cpp:2417` |
| `d3d11-shader.cpp` | 526 | shader 对象；**shader 文本原样交 `D3DCompile`**（`:281`）——因为 `.effect` 本来就是 HLSL 方言，不需要重写。参数上传处 `:345` 调 `device_load_texture_srgb` |
| `d3d11-shaderprocessor.cpp` / `.hpp` | 247 / 38 | 只从 `shader_parse`（`:237`）取**元数据**：`BuildInputLayoutFromVars`（`:107`）建 input layout、semantic 名映射（`:24` 两张表，`POSITION`→`SV_Position` 等） |
| `d3d11-texture2d.cpp` | 381 | 2D/cube 纹理 + `InitSRD`（`:21`，subresource data 数组） |
| `d3d11-texture3d.cpp` | 236 | volume 纹理 |
| `d3d11-duplicator.cpp` | 315 | **DXGI 桌面复制（Desktop Duplication）**——Windows 屏幕采集的底座，`get_monitor`（`:21`）起 |
| `d3d11-vertexbuffer.cpp` | 147 | 顶点缓冲，多个 UV 通道各一个 buffer（`PushBuffer` `:22`） |
| `d3d11-samplerstate.cpp` | 90 | `gs_sampler_info` → `D3D11_SAMPLER_DESC`（`ConvertGSAddressMode` `:23`） |
| `d3d11-stagesurf.cpp` | 68 | 暂存面 = `D3D11_USAGE_STAGING` 纹理（构造器 `:20`，P010 变体 `:45`） |
| `d3d11-indexbuffer.cpp` / `d3d11-zstencilbuffer.cpp` | 57 / 57 | 索引缓冲 / 深度模板 |

---

## `libobs-winrt/`　并不是图形后端

**职责**：C++/WinRT 写的**薄封装库**，把 `Windows.Graphics.Capture`（Win10 1803+ 的现代窗口/显示器采集 API）
包成纯 C 接口给 `plugins/win-capture/` 用。消费方实测只有两个文件：
`plugins/win-capture/duplicator-monitor-capture.c:10`（显示器采集）与 `window-capture.c:11`（窗口采集）。
和 `gs_exports` **毫无关系**——它不导出任何 `device_*` 符号，也不参与后端选择。

| 文件 | 行数 | 功能 |
|---|---|---|
| `winrt-capture.cpp` | 606 | 采集会话本体：`struct winrt_capture`（`:94`）、`winrt_capture_init_window`（`:434`）/`_init_monitor`（`:440`）、`winrt_capture_render`（`:528`，把采集帧交给 OBS 纹理）、色彩空间查询（`:523`）、光标开关（`:500`）、采集线程启停（`:589`/`:599`） |
| `winrt-capture.h` | 30 | 13 个 `EXPORT` 的 C 声明（`extern "C"` 包裹），供 C 插件 include |
| `winrt-dispatch.cpp` / `.h` | 56 / 19 | WinRT 运行时初始化与 dispatcher 队列：`winrt_initialize`/`winrt_uninitialize`/`winrt_dispatcher_init`/`_free` |

---

## 三后端文件对照表

同一个 `gs` 概念在三个后端各落在哪个文件（—＝该后端不单独成文件，或整族未实现）：

| gs 概念 | `libobs-metal/`（Swift） | `libobs-opengl/`（C） | `libobs-d3d11/`（C++） |
|---|---|---|---|
| 设备与全局状态 | `metal-subsystem.swift` + `MetalDevice.swift` | `gl-subsystem.c` / `.h` | `d3d11-subsystem.cpp` / `.hpp` |
| "当前状态"容器 | `MetalRenderState.swift` | `struct gs_device`（`gl-subsystem.h`） | `struct gs_device`（`d3d11-subsystem.hpp:962`） |
| 平台层（窗口/上下文） | `metal-swapchain.swift` + `OBSSwapChain.swift` | `gl-cocoa.m` / `gl-windows.c` / `gl-nix.c`(+egl) | 同在 `d3d11-subsystem.cpp`（DXGI） |
| shader 语言翻译 | `OBSShader.swift`（→ MSL） | `gl-shaderparser.c`（→ GLSL） | `d3d11-shaderprocessor.cpp`（只取元数据，文本直给 `D3DCompile`） |
| shader 对象 | `MetalShader.swift` + `metal-shader.swift` | `gl-shader.c`（含 program 链接） | `d3d11-shader.cpp` |
| 2D / cube 纹理 | `MetalTexture.swift` + `metal-texture2d.swift` | `gl-texture2d.c` + `gl-texturecube.c` | `d3d11-texture2d.cpp` |
| 3D（volume）纹理 | `metal-texture3d.swift` | `gl-texture3d.c` | `d3d11-texture3d.cpp` |
| 顶点缓冲 | `MetalBuffer.swift` + `metal-vertexbuffer.swift` | `gl-vertexbuffer.c` | `d3d11-vertexbuffer.cpp` |
| 索引缓冲 | `MetalBuffer.swift` + `metal-indexbuffer.swift` | `gl-indexbuffer.c` | `d3d11-indexbuffer.cpp` |
| 暂存面 stagesurf | `MetalStageBuffer.swift` + `metal-stagesurf.swift` | `gl-stagesurf.c` | `d3d11-stagesurf.cpp` |
| 深度模板 zstencil | `metal-zstencilbuffer.swift` | `gl-zstencil.c` | `d3d11-zstencilbuffer.cpp` |
| 采样器 samplerstate | `metal-samplerstate.swift` | 在 `gl-subsystem.c:171` | `d3d11-samplerstate.cpp` |
| GPU 计时器 | `metal-unimplemented.swift`（**空壳**） | `gl-subsystem.c` | `d3d11-subsystem.cpp` |
| 线程上下文 enter/leave | `metal-unimplemented.swift`（**空壳**） | `gl-cocoa.m:359`/`:366` 等平台文件 | `d3d11-subsystem.cpp`（空操作） |
| 跨进程共享纹理 | `metal-texture2d.swift:463`-`:528`（IOSurface） | `gl-cocoa.m:466`-`:616`（IOSurface）/ `gl-egl-common.c`（dmabuf） | `d3d11-subsystem.cpp`（DXGI 共享句柄） |
| 屏幕采集底座 | — | — | `d3d11-duplicator.cpp` + `libobs-winrt/` |
| 设备丢失重建 | — | — | `d3d11-rebuild.cpp` |
| 类型转换胶水 | `libobs+Extensions.swift` 等 10 个 `+Extensions` | `gl-subsystem.h` 的 `static inline` | `d3d11-subsystem.hpp` 的 `Convert*` |
| 错误处理 | `MetalError.swift` | `gl-helpers.h` 的 `gl_error_to_str` | `HRESULT` + `d3d11-subsystem.hpp` 的异常类 |

---

## 阅读建议

1. **先读 `libobs-metal/README.md`（83 行，10 分钟）**，再读代码。它把
   "为什么预览会卡"（`:51`-`:63`，`CAMetalLayer` 只给 3 个 drawable）和
   "MSL 严格性导致的四条 workaround"（`:75`-`:84`）讲得比任何注释都集中。
   这份 README 是全仓库少见的"作者主动交代设计取舍"的文档，读完再看代码事半功倍。
2. **Metal 后端的最短必读路径（约 700 行）**：
   `MetalTexture.swift:52`-`:206`（IOSurface 绑定 + rebind + sRGB view，**你最需要的那块**）
   → `MetalDevice.swift:207`-`:260`（模拟 clear 的注释）
   → `MetalDevice.swift:330`-`:360`（pipeline 缓存的动机）
   → `MetalDevice.swift:123`-`:185`（`CVDisplayLink` + `blitSwapChains`）
   → `metal-unimplemented.swift`（97 行全读，知道哪些能省）。
   **`metal-subsystem.swift` 的 985 行不要顺读**——41 个函数形状高度重复，按名字 grep 即可。
3. **`OBSShader.swift`（1603 行）建议只读三段**：`init`（`:122`-`:150`，看 `shader_parse` 怎么被调）、
   `transpiled()`（`:155`-`:182`，看六步流水线）、`buildMetadata()` 的文档注释（`:184`-`:200`，看 MSL 对齐为什么"承重"）。
   剩下 1300 行是逐 token 字符串重写，读了收获很低。**如果你决定不复用 OBS 的 `.effect`，整个文件可以跳过。**
4. **`gl-cocoa.m` 要完整读一遍**（616 行）。它是 macOS 上**当前默认在跑**的代码，
   而且 `device_present`（`:402`）里那次 `glBlitFramebuffer` 的 Y 翻转、
   `GL_TEXTURE_RECTANGLE_ARB`（`:511`）、以及 `case 0` 的 Syphon 历史包袱（`:491`），
   都是你在 macOS 上做视频会踩到的同类问题。**和 Metal 后端对照读，能同时学到两种并发模型。**
5. **可以整块跳过的**：`libobs-d3d11/`（除了知道 `d3d11-rebuild.cpp` 这个"设备丢失 → 所有资源 `Rebuild()`"模式）、
   `libobs-winrt/`（Windows 采集封装，与图形后端无关）、
   `libobs-opengl/` 的 `gl-windows.c` / `gl-nix.c` / `gl-x11-egl.c` / `gl-wayland-egl.c` / `gl-egl-common.c`（非 macOS 平台层）、
   `gl-shaderparser.c`（如果不打算支持 GL）、以及 10 个 `MTL*+Extensions.swift` 里那 4 个只加 `Equatable` 的
   （`MTLViewport/MTLSize/MTLRegion/MTLOrigin`，合计 106 行）。
6. **给 WorkOBS/WorkLabs 的取舍建议**：
   - **值得直接照搬**：①`MetalTexture` 这个"包装类持有 linear + sRGB 两个 view、rebind 时换内层 `MTLTexture`"的设计；
     ②`descriptor.hashValue` → pipeline / depth-stencil state 缓存；
     ③`hasPendingWrites` + `inFlightRenderTargets` 显式管写后读依赖；
     ④"离屏渲染 + `CVDisplayLink` 回调里 blit 进 drawable + `MTLFence` 同步"这套预览方案
     （**你如果直接向 `CAMetalLayer` 的 drawable 渲染，帧率会被屏幕刷新率锁死**，这是 OBS 花了一整节 README 说明的坑）。
   - **可以大胆砍掉**：`OBSShader.swift` 整层（直接写 `.metal`）、GPU 计时器、cube/volume 纹理、
     debug marker、`device_enter/leave_context`（Metal 本就不需要，OBS 都是空壳）。
   - **必须自己补的**（OBS Metal 后端没做，而你大概会需要）：**多平面 IOSurface**——
     `MetalTexture.bindSurface`（`:57`）把 `plane` 硬编码为 0，且格式表（`CVPixelFormat+Extensions.swift:23`）
     不含任何 YUV 格式。要零拷贝吃摄像头/解码器的 NV12/P010，得自己按 plane 建两张纹理再在 shader 里做色彩转换。
