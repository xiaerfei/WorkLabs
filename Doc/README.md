# WorkLabs 文档索引

本目录按**用途来源**分四大类。下面是导航；文末有「时间戳/同步」等**跨主题交叉索引**。

```
Doc/
├─ 调研/          对外部项目 / 实现的取经（IINA · mpv · OBS · TVUExternalSource）
├─ WorkLabs设计/  本项目架构 / 模块设计 / 代码审查
├─ 规划/          实施计划 / 任务清单 / 路线
└─ 基础知识/      音视频基础学习笔记（aac · h264 · 书籍 · 杂项 · 散篇）
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

### OBS/
- [OBS_UI_Analysis.md](调研/OBS/OBS_UI_Analysis.md) — OBS UI 面板分析
- OBS_Architecture.drawio / OBS_Architecture.png — OBS 架构图

### TVUExternalSource/
- [TVUExternalSource模块分析.md](调研/TVUExternalSource/TVUExternalSource模块分析.md) — 外部源模块详细分析
- [TVUExternalSource时间戳调研.md](调研/TVUExternalSource/TVUExternalSource时间戳调研.md) — 时间戳与时钟漂移调研
- [TVUExternalSource时间戳设计评价.md](调研/TVUExternalSource/TVUExternalSource时间戳设计评价.md) — 时间戳/时钟同步设计评价
- [plan.md](调研/TVUExternalSource/plan.md) — TVUAnywhere iOS PTS 时间戳设计逻辑分析
- [分析.md](调研/TVUExternalSource/分析.md) — RTMP 聚合转发：时间戳重算与音视频同步

---

## 🛠 WorkLabs设计/ —— 本项目架构 / 模块 / 审查
- [WLMediaSource视频读取_漏洞与mpv对照.md](WorkLabs设计/WLMediaSource视频读取_漏洞与mpv对照.md) — FFmpeg 视频读取链路 8 类漏洞清单 + mpv 对照阅读
- [OBS架构设计.md](WorkLabs设计/OBS架构设计.md) — WorkLabs OBS-Style 架构设计
- [可切源推流时间戳设计.md](WorkLabs设计/可切源推流时间戳设计.md) — 可切源推流的时间戳设计方案
- [视频源设置模块.md](WorkLabs设计/视频源设置模块.md) — 视频源设置模块设计
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
- **书籍/** — [音视频开发.md](基础知识/书籍/音视频开发.md)
- **杂项记录/** — [something.md](基础知识/杂项记录/something.md)（音视频技术资料整理）· images/
- 散篇笔记：
  - [AAC总结.md](基础知识/AAC总结.md) — AAC 音频编码完全指南
  - [<AudioStreamBasicDescription 结构体含义.md>](<基础知识/AudioStreamBasicDescription 结构体含义.md>)
  - [<SwrContext 使用.md>](<基础知识/SwrContext 使用.md>) — swr_init / swr_convert 用法
  - [TPCircularBuffer高性能环形缓冲区原理.md](基础知识/TPCircularBuffer高性能环形缓冲区原理.md)
  - [<reset 与 resampleFrameNULL 区别.md>](<基础知识/reset 与 resampleFrameNULL 区别.md>)
  - video.webp — 示例素材

---

## 🕐 跨主题交叉索引：时间戳 / 音视频同步

时间戳/同步主题散落在多类文档，集中索引如下（也是当前重点改造方向）：

| 文档 | 角度 |
|---|---|
| [调研/mpv/MPV_时间戳与队列设计调研.md](调研/mpv/MPV_时间戳与队列设计调研.md) | mpv 取经：单调时钟 / 音频主时钟 / NOPTS 哨兵 / start_time 归一化 / 帧间隔 clamp（P0-P2 清单）|
| [WorkLabs设计/WLMediaSource视频读取_漏洞与mpv对照.md](WorkLabs设计/WLMediaSource视频读取_漏洞与mpv对照.md) | 本项目视频读取链路时间戳漏洞（§3 NOPTS / §7 start_time+clamp）|
| [WorkLabs设计/可切源推流时间戳设计.md](WorkLabs设计/可切源推流时间戳设计.md) | 可切源推流时间戳设计方案 |
| [调研/TVUExternalSource/时间戳调研](调研/TVUExternalSource/TVUExternalSource时间戳调研.md) · [设计评价](调研/TVUExternalSource/TVUExternalSource时间戳设计评价.md) | TVU 时钟漂移 / 同步设计评价 |
| [调研/TVUExternalSource/plan.md](调研/TVUExternalSource/plan.md) · [分析.md](调研/TVUExternalSource/分析.md) | TVUAnywhere PTS 设计 / RTMP 聚合转发同步 |
