# libobs Core 逻辑架构图

> 源码位置: [`libobs/`](libobs/)
> 本文档用 Mermaid 绘制，GitHub / VSCode 可直接渲染。

---

## 一、整体分层架构

libobs 采用自底向上的分层设计，从平台/工具基础到核心对象模型，再到对外 API。

```mermaid
flowchart TB
    subgraph APP["应用层 (OBS Studio / 第三方应用)"]
        UI["OBS Studio UI (Qt)"]
    end

    subgraph PUBAPI["公共 API 层 (obs.h / obs.c)"]
        STARTUP["obs_startup / obs_shutdown<br/>生命周期管理"]
        REG["obs_register_source / encoder /<br/>output / service — 插件注册"]
    end

    subgraph CORE["核心对象模型层"]
        SRC["Source 源<br/>(obs-source.c)"]
        ENC["Encoder 编码器<br/>(obs-encoder.c)"]
        OUT["Output 输出<br/>(obs-output.c)"]
        SVC["Service 服务<br/>(obs-service.c)"]
        DISP["Display 显示<br/>(obs-display.c)"]
        VIEW["View 视图<br/>(obs-view.c)"]
    end

    subgraph PIPE["音视频管线层"]
        OVIDEO["obs-video.c<br/>主视频渲染循环"]
        OAUDIO["obs-audio.c<br/>主音频混合"]
        OGPUENC["obs-video-gpu-encode.c<br/>GPU 编码纹理"]
        ODELAY["obs-output-delay.c<br/>延迟输出缓存"]
        NAL["obs-avc / obs-hevc / obs-av1<br/>NALU 封装"]
    end

    subgraph MIO["媒体 IO 层 (media-io/)"]
        VIO["video-io.c<br/>视频输入输出"]
        AIO["audio-io.c<br/>音频输入输出"]
        VFRAME["video-frame.c<br/>帧结构/范围处理"]
        FCONV["format-conversion.c<br/>格式转换"]
        VSCALE["video-scaler-ffmpeg.c<br/>视频缩放"]
        ARSCALE["audio-resampler-ffmpeg.c<br/>音频重采样"]
        VMAT["video-matrices.c<br/>色彩矩阵"]
    end

    subgraph GFX["图形层 (graphics/)"]
        GRAPH["graphics.c<br/>图形设备抽象"]
        EFFECT["effect.c / effect-parser.c<br/>Shader/Effect 系统"]
        TEX["texture-render.c<br/>纹理渲染"]
        MATH["vec2/3/4, matrix3/4, quat<br/>数学库"]
        IMG["image-file.c / libnsgif<br/>图像解码"]
    end

    subgraph CB["回调系统 (callback/)"]
        SIG["signal.c<br/>信号"]
        PROC["proc.c<br/>过程调用"]
        CD["calldata.c<br/>调用数据"]
    end

    subgraph DATA["数据/属性层"]
        ODATA["obs-data.c<br/>设置数据 (obs_data_t)"]
        PROP["obs-properties.c<br/>属性 UI"]
        HOT["obs-hotkey.c<br/>热键"]
        MISS["obs-missing-files.c<br/>缺失文件"]
    end

    subgraph MOD["模块层"]
        OMOD["obs-module.c<br/>插件加载/管理"]
    end

    subgraph UTIL["工具库 (util/)"]
        BMEM["bmem.c 内存"]
        THREAD["threading 线程"]
        PLAT["platform.c 平台抽象"]
        DSTR["dstr / darray / circlebuf<br/>数据结构"]
        CFG["config-file.c 配置"]
        I18N["text-lookup.c 国际化"]
        PROF["profiler.c 性能分析"]
    end

    subgraph OS["平台适配层"]
        MAC["obs-cocoa.m (macOS)"]
        NIX["obs-nix.c (Linux)"]
        WIN["obs-windows.c (Windows)"]
        WL["obs-nix-wayland.c"]
        X11["obs-nix-x11.c"]
        AM["audio-monitoring/<br/>(null/pulse/wasapi/coreaudio)"]
    end

    UI --> PUBAPI
    PUBAPI --> CORE
    PUBAPI --> MOD
    CORE --> PIPE
    CORE --> DATA
    CORE --> CB
    PIPE --> MIO
    PIPE --> GFX
    GFX --> UTIL
    MIO --> UTIL
    CB --> UTIL
    DATA --> UTIL
    MOD --> UTIL
    CORE --> UTIL
    UTIL --> OS
    GFX --> OS
```

