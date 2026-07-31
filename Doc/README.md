# WorkLabs 文档索引

本目录按**用途来源**分四大类。下面是导航；文末有「时间戳/同步」等**跨主题交叉索引**。

```
Doc/
├─ 调研/          对外部项目 / 实现的取经（IINA · mpv · OBS · TVUExternalSource）
├─ WorkLabs设计/  本项目架构 / 模块设计 / 代码审查
├─ 规划/          实施计划 / 任务清单 / 路线
├─ 基础知识/      音视频基础学习笔记（aac · h264 · 书籍 · 杂项 · 散篇）
└─ issues/        测试发现的问题 + 排查纪要（现象 · 根因假设 · 修法 · 复现条件）
```

---

## 📚 调研/ —— 对外部项目/实现的取经

### IINA/（基于 mpv 的 macOS 播放器）
- [IINA_Architecture_Report.md](调研/IINA/IINA_Architecture_Report.md) — 项目架构调研
- [IINA_Queue_and_Rendering_Report.md](调研/IINA/IINA_Queue_and_Rendering_Report.md) — 队列设计与渲染体系
- [IINA_Technical_Deep_Dive.md](调研/IINA/IINA_Technical_Deep_Dive.md) — 技术深度分析

### mpv/
- [MPV_调研与预览CPU优化报告.md](调研/mpv/MPV_调研与预览CPU优化报告.md) — 线程/队列/渲染调研 + WorkLabs 预览 CPU 优化全程（优化①停空转合成 ②渲染线程精确等待 ③删冗余 Metal 管线 ④抛弃 CoreImage 全面 Metal 化 Phase 0-2，含内存修复记录）
- [MPV_时间戳与队列设计调研.md](调研/mpv/MPV_时间戳与队列设计调研.md) — 时钟体系/音频主时钟/时间戳归一化/队列限流背压/唤醒深挖 + 分级取经清单（P0-P2）
- [MPV_时间戳源码深挖.md](调研/mpv/MPV_时间戳源码深挖.md) — **源码级**逐函数追时间戳完整生命周期：产生与归一化 / 异常处理 / A/V 同步时钟 / seek·暂停·启动对齐（行号实读核对 v0.41.0-718，比上一篇更细）
- [MPV时间戳_讨论纪要与功能规划.md](调研/mpv/MPV时间戳_讨论纪要与功能规划.md) — 上述调研的**应用层讨论纪要**：mpv 时间戳对 WorkLabs 的参考意义（含现状核实）/ 设计本质 / 面向 seek 拖进度条 + loop 循环 + 精确 A/V 同步的落地规划与待斟酌决策点

### OBS/
- **目录导航系列（obs-studio `f2db097`，2026-07-09 · 约 1900 源文件 49 万行的逐目录/逐文件功能地图）** ← *找代码从这里进*
  - [目录导航/README.md](调研/OBS/目录导航/README.md) — **总索引**：顶层目录地图 + 「我想看 X → 去哪」全局速查表 + OBS 五条主干读码路线 + libwl 对应关系
  - [01 libobs 内核](调研/OBS/目录导航/01_libobs核心.md) — 对象模型（源/场景/输出/编码器）+ 节拍主循环 + 音频混音 + 插件系统 + `obs-cocoa.m`
  - [02 libobs/graphics](调研/OBS/目录导航/02_libobs_graphics.md) — `gs_*` 图形抽象层 + `.effect` 着色器语言解析器 + 数学库
  - [03 libobs/util + media-io](调研/OBS/目录导航/03_libobs_util_media-io.md) — 基础设施轮子（含 🔧 可直接搬走标记）+ 帧总线 `video_output_*` + 重采样/格式转换
  - [04 编码 / 输出 / 服务](调研/OBS/目录导航/04_plugins_编码_输出_服务.md) — obs-ffmpeg（含独立 mux 子进程）· RTMP 推流与丢帧策略 · VideoToolbox 编码
  - [05 源 / 滤镜 / 转场](调研/OBS/目录导航/05_plugins_源_滤镜_转场.md) — 内置滤镜的标准形状 · 转场机制 · 图片源（同步源代表）
  - [06 平台采集](调研/OBS/目录导航/06_plugins_平台采集.md) — macOS 摄像头/屏幕/系统音频/虚拟摄像头（详）+ Windows/Linux（略）
  - [07 硬件 / 浏览器 / 远控 / 工具](调研/OBS/目录导航/07_plugins_硬件_浏览器_远控_工具.md) — DeckLink/AJA 采集卡 · CEF 浏览器源 · obs-websocket · frontend-tools
  - [08 frontend（Qt 界面）](调研/OBS/目录导航/08_frontend_Qt界面.md) — 主窗口 25 文件分片 · 预览控件如何对接 `obs_display` · 设置面板
  - [09 图形后端](调研/OBS/目录导航/09_图形后端_metal_opengl_d3d11.md) — Metal(Swift)/OpenGL/D3D11 三后端 + 抽象层绑定机制 + CVPixelBuffer→MTLTexture
  - [10 shared / deps / 构建 / 测试](调研/OBS/目录导航/10_shared_deps_构建_测试_文档.md) — **`shared/media-playback` 媒体播放内核**（pts 节流/seek/loop）+ 最小插件示例 + macOS 编译
