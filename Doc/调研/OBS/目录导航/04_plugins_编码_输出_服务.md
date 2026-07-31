# OBS 目录导航 · plugins 编码 / 输出 / 服务（录制与推流全链路）

> 源码范围：`plugins/obs-ffmpeg/`、`plugins/obs-outputs/`、`plugins/obs-x264/`、`plugins/obs-libfdk/`、`plugins/coreaudio-encoder/`、`plugins/mac-videotoolbox/`、`plugins/obs-nvenc/`、`plugins/obs-qsv11/`、`plugins/obs-webrtc/`、`plugins/rtmp-services/`、`plugins/obs-vst/` ｜ 源文件 137 个（不含 `data/locale/*.ini`）｜ 基于 obs-studio commit `f2db097`（2026-07-09）
> 返回总索引：[README.md](README.md)

## 本篇速查

想找什么 → 去哪：

| 我想看… | 去这里 |
|---|---|
| macOS 上 `h264_videotoolbox` 怎么建会话、怎么取 SPS/PPS | [`mac-videotoolbox/encoder.c`](#mac-videotoolboxencoderc) |
| 录 mp4 为什么要开子进程复用 | [`obs-ffmpeg-mux.c`](#obs-ffmpeg-muxc) + [`ffmpeg-mux/ffmpeg-mux.c`](#ffmpeg-muxffmpeg-muxc) |
| 推流卡了以后怎么丢帧（拥塞策略） | [`rtmp-stream.c:1752`](#rtmp-streamc) `check_to_drop_frames` |
| 动态降码率（DBR）逻辑 | [`rtmp-stream.c:1623`](#rtmp-streamc) `dbr_bitrate_lowered` |
| FLV tag 怎么拼、增强 RTMP（HEVC/AV1/多轨）怎么打包 | [`flv-mux.c`](#flv-muxc) |
| 媒体文件源（播放本地视频）在哪 | [`obs-ffmpeg-source.c`](#obs-ffmpeg-sourcec)，播放逻辑在 `shared/media-playback/` |
| 重放缓存 Replay Buffer 实现 | `obs-ffmpeg-mux.c:911`～`:1270`（和 mp4 录制同一个文件） |
| 平台推流地址表（Twitch / B 站 / YouTube…） | [`rtmp-services/data/services.json`](#rtmp-services) |
| AAC 编码器有哪几个实现、macOS 用哪个 | `coreaudio-encoder/`（首选）、`obs-ffmpeg-audio-encoders.c`（`aac_at`/ffmpeg）、`obs-libfdk/` |
| 不带音视频编码器、直接让 FFmpeg 全程接管的输出 | [`obs-ffmpeg-output.c`](#obs-ffmpeg-输出与复用--路径-obs-ffmpeg) |
| SRT / RIST 推流 | `obs-ffmpeg-mpegts.c` + `obs-ffmpeg-srt.h` / `obs-ffmpeg-rist.h` |
| WHIP（WebRTC）推流 | [`obs-webrtc/whip-output.cpp`](#obs-webrtc　pluginsobs-webrtc) |

---

## 一句话职责

这一篇是 OBS "把混好的画面和声音变成文件 / 变成流" 的整个下半段。`libobs` 侧只负责把混好的 raw frame 交给 `obs_encoder`，把编码后的 `encoder_packet` 交给 `obs_output`；**具体用哪个编码器、封成什么容器、推到哪个平台，全部由这些插件提供**。

流水线大致是：`libobs` 合成 → 编码器插件（本篇的 `mac-videotoolbox` / `obs-x264` / `obs-nvenc` / `obs-qsv11` / `obs-ffmpeg-*-encoders` / `coreaudio-encoder`）→ 输出插件（本篇的 `obs-ffmpeg-mux`（mp4/mkv 录制）、`obs-outputs/rtmp-stream`（RTMP 推流）、`obs-webrtc`（WHIP））。`rtmp-services` 不参与数据流，它只是一张"平台 → 推流地址 + 推荐参数"的查表插件，被 `obs_service_t` 用来喂给推流输出。`obs-vst` 是个例外——它不属于这条链，是个音频滤镜（VST 宿主），放在本篇只是因为归类。

---

## obs-ffmpeg/　`plugins/obs-ffmpeg/`

**职责**：本篇的核心目录，一个插件里塞了四类东西——**编码器**（包 libavcodec 的软/硬编码器）、**输出与复用器**（mp4/mkv 录制、Replay Buffer、HLS、SRT/RIST）、**媒体文件源**、以及 **AMD AMF 纹理直编**。所有注册都在 `obs-ffmpeg.c:obs_module_load`（`:344` 起）里做条件注册：探测不到硬件就不注册，UI 里就看不到那个编码器。

### 模块入口与公共设施

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-ffmpeg.c` | 429 | 模块入口。`extern` 声明所有 `obs_*_info` 然后条件注册；`register_encoder_if_available()` 按 libavcodec 里有没有该 codec 决定要不要注册（openh264 / svtav1 / libaom-av1） |
| `obs-ffmpeg-formats.h` | 118 | 纯 inline 转换表：`obs_to_ffmpeg_video_format` / 色彩空间 / `rescale_ts`。想知道 OBS 的 `video_format` 对应哪个 `AV_PIX_FMT` 就看这里 |
| `obs-ffmpeg-compat.h` | 11 | 只有一个 `LIBAVCODEC_VERSION_CHECK` 宏，用来同时兼容 libav 和 FFmpeg 的版本号规则 |
| `obs-ffmpeg-logging.c` | 136 | 把 `av_log` 桥到 `blog`。维护一个 per-context 的字符串缓冲，因为 FFmpeg 会分多次 `av_log` 输出一行 |

### 编码器（包 libavcodec）　

**职责**：所有走 `avcodec_send_frame`/`avcodec_receive_packet` 的编码器共用 `obs_ffmpeg_video_encoder` 这层壳，各 codec 文件只负责"填参数"。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-ffmpeg-video-encoders.c` | 279 | **公共视频编码器骨架**：`avcodec_open2`、`AVFrame` 分配、raw frame → `AVFrame` 拷贝、`encode()` 收包、`first_packet_cb` 钩子（第一个包里抽 extradata）。下面几个文件都是它的使用者 |
| `obs-ffmpeg-video-encoders.h` | 50 | `struct ffmpeg_video_encoder` 定义 + 上面那份的声明 |
| `obs-ffmpeg-nvenc.c` | 611 | 走 FFmpeg 的 `h264_nvenc`/`hevc_nvenc`（和独立的 `obs-nvenc/` 插件是两套实现，这套是回退/Linux 用）。注册在 `:577`、`:595` |
| `obs-ffmpeg-av1.c` | 346 | AV1 软编：`libsvtav1`（`:320`）和 `libaom-av1`（`:334`）两个注册项，共用一份属性页 |
| `obs-ffmpeg-openh264.c` | 250 | `libopenh264` 软编 H.264（GPL 之外的授权替代品，代码结构照抄 av1 那份）。注册在 `:238` |
| `obs-ffmpeg-vaapi.c` | 1302 | Linux VAAPI 硬编（H.264/HEVC/AV1），每个 codec 各注册"普通"和 `_tex`（纹理直编）两份，共 6 个（`:1206`～`:1287`） |
| `vaapi-utils.c` / `.h` | 379 / 29 | VAAPI 能力探测：打开 DRM 设备、查 profile / rate-control / B 帧支持，决定上面 6 个要不要注册 |
| `obs-ffmpeg-audio-encoders.c` | 570 | **一份代码注册 7 个音频编码器**：`aac`(ffmpeg 内置)、`opus`、`pcm_s16le/s24le/f32le`、`alac`、`flac`（`:465`～`:557`）。`:254` 起有段值得看的逻辑：用 `avcodec_get_supported_config` 校验请求的 sample_fmt 编码器是否真支持，不支持就退回它列出的第一个 |

### 编码器（AMD AMF，不走 libavcodec）

| 文件 | 行数 | 功能 |
|---|---|---|
| `texture-amf.cpp` | 2834 | Windows-only。直接调 AMD AMF SDK，从 D3D11 纹理直接编码（零拷贝），支持 AVC/HEVC/AV1。本目录最大的文件，但对 macOS 读者可跳过 |
| `texture-amf-opts.hpp` | 345 | AMF 自定义选项字符串（`key=value`）解析并映射到 AMF property |
| `obs-amf-test/obs-amf-test.cpp` | 180 | **独立小 exe**：在子进程里探测 AMF 能力。理由和 `ffmpeg-mux` 同源——驱动崩溃不能带崩 OBS（`texture-amf.cpp:2721` 那句 "Seems the AMF test subprocess crashed"） |

### 输出与复用　

**职责**：把编码后的 `encoder_packet` 写进容器。这里有四个 `obs_output_info`：`ffmpeg_muxer`（本地文件录制，走子进程）、`replay_buffer`（重放缓存）、`ffmpeg_hls_muxer`（HLS 推流）、`ffmpeg_mpegts_muxer`（SRT/RIST），外加一个"不用 OBS 编码器、FFmpeg 全包"的 `ffmpeg_output`。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-ffmpeg-mux.c` ⭐ | 1270 | **mp4/mkv 录制的主体 + Replay Buffer**。自己不复用，把包通过管道喂给 `obs-ffmpeg-mux` 子进程；含分段录制（split file）、时间戳归零、文件名生成、重放缓存环形队列（`:911` 之后是完全独立的 replay buffer 实现） |
| `obs-ffmpeg-mux.h` | 76 | `struct ffmpeg_muxer`（进程管道 `os_process_pipe_t *pipe`、per-track 时间戳偏移、split 状态）+ 给 hls/mpegts 复用的公共函数声明 |
| `ffmpeg-mux/ffmpeg-mux.c` ⭐ | 1209 | **独立子进程程序**（编译成 `obs-ffmpeg-mux` 可执行文件）。从 stdin 读 `ffm_packet_info`+裸数据，用 libavformat 写文件；带一个批量 IO 线程（1MB chunk）吸收磁盘抖动 |
| `ffmpeg-mux/ffmpeg-mux.h` | 39 | 父子进程之间的**线协议**：`enum ffm_packet_type`（VIDEO/AUDIO/CHANGE_FILE）+ `struct ffm_packet_info`（pts/dts/size/index/type/keyframe）。这 39 行就是整个 IPC 契约 |
| `obs-ffmpeg-output.c` | 1165 | `ffmpeg_output`：**不用 OBS 编码器**的输出。直接拿 raw `video_data`/`audio_data`，自己 `swscale`+`avcodec` 编码再复用。给"自定义 FFmpeg 输出"那个高级选项用 |
| `obs-ffmpeg-output.h` | 139 | `struct ffmpeg_cfg`（url/format/bitrate/encoder 名…）+ `struct ffmpeg_data`/`ffmpeg_output`，被 `-output.c` 和 `-mpegts.c` 共用 |
| `obs-ffmpeg-mpegts.c` | 1396 | SRT / RIST 推流（`NEW_MPEGTS_OUTPUT` 开启时替代 `obs-ffmpeg-mux.c:892` 那个旧版）。自建 `AVIOContext` 绕过 FFmpeg 的协议层，直接调 libsrt / librist。注册在 `:1378` |
| `obs-ffmpeg-srt.h` | 919 | FFmpeg `libavformat/libsrt.c` 的移植版（header-only），提供 `URLContext` 风格的 SRT 收发 |
| `obs-ffmpeg-rist.h` | 253 | 同上，移植 `libavformat/librist.c` |
| `obs-ffmpeg-url.h` | 140 | 上面两个共用的精简 `URLContext` 结构 + 协议名常量 |
| `obs-ffmpeg-hls-mux.c` | 331 | HLS 推流。**复用 `obs-ffmpeg-mux.c` 的子进程管道**（`:146` 调 `start_pipe`），但另加一个写线程 + 自己一套丢帧逻辑（`:179` `drop_frames`、`:222` `check_to_drop_frames`），因为 HLS 是网络输出会堵。注册在 `:313` |

### 源

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-ffmpeg-source.c` ⭐ | 807 | 媒体文件源 / 网络拉流源（`ffmpeg_source`，`:784`）。**它自己不解码**——所有解封装、解码、节流、seek、loop 都委托给 `shared/media-playback/`，本文件只做属性页、回调转发、重连线程、hotkey |

### ⭐ 重点文件展开

#### `obs-ffmpeg-mux.c`

- **做什么**：OBS 本地录制（mp4 / mkv / flv / ts 等）的输出实现。它**完全不碰 libavformat**（虽然 include 了，只用来查 codec id）。`ffmpeg_mux_start_internal`（`:380`）先试着 `fopen` 目标路径确认可写（`:416`，注释直言这是为了给出人话错误，因为子进程的错误传不回来），然后 `start_pipe`（`:306`）拉起子进程；`ffmpeg_mux_data`（`:774`）收到包先补发 headers 再 `write_packet`（`:604`）把 `ffm_packet_info` + 裸数据两次 `os_process_pipe_write` 塞进管道。文件后半（`:911`～`:1270`）是一个结构完全独立的 **Replay Buffer**：包全存在 `deque` 里，按时长/大小 `purge_front` 淘汰（`:1000`），触发保存时才起 `replay_buffer_mux_thread`（`:1090`）拉一个子进程把缓存刷成文件。
- **关键入口**：`build_command_line`（`:267`，把编码器参数编成 argv）、`start_pipe`（`:306`）、`write_packet`（`:604`）、`send_headers`（`:668`）、`ffmpeg_mux_data`（`:774`）、`should_split`（`:689`，只在视频关键帧处切段）、`deactivate`（`:456`，`os_process_pipe_destroy` 等子进程收尾）、`struct obs_output_info ffmpeg_muxer`（`:864`）、`replay_buffer`（`:1259`）。
- **看点**：**为什么要开独立子进程复用**——这是 OBS 一个纯可靠性取向的设计取舍，理由有三条，都能从代码里读出来：
  1. **崩溃隔离**。libavformat 的 muxer 在遇到畸形包、磁盘写失败、路径变成只读时可能 `abort`/段错误。跑在子进程里，最坏结果是"这次录制文件坏了"，OBS 主进程和正在进行的**推流**毫发无损。反过来 OBS 主进程崩了，子进程还能把已收到的包写完并正常 `av_write_trailer`（`main` 循环在 `ffmpeg-mux.c:1184` 读到 EOF 就自然退出 → `ffmpeg_mux_free` 写 trailer），所以 OBS 崩溃后 mp4 通常还能播。
  2. **阻塞隔离**。写盘（尤其网络盘 / 机械盘 / 杀软扫描）会长时间阻塞。管道有内核缓冲 + 子进程内部还有 1MB chunk 的 IO 线程，主进程的 `encoded_packet` 回调不会被磁盘 stall 拖住。`:318` 那段专门为 Windows Defender 加的错误提示就是这个问题的实战痕迹。
  3. **许可证/依赖隔离**（次要）：子进程是个独立可执行文件，链哪个 FFmpeg 与主程序解耦。
  代价也清楚：**错误无法回传**。`:414` 留着 `TODO: remove once ffmpeg-mux is refactored to pass errors back`，所以现在只能靠"写前试探性 fopen"和"管道写失败 → `signal_failure`（`:513`）"两个粗糙手段判断出错。这个取舍值得抄——WorkLabs 目前是 in-process `WLRecorder`，一旦 muxer 出问题会连带干掉推流。
  另外注意 `ts_offset_update`（`:349`）：**只有分段录制才做时间戳归零**（每段各自减掉本段首帧的 pts），普通录制原样透传，归零交给子进程做。

#### `ffmpeg-mux/ffmpeg-mux.c`

- **做什么**：上面那个子进程的本体。`main`（`:1141`）就是一个"读 header → 读 payload → 写包"的死循环，没有任何 OBS 依赖（不 link libobs）。`init_params`（`:336`）从 argv 解析出路径、有无视频、音轨数、每轨的编码器名/码率/采样率等；`ffmpeg_mux_get_extra_data`（`:641`）先读走第一批 header 包当 extradata；`create_video_stream`（`:431`）/`create_audio_stream`（`:508`）建 `AVStream` 并塞 extradata；之后每个 `FFM_PACKET_VIDEO/AUDIO` 走 `ffmpeg_mux_packet`（`:1072`）→ `rescale_ts` → `av_interleaved_write_frame`。`FFM_PACKET_CHANGE_FILE`（`:1106`）用来实现分段录制：关掉当前文件、按新文件名重开、重建流。
- **关键入口**：`main`（`:1141`）、`init_params`（`:336`）、`ffmpeg_mux_get_header`（`:621`）、`ffmpeg_mux_io_thread`（`:664`）、`ffmpeg_mux_write_av_buffer`（`:821`）、`open_output_file`（`:867`）、`ffmpeg_mux_packet`（`:1072`）、`read_change_file`（`:1106`）。
- **看点**：**自定义 `AVIOContext` + 批量写线程**（`:664`，`CHUNK_SIZE = 1MB`，`:662`）。本地文件时它不让 libavformat 直接写盘，而是 `avio_alloc_context`（`:901`）接住写请求，把 `{seek_offset, data_length}` + 数据压进一个 `deque`，由独立 IO 线程攒到 1MB 再真正 `fwrite`。妙处在于它**把 mp4 muxer 的随机 seek 也一起缓冲了**：线程维护 `current_seek_position`（虚拟位置）和 `next_seek_position`，只有当 libavformat 的写位置真的不连续时才 flush 当前 chunk 并 `fseek`（注释在 `:682`）。mp4 收尾要回头改 `moov`，这个设计让"平时顺序写 + 收尾少量 seek"都不至于打断批量。想在自己的 recorder 里对付机械盘/网络盘抖动，这一段是现成范本。
  另一个细节：`ffmpeg_mux_is_network`（`:161`）按 URL 前缀（srt/udp/tcp/http/rist）判断是不是网络目标，网络目标不走 IO 缓冲线程，直接交给 libavformat。

#### `obs-ffmpeg-source.c`

- **做什么**：`ffmpeg_source` 源的**外壳**。真正的播放引擎在 `shared/media-playback/`（`media.c` 1052 行、`cache.c` 701 行、`decode.c` 421 行、`media-playback.c` 176 行，共 2878 行），本文件通过 `#include <media-playback/media-playback.h>` 使用，只干四件事：填 `struct mp_media_info`（`:293`）把配置和四个回调（`v_cb`/`v_preload_cb`/`v_seek_cb`/`a_cb` + `stop_cb`）交出去；把回调里拿到的帧转手 `obs_source_output_video`/`obs_source_output_audio`（`:240`/`:265`）；实现 `media_*` 控制接口（play/pause/stop/restart/seek，`:676`～`:747`）转调 `media_playback_*`；管一个网络源断线重连线程（`:335` `ffmpeg_source_reconnect`）。
- **关键入口**：`ffmpeg_source_open`（`:290`，唯一一处 `media_playback_create`）、`get_frame`（`:240`）、`get_audio`（`:265`）、`ffmpeg_source_tick`（`:353`）、`ffmpeg_source_update`（`:391`，判断哪些属性改了必须重开媒体）、`ffmpeg_source_getproperties`（`:135`）、`struct obs_source_info ffmpeg_source`（`:784`）。
- **看点**：**这是"源"和"播放器"分层的教科书示例**。`media_playback` 有两种后端（`media.c` 的流式播放 + `cache.c` 的全解码缓存，用 `full_decode` 开关选，转场贴片 stinger 会开 `request_preload`），源这一层对此完全无感。对照 WorkLabs 现在把解封装/解码/节流全塞在 `WLMediaSource` 里，这个拆法（源 = 属性 + 生命周期 + 帧转发；播放引擎 = 独立可复用库）是很值得照抄的边界。
  另外注意属性名，因为它们直接对应播放引擎的能力：`buffering_mb`（0~16MB 缓冲）、`hw_decode`、`speed_percent`（1~200%，变速播放）、`seekable`（网络源也允许 seek）、`close_when_inactive`、`clear_on_media_end`、`linear_alpha`、`ffmpeg_options`（透传 `AVDictionary`）。`:327` 那句 `obs_source_show_preloaded_video` 是"loop/末尾清空时先预载首帧避免闪黑"的技巧。

---

## obs-outputs/　`plugins/obs-outputs/`

**职责**：OBS 自带的 RTMP 推流 + FLV/MP4 直写。和 `obs-ffmpeg` 的区别是：**这里的复用器全是 OBS 手写的**（`flv-mux.c`、`mp4-mux.c`），不依赖 libavformat，因此推流路径上完全没有 FFmpeg。附带一份 vendored 的 librtmp。

### RTMP 推流

| 文件 | 行数 | 功能 |
|---|---|---|
| `rtmp-stream.c` ⭐ | 2008 | RTMP/RTMPS 推流输出（`rtmp_output_info`，`:1982`）。连接线程 + 发送线程 + 包队列 + **拥塞丢帧** + **动态码率 DBR**；`:1954`～`:1976` 暴露给 UI 的 `total_bytes_sent`/`dropped_frames`/`congestion`/`connect_time` |
| `rtmp-stream.h` | 230 | `struct rtmp_stream`（含 `RTMP rtmp` 实例、`deque packets`、`drop_threshold_usec`、`dbr_*`、`write_buf`）+ 所有 `OPT_*` 设置键名（`:25`～`:33`）+ 丢帧压测开关 `TEST_FRAMEDROPS`（`:36`，默认注释掉） |
| `rtmp-windows.c` | 320 | Windows-only 的 `socket_thread_windows`（`:314`）："new socket loop"——用 `WSAEventSelect` 自己管发送窗口，绕开 Windows 上 `send()` 阻塞行为差的问题。macOS/Linux 走 `rtmp-stream.c` 里的普通同步发送 |
| `net-if.c` / `.h` | 265 / 77 | 枚举本机网卡地址（`getifaddrs` / `GetAdaptersAddresses`），供"绑定到指定网卡 IP"（`OPT_BIND_IP`）的下拉框用 |

### FLV / MP4 复用与文件输出

| 文件 | 行数 | 功能 |
|---|---|---|
| `flv-mux.c` ⭐ | 643 | **手写 FLV 复用器**：onMetaData、legacy FLV tag、以及 Y2023 "增强 RTMP"（Enhanced RTMP）扩展 tag——HEVC/AV1 的 fourCC、多轨（multitrack）、HDR metadata |
| `flv-mux.h` | 79 | `enum video_id_t`/`audio_id_t`、`to_video_type`/`to_audio_type`、`get_ms_time`（把包时间戳换成 FLV 的毫秒），+ 导出的 `flv_packet_*` 声明 |
| `flv-output.c` | 629 | 把 `flv-mux.c` 的产物直接落成 `.flv` 文件（`flv_output_info`，`:613`）。走 `write_file_info` 在收尾时回填 duration/filesize |
| `mp4-mux.c` | 3016 | **手写 MP4/MOV 复用器**（2024 年新增）。本目录第二大文件；直接拼 box，支持 fragmented 写入 + 收尾"soft-remux" |
| `mp4-mux-internal.h` | 416 | 上面那份的内部结构：track 状态、box 偏移记录、`deque`/`serializer` 用法 |
| `mp4-mux.h` | 48 | 公开 API + 两个值得注意的枚举：`enum mp4_flavor`（`:26`，MP4 / MOV / CMAF-未实现）和 `enum mp4_mux_flags`（`:33`，`MP4_SKIP_FINALISATION`、`MP4_USE_NEGATIVE_CTS`、`MP4_WRITE_ENCODER_INFO`…） |
| `mp4-output.c` | 625 | `mp4_output_info`（`:597`）+ `mov_output_info`（`:612`）。日志里自称 "Hybrid MP4/MOV"（`:329`）：**先按 fragmented MP4 写（崩溃也能播），停止时再 soft-remux 成标准 MP4**。含章节标记（`mp4_add_chapter_proc`，`:172`）和分段录制 |
| `rtmp-hevc.c` / `.h` | 877 / 23 | HEVC 的 `hvcC` 头构造 + NAL 解析，给 FLV/MP4 复用器用 |
| `rtmp-av1.c` / `.h` | 603 / 26 | 同上，AV1 的 `av1C`/OBU 处理，注释标明"改编自 FFmpeg 的 `libavformat/av1.c`" |
| `utils.h` | 76 | `clz32`/`ctz32` 位运算兼容层（MSVC 上用 BSR 而非 `__lzcnt`，注释解释了老 Intel CPU 上 lzcnt 不对） |
| `rtmp-helpers.h` | 51 | 把 C 字符串包成 librtmp 的 `AVal` 的一堆 inline 助手 |

### 模块入口 / 空输出

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-outputs.c` | 79 | 模块入口，注册 5 个输出（rtmp / null / flv / mp4 / mov）；Windows 上还要给 mbedTLS 装线程回调 |
| `null-output.c` | 97 | 什么都不做的输出（`null_output_info`，`:88`），给测试和"只跑编码器不落地"用 |
| `obs-output-ver.h` | 3 | 只有一个 `MODULE_NAME` 宏 |

### librtmp/　（vendored 第三方）

`librtmp` 的一份内嵌拷贝（RTMP_LIB_VERSION `0x020300` = 2.3，见 `rtmp.h:182`），OBS 没有把它当外部依赖。共 15 个文件、约 10.2k 行，主体是 `rtmp.c`（5395）+ `amf.c`（1318）+ `handshake.h`（950，RTMPE 握手，纯 header 实现）+ `hashswf.c`（694）+ `parseurl.c`（279）+ `log.c`（228）+ `md5.c`（295）/ `cencode.c`（111，base64）。

OBS 侧的改造集中在两点，都在**外部**而不是改库内部：
- **TLS 后端换成 mbedTLS**（`rtmp_sys.h` / `rtmp.h:159` 附近的 `USE_OPENSSL` 分支），所以 RTMPS 能用；`obs-outputs.c` 给 mbedTLS 注册互斥回调。
- **发送出口被劫持**：`rtmp-stream.c:348` 的 `socket_queue_data` 被装到 `RTMPSockBuf` 上，librtmp 以为自己在 `send()`，实际是把字节写进 OBS 自己的 `write_buf`，再由 OBS 的 socket 线程发出去。这是"new socket loop"能实现的前提。

日常读代码基本不用进这个目录，除了想查 RTMP chunk / AMF 编码细节。

### ⭐ 重点文件展开

#### `rtmp-stream.c`

- **做什么**：RTMP 推流的全部逻辑。结构是三段：**连接**（`connect_thread` `:1499` → `try_connect` `:1165` → `init_send` `:978`，含 `send_meta_data`/`send_headers`）、**入队**（`rtmp_stream_data` `:1838`，把 AVCC 转 AnnexB 之外的 codec 各自 `obs_parse_*_packet`，然后 `add_video_packet`/`add_packet` 压进 `deque`）、**发送**（`send_thread` `:632` 从队列取包 → `flv_packet_*` 打包 → `RTMP_Write`）。停止时还要发 footer（`send_footers` `:955`，增强 RTMP 的 `PACKETTYPE_SEQ_END`）。
- **关键入口**：`rtmp_stream_data`（`:1838`）、`add_video_packet`（`:1820`）、`check_to_drop_frames`（`:1752`）、`drop_frames`（`:1564`）、`send_thread`（`:632`）、`dbr_bitrate_lowered`（`:1623`）/`dbr_set_bitrate`（`:1684`）/`dbr_inc_bitrate`（`:1738`）、`init_connect`（`:1326`，读所有 `OPT_*`）、`struct obs_output_info rtmp_output_info`（`:1982`）。
- **看点**：**拥塞时的丢帧策略，全部在 `rtmp-stream.c:1752 check_to_drop_frames` + `:1564 drop_frames` 这两个函数里**，机制如下（一句话：拿"待发队列里积压了多少毫秒的内容"当拥塞指标，超阈值就按 NAL 优先级整批砍）：

  1. **指标**：`buffer_duration_usec = stream->last_dts_usec - first.dts_usec`（`:1784`），即队列里最新包和最旧视频包的 dts 差 —— 队列积压的**播放时长**，而不是字节数。`stream->congestion = buffer_duration_usec / drop_threshold`（`:1787`）就是 UI 上那个拥塞条。包数少于 5 直接判定不拥塞（`:1773`）。
  2. **两级阈值**：`add_video_packet`（`:1820`）连着调两次 `check_to_drop_frames`——先 `pframes=false`（阈值 `drop_threshold_usec`，来自 `OPT_DROP_THRESHOLD`，默认较低），砍掉优先级低于 `OBS_NAL_PRIORITY_HIGH` 的（B 帧/可丢帧）；再 `pframes=true`（阈值 `pframe_drop_threshold_usec`，`init_connect:1460` 强制它至少比前者大 200ms），砍到只剩 `OBS_NAL_PRIORITY_HIGHEST`（即只留 IDR）。先丢无关紧要的，还堵就连 P 帧一起丢。
  3. **怎么丢**：`drop_frames`（`:1564`）遍历整个队列重建一个新队列，**音频包和 `drop_priority >= highest_priority` 的视频包保留，其余 release**（`:1584`）。所以 OBS 从不丢音频——丢了音频就是可闻的爆音，丢视频只是卡一下。
  4. **丢帧后的滞后状态**：丢完把 `stream->min_priority = highest_priority`（`:1596`），之后新来的包只要 `drop_priority < min_priority` 就在入口直接丢（`:1827`），直到来了一个够高优先级的包（通常是下一个关键帧）才 `min_priority = 0` 复位。这是为了避免"丢了一半 GOP 后继续发依赖已丢帧的 P 帧"造成花屏。
  5. **DBR 优先于丢帧**：如果开了动态码率（`OPT_DYN_BITRATE`），积压超过 `DBR_TRIGGER_USEC`（200ms，`:45`）就走 `dbr_bitrate_lowered` 降编码器码率并**直接 return，不丢帧**（`:1794`～`:1812`）。代码注释还留着"要不要只丢 P 帧"的实验痕迹（`:1790`）。

  第 4 条这个 `min_priority` 滞后机制，是 `mac-videotoolbox/encoder.c` 里那个 NAL 优先级修补（见下）存在的唯一原因——两个文件要连起来读。

#### `flv-mux.c`

- **做什么**：把 `encoder_packet` 拼成 FLV tag 字节流，通过 `array_output_serializer`（写内存 buffer）输出。三层：`flv_meta_data`（`:267` → `build_flv_meta_data` `:190`，onMetaData 里写 duration/宽高/码率/编码器名 fourCC）；**legacy 路径** `flv_packet_mux`（`:372` → `flv_video` `:308` / `flv_audio` `:341`），只管 H.264+AAC；**增强 RTMP（Y2023 spec）路径** `flv_packet_ex`（`:443`）/ `flv_packet_audio_ex`（`:388`）/ `flv_packet_metadata`（`:536`），用 `FRAME_HEADER_EX`（`:51`）标记的扩展 tag 承载 HEVC / AV1 / 多轨 / HDR。
- **关键入口**：`flv_meta_data`（`:267`）、`flv_packet_mux`（`:372`）、`flv_packet_ex`（`:443`）、`flv_packet_start`/`_frames`/`_end`（`:503`/`:508`/`:519`，序列头 / 帧 / 序列尾三种 packet type 的薄封装）、`flv_packet_audio_start`/`_audio_frames`（`:524`/`:530`）、`write_file_info`（`:176`，`.flv` 文件收尾回填）。
- **看点**：这是**"手写复用器要小到什么程度才划算"的答案**——643 行就换掉了整个 libavformat 的 FLV muxer，而且换来了对 Enhanced RTMP 的第一时间支持（`:32`～`:63` 那几个 enum：`PACKETTYPE_MULTITRACK = 6`、`MULTITRACKTYPE_MANY_TRACKS_MANY_CODECS = 0x20`，是 spec 直译）。三个具体值得学的点：
  - **时间戳单位在入口就统一**：`get_ms_time`（`flv-mux.h:56`）把任意 timebase 的包换成 FLV 的 int32 毫秒，并且所有调用都先减 `dts_offset`（首包 dts），保证 tag 时间戳从 0 开始。RTMP 的 timestamp 是 24bit+扩展 8bit，`s_wtimestamp`（`:130`）专门处理这个别扭格式。
  - **composition time offset 只在 H.264/HEVC + FRAMES 类型时才写那 3 个字节**（`:459`），AV1 不写——头部长度是按 codec 动态算的（`header_metadata_size`），改的时候容易漏。
  - `:26` 有一句诚实的 `TODO: FIXME: this is currently hard-coded to h264 and aac!` ——那是 legacy 路径的现状，新 codec 全走 `_ex` 路径，别被这句注释误导以为整个文件只支持 h264。

---

## obs-x264/　`plugins/obs-x264/`

**职责**：x264 软编 H.264。是 OBS 的"永远能用"的兜底编码器，也是其他编码器行为的参照标准（比如负 dts 的表示方式）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-x264.c` | 865 | 全部实现（`obs_x264_encoder`，`:850`）：preset/profile/tune/rate control 属性页、`x264_param_t` 组装（`update_params` `:348`）、自定义 `x264opts` 覆盖（`override_base_param` `:241` / `set_param` `:278`）、ROI 区域码率控制（`roi_cb` `:727` / `add_roi` `:751`）、`load_headers`（`:605`，从 `x264_encoder_headers` 取 SPS/PPS 当 extradata）、`parse_packet`（`:677`，NAL → `encoder_packet` 并按 NAL 类型算 `drop_priority`） |
| `obs-x264-test.c` | 71 | 单元测试，测的是 `opts-parser.h` 的 `obs_parse_options`（自定义选项字符串解析），不是编码器本身 |
| `obs-x264-plugin-main.c` | 16 | 模块入口，就 `obs_register_encoder(&obs_x264_encoder)` 一行 |

## obs-libfdk/　`plugins/obs-libfdk/`

**职责**：Fraunhofer FDK-AAC 音频编码器。因为授权原因通常不随官方包分发，是"自行编译才有"的选项。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-libfdk.c` | 327 | 整个插件（`obs_libfdk_encoder`，`:304`）：`aacEncOpen`/`aacEncEncode` 包装、AOT 选择、`AACENC_ERROR` → 人话字符串（`libfdk_get_error` `:12`）、从 `AACENC_InfoStruct.confBuf` 取 AudioSpecificConfig 当 extradata |

## coreaudio-encoder/　`plugins/coreaudio-encoder/`

**职责**：**macOS 上 OBS 的默认 AAC 编码器**，用 AudioToolbox 的 `AudioConverter`。同一份代码在 Windows 上也能跑（如果装了 iTunes/QuickTime 的 dll），靠 `windows-imports.h` 手动声明 AudioToolbox 的 ABI 后动态加载。

| 文件 | 行数 | 功能 |
|---|---|---|
| `encoder.cpp` | 1324 | 全部实现。`obs_module_load`（`:1288`）先 `load_core_audio()` 再注册单个 `aac` 编码器（`:1315`）。核心是 `AudioConverterFillComplexBuffer` 驱动的 pull 模型；`:741` 之后有一段从 HandBrake libhb 抄来的 **ESDS descriptor 构造**（用来生成 mp4 需要的 extradata） |
| `windows-imports.h` | 482 | Windows 上手写的 AudioToolbox 头文件替身（`typedef`+函数指针+`GetProcAddress`）。macOS 下整个文件被 `#ifndef _WIN32` 跳过 |

**macOS 相关的坑（重要）**：`priming_samples`。AAC 编码器有固有的前导延迟（encoder delay / leading frames）。这里 `:595` 从 `AudioConverterPrimeInfo.leadingFrames` 读出来，然后 **`:705`/`:706` 把它从 pts 和 dts 里减掉**，并且通过 `get_priming_samples`（`:1313` 挂 `aac_priming_samples` `:735`）把这个值告诉 libobs，让复用器能正确写 edit list / 起始偏移。如果自己接 `aac_at` 或 AudioToolbox 却不处理这个量，结果就是**音频比视频早约 2048 个采样（~46ms）**——典型症状是"录出来的 mp4 音画不同步，但预览时是同步的"。

## mac-videotoolbox/　`plugins/mac-videotoolbox/`

**职责**：macOS 的硬件视频编码器（H.264 / HEVC / ProRes），走 VideoToolbox 的 `VTCompressionSession`。**只有一个文件，但对 macOS 上做录制/推流的人是必读**。

| 文件 | 行数 | 功能 |
|---|---|---|
| `encoder.c` ⭐ | 1535 | 全部实现。运行时枚举系统里所有 VT 编码器并**逐个动态注册**成独立的 `obs_encoder_info`；含 AVCC→AnnexB 转换、SPS/PPS 抽取、色彩空间/HDR 属性设置、以及一处专门为 RTMP 丢帧机制打的 NAL 优先级补丁 |

### ⭐ 重点文件展开

#### `mac-videotoolbox/encoder.c`

- **做什么**：把 VideoToolbox 包装成 OBS 编码器。逐函数看：

  **注册（动态、不是静态表）**
  - `obs_module_load`（`:1422`）：把 `VTCopyVideoEncoderList` 扔到一个 `dispatch_group` 异步执行（这个调用慢，不能阻塞模块加载），并顺便用 `os_get_emulation_status()` 判断是不是 Rosetta 下跑的 x86_64（`is_apple_silicon`，`:1433`）。
  - `obs_module_post_load`（`:1438`）：等那个 group 完成，然后**遍历系统返回的编码器字典数组，一个条目注册一个 `obs_encoder_info`**（`:1523`）。`info.id` 就是系统给的 `kVTVideoEncoderList_EncoderID` 字符串，`info.type_data` 存 `{disp_name, id, codec_type, hardware_accelerated}`。所以 UI 上你会看到 "Apple VT H264 Hardware Encoder" 这种带厂商名的条目 —— 名字来自系统而不是硬编码。H264/HEVC 用 `vt_properties_h26x`（`:1236`），ProRes 用 `vt_properties_prores`（`:1307`）；ProRes 的各种子类型（4444XQ/4444/422Proxy/LT/HQ）不各自注册，而是 `continue` 掉、只塞进 `vt_prores_*_encoder_list`（`:1401`）当 profile 选项。
  - caps 声明为 `OBS_ENCODER_CAP_DYN_BITRATE | OBS_ENCODER_CAP_MULTITRACK_DYN_BITRATE`（`:1450`）——所以它能配合 `rtmp-stream.c` 的 DBR 动态降码率。

  **建会话**
  - `create_encoder`（`:488`）：`create_encoder_spec`（`:425`，按 EncoderID 精确指定编码器）+ `create_pixbuf_spec`（`:469`）→ `VTCompressionSessionCreate`，回调是 `sample_encoded_callback`（`:403`）。建完立刻 `VTSessionCopyProperty(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)` 反查**实际**有没有走硬件（`:518`），因为你要了硬件不一定给你。
  - `session_set_bitrate`（`:275`）：rate control 映射。**CBR 只在 macOS 13+ 且 Apple Silicon 上才是真 CBR**（`kVTCompressionPropertyKey_ConstantBitRate`），否则打 warning 退回 ABR（`AverageBitRate`）；**CRF 只在 Apple Silicon 上可用**（`kVTCompressionPropertyKey_Quality`），Intel Mac 上也退回 ABR。`limit_bitrate` 走 `kVTCompressionPropertyKey_DataRateLimits`，用 `{cpb_size, window}` 两元素数组表达。
  - `session_set_colorspace`（`:353`）：一次性 `VTSessionSetProperties` 设 primaries/transfer/YCbCrMatrix，HDR（PQ/HLG）时追加 `MasteringDisplayColorVolume` + `ContentLightLevelInfo`，这两个 blob 由 `obs_to_vt_masteringdisplay`（`:198`）/`obs_to_vt_contentlightlevelinfo`（`:226`）手工拼二进制（注释说改编自 Chromium）。
  - `sample_encoded_callback`（`:403`）：**不做任何处理**，只 `CFRetain` 后塞进 `CMSimpleQueueRef`，并 release 掉当作 `sourceFrameRefcon` 传进去的 pixel buffer。异步转同步靠这个队列。

  **拿 extradata（SPS/PPS）——问题的关键**
  - VideoToolbox **不提供"编码前先给我参数集"的接口**，SPS/PPS 只存在于 `CMSampleBuffer` 的 `CMFormatDescription` 里，也就是**必须先编出第一帧才能拿到**。
  - `parse_sample`（`:982`）里，只要 `enc->extra_data.num == 0` 就把 `extra_data` 指针传下去（`:1006`）；`convert_sample_to_annexb`（`:924`）先用 `CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, 0, NULL, NULL, &param_count, &nal_length_bytes)` 查有几个参数集、NAL 长度前缀几字节；`handle_keyframe`（`:887`）逐个取出参数集，**每个前面补 4 字节 AnnexB startcode 写进 packet，同时整份拷进 `enc->extra_data`**（`:918`）。
  - `vt_extra_data`（`:1172`）就只是把这个 darray 交出去。所以 **`get_extra_data` 在第一个关键帧编出来之前返回的是空**——这正是 `obs-ffmpeg-mux.c` 要把 `avformat_write_header` 延迟到第一个包、`ffmpeg-mux.c:641` 要先读 header 包的原因。WorkLabs 的 `WLRecorder` 已经踩过同一个坑并用同样的办法解决了。
  - 一个防御性细节：`:946` 对 `InvalidParameter` 错误**假定 2 个参数集 + 4 字节 NAL 长度**继续跑，而不是失败退出。
  - 另外注意 `handle_keyframe` 每个关键帧都会重新写一遍 SPS/PPS 进码流（in-band），不只写一次。

  **编码一帧**
  - `vt_encode`（`:1112`）：`get_cached_pixel_buffer`（`:1064`）从 `VTCompressionSessionGetPixelBufferPool` 取一个 buffer → `CVPixelBufferLockBaseAddress` → **逐行 memcpy**（`:1142`，因为 pool 的 stride 和 OBS 的 linesize 不一致）→ `VTCompressionSessionEncodeFrame` → 立刻 `CMSimpleQueueDequeue` 试着取一个已编好的包，取不到就 `return true` 且 `*received_packet` 保持 false。
  - **坑**：从 session pool 拿到的 pixel buffer **没有色彩空间附件**，必须自己 `CVBufferSetAttachment` 补上 YCbCrMatrix / ColorPrimaries / TransferFunction（`:1082`～`:1087`），代码里那句注释就是作者的困惑："Why aren't these already set on the pixel buffer?"。不补的话编出来的颜色/范围会错。
  - **坑**：`kVTCompressionPropertyKey_RealTime` 被显式设成 **`kCFBooleanFalse`**（`:596`），注释说设失败只会"frame delay might be increased"。也就是 OBS 有意不用 realtime 模式（换更好的压缩效率），代价是延迟。
  - **坑**：关键帧间隔要**同时设两个 key**——`MaxKeyFrameIntervalDuration`（秒，`:530`，注释写明 "This can fail when using GPU hardware encoding"，失败只 warning）和 `MaxKeyFrameInterval`（帧数 = keyint × fps，`:537`/`:543`）。只设其中一个在部分机型上关键帧间隔会不对。
  - **坑**：像素格式限制在 `set_video_format`（`:666`）——`I420`/`NV12` 通用；**`P010`（10bit）只有 HEVC 支持，H.264 走 P010 直接失败**；`P216`/`P416` 不支持 full range（返回 `kResultFullRangeUnsupported`）。
  - **坑**：B 帧时 dts 的处理（`parse_sample:989`）——注释 "imitate x264's negative dts"，用 `dts -= off`（off = 2 帧时长）人为造出负 dts，为的是和 x264 的行为一致，让下游复用器统一处理。

  **NAL 优先级补丁（最容易被忽略的一处）**
  - `parse_sample:1024`～`:1054`，注释原文：VideoToolbox 产出的包优先级比 RTMP 代码期望的低，导致推流**丢帧后无法恢复**。修法是遍历 AnnexB 码流，把 IDR slice 的 `nal_ref_idc` 强改成 `OBS_NAL_PRIORITY_HIGHEST`、普通 slice（原本不是 disposable 的）改成 `OBS_NAL_PRIORITY_HIGH`。
  - 为什么必须这么干：`rtmp-stream.c` 的 `min_priority` 滞后机制（见上文）靠 `drop_priority` 判断"什么时候可以停止丢帧"，如果所有帧的优先级都偏低，丢帧一旦触发就再也遇不到"够高优先级"的包，会一直丢下去。**这是 macOS + VideoToolbox + RTMP 组合的一个真实历史 bug 的修复痕迹**，自己搭这条链路的话几乎一定会撞上。

- **关键入口**：`obs_module_post_load`（`:1438`）、`create_encoder`（`:488`）、`session_set_bitrate`（`:275`）、`session_set_colorspace`（`:353`）、`sample_encoded_callback`（`:403`）、`set_video_format`（`:666`）、`update_params`（`:708`）、`vt_encode`（`:1112`）、`get_cached_pixel_buffer`（`:1064`）、`parse_sample`（`:982`）、`convert_sample_to_annexb`（`:924`）、`handle_keyframe`（`:887`）、`vt_extra_data`（`:1172`）。
- **看点**：见上面逐函数里标出的六个坑。整体设计取舍是"**用系统枚举替代硬编码能力表**"——`VTCopyVideoEncoderList` 让 OBS 不需要维护"哪代 Mac 支持什么"的表格，代价是要异步加载 + `obs_module_post_load` 两段式初始化。`dump_encoder_info`（`:633`）把最终生效的参数全打进日志（含 `hw_enc` 实际值），排查用户"为什么我的编码变软了"很好使，值得照抄这个习惯。

## obs-nvenc/　`plugins/obs-nvenc/`

**职责**：直接调 NVIDIA NVENC SDK（不经 FFmpeg）的硬件编码器，支持从显存纹理零拷贝编码。Windows 为主，Linux 走 CUDA/OpenGL 路径。macOS 无关，压缩描述。

| 文件 | 行数 | 功能 |
|---|---|---|
| `nvenc.c` | 1534 | 主体。注册 6 个编码器（`h264/hevc/av1` × 纹理版/`_soft`软表面版，`:1403`～`:1505`），核心是 NVENC 的 `NvEncEncodePicture` 循环 + 输出 bitstream lock/unlock |
| `nvenc-internal.h` | 212 | `struct nvenc_data` + 三种后端（d3d11 / cuda / opengl）的统一接口声明 |
| `nvenc-d3d11.c` | 264 | D3D11 后端：把 OBS 的共享纹理直接注册给 NVENC（Windows 零拷贝路径） |
| `nvenc-cuda.c` | 326 | CUDA 后端：CUDA array + host register，Linux/回退路径 |
| `nvenc-opengl.c` | 145 | OpenGL 纹理 → CUDA interop，Linux 纹理路径 |
| `cuda-helpers.c` / `.h` | 156 / 63 | `dynlink_cuda` 动态加载 + FFmpeg 头里缺的几个 CUDA 声明 |
| `nvenc-helpers.c` / `.h` | 388 / 89 | `nvEncodeAPI` 动态加载、驱动版本校验、能力探测 |
| `nvenc-properties.c` | 289 | 属性读写与 UI（`struct nvenc_properties` ↔ `obs_data_t`） |
| `nvenc-opts-parser.c` | 226 | 自定义选项解析。NVIDIA 的配置结构用了大量位域，无法 `offsetof`，所以整个文件靠宏展开（`:6` 注释解释了这点） |
| `nvenc-compat.c` | 407 | **纯兼容层**：为 OBS 31.0 之前的老编码器 id 注册 6 个"影子"编码器（`:298`～`:372`），它们只改写 settings 然后转发到新实现。文件头注释说明将来会删 |
| `obs-nvenc.c` / `.h` | 30 / 11 | 模块入口 |
| `obs-nvenc-test/obs-nvenc-test.cpp` | 576 | 独立子进程能力探测程序（同 `obs-amf-test`，驱动崩溃隔离） |

## obs-qsv11/　`plugins/obs-qsv11/`

**职责**：Intel Quick Sync（oneVPL / Media SDK）硬件编码器。同样 Windows/Linux，macOS 无关。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-qsv11.c` | 1422 | OBS 侧适配层，注册 8 个编码器（h264/av1/hevc × 纹理版/普通版，另 h264 还有 v2 变体，`:1292`～`:1408`） |
| `QSV_Encoder_Internal.cpp` / `.h` | 980 / 139 | 真正的 MFX 会话与编码循环（C++，和 OBS API 隔离） |
| `QSV_Encoder.cpp` / `.h` | 332 / 171 | C 接口外壳，供 `obs-qsv11.c` 调用 |
| `common_utils.cpp` / `.h` | 307 / 177 | Intel 示例代码来的通用工具（surface 分配、frame allocator） |
| `common_utils_windows.cpp` / `common_utils_linux.cpp` | 246 / 529 | 平台相关的设备/分配器实现 |
| `common_directx11.cpp` / `.h` | 530 / 28 | D3D11 分配器（纹理直编路径） |
| `obs-qsv11-plugin-main.c` | 109 | 模块入口，探测成功才注册 |
| `obs-qsv-test/obs-qsv-test.cpp` | 209 | 独立子进程能力探测程序 |
| `bits/linux_defs.h` / `bits/windows_defs.h` | 9 / 6 | 平台宏差异 |

## obs-webrtc/　`plugins/obs-webrtc/`

**职责**：WHIP（WebRTC-HTTP Ingestion Protocol）推流。用 libdatachannel 做 WebRTC 传输，是 OBS 里唯一走 SRTP/RTP 而非 RTMP/MPEG-TS 的输出。

| 文件 | 行数 | 功能 |
|---|---|---|
| `whip-output.cpp` | 792 | 输出主体（`register_whip_output` `:733`）：HTTP POST SDP offer 做信令、`rtc::PeerConnection` + 两条 track（audio pt=111 opus / video）、`RtpPacketizer` 把 H.264/HEVC/AV1 切成 ≤1200 字节的 RTP 包（`MAX_VIDEO_FRAGMENT_SIZE` `:11`，注释说明 576~1470 是取舍区间） |
| `whip-output.h` | 77 | `class WHIPOutput` 声明 |
| `whip-service.cpp` / `.h` | 98 / 18 | 对应的 `obs_service_t`：只有 server URL + bearer token 两个字段；声明支持的 codec 是 `opus` / `h264,hevc,av1`（`:3`～`:4`） |
| `whip-utils.h` | 77 | 随机 SSRC/mid 生成、`trim_string`、User-Agent 拼接 |
| `obs-webrtc.cpp` | 19 | 模块入口 |

## rtmp-services/　`plugins/rtmp-services/`

**职责**：**不参与数据流**的查表插件。提供两个 `obs_service_t`：`rtmp_common`（从 `services.json` 里选平台 → 得到服务器列表、推荐码率/编码器、串流密钥申请链接）和 `rtmp_custom`（用户手填 URL + key）。此外还负责在线更新服务列表和向部分平台**动态查询最优 ingest 节点**。

| 文件 | 行数 | 功能 |
|---|---|---|
| `data/services.json` | 3591 | **平台数据本体**。621 条 `"name"`（平台 + 服务器节点），每个平台有 `servers[]`、`recommended`（最大码率/分辨率/关键帧间隔/codec 白名单）、`stream_key_link`，Twitch 等还有 `multitrack_video_configuration_url` |
| `data/schema/service-schema-v5.json` | 275 | 上面那份的 JSON Schema（format_version 5），改数据前先看这个 |
| `data/schema/package-schema.json` / `data/package.json` | 47 / 11 | 在线更新用的包描述（版本号、文件列表） |
| `rtmp-common.c` | 1180 | `rtmp_common_service`（`:1160`）：解析 `services.json`（jansson）、构造平台/服务器下拉框、把 `recommended` 里的限制回写到编码器设置（这是"选了 Twitch 后码率被自动限制"的实现处） |
| `rtmp-custom.c` | 194 | `rtmp_custom_service`（`:179`）：server / key / 可选 auth 用户名密码，最简实现，读这个文件就能看懂 `obs_service_info` 接口 |
| `rtmp-services-main.c` | 138 | 模块入口 + 用 `file-updater/` 后台拉取新版 `services.json`（所以不升级 OBS 也能拿到新平台） |
| `rtmp-format-ver.h` | 3 | 数据格式版本号常量 |
| `service-specific/service-ingest.c` / `.h` | 192 / 30 | **通用 ingest 列表框架**：带互斥锁的懒加载 + 本地缓存文件（`*_ingests.json` / `.new.json`）+ 后台刷新 |
| `service-specific/twitch.c` / `.h` | 52 / 8 | Twitch ingest 列表，就是上面框架的一个 20 行实例 |
| `service-specific/amazon-ivs.c` / `.h` | 54 / 8 | 同上，Amazon IVS |
| `service-specific/showroom.c` / `.h` | 151 / 10 | Showroom：不是列表，而是每次用 curl 查一个"当前该推哪"的接口（自带 access_key + 时间戳缓存） |
| `service-specific/nimotv.c` / `.h` | 131 / 3 | Nimo TV，同样是 curl 查询单个 ingest |
| `service-specific/dacast.c` / `.h` | 174 / 14 | Dacast：用 `file-updater` 拉取带 key 的 ingest 信息 |

## obs-vst/　`plugins/obs-vst/`

**职责**：**本篇唯一不属于录制/推流链路的插件**——VST 2.x 音频滤镜宿主。注册成一个 `obs_source_info` 滤镜（`obs-vst.cpp:346`），把 OBS 的音频帧喂给 VST 插件的 `processReplacing`，并能弹出插件自带的编辑器界面（Qt 窗口里嵌宿主平台的原生 view）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `obs-vst.cpp` | 348 | OBS 滤镜接口：`filter_audio` 回调、属性页（扫描系统 VST 目录列出插件）、chunk 数据保存/恢复（用 `QCryptographicHash` 校验） |
| `VSTPlugin.cpp` | 429 | 平台无关的宿主逻辑：`AEffect` 打开/关闭、`BLOCK_SIZE`(512) 分块处理、`dispatcher` 调用、`effGetChunk`/`effSetChunk` 状态序列化 |
| `headers/VSTPlugin.h` | 110 | `class VSTPlugin : public QObject` 声明（平台相关的 `loadEffect`/`unloadEffect` 是纯声明，由各平台文件实现） |
| `headers/vst-plugin-callbacks.hpp` | 21 | VST `audioMasterCallback` 的宿主应答 |
| `vst_header/aeffectx.h` | 382 | VST 2.4 SDK 的公开头（第三方，`AEffect` 结构等） |
| `EditorWidget.cpp` | 31 | 编辑器窗口的平台无关部分 |
| `headers/EditorWidget.h` | 63 | `class EditorWidget : public QWidget` 声明 |
| `mac/VSTPlugin-osx.mm` | 92 | **macOS**：用 `CFBundleCreate` + `CFBundleGetFunctionPointerForName` 找 `VSTPluginMain`/`main_macho` 入口加载 `.vst` bundle；`unloadEffect` 里 `CFBundleUnloadExecutable` |
| `mac/EditorWidget-osx.mm` | 57 | **macOS**：从 `QWidget::winId()` 取出 `NSView`，把它作为 `effEditOpen` 的父窗口交给插件画自己的 UI；`handleResizeRequest` 调整 `NSView` frame |
| `win/VSTPlugin-win.cpp` | 92 | Windows：`LoadLibrary` + `GetProcAddress` |
| `win/EditorWidget-win.cpp` | 89 | Windows：HWND 宿主 + 自定义窗口过程 |
| `linux/VSTPlugin-linux.cpp` | 69 | Linux：`dlopen` |
| `linux/EditorWidget-linux.cpp` | 36 | Linux：X11 窗口宿主 |

---

## 阅读建议

1. **想抄录制**：`mac-videotoolbox/encoder.c` → `obs-ffmpeg-mux.c` → `ffmpeg-mux/ffmpeg-mux.h`（39 行的 IPC 协议）→ `ffmpeg-mux/ffmpeg-mux.c`。这四份连起来就是"macOS 硬编 + 隔离复用"的完整方案，也正好是 WorkLabs 现有 `WLEncoder`+`WLRecorder` 的对照物。重点比对两件事：extradata 延迟到第一帧、muxer 崩溃不带崩主进程。
2. **想抄推流**：`flv-mux.h`（79 行，先建立 FLV 术语）→ `flv-mux.c` → `rtmp-stream.c` 的三个线程分段。`rtmp-stream.c` 别从头读，直接跳 `:1752 check_to_drop_frames` / `:1564 drop_frames` / `:1820 add_video_packet` 这三个函数，拥塞控制的全部精华就在那 100 行里。
3. **想抄媒体源**：`obs-ffmpeg-source.c` 只需扫一遍看清"源 = 壳"，真正要读的是 `shared/media-playback/media.c`（不在本篇范围）。这条边界划分本身比代码更有价值。
4. **可以直接跳过**：`texture-amf.cpp`（2834 行 AMD）、`obs-nvenc/` 除 `nvenc-compat.c` 的注释外全部、`obs-qsv11/` 全部、`librtmp/` 全部（除非查 AMF/chunk 编码细节）、`obs-vst/` 除两个 `mac/*.mm` 外全部、`rtmp-services/data/services.json`（当数据看，不当代码看）。
5. **三个"独立子进程"值得一起看**：`ffmpeg-mux/`（复用）、`obs-amf-test/`、`obs-nvenc-test/`、`obs-qsv-test/`（能力探测）。OBS 对"可能崩且不受我控制的第三方代码"的一贯态度就是踢出主进程，这个模式在自己项目里也适用（比如硬件编码器探测）。
6. **两处历史 bug 修复痕迹别错过**：`mac-videotoolbox/encoder.c:1024`（NAL 优先级 → RTMP 丢帧无法恢复）和 `coreaudio-encoder/encoder.cpp:705`（AAC priming samples → 音画不同步）。这两个都是"不看注释永远不会想到"的坑，且都只在 macOS 路径上出现。