---

## 二、核心对象模型关系

`obs` 全局对象是所有核心对象的容器，对象之间通过引用组合成完整的采集→处理→编码→输出流水线。

```mermaid
flowchart LR
    OBS["obs 全局对象<br/>(obs.c)"]

    OBS --> DISPS["displays[]<br/>显示窗口列表"]
    OBS --> VIEWS["views[]<br/>视图列表"]
    OBS --> SOURCES["sources[]<br/>所有源 (哈希表)"]
    OBS --> ENCODERS["encoders[]<br/>编码器"]
    OBS --> OUTPUTS["outputs[]<br/>输出"]
    OBS --> SERVICES["services[]<br/>流媒体服务"]
    OBS --> MODULES["modules[]<br/>已加载插件"]

    subgraph SOURCE_HIER["源的类型体系"]
        INPUT["输入源 Input<br/>(摄像头/采集/窗口)"]
        FILTER["滤镜 Filter<br/>(色彩/模糊/掩码)"]
        TRANS["过渡 Transition<br/>(切换/淡入淡出)"]
        SCENE["场景 Scene<br/>(obs-scene.c)"]
    end

    SOURCES --> SOURCE_HIER

    SCENE -->|包含| ITEMS["scene items<br/>(场景中的源实例)"]
    ITEMS -->|引用| SOURCES

    FILTER -->|挂载到| SOURCES
    TRANS -->|引用两个| SOURCES

    ENCODERS -->|接收| SOURCES
    OUTPUTS -->|引用| ENCODERS
    OUTPUTS -->|引用| SERVICES
    OUTPUTS -->|引用| SOURCES

    VIEWS -->|包含| SOURCES
    DISPS -->|渲染| VIEWS
```

---

## 三、视频渲染数据流

从源采集到最终显示/编码的完整视频流水线。

```mermaid
flowchart LR
    subgraph CAPTURE["采集层"]
        ASYNC["异步源<br/>(obs_source_output_video)"]
        SYNC["同步源<br/>(video_render 回调)"]
    end

    subgraph CACHE["帧缓存 (obs-source.c)"]
        FRAME["obs_source_frame<br/>filter_video 滤镜链处理"]
        TEXCACHE["纹理缓存<br/>(NUM_TEXTURES=2 双缓冲)"]
    end

    subgraph RENDER["渲染管线 (obs-video.c)"]
        TICK["video_tick<br/>每帧时间步进"]
        RENDERCALL["obs_source_video_render<br/>递归渲染场景树"]
        FILTERRENDER["滤镜包装绘制<br/>obs_source_process_filter"]
    end

    subgraph OUTPUT_V["输出分流"]
        DISP_OUT["Display 显示<br/>(obs-display.c)"]
        ENC_TEX["编码纹理<br/>(obs-video-gpu-encode.c)"]
        CAPTURE_OUT["画面捕获"]
    end

    subgraph ENCODE["编码层"]
        GPUENC["GPU 编码器<br/>(共享纹理)"]
        CPUENC["CPU 编码器<br/>(回读 GPU 纹理)"]
        NALU["obs-avc/hevc/av1<br/>NALU 封装"]
    end

    ASYNC --> FRAME
    SYNC --> RENDERCALL
    FRAME --> TEXCACHE
    TEXCACHE --> RENDERCALL

    TICK --> RENDERCALL
    RENDERCALL --> FILTERRENDER
    FILTERRENDER --> RENDERCALL

    RENDERCALL --> DISP_OUT
    RENDERCALL --> ENC_TEX
    RENDERCALL --> CAPTURE_OUT

    ENC_TEX --> GPUENC
    ENC_TEX --> CPUENC
    GPUENC --> NALU
    CPUENC --> NALU
    NALU --> OUTPUT_PKT["encoder_packet<br/>送入 Output"]
```

---

## 四、音频混合数据流

音频从源采集到最终编码输出的完整流水线。