- [OBS_UI_Analysis.md](调研/OBS/OBS_UI_Analysis.md) — OBS UI 面板分析
- OBS_Architecture.drawio / OBS_Architecture.png — OBS 架构图
- **源码级深挖系列（obs-studio 32.1.2，与 WorkLabs 逻辑几乎一致，比 mpv 更贴近）**：
  - [OBS_架构骨架与WorkLabs模块映射.md](调研/OBS/OBS_架构骨架与WorkLabs模块映射.md) — ① 核心数据结构 · 线程模型 · OBS↔WorkLabs 模块映射（系列入口）
  - [OBS_源异步帧缓冲与时间戳节流.md](调研/OBS/OBS_源异步帧缓冲与时间戳节流.md) — ② 源投帧进缓冲、video tick 按系统时钟选帧/丢过期帧（vs WorkLabs 各源绝对锚定节流）
  - [OBS_合成tick_音频混音_AV同步.md](调研/OBS/OBS_合成tick_音频混音_AV同步.md) — ③ 固定 fps 合成主循环 · 时间窗口混音 · 双管线共享系统时钟的 A/V 同步（vs mpv 视频追音频）
  - [OBS_输出侧_编码_复用_录制推流.md](调研/OBS/OBS_输出侧_编码_复用_录制推流.md) — ④ 编码 pts · interleave a/v 对齐（discard→归零→单调交错）· 录制/推流共用

