# OBS 目录导航 · libobs/util + libobs/media-io（基础设施与音视频数据层）

> 源码范围：`libobs/util/`（顶层 61 个 + 子目录 14 个）、`libobs/media-io/`（19 个）｜ 源文件共 94 个 ｜ 基于 obs-studio commit `f2db097`（2026-07-09）
> 返回总索引：[README.md](README.md)

## 本篇速查

想找什么 → 去哪：

| 我想看… | 去这里 |
|---|---|
| 合成结果怎么分发给多个编码器/输出（帧总线 frame bus） | [`media-io/video-io.c`](#video-ioc) |
| 音频节拍线程怎么定时向下游要 1024 帧 | [`media-io/audio-io.c`](#libobsmedia-io音视频数据表示与分发) |
| 环形缓冲 / FIFO（OBS 到处在用的那个轮子） | [`util/deque.h`](#dequeh) |
| 采样率 / 声道 / 采样格式转换（swresample 封装） | [`media-io/audio-resampler-ffmpeg.c`](#audio-resampler-ffmpegc) |
| 像素格式缩放 / 色彩空间转换（swscale 封装） | [`media-io/video-scaler-ffmpeg.c`](#libobsmedia-io音视频数据表示与分发) |
| YUV 各种平面布局的 linesize / plane 高度怎么算 | [`media-io/video-frame.c`](#libobsmedia-io音视频数据表示与分发) |
| BT.601/709/2020 的 YUV→RGB 矩阵是怎么生成的 | [`media-io/video-matrices.c`](#libobsmedia-io音视频数据表示与分发) |
| 帧耗时统计 / 火焰图式层级剖析 | [`util/profiler.c`](#profilerc) |
| macOS 平台适配（路径、CPU 占用、防休眠、CFString） | [`util/platform-cocoa.m`](#平台抽象platform) |
| `os_gettime_ns` / `os_sleepto_ns` 在 mac 上怎么实现 | `util/platform-cocoa.m:41`、`util/platform-nix.c` |
| 动态数组 / 动态字符串这两个基础容器 | `util/darray.h`、`util/dstr.c` |
| ini 配置读写（含 default 层） | `util/config-file.c` |
| effect / shader 文件是怎么被词法分析的 | `util/cf-lexer.c`、`util/cf-parser.h` |
| 线程、信号量、事件、原子操作的跨平台封装 | `util/threading.h` + `util/threading-posix.c` |
| 二进制写文件（FLV/mp4 那种）的抽象接口 | `util/serializer.h` + `util/buffered-file-serializer.c` |

标记约定：
- ⭐ = 架构关键或代码量大，篇末有展开小节。
- 🔧 = **可以直接抄进自己内核的轮子**（无 OBS 依赖 / 依赖极浅，改个前缀就能用）。

---

## 一句话职责

`libobs/util/` 是 OBS 自己攒的一套 C 标准库补充：内存、字符串、容器、线程、平台差异、配置、词法器、性能剖析。
它**不依赖 libobs 任何业务代码**（唯一例外是 `source-profiler.c`，它 include 了 `obs-internal.h`），
所以是整棵依赖树的最底层——`graphics/`、`media-io/`、`obs-*.c`、所有插件都往下调它。

`libobs/media-io/` 是往上一层：定义"一帧视频/一块音频长什么样"（格式枚举、平面布局、色彩矩阵），
提供两个 FFmpeg 封装（swscale 缩放、swresample 重采样），以及**最关键的一对帧总线**
`video_output_*` / `audio_output_*`——合成器（`obs-video.c`）把成品塞进去，多个编码器/输出从里面按需拉走。
它是 OBS 里"合成"与"编码输出"之间那道唯一的解耦缝。

---

## libobs/util/　`libobs/util/`

**职责**：跨平台基础设施。分七个功能族：内存与日志、字符串与容器、平台抽象、线程与进程、序列化与配置、性能诊断、词法分析。

### 内存与日志

| 文件 | 行数 | 功能 |
|---|---|---|
| `bmem.c` 🔧 | 164 | OBS 全局分配器：32 字节对齐（Windows 用 `_aligned_malloc`，*nix 用手写偏移 hack，因为 POSIX 没有对齐版 realloc）、`num_allocs` 原子计数用于泄漏检查；**分配失败或 size==0 直接 `bcrash` 崩掉，永不返回 NULL**（`bmalloc`:101） |
| `bmem.h` | 94 | `bmalloc`/`brealloc`/`bfree`/`bzalloc`/`bmemdup`/`bstrdup` 声明；对齐技巧注释来源标注为抄自 FFmpeg |
| `base.c` | 126 | 日志与崩溃的**可替换 handler**：`base_set_log_handler` / `base_set_crash_handler`，默认 handler 打到 stderr。`blog` 是全代码库唯一日志入口 |
| `base.h` | 97 | `LOG_ERROR=100 / WARNING=200 / INFO=300 / DEBUG=400` 四级（数值间隔 100 便于插值）、`blog`/`bcrash` 带 printf 格式检查属性 |
| `c99defs.h` | 79 | 给 MSVC 补 C99（bool/stdint）、`EXPORT`/`FORCE_INLINE`/`OBS_NORETURN`/`PRAGMA_WARN_PUSH` 等编译器抽象宏 |

### 字符串与容器

| 文件 | 行数 | 功能 |
|---|---|---|
| `dstr.c` 🔧 | 787 | 动态字符串（`struct dstr {char *array; size_t len, capacity;}`）实现：copy/cat/insert/replace/find/printf/替换、`strlist_split`、大小写无关比较 `astrcmpi` |
| `dstr.h` 🔧 | 320 | 同名实现的声明；一半以上是 `static inline`（init/free/move/resize/is_empty 等），拷贝成本极低 |
| `dstr.hpp` | 46 | `class DStr` —— RAII 包装，`operator->` 直取内部 `dstr`，给 C++ 侧（UI/插件）用 |
| `darray.h` 🔧 | 606 | 动态数组。裸 `struct darray` 按元素 size 传参（不类型安全），配 `DARRAY(type)` 宏（:438）+ `da_push_back`/`da_erase`/`da_find` 等一整套 `da_*` 宏（:448 起）拿回类型安全。OBS 内部 90% 的数组都是它 |
| `deque.h` ⭐🔧 | 319 | 双端队列 / 环形缓冲，纯 header-only inline。**过去叫 `circlebuf.h`**（本仓库是浅克隆，无法从 git 历史核实改名 commit；API 一一对应）。音频缓冲、包队列全靠它 |
| `text-lookup.c` | 271 | 本地化字符串表：读 `.ini` 式语言文件，用 `lexer` 解析，存进 uthash 哈希表，`text_lookup_getstr` 按 key 取值 |
| `text-lookup.h` | 45 | 同名实现的声明（`lookup_t` 不透明句柄） |
| `utf8.c` | 366 | UTF-8 编解码（RFC3629），Windows 上还负责 wchar 互转的底层 |
| `utf8.h` | 35 | 同名实现的声明 |
| `uthash.h` | 34 | 把系统 uthash 的分配器改成 `bmalloc`/`bfree`、哈希函数改成 SFH（Super Fast Hash）的一层薄配置；OBS 所有哈希表都 include 这个而不是原版 |
| `crc32.c` / `crc32.h` | 64 / 29 | 标准 CRC32 查表实现（注释标明源自 Gary S. Brown 的代码），单函数 `calc_crc32` |
| `bitstream.c` / `bitstream.h` | 51 / 28 | 极简 bit 级读取器（`read_bit`/`read_bits`/`r8`/`r16`），用来解 SPS/PPS 这类比特流头 |
| `util_uint64.h` 🔧 | 34 | 只有一个 `util_mul_div64(num, mul, div)`——**先取余再乘除，避免 `num*mul` 溢出**；x64 MSVC 走 `_umul128`/`_udiv128`。时间基换算（ns↔帧号）到处在用 |
| `util_uint128.h` 🔧 | 108 | 128 位整数的乘/移位/比较（手写 4×uint32），给需要更高精度的时间戳换算兜底 |
| `sse-intrin.h` | 41 | SIMD 抽象：MSVC/x86 直接 `emmintrin.h`，其它平台（含 **Apple Silicon**）靠 vendored 的 `simde/x86/sse2.h` + `SIMDE_ENABLE_NATIVE_ALIASES` 把 SSE2 intrinsic 映射到 NEON。**注意：`util/` 下没有 `simde/` 目录**，simde 来自 `deps/` 或系统 |
| `util.hpp` | 155 | C++ 便利封装三件套：`BPtr<T>`（bfree 的智能指针）、`ConfigFile`（config_t RAII）、`TextLookup`（lookup_t RAII） |

### 平台抽象　`platform*`

**职责**：所有"这事各系统写法不同"的东西收在 `platform.h` 一个头文件后面——文件 IO、编码转换、`dlopen`、
纳秒时钟与精确 sleep、配置目录、目录遍历/glob、CPU 核数、内存/磁盘占用、防休眠、UUID。
`platform.c` 装平台无关的公共部分，剩下按系统分文件实现。

**macOS 的组合方式很重要**：`libobs/cmake/os-macos.cmake:22-27` 同时编译
`platform-cocoa.m` + `platform-nix.c` + `pipe-posix.c` + `threading-posix.c`。
也就是说 **macOS 上 `platform-nix.c` 也在编译**，它内部用 `#if !defined(__APPLE__)` 把与 Cocoa 版重复的函数挖掉。
另外 `platform-cocoa.m` 被单独指定 `-fobjc-arc`（`os-macos.cmake:31`）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `platform.h` | 224 | 整套 `os_*` API 的唯一声明处，按功能分块：文件/编码转换（:33-74）、dlopen（:76-79）、CPU 占用与高性能令牌（:84-90）、sleep/时钟（:97-101）、配置路径（:103-109）、目录与 glob（:128-153）、mkdir/rename/copyfile/`os_safe_replace`（:161-167）、防休眠（:172-174）、核数与内存（:179-193）、`os_generate_uuid`（:197） |
| `platform.c` | 846 | 平台无关公共实现：`os_fread_utf8`（带 BOM 处理）、`os_quick_read/write_*_file`（含 `_safe` 原子替换写法）、mbs↔wcs↔utf8 六向转换、locale 无关的 `os_strtod`/`os_dtostr`（:554/:563，先把小数点换成本地符号再转，避免 locale 坑）、`os_mkdirs` 递归建目录、`os_generate_formatted_filename`（录制文件名模板 `%CCYY-%MM-%DD` 展开，:698） |
| `platform-cocoa.m` ⭐ | 530 | **macOS 专属实现**，逐项：`os_gettime_ns`（:41，一行 `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`——注意是 UPTIME_RAW，休眠期间不走时）；`os_get_config_path` / `os_get_program_data_path`（:87-102，走 `NSSearchPathForDirectoriesInDomains` 拼 `Library/Application Support/<name>`）；`os_get_executable_path_ptr`（:107，`NSBundle` 取 exe 目录）；`os_cpu_usage_info_*`（:184-217，用 `mach` 的 `thread_info`/`task_info` 累加 user+system 时间算占用率）；`os_request_high_performance` / `os_end_high_performance`（:223-233）；`os_inhibit_sleep_*`（:248-285，`IOPMAssertion` 防休眠）；`os_get_emulation_status`（:298，`sysctlbyname("sysctl.proc_translated")` 判断是否跑在 Rosetta 下）；`os_get_physical_cores` / `os_get_logical_cores`（:312-337，`sysctlbyname hw.physicalcpu/hw.logicalcpu`）；`os_get_sys_free_size` / `os_get_sys_total_size`（:352/:407，`host_statistics` + `hw.memsize`）；`os_get_free_space` / `os_get_free_disk_space`（:361/:386，**不用 statvfs 而是走 `NSURL resourceValuesForKeys:` 的 `NSURLVolumeAvailableCapacityForImportantUsageKey`**——APFS 上这才是"清掉可回收快照后真正能写多少"的数字，statvfs 会低报；这两个在 `platform-nix.c` 里被 `#ifndef __APPLE__` 挖掉）；`os_get_proc_memory_usage` / resident / virtual（:425-444，`mach_task_basic_info`）；最后 :455-530 是 `cfstr_copy_cstr` / `cfstr_copy_dstr`——CFString 转 C 串/dstr，**先试 `CFStringGetCStringPtr` 快路径，失败再按最大字节数分配慢路径**，注释里明确写了 kCFNotFound 与 null terminator 的处理 |
| `apple/cfstring-utils.h` | 16 | 上面那两个 `cfstr_copy_*` 的公开头（macOS 构建时列入 public headers，`libobs/CMakeLists.txt:373`），插件可直接用 |
| `platform-nix.c` | 1108 | POSIX 实现，**macOS 也编译**。整文件 `os_dlopen`（:62）对 Apple 特殊处理：补 `.dylib`/`.framework`/`.plugin` 后缀、用 `RTLD_NOW\|RTLD_FIRST`，且给 Python 单独加 `RTLD_GLOBAL`（:78-84，为脚本插件踩过的坑）。其余 `#ifndef __APPLE__` 段（:495 磁盘空间、:803 核数、:1089 磁盘剩余）在 mac 上让位给 cocoa 版；`os_generate_uuid` 用 libuuid（:1100） |
| `platform-nix-dbus.c` | 166 | Linux 专属：D-Bus 防休眠（注释标明基本照搬 VLC 的 d-bus power 实现） |
| `platform-nix-portal.c` | 223 | Linux 专属：XDG Desktop Portal（Flatpak/Wayland 环境下的权限申请通道） |
| `platform-windows.c` | 1374 | Windows 专属实现（Win32 文件/注册表/`timeBeginPeriod` 精确 sleep/WMI 硬件名等），mac 开发可跳过 |

### 线程、同步与子进程

| 文件 | 行数 | 功能 |
|---|---|---|
| `threading.h` 🔧 | 103 | 跨平台线程门面：给 Windows 补 pthread、`pthread_mutex_init_value`（可赋值的初始化，:45）、`pthread_mutex_init_recursive`（:54）、`os_event_*`（手动/自动复位事件，`enum os_event_type`:70）、`os_sem_*`、`os_set_thread_name`、`THREAD_LOCAL` 宏（:96-98） |
| `threading-posix.c` | 273 | POSIX 实现：`os_event` 用 mutex+condvar 手搓（含 `os_event_timedwait`:106、`os_event_try`:136）；信号量分两套——**Apple 走 mach `semaphore_t`，其它走 POSIX `sem_t`**（:172 与 :218 两份 `os_sem_data`） |
| `threading-posix.h` 🔧 | 77 | 原子操作 inline 集合（`os_atomic_inc_long`/`dec`/`set_bool`/`load_long`…），全部落到 `__atomic_*` + `__ATOMIC_SEQ_CST` |
| `threading-windows.c` / `threading-windows.h` | 213 / 142 | 同上的 Win32 版（`CreateEvent`/`CreateSemaphore`/`_Interlocked*`） |
| `pipe.h` / `pipe.c` | 51 / 75 | 子进程管道的公共部分：`os_process_args_*` 构造 argv 列表（用 darray+dstr 攒，:25-65），避免手拼命令行的转义问题 |
| `pipe-posix.c` | 207 | POSIX 实现：`posix_spawn` + pipe 三件套，`os_process_pipe_read` / `read_err` / `write`（:168-196），stdout 与 stderr 分开读 |
| `pipe-windows.c` | 279 | 同上 Win32 版（匿名管道 + `CreateProcess`） |
| `task.c` 🔧 | 164 | 极简任务队列 `os_task_queue`：一条线程 + 信号量 + `deque` 存任务，`os_task_queue_wait` 能阻塞等到队列排空、`os_task_queue_inside` 判断当前是否就在该队列线程里（防自死锁）。线程函数名字叫 `tiny_tubular_task_thread`（:131） |
| `task.h` | 22 | 同名实现的声明（5 个函数，接口极小） |
| `curl/curl-helper.h` | 35 | 只做一件事：把 Windows 上 curl 的证书吊销检查放宽（`CURLSSLOPT_REVOKE_BEST_EFFORT`），非 Windows 展开成空宏。用了 curl 的地方 include 它而不是直接 `curl/curl.h` |

### 序列化与配置

**职责**：`serializer.h` 是一个"写字节流去哪"的函数指针接口，三种后端（内存数组 / 文件 / 带线程的缓冲文件）实现同一个接口——
FLV muxer、mp4 写入这类"要往容器里塞字节"的代码就只依赖接口，不关心落地方式。

| 文件 | 行数 | 功能 |
|---|---|---|
| `serializer.h` 🔧 | 158 | `struct serializer {void *data; read/write/seek/get_pos 函数指针}`（:32），外加一大堆 `s_w8`/`s_wl16`/`s_wl32`/`s_wb32`/`s_wbf`… 大小端 inline 写入助手（:83-155）。要写 FLV/mp4 这类格式，这个接口设计可以直接抄 |
| `array-serializer.c` / `.h` | 93 / 37 | 后端一：写进内存 darray（`array_output_serializer_init`:74），支持 seek/覆写 |
| `file-serializer.c` / `.h` | 183 / 34 | 后端二：直接 `FILE*` 读或写；`file_output_serializer_init_safe`（:134）写临时文件再原子替换 |
| `buffered-file-serializer.c` / `.h` | 394 / 32 | 后端三：**带独立 IO 线程 + 分块缓冲**的写入器（`io_thread`:58），写调用只进内存缓冲立即返回，磁盘卡顿不阻塞调用者；缓冲上限可配（`buffered_file_serializer_init`:327）。录制写盘用它扛磁盘抖动 |
| `config-file.c` | 789 | ini 风格配置：section/item **两层 uthash 哈希表**（:30-62），自己用 `lexer` 手写解析（`parse_config_data`:203）含转义处理（`unescape`:119）；**双层数据——user 值 + default 值**，取不到 user 就回落 default（`config_find_item`:498）；`config_save_safe` 临时文件+备份原子保存 |
| `config-file.h` | 103 | `config_get_*` / `config_set_*` / `config_set_default_*` / `config_has_user_value` 全套声明；头部注释明确建议"读任何值之前先把 default 设好" |

### 性能与诊断

| 文件 | 行数 | 功能 |
|---|---|---|
| `profiler.c` ⭐ | 1117 | 层级式性能剖析器：`profile_start`/`profile_end` 配对，靠 thread-local 栈自动建父子树；统计不存平均值而是**存耗时直方图**（自制开放寻址哈希表 `profile_times_table`），能出中位数/百分位；支持快照（snapshot）、`profiler_print` 文本输出、CSV/CSV.gz 导出 |
| `profiler.h` | 97 | 分三段声明：埋点 API（`profile_start`/`profile_end`/`profile_register_root`/`profile_reenable_thread`，:17-22）、name store（`profile_store_name` 把格式化后的名字驻留成稳定指针，:50）、snapshot 查询 API（:66-93） |
| `profiler.hpp` | 47 | `struct ScopeProfiler` —— RAII 版埋点，构造 start、析构 end，可移动不可拷贝 |
| `source-profiler.c` | 630 | **不是通用 util**，它 include `obs-internal.h`：per-source 的渲染/异步帧耗时与 GPU 计时统计（UI 里那个"统计"面板的数据源）。内部自带一个 `struct ucirclebuf`（:48）存最近 N 次采样 |
| `source-profiler.h` | 66 | 同名实现的声明（`source_profiler_enable`/`_frame_collect`/`_source_tick_start` 等） |

### 词法分析与 C 族预处理器

**职责**：OBS 的 effect（`.effect` 着色器）和 shader 文件不是交给别人解析的，是自研的一套 C 风格词法器 + 预处理器。
`lexer` 是通用底座，`cf-lexer` 在它上面实现 C 家族 token 化 + `#define`/`#include` 展开，`cf-parser` 提供"逐 token 前进 + 报错定位"的骨架。
使用者：`graphics/effect-parser.c`、`graphics/shader-parser.c`、`callback/decl.c`（信号声明串解析）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `lexer.c` | 305 | 通用词法底座：`strref`（**零拷贝字符串切片**，指针+长度）的比较、`valid_int_str`/`valid_float_str` 数字判定、`lexer_getbasetoken`（:239 切出 name/数字/空白/换行/字符串/单字符六类 token）、`lexer_getstroffset`（:283 由指针反算行列号，用于报错） |
| `lexer.h` 🔧 | 273 | `struct strref`（:30）、`enum base_token_type`（:126）、`struct error_data`/`error_item`（:155-182，把多条错误攒起来 `error_data_buildstring` 一次性输出）、`struct lexer`（:230）。想给自己的配置/着色器语言写解析器，这套 strref + error_data 的组织方式很值得抄 |
| `cf-lexer.c` | 1376 | 本篇最大的文件：C 家族词法器 + **完整的预处理器**——`#define`（含带参宏与展开）、`#include`、`#if`/`#ifdef`/`#else`/`#endif` 条件编译、注释剥离、行接续。effect 里能写宏就靠它 |
| `cf-lexer.h` | 199 | token 定义与 `cf_lexer`/`cf_preprocessor` 结构声明；头部注释列了 C 族 token 的 6 类定义 |
| `cf-parser.c` | 60 | 只有两个函数：`cf_adderror`（:19 带 file/row/col 的错误累积）、`cf_pass_pair`（:38 跳过配对括号） |
| `cf-parser.h` | 281 | 实际的 parser 骨架大头在这里（大量 inline）：`cf_next_token`/`cf_token_is`/`cf_go_to_token`/各种 `cf_adderror_expecting` 便利宏，是"手写递归下降"的脚手架 |

### 平台专属子目录

| 目录 | 内容 | 说明 |
|---|---|---|
| `util/windows/` | 12 个文件（`ComPtr.hpp` 186、`window-helpers.c` 575、`WinHandle.hpp` 81、`CoTaskMemPtr.hpp` 52、`HRError.hpp` 24、`win-version.h` 57、`win-registry.h` 37、`device-enum.c/h` 30/14、`obfuscate.c/h` 38/16 + `window-helpers.h` 47） | Windows-only：COM 智能指针 / 句柄 RAII、窗口枚举与匹配（窗口捕获源用）、注册表读、系统版本、DirectShow 设备枚举、API 名混淆（反作弊白名单规避）。mac 开发整目录可跳过 |
| `util/apple/` | `cfstring-utils.h`（16 行） | 见上面平台抽象小节 |
| `util/curl/` | `curl-helper.h`（35 行） | 见上面线程/子进程小节 |

### ⭐ 重点文件展开

#### `deque.h`
- **做什么**：一个 header-only、按**字节**（不是按元素）操作的环形双端队列。`struct deque {void *data; size_t size, start_pos, end_pos, capacity;}`（:32）。所有函数都是 `static inline`，没有 `.c` 文件。
- **关键入口**：`deque_push_back`（:143）/ `deque_push_front`（:166）/ `deque_push_back_zero`（:190，直接塞一段 0，音频补静音就用它）/ `deque_peek_front`（:237）/ `deque_pop_front`（:272）/ `deque_data(dq, idx)`（:303，按相对下标取指针）。扩容在 `deque_ensure_capacity`（:66）：容量翻倍，然后 `deque_reorder_data`（:52）把绕回头部的那段数据 `memmove` 到新缓冲的尾部，保持环的连续语义。
- **看点**：按字节而非元素设计，所以同一份代码既能当 PCM 字节缓冲，也能当 `struct` 队列（`deque_push_back(&dq, &pkt, sizeof(pkt))`）——省掉一层泛型。`deque_upsize`（:91）处理"跨越 capacity 边界的 memset 要拆两段"这个环形缓冲经典坑，逻辑可以照抄。对比你现在用的 `TPCircularBuffer`：TPCB 是无锁单生产者单消费者、依赖 mach VM 地址镜像映射（mac 专属魔法）；`deque` 完全普通内存 + 需要外部加锁，但跨平台、能双端、能任意位置覆写（`deque_place`:119）。做包队列/帧队列这类"有锁也无所谓"的地方，`deque` 更省心。

#### `profiler.c`
- **做什么**：给 OBS 的每帧循环做层级耗时剖析。埋点是一对 `profile_start(name)` / `profile_end(name)`，name **必须是稳定指针**（比较用的是指针相等 `==`，不是 `strcmp`，见 `get_root_entry`:299），所以动态名字要先过 `profile_store_name` 驻留。
- **关键入口**：`profile_start`（:358）、`profile_end`（:385）、`merge_context`（:329）、thread-local 状态 `thread_context`/`thread_enabled`（:255-256）、直方图插入 `add_hashmap_entry`（:102）、快照 `profile_snapshot_create`（:886）、`profiler_print`（:717）、`profiler_snapshot_dump_csv_gz`（:991，直接 zlib 写 .gz）。
- **看点**：三个设计取舍很值得学。① **热路径几乎零锁**：`profile_start` 只在 thread-local 的 `profile_call` 树上挂节点（子节点直接 `da_push_back` 进父节点数组），只有最外层 `profile_end` 才 `merge_context` 去抢全局锁合并——每帧只锁一次。② **不存平均值，存直方图**：每个节点有个 `profile_times_table`（开放寻址 + 记录探测距离 `probes`，负载因子 0.7 扩容，:127），key 是"微秒耗时"，value 是次数。这样能出 min/max/中位数/百分位，而平均值会把卡顿抹平——做实时管线诊断这点是关键。③ 同时统计 **times_between_calls**（两次调用之间的间隔）并和 `profile_register_root` 注册的期望间隔比对，这才是"掉帧/节拍不稳"的直接证据。另外 `profile_end` 遇到名字不匹配会尝试沿父链回溯自动补齐（:400-417），对付提前 return 漏掉 end 的情况。

---

## libobs/media-io/　`libobs/media-io/`

**职责**：定义音视频数据的"形状"和"搬运通道"。上游是合成器（`obs-video.c` 把 GPU 下载回来的像素塞进来）和音频混合（`obs-audio.c`），
下游是各个编码器与输出。两条总线（`video_output_*` / `audio_output_*`）是 OBS "合成一次、喂多个消费者"的实现处；
另有两个 FFmpeg 薄封装（缩放、重采样）和一批纯数据描述文件（格式枚举、平面布局、色彩矩阵）。

| 文件 | 行数 | 功能 |
|---|---|---|
| `video-io.c` ⭐ | 679 | **视频帧总线**：16 格帧缓存环 + 一条 `video_thread` 把每帧分发给所有已连接的 input（编码器），每个 input 可带自己的缩放/格式转换和帧率分频。详见展开 |
| `video-io.h` | 338 | 本篇最该先读的头文件：`enum video_format`（:34，I420/NV12/P010/I444/V210/R10L… 共 20+ 种，注释标了平面数）、`enum video_trc`/`video_colorspace`/`video_range_type`（:99-119）、`struct video_data`（:121，data[8]+linesize[8]+timestamp）、`struct video_output_info`（:127）、`format_is_yuv`（:141）、`get_video_format_name`（:177）、`resolve_video_range`（:255）、`struct video_scale_info`（:278）、以及全部 `video_output_*` 声明（:298-326） |
| `audio-io.c` ⭐ | 455 | **音频帧总线**：与 video 对偶但方向相反——它是**主动拉（pull）**。`audio_thread`（:205）按 `AUDIO_OUTPUT_FRAMES=1024` 一块、用 `os_sleepto_ns_fast` 精确对齐节拍，回调 `input_cb` 向 libobs 要数据（`input_and_output`:160），`clamp_audio_output`（:132）把混音结果夹到 ±1.0（同时保留一份未夹的 `buffer_unclamped` 给声明 `allow_clipping` 的消费者），再 `do_audio_output`（:107）逐 input 重采样后分发。支持 6 条独立 mix 轨（`MAX_AUDIO_MIXES`） |
| `audio-io.h` | 228 | `MAX_AUDIO_MIXES 6` / `MAX_AUDIO_CHANNELS 8` / **`AUDIO_OUTPUT_FRAMES 1024`**（:28-31，整个音频管线的块大小常量）、`enum audio_format`（:43，交错与 planar 各 4 种）、`enum speaker_layout`（:66）、`struct audio_data`/`audio_output_data`（:77-85）、以及一批换算 inline：`get_audio_channels`/`get_audio_bytes_per_channel`/`is_audio_planar`/`get_audio_size`/`audio_frames_to_ns`/`ns_to_audio_frames`（:108-203）🔧 |
| `audio-resampler-ffmpeg.c` ⭐ | 218 | swresample 封装：采样率/声道布局/采样格式三合一转换，含单声道上混矩阵和**重采样延迟补正**。详见展开 |
| `audio-resampler.h` | 44 | 接口只有 3 个函数 + `struct resample_info {samples_per_sec, format, speakers}`；文件名带 `-ffmpeg` 说明这是可替换实现 |
| `audio-math.h` 🔧 | 43 | 纯 inline 数学：dB↔线性增益换算（`db_to_mul`/`mul_to_db`），含 MSVC 的 `-inf` 警告抑制。做音量条/推子直接用 |
| `video-scaler-ffmpeg.c` | 270 | swscale 封装：`video_scaler_create`（:143）把 OBS 的 `video_format`/`colorspace`/`range` 映射成 `AVPixelFormat` + `sws` 色彩系数（`get_ffmpeg_coeffs`:105 按 BT.601/709/2020 取 `sws_getCoefficients`）并设 src/dst range；`video_scaler_scale`（:232）执行。CPU 侧缩放兼格式转换都走它 |
| `video-scaler.h` | 43 | 同名实现的声明 + `enum video_scale_type`（POINT/FAST_BILINEAR/BILINEAR/BICUBIC）与三个返回码 |
| `video-frame.c` 🔧 | 263 | **平面布局的权威计算**：`video_frame_get_linesizes`（:34）和 `video_frame_get_plane_heights`（:123）为 20+ 种格式逐个算每个 plane 的行宽与高（含 P010/I010 的 2 字节、V210 的 6 像素打包成 16 字节、I40A/YUVA 的 alpha 平面）；`video_frame_init`（:190）**一次 `bmalloc` 分配所有 plane** 再按累加偏移切指针（每个 plane 尺寸先按 `base_get_alignment()`＝32 对齐）；`video_frame_copy`（:235）按 plane memcpy。自己写内核时这两张表能省掉一堆试错 |
| `video-frame.h` | 64 | `struct video_frame {data[8], linesize[8]}` + 上述函数声明 + `video_frame_free` |
| `format-conversion.c` | 288 | **CPU 侧像素格式转换**，只覆盖 OBS 实际需要的几条路径：`compress_uyvx_to_i420`/`_to_nv12`（:80/:112，打包 4:4:4 → 半采样，chroma 用 2×2 平均）、`convert_uyvx_to_i444`（:143）、`decompress_420`/`decompress_nv12`/`decompress_422`（:176-241，反向展开成打包 444）。GPU 转换是首选路径，这里是 fallback |
| `format-conversion.h` | 50 | 同名实现的声明（头部注释：往返打包 444 YUV 的转换函数） |
| `video-matrices.c` | 256 | 色彩矩阵**生成器**（不是硬编码常量表）：`initialize_matrices`（:120）按 Kb/Kr 系数 + range 上下限，为 601/709/2020/2100 × full/limited × 8/10/12/16 bit 组合算出 4×4 的 YUV→RGB 矩阵与逆矩阵；`video_format_get_parameters`（:221）/`_for_format`（:229）对外取用。shader 里的 `color_matrix` uniform 就来自这里 |
| `video-fourcc.c` | 51 | `video_format_from_fourcc`：把设备报上来的一堆同义 FOURCC（`UYVY`/`2vuy`/`HDYC`/`yuvs`…）归一成 `enum video_format`。摄像头/采集卡接入时的必要脏活，可直接抄表 |
| `media-remux.c` | 266 | 独立小工具：用 FFmpeg **纯复用（remux，不重编码）** 把文件换容器——录 mkv 再转 mp4 那个功能。`media_remux_job_create`（:136）开输入输出、`process_packets`（:177）搬包并回调进度、`media_remux_job_process`（:221） |
| `media-remux.h` | 37 | 同名实现的声明（3 个函数 + 进度回调 typedef） |
| `frame-rate.h` 🔧 | 29 | 只有 `struct media_frames_per_second {numerator, denominator}` 和两个换算 inline（`to_frame_interval`/`to_fps`）。**帧率必须用有理数存**（30000/1001 这种），这个小结构体值得照搬 |
| `media-io-defs.h` | 20 | 只定义 `MAX_AV_PLANES 8` —— 全库所有 `data[MAX_AV_PLANES]` 数组的来源 |

### ⭐ 重点文件展开

#### `video-io.c`
- **做什么**：**OBS 把合成结果分发给多个编码器/输出的核心机制**。一个 `video_t`（`struct video_output`:70）= 一条视频轨：内部有 `struct cached_frame_info cache[MAX_CACHE_SIZE]`（:88，`MAX_CACHE_SIZE = 16`，:35）这个**固定 16 格的帧缓存环**，加一条自己的 `video_thread`（:190），加一个 `DARRAY(struct video_input) inputs`（:83）—— 每个 input 就是一个下游消费者（通常是一个编码器）。
- **生产侧**：合成器在 `obs-video.c:785` 调 `video_output_lock_frame(video, &frame, count, timestamp)`（:509）拿到环里下一格的**可写指针**，把 GPU 下载回来的像素直接 memcpy/组装进去（`copy_rgbx_frame` 或 `set_gpu_converted_data`），然后 `video_output_unlock_frame`（:547）—— 后者做两件事：`available_frames--` 和 `os_sem_post(update_semaphore)` 唤醒分发线程。**零拷贝的关键就在这个 lock/unlock 契约**：调用者写进总线自己的缓冲，不需要另外分配帧再交接。
- **消费侧**：`video_thread`（:190）被信号量唤醒后循环 `video_output_cur_frame`（:126）：取环头那格，遍历所有 input，按 `frame_rate_divisor` 计数器决定这一帧要不要给它（:151-156），需要缩放的先 `scale_video_output`（:98，走 `video_scaler_scale`，每个 input 自带 `MAX_CONVERT_BUFFERS=3` 个转换缓冲轮换），再回调 `input->callback`。`count`/`skipped` 那套计数（:168-181）是**帧复制/丢帧的记账**：一帧可以被"消费 count 次"（对应 CFR 下重复输出同一帧），环满时新帧不进环而是给环尾那格 `count += count; skipped += count`（:521-524），于是编码器跟不上就体现为 `skipped_frames` 上升而不是内存暴涨。
- **关键入口**：`video_output_open`（:239）、`video_output_connect2`（:398，带 `frame_rate_divisor`）、`video_output_disconnect2`（:470）、`video_output_lock_frame`（:509）、`video_output_unlock_frame`（:547）、`video_output_create_with_frame_rate_divisor`（:660）。
- **看点**：① `frame_rate_divisor` 用**独立计数器而不是取余**，注释（:49-57）解释得很清楚：取余会让分频后落在哪一帧取决于"编码器启动时的总帧数"，同时启动的两个编码器会对不齐；用各自从 0 开始的计数器就能保证对齐。② `video_output_create_with_frame_rate_divisor`（:660）返回一个**浅拷贝 + `parent` 指针**的假 `video_t`（`info.fps_den *= divisor`），所有 API 入口先 `get_root()`（:385）回溯到真身——一个轻量的"视图"技巧，让"30fps 录制 + 60fps 推流"共用同一个环。③ `raw_active` 与 `gpu_refs` 两个引用计数分别代表"有 CPU 编码器"和"有 texture 编码器"，只在都归零时才 `log_skipped`（:451）。④ 分发是**单线程串行**的：一个下游 callback 里卡住会拖累所有下游。OBS 的对策是 callback 里只做入队。

#### `audio-resampler-ffmpeg.c`
- **做什么**：`SwrContext` 的一层薄壳，把 OBS 的 `resample_info {samples_per_sec, audio_format, speaker_layout}` 翻译成 FFmpeg 的 `(sample_rate, AVSampleFormat, AVChannelLayout)` 三元组，做采样率/格式/声道的一站式转换，并管理输出缓冲的生命周期。
- **关键入口**：`audio_resampler_create`（:100）、`audio_resampler_resample`（:181）、`audio_resampler_destroy`（:169）；格式映射 `convert_audio_format`（:46）。
- **看点**：三个细节是自己写重采样时最容易漏的。① **延迟补正**：`swr_convert` 内部会攒样本（滤波器需要前后文），所以每次调用都用 `swr_get_delay(ctx, 1000000000)` 取出**以纳秒为单位的当前内部延迟**并通过 `*ts_offset` 回传（:194），调用方（`audio-io.c:101`）拿到后做 `data->timestamp -= offset`。不做这一步，重采样会引入一个随缓冲状态浮动的时间戳偏移，表现为音视频慢慢不同步。② **输出缓冲按需增长**：先用 `swr_get_delay` + `av_rescale_rnd(..., AV_ROUND_UP)` 估算这次最多产出多少帧（:190-192），只在超过现有容量时重新 `av_samples_alloc`（:197-204）—— 稳态下零分配。③ **单声道上混要显式给矩阵**：输入是 mono、输出多声道时，默认 swr 只会把声音塞进一个声道；这里用 `swr_set_matrix` 传了一张全 1 矩阵（:145-157，按目标声道数选行，注意 5.1/7.1 那几行把中置/低音位置置 0），让 mono 平均铺到各声道。④ 整个文件用 `#if LIBSWRESAMPLE_VERSION_INT < AV_VERSION_INT(4,5,100)` 分了新旧两套声道布局 API（`uint64_t layout` vs `AVChannelLayout`），是 FFmpeg 跨版本兼容的标准写法。

---

## 阅读建议

1. **先读三个头文件建立词汇表**：`media-io/video-io.h`（格式枚举 + `video_data` + 总线 API）、`media-io/audio-io.h`（1024 块大小 + 格式/布局枚举 + 换算 inline）、`util/platform.h`（`os_*` 全景）。这三个读完，再看 libobs 任何一处代码都不会卡在"这个类型是啥"。
2. **然后读 `video-io.c` 全文**（679 行，本篇最值得逐行的一个）。它是 OBS "合成一次、喂多个消费者"的全部秘密，而且**你现在 `WLEncoder` 那套"编码一次 fan out 给 recorder + pusher"解决的是同一个问题，但切面更靠后**——OBS 是在**编码之前**就做扇出（一份合成帧 → N 个编码器，每个可有自己的分辨率/帧率），所以能支持"录 1080p60 + 推 720p30"。读完再决定要不要把扇出点从编码后前移。
3. **`deque.h` 和 `util_uint64.h` / `frame-rate.h` / `audio-math.h` 建议直接拿走**，都是自包含的小轮子，只需把 `bmalloc/bfree` 换成自己的分配器。`darray.h` 的 `DARRAY(type)` 宏也值得抄——比 `NSMutableArray` 装 `NSValue` 快一个数量级，且在 C 侧无 ARC 开销。
4. **`profiler.c` 建议只读设计不抄实现**（1117 行，直方图哈希表那部分复杂度不低）。先抄"thread-local 树 + 只在根节点合并 + 存直方图不存平均"这三条思路，用 `os_gettime_ns` 加几个 `deque` 就能做个 100 行的简化版。
5. **macOS 相关只需读两个文件**：`platform-cocoa.m`（530 行，全是能直接借用的 mach/Cocoa 调用——CPU 占用、内存占用、Rosetta 检测、`IOPMAssertion` 防休眠、CFString 转换）和 `platform-nix.c:62-95`（`os_dlopen` 对 dylib/framework/Python 的处理）。`platform-nix.c` 的其余部分和 `platform-windows.c`、`util/windows/` 整个目录可以跳过。
6. **可以完全跳过的**：`utf8.c`/`platform.c` 里的 mbs↔wcs 转换族（Windows 遗留需求，mac 上原生 UTF-8）、`cf-lexer.c`（1376 行，除非你也要自研 effect 语言）、`media-remux.c`（独立小工具）、`format-conversion.c`（你已经在 Metal 里做格式转换，CPU fallback 用不上）、`source-profiler.c`（强耦合 libobs 内部结构）。
7. **`serializer.h` 那套接口值得在写 muxer 前先看一眼**（158 行，10 分钟）。你现在 recorder/pusher 都直接用 FFmpeg 的 `AVIOContext`，等哪天要自己写 FLV 打包或者要"写盘走后台线程缓冲"，`buffered-file-serializer.c` 的结构就是现成答案。