```mermaid
flowchart LR
    subgraph ACAP["音频采集"]
        ASRC["异步音频源<br/>(obs_source_output_audio)"]
    end

    subgraph AFILTER["音频处理 (obs-source.c)"]
        AFRAME["obs_audio_data<br/>filter_audio 滤镜链"]
        ACIRC["环形缓冲<br/>(每源时间对齐)"]
    end

    subgraph AMIX["音频混合 (obs-audio.c)"]
        MIXER["主混音器<br/>(NUM_CHANNELS=3)"]
        TRACK["音轨分组<br/>(1/2/3/4...)"]
    end

    subgraph AENC["音频编码"]
        AENCODER["音频编码器<br/>(obs-encoder.c)"]
    end

    subgraph AMON["音频监听"]
        MON["audio-monitoring/<br/>(pulse/wasapi/coreaudio)"]
    end

    subgraph AOUT["音频输出"]
        AOUTPUT["Output<br/>(推流/录像)"]
    end

    ASRC --> AFRAME
    AFRAME --> ACIRC
    ACIRC --> MIXER
    MIXER --> TRACK
    TRACK --> AENCODER
    MIXER --> MON
    AENCODER --> AOUTPUT
```

---

## 五、模块/插件加载机制

插件通过统一接口注册到 libobs，由 `obs-module.c` 在启动时加载。

```mermaid
flowchart TB
    START["obs_startup()"] --> LOADMOD["obs_load_modules()<br/>扫描插件目录"]
    LOADMOD --> DLOPEN["dlopen / LoadLibrary<br/>加载 .so/.dylib/.dll"]
    DLOPEN --> MODLOAD["调用 obs_module_load()<br/>(插件入口)"]

    MODLOAD --> REG1["obs_register_source(&info)"]
    MODLOAD --> REG2["obs_register_encoder(&info)"]
    MODLOAD --> REG3["obs_register_output(&info)"]
    MODLOAD --> REG4["obs_register_service(&info)"]

    REG1 --> SRCREG["源类型注册表"]
    REG2 --> ENCREG["编码器注册表"]
    REG3 --> OUTREG["输出注册表"]
    REG4 --> SVCREG["服务注册表"]

    SRCREG --> LOOKUP["obs_source_create(id, ...)<br/>运行时按 id 查找实例化"]
    ENCREG --> ELOOKUP["obs_encoder_create(id, ...)"]
    OUTREG --> OLOOKUP["obs_output_create(id, ...)"]
    SVCREG --> SLOOKUP["obs_service_create(id, ...)"]

    subgraph PLUGIN_TYPES["四类插件"]
        SRC_PLUGIN["源插件<br/>input/filter/transition"]
        ENC_PLUGIN["编码器插件<br/>H264/HEVC/AV1/AAC"]
        OUT_PLUGIN["输出插件<br/>RTMP/FLV/MP4"]
        SVC_PLUGIN["服务插件<br/>RTMP/SRT/custom"]
    end

    SRC_PLUGIN -.-> REG1
    ENC_PLUGIN -.-> REG2
    OUT_PLUGIN -.-> REG3
    SVC_PLUGIN -.-> REG4
```

---

## 六、图形设备抽象

libobs 通过函数指针表动态加载 GPU 后端（D3D11 / OpenGL / Metal），对上层提供统一接口。

```mermaid
flowchart TB
    subgraph UPPER["上层调用"]
        GRAPH_API["graphics.h API<br/>gs_texture_create / gs_draw / ..."]
    end

    subgraph ABSTRACT["图形设备抽象层 (graphics.c)"]
        DISPATCH["函数指针分发<br/>(device-exports.h)"]
        IMPORTS["graphics-imports.c<br/>加载后端导出符号"]
    end

    subgraph BACKEND["GPU 后端 (独立库 libobs-d3d11 / libobs-opengl / libobs-metal)"]
        D3D11["libobs-d3d11<br/>(Windows)"]
        OGL["libobs-opengl<br/>(Linux/Windows)"]
        METAL["libobs-metal<br/>(macOS)"]
    end

    subgraph RES["图形资源"]
        EFFECT_FILES[".effect 文件<br/>(data/ 目录)"]
        SHADER["effect-parser.c<br/>解析为 shader"]
        TEX_RES["纹理/渲染目标"]
    end

    UPPER --> GRAPH_API
    GRAPH_API --> DISPATCH
    DISPATCH --> IMPORTS
    IMPORTS --> D3D11
    IMPORTS --> OGL
    IMPORTS --> METAL

    EFFECT_FILES --> SHADER
    SHADER --> GRAPH_API
    GRAPH_API --> TEX_RES
```