### TVUExternalSource/（tvuanywhere_ios 直播管线调研，已重组为编号系列）
- [README.md](调研/TVUExternalSource/README.md) — **系列索引**：全链路 mermaid 一图流 + 文档清单（行号基线 `89e4c235a`，2026-06-12）
- 管线模块（按数据流向）：[01 外部源模块](调研/TVUExternalSource/01-外部源模块-TVUExternalSource.md) · [02 合流层 TVUAVStream](调研/TVUExternalSource/02-合流层-TVUAVStream.md) · [03 编码层 TVUEncoder](调研/TVUExternalSource/03-编码层-TVUEncoder.md) · [04 推流层 Mux与Transport](调研/TVUExternalSource/04-推流层-Mux与Transport.md) · [05 多源采集入队](调研/TVUExternalSource/05-多源采集入队.md) · [06 本地录制旁路](调研/TVUExternalSource/06-本地录制旁路.md)
- **时间戳专题/** — [01 PTS设计逻辑分析](调研/TVUExternalSource/时间戳专题/01-PTS设计逻辑分析.md) · [02 时间戳与时钟漂移调研](调研/TVUExternalSource/时间戳专题/02-时间戳与时钟漂移调研.md) · [03 时间戳设计评价](调研/TVUExternalSource/时间戳专题/03-时间戳设计评价.md) · [04 NTP时钟同步 TVUHostTimer](调研/TVUExternalSource/时间戳专题/04-NTP时钟同步-TVUHostTimer.md)
- **方案/** — [RTMP聚合转发-时间戳重算与PLL方案](调研/TVUExternalSource/方案/RTMP聚合转发-时间戳重算与PLL方案.md)

---

## 🛠 WorkLabs设计/ —— 本项目架构 / 模块 / 审查
- [WLMediaSource视频读取_漏洞与mpv对照.md](WorkLabs设计/WLMediaSource视频读取_漏洞与mpv对照.md) — FFmpeg 视频读取链路 8 类漏洞清单 + mpv 对照阅读
- [WLMediaSource_渲染节流改造与时间戳锚定陷阱.md](WorkLabs设计/WLMediaSource_渲染节流改造与时间戳锚定陷阱.md) — render 线程 usleep 轮询→（中途 condvar 等待）→ pop-then-sleep 分段睡眠，`WLNodeQueue` 回归纯 FIFO（节流移出队列）+ baseTime 单调纳秒 CAS 锚定；重点剖析 pts 微负/大正(seek) 的下溢陷阱与 int64 根治，以及 inf/NaN·巨值 deadline 导致 render 挂死的两道防线（isfinite + clamp）
- [WLVideoMix_合成tick改造_原理与实施计划.md](WorkLabs设计/WLVideoMix_合成tick改造_原理与实施计划.md) — **当前代码上的落地方案**：WLVideoMix 从 push（输入事件驱动）改 tick（固定节拍拉取）；含 fps 不一致的虚拟时钟选帧原理（OBS `ready_async_frame`）、生产/消费两层节流分工、阶段一/二/三实施路线、决策点与 CFR 兼容性。**阶段一/二已落地**（`141507f`/`2403c1e`/`977c086`），**§8 是落地后的代码逐段对照详解**（数据结构/tick 引擎/虚拟钟选帧/所有权/合成/线程模型/观测埋点 + 每处「为什么这么设计」）——对照代码斟酌看这节
- [OBS架构设计.md](WorkLabs设计/OBS架构设计.md) — WorkLabs OBS-Style 架构设计（WLScene/WLSceneRenderer 远期愿景）
- [可切源推流时间戳设计.md](WorkLabs设计/可切源推流时间戳设计.md) — 可切源推流的时间戳设计方案
- [视频源设置模块.md](WorkLabs设计/视频源设置模块.md) — 视频源设置模块设计
- [音频断流漂移_AV同步精度方案.md](WorkLabs设计/音频断流漂移_AV同步精度方案.md) — 隐患 B：音频断流后超前于视频的漂移；根因＝混音器无数据跳帧（样本计数 vs 墙钟·范式混杂）+ 首选修法（断流补静音帧）
- [AV同步_对齐OBS的剩余差距_晶振漂移与interleave.md](WorkLabs设计/AV同步_对齐OBS的剩余差距_晶振漂移与interleave.md) — 对齐 OBS 的剩余两块差距评估：晶振漂移补偿（真差距·低优先·建议先观测）+ 输出 interleave（实读后发现基本已覆盖，纠正先前判断）；附 OBS 音频时钟认知澄清
- streams.drawio — 流结构图

---

## 🗂 规划/ —— 实施计划 / 任务 / 路线
- **NewPlan/** — 多路流推流系统规划
  - [TaskNewPlan.md](规划/NewPlan/TaskNewPlan.md) — 实施计划（简化版，含版本 changelog）
  - [TaskPlanAndCriteria.md](规划/NewPlan/TaskPlanAndCriteria.md) — 实施计划与验收标准
  - Plan.d2 / domain.puml / images/ — 规划图与领域模型
- [TaskPlan.md](规划/TaskPlan.md) — 设计目标与任务
- [PanelTask.md](规划/PanelTask.md) — ControlPanel 重构计划
- [音频播放系统重构计划.md](规划/音频播放系统重构计划.md)
- [待实现清单.md](规划/待实现清单.md)
- [学习规划.md](规划/学习规划.md) — 音视频流媒体开发职业/学习规划
- 音视频规划.xmind — 规划脑图

---

## 📖 基础知识/ —— 音视频基础学习笔记
- **aac/** — [aac.md](基础知识/aac/aac.md) · 深入理解 AudioUnit（IO / Mixing）· [音频基础记录.md](基础知识/aac/音频基础记录.md) · images/
- **h264/** — [h264.md](基础知识/h264/h264.md) · [YUV.md](基础知识/h264/YUV.md) · [Gemini-YUV.md](基础知识/h264/Gemini-YUV.md) · images/
- **视频编码原理/** — [README（索引）](基础知识/视频编码原理/README.md) · [01 原文解读：七步构建玩具编码器](基础知识/视频编码原理/01-原文解读-七步构建玩具编码器.md) · [02 实现难度评估与避坑](基础知识/视频编码原理/02-实现难度评估与避坑.md) · [03 与WorkLabs管线对照](基础知识/视频编码原理/03-与WorkLabs管线对照.md) — 基于 skywind《视频编码原理简介》的专题
- **书籍/** — [音视频开发.md](基础知识/书籍/音视频开发.md)
- **杂项记录/** — [something.md](基础知识/杂项记录/something.md)（音视频技术资料整理）· [我的音视频技术路线_文章分析.md](基础知识/杂项记录/我的音视频技术路线_文章分析.md)（知乎文章定性分析：内容地图/为什么杂/对 WorkLabs 有用的三块）· images/
- 散篇笔记：
  - [AAC总结.md](基础知识/AAC总结.md) — AAC 音频编码完全指南
  - [滤镜特效Shader参考_LUT_美颜_转场_movit.md](基础知识/滤镜特效Shader参考_LUT_美颜_转场_movit.md) — **滤镜方向参考资料**：1D/3D LUT 采样 · 磨皮滤波器家族 · 转场双输入+progress 范式 · movit shader 链组装（单 pass）；每节附 Metal 落地注记
  - [<AudioStreamBasicDescription 结构体含义.md>](<基础知识/AudioStreamBasicDescription 结构体含义.md>)
  - [<SwrContext 使用.md>](<基础知识/SwrContext 使用.md>) — swr_init / swr_convert 用法
  - [TPCircularBuffer高性能环形缓冲区原理.md](基础知识/TPCircularBuffer高性能环形缓冲区原理.md)
  - [<reset 与 resampleFrameNULL 区别.md>](<基础知识/reset 与 resampleFrameNULL 区别.md>)
  - video.webp — 示例素材

---

## 🐞 issues/ —— 问题排查

- [someissues.md](issues/someissues.md) — 测试发现的现象清单（✅ 三条滤镜渲染现象已修复：`5d8ecd2` + `a75447c`）
- [滤镜渲染问题排查.md](issues/滤镜渲染问题排查.md) — 颜色校正/裁剪三条现象排查（✅ **已修复并实测通过**：实际根因＝10-bit HEVC 源被当 8-bit BGRA 绑定纹理；文中静态假设仅部分命中，保留回溯）
- [麦克风录制无声_修复记录.md](issues/麦克风录制无声_修复记录.md) — 「摄像头+麦克风」录制/推流无声的根因（`audioEnabled` 漏判麦克风）+ 修法（✅ **已实测通过**；隐患 B 断流音频漂移＝混音器断流补静音帧，亦已实测通过）

---

## 🕐 跨主题交叉索引：时间戳 / 音视频同步

时间戳/同步主题散落在多类文档，集中索引如下（也是当前重点改造方向）：

| 文档 | 角度 |
|---|---|
| [调研/mpv/MPV_时间戳与队列设计调研.md](调研/mpv/MPV_时间戳与队列设计调研.md) | mpv 取经：单调时钟 / 音频主时钟 / NOPTS 哨兵 / start_time 归一化 / 帧间隔 clamp（P0-P2 清单）|
| [调研/mpv/MPV_时间戳源码深挖.md](调研/mpv/MPV_时间戳源码深挖.md) | mpv 源码级深挖：时间戳产生归一化 / 异常 clamp / 音频主时钟实测 / seek·暂停清零重建（逐函数 + 行号核对）|
| [调研/mpv/MPV时间戳_讨论纪要与功能规划.md](调研/mpv/MPV时间戳_讨论纪要与功能规划.md) | 应用层：现状核实（P0 三件套已做 2/3、源内仍绝对锚定）+ seek/loop 落地规划（清零重建·hr-seek·对齐重起）+ 待斟酌决策点 |
| [调研/OBS/OBS_源异步帧缓冲与时间戳节流.md](调研/OBS/OBS_源异步帧缓冲与时间戳节流.md) | **OBS（合成器）时间戳范式**：源只投帧，video tick 按系统时钟选帧/丢过期帧（last_frame_ts 虚拟时钟）；±2s 跳变复位 |
| [调研/OBS/OBS_合成tick_音频混音_AV同步.md](调研/OBS/OBS_合成tick_音频混音_AV同步.md) | **OBS A/V 同步本质**：video/audio 两条线程各睡到 os_gettime_ns 绝对刻度、源入口 timing_adjust 归一，无反馈天然对齐（对比 mpv 视频追音频）|
| [调研/OBS/OBS_输出侧_编码_复用_录制推流.md](调研/OBS/OBS_输出侧_编码_复用_录制推流.md) | **OBS a/v 复用对齐**：编码 pts 拉回系统时钟域 → interleave 共同起点对齐 + 归零 + 单调交错（WorkLabs 加 AAC/RTMP 模板）|
| [WorkLabs设计/WLMediaSource视频读取_漏洞与mpv对照.md](WorkLabs设计/WLMediaSource视频读取_漏洞与mpv对照.md) | 本项目视频读取链路时间戳漏洞（§3 NOPTS / §7 start_time+clamp）|
| [WorkLabs设计/WLMediaSource_渲染节流改造与时间戳锚定陷阱.md](WorkLabs设计/WLMediaSource_渲染节流改造与时间戳锚定陷阱.md) | render 节流 pop-then-sleep（队列回归纯 FIFO）+ baseTime 单调纳秒锚定；pts 下溢陷阱（微负 / seek 大正）与 int64 根治 |
| [WorkLabs设计/WLVideoMix_合成tick改造_原理与实施计划.md](WorkLabs设计/WLVideoMix_合成tick改造_原理与实施计划.md) | **合成端**：push→tick 节拍化；fps 不一致的虚拟时钟选帧（慢源重复/快源抽帧/多源对齐同一系统钟）；生产层(源节流)vs 消费层(tick选帧)分工；阶段三 a/v 用 timing_adjust 归一同一钟 |
| [WorkLabs设计/可切源推流时间戳设计.md](WorkLabs设计/可切源推流时间戳设计.md) | 可切源推流时间戳设计方案 |
| [WorkLabs设计/音频断流漂移_AV同步精度方案.md](WorkLabs设计/音频断流漂移_AV同步精度方案.md) | **音频断流漂移（隐患 B）修复方案**：根因＝混音器无数据跳帧（音频样本计数 vs 视频墙钟·范式混杂）；首选修法＝混音器断流补静音帧（对齐 OBS「混音窗口始终处理、缺数据贡献 0」）|
| [WorkLabs设计/AV同步_对齐OBS的剩余差距_晶振漂移与interleave.md](WorkLabs设计/AV同步_对齐OBS的剩余差距_晶振漂移与interleave.md) | **对齐 OBS 剩余差距评估**：晶振漂移补偿（声卡晶振≠标称采样率）三家族——WorkLabs 被动吸收（看水位丢/补）vs OBS 时间戳对齐（看戳排+静音/丢弃）vs mpv ASRC 重采样（平滑变速）；真差距·低优先·建议先观测 + interleave（`av_interleaved_write_frame`+首包归零已覆盖三件套,基本非差距,纠正先前判断）+ OBS 音频时钟澄清（回调＝打戳时机,基准＝系统单调钟）|
| [调研/TVUExternalSource/时间戳专题](调研/TVUExternalSource/时间戳专题/01-PTS设计逻辑分析.md)（01 PTS设计 · [02 时钟漂移调研](调研/TVUExternalSource/时间戳专题/02-时间戳与时钟漂移调研.md) · [03 设计评价](调研/TVUExternalSource/时间戳专题/03-时间戳设计评价.md)） | TVUAnywhere PTS 设计 / 时钟漂移 / 同步设计评价 |
| [调研/TVUExternalSource/方案/RTMP聚合转发-时间戳重算与PLL方案.md](调研/TVUExternalSource/方案/RTMP聚合转发-时间戳重算与PLL方案.md) | RTMP 聚合转发：时间戳重算与音视频同步 |