---

## 七、回调与信号系统

libobs 使用 signal/proc 机制实现对象间松耦合通信。

```mermaid
flowchart LR
    subgraph EMITTER["信号发射方"]
        SOURCE_EV["obs-source 事件<br/>(activate/deactivate/...)"]
        OUTPUT_EV["obs-output 事件<br/>(start/stop/reconnect)"]
    end

    subgraph CBSYS["回调系统 (callback/)"]
        SIGNAL["signal.c<br/>信号订阅/发射"]
        PROC["proc.c<br/>过程调用 (同步请求)"]
        CALLDATA["calldata.c<br/>参数容器 (obs_data_t 类似)"]
    end

    subgraph RECEIVER["接收方"]
        HANDLER["UI 处理函数"]
        SCRIPT["脚本/插件回调"]
        INTERNAL["libobs 内部逻辑"]
    end

    EMITTER --> SIGNAL
    EMITTER --> PROC
    SIGNAL --> CALLDATA
    PROC --> CALLDATA
    SIGNAL --> RECEIVER
    PROC --> RECEIVER
```

---

## 八、目录结构速查

```mermaid
flowchart TB
    ROOT["libobs/"]

    ROOT --> CORE_FILES["核心文件 (顶层)"]
    ROOT --> MEDIA_IO["media-io/<br/>媒体 IO"]
    ROOT --> GRAPHICS["graphics/<br/>图形"]
    ROOT --> CALLBACK["callback/<br/>信号/过程调用"]
    ROOT --> UTIL["util/<br/>工具库"]
    ROOT --> AUDIO_MON["audio-monitoring/<br/>音频监听"]
    ROOT --> DATA["data/<br/>.effect 着色器"]
    ROOT --> CMAKE["cmake/<br/>构建配置"]

    CORE_FILES --> CF1["obs.c/obs.h<br/>核心 API"]
    CORE_FILES --> CF2["obs-source.c<br/>源对象"]
    CORE_FILES --> CF3["obs-video.c<br/>视频管线"]
    CORE_FILES --> CF4["obs-audio.c<br/>音频管线"]
    CORE_FILES --> CF5["obs-encoder.c<br/>编码器"]
    CORE_FILES --> CF6["obs-output.c<br/>输出"]
    CORE_FILES --> CF7["obs-scene.c<br/>场景"]
    CORE_FILES --> CF8["obs-module.c<br/>模块加载"]

    MEDIA_IO --> MI1["video-io / audio-io<br/>输入输出"]
    MEDIA_IO --> MI2["video-frame.c<br/>帧/范围处理"]
    MEDIA_IO --> MI3["format-conversion.c<br/>格式转换"]
    MEDIA_IO --> MI4["video-scaler / audio-resampler<br/>缩放/重采样"]

    GRAPHICS --> G1["graphics.c<br/>设备抽象"]
    GRAPHICS --> G2["effect.c / effect-parser.c<br/>Shader 系统"]
    GRAPHICS --> G3["vec/matrix/quat<br/>数学库"]

    UTIL --> U1["bmem / threading / platform<br/>基础"]
    UTIL --> U2["dstr / darray / circlebuf<br/>数据结构"]
    UTIL --> U3["config-file / text-lookup<br/>配置/国际化"]
```

---

## 九、总结

libobs 的核心架构可以归纳为三层流水线：

1. **对象模型层** — `source / encoder / output / service` 四类核心对象，由插件通过 `obs_register_*` 注册、由应用通过 `obs_*_create` 实例化。
2. **管线调度层** — `obs-video.c` 驱动视频渲染循环，`obs-audio.c` 驱动音频混合循环，二者以时间戳对齐。
3. **基础设施层** — `graphics/` 提供 GPU 抽象，`media-io/` 提供帧/格式处理，`util/` 提供跨平台基础，`callback/` 提供松耦合通信。

插件只需实现 `obs_source_info` / `obs_encoder_info` / `obs_output_info` / `obs_service_info` 中的回调函数指针，即可接入完整流水线，无需关心调度细节。
