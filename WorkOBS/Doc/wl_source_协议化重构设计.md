# WLSource 协议化重构：壳 + Protocol 组合（对齐 OBS 三元结构）

> 日期：2026-07-16 ｜ 状态：设计定稿，**用户亲自实施**（本次角色反转：Claude 出计划，用户写代码）
> 前篇：《源注册机制设计》（C 版 vtable）→ 81e8e94（C++ 继承版）→ 3e03321（info 元数据对齐）→ 本篇
> 基线：OBS 源码 commit `f2db097`（本地 `~/Documents/github/obs-studio`）

---

## 1. 背景与动机

C++ 化时（81e8e94）我们把 OBS 手写 vtable 翻译成了**继承式**：`WLSource` 抽象基类同时承载「接口约定」和「async_frames 缓冲实现」，`WLMediaSource` 继承它。几轮虚函数机制讨论后确认真正的不适感来源：**不是虚函数机制，而是"继承一个带实现的基类"**（fragile base class）。

诉求明确为：**`obs_source_info` 的回调面 = 一个纯 protocol**（ObjC `@protocol` 语感——零数据成员、零实现代码，实现方只表达"遵守协议"）。

关键事实（回看 OBS 才发现）：**OBS 手写的多态本来就是非侵入的**。`obs_source_t` 持有 `info`（函数表）+ `context.data`（插件私有对象 void*），数据与表分离、由壳打包——这正是胖指针（fat pointer）形状，microsoft/proxy、Rust `dyn`、Go interface 同族。我们当初翻译成侵入式继承，反而偏离了原型。

## 2. OBS 的三元结构（本次对齐目标）

```
obs_source_t（壳，libobs 核心）          ← async_frames 缓冲、挑帧、filter 链全在这
 ├─ info          obs_source_info 按值拷贝（obs-source.c:450）：回调面 = protocol
 └─ context.data  插件私有对象；create(settings, source) 双参把壳给插件，
                  插件线程用 obs_source_output_video(source, frame) 回喂
```

要点：**缓冲和挑帧不属于 info，属于壳**——插件只实现回调协议。这就是为什么 OBS 的 create 是双参。

## 3. 方案对比与裁决

| | 方案 A：壳 + 协议组合（**已选定**） | 方案 B：继承分层 |
|---|---|---|
| 形状 | `WLSource` 壳（非多态）+ `WLSourceProtocol` 纯协议 | `IWLSource` ← `WLAsyncSource` ← 具体源 |
| 与 OBS 对应 | 三元结构一一对应 | OBS 没有"AsyncSource 中间类"角色 |
| protocol 纯净度 | 完全纯净 | `info` 成员在纯接口里没有干净去处 |
| 同步源背缓冲 | 壳按 ASYNC 位条件分配，天然不背 | 仍需另行处理 |
| 手术大小 | 大（但当前代码量小，此刻最便宜） | 小 |

选 A 的三个理由：①读 OBS 源码时结构直接映射，学习回报最高；②protocol 洁癖完全满足；③顺手消掉"同步源白背 30 槽缓冲"的 M3 欠账。

## 4. 目标形状

```
OBS                        WorkOBS
obs_source_t（壳）    →    WLSource        非多态、无虚函数、不被继承
obs_source_info 回调  →    WLSourceProtocol 纯协议（虚析构 + 纯虚/默认空实现）
context.data          →    协议实现类的 this（WLMediaSource）
create(settings,src)  →    create 双参工厂：把壳给实现体，供回喂帧
obs_source_output_video →  source->output_video(pb, pts)（壳的 public 方法）
```

```
WLSource（壳）                             WLSourceProtocol（纯协议）
 ├─ info（wl_source_type_info 按值拷贝）     ├─ virtual ~WLSourceProtocol() {}
 ├─ async_frames 环形缓冲（ASYNC 位条件分配） ├─ virtual int  start() = 0
 ├─ get_frame() 挑帧（消费端，tick 调）      ├─ virtual void stop()  = 0
 ├─ output_video()（生产端，backend 线程调）  ├─ pause/seek/update    默认空 = @optional
 ├─ 控制透传 start/stop/pause/seek/update…  ├─ get_duration→-1  get_width/height→0
 └─ backend* ────────────────────────────► └─ video_render() {}   同步源 M3 覆写
```

对照 ObjC：必选方法 = 纯虚；`@optional` = 默认空实现；`respondsToSelector:` 在 C++ 无对应物——"支持与否"由 `info.output_flags` 声明（这正是 ASYNC 位是分流唯一依据的原因）。

## 5. 文件改动清单

| 文件 | 动作 | 内容 |
|---|---|---|
| `libwl/src/source/WLSourceProtocol.hpp` | **新建** | 纯协议，无 .cpp（类内定义默认实现，隐式 inline；"一个头 = 一个协议"） |
| `libwl/src/source/WLSource.hpp/.cpp` | **重写为壳** | 删全部 virtual；加 backend 组合 + 透传；ctor 收 info 参数 |
| `libwl/src/source/WLMediaSource.hpp/.cpp` | 改 | 继承 `WLSourceProtocol`；存 `WLSource *source` 反向引用；ctor 三参 |
| `libwl/src/core/WLCore.cpp` | 改 add_source | OBS 双参创建流程 |
| `WLGraphics.cpp` / `ViewController.mm` / `WLSourceRegistry.*` | **零改动** | 已 grep 验证（见 §6 步骤④后注） |

## 6. 施工步骤 + 坑清单

**① 新建 `WLSourceProtocol.hpp`**（建完先跑 xcodegen，见⑤）

内容：虚析构 `{}` ＋ 纯虚 `start()/stop()` ＋ 默认空 `pause(bool)/seek(int64_t)/update(const char*)` ＋ `get_duration()→-1`、`get_width()/get_height()→0` ＋ `video_render(){}`。

- ⚠️ **坑 1：虚析构不能省**——壳拿 `WLSourceProtocol*` delete，没它子类 dtor 不跑（线程不 join、decoder 泄漏）。

**② `WLSource` 壳化**

- 删：所有 `virtual`、所有控制/查询虚函数。
- 留：`wl_async_frame`、枚举/flags 宏/`wl_source_type_info`、`info` 成员、缓冲成员、`get_frame`；`output_video` 改 **public**（backend 要调）。
- 加：`WLSourceProtocol *backend` ＋ `set_backend()`；ctor 改 `WLSource(const wl_source_type_info *type_info)`——内部 `info = *type_info`（从 add_source 挪进来）＋ **按 ASYNC 位条件分配缓冲**（同步源 frames=NULL/capacity=0，现有 `capacity==0` 短路是现成防御）；控制透传一行转发，**带 `backend ? … : 默认值` 防御**。
- `wl_source_type_info.create` 改双参：`WLSourceProtocol *(*create)(const char *settings, WLSource *source);`
- ⚠️ **坑 2（最大）：dtor 顺序**。壳 dtor 第一行 `delete backend`（→ 协议虚析构 → 子类 dtor join 生产线程），**之后**才清缓冲、销毁锁。原先此顺序由 C++ 析构链（子类先、基类后）隐式保证，现在是手写的显式两行——写反 = 生产线程写已释放缓冲。
- ⚠️ **坑 3：壳保持非多态**。dtor 不加 virtual 是刻意的（没人继承它）。
- ⚠️ **坑 4：头文件依赖**。`WLSource.hpp` 只前置声明 `class WLSourceProtocol;`（存指针够用，透传实现放 .cpp）；`WLSource.cpp` 再 include 协议头。`WLMediaSource.hpp` include 协议头（继承需完整定义）＋前置声明 `class WLSource;`；`WLMediaSource.cpp` include `WLSource.hpp`（解引用调 output_video）。

**③ `WLMediaSource` 改协议实现体**

- hpp：include 换 `WLSourceProtocol.hpp`；`: public WLSourceProtocol`；成员加 `WLSource *source;`；ctor 加第三参。
- cpp：ctor 里 `this->source = source;`（new 不清零，别漏）；**:164 唯一喂帧点** `output_video(pb, vpts)` → `source->output_video(pb, vpts)`；:63 注释「WLSource 虚接口」改「WLSourceProtocol 协议」；工厂改双参；`g_media_source_info` 其余字段不动。

**④ `WLCore::add_source` 走 OBS 流程**

```cpp
WLSource *src = new WLSource(info);                      // 壳先建：拷 info + 备好缓冲
WLSourceProtocol *backend = info->create(settings, src); // 把壳给实现体
if (!backend) { delete src; return NULL; }
src->set_backend(backend);                               // 绑定后入表
```

删掉原 `src->info = *info;` 行（挪进壳 ctor）。

> 零改动验证（grep 依据）：`WLGraphics` 只用 `src->info.output_flags` + `src->get_frame()`（都留在壳上）；`ViewController.mm` 只调 `_source->start()`（壳透传，:50）；`WLSourceRegistry` 只碰 `wl_source_type_info*` 指针。

**⑤ 构建**

```bash
cd /Users/tvum4pro/Documents/github/WorkLabs/WorkOBS/OBSLabs   # ⚠️ 坑 5：必须先 cd 到这
xcodegen generate && LANG=en_US.UTF-8 pod install               # 新增文件才需要
xcodebuild -workspace OBSLabs.xcworkspace -scheme OBSLabs -configuration Debug build
```

在仓库根目录跑 xcodegen 会误生成外层 WorkLabs 工程（已踩两次）。

## 7. 验收标准

1. 编译过。
2. 跑 app 选 60fps 视频：`[get]` 日志与重构前**完全一致**（advanced=2、show 匀速 +33ms、结尾 depth→0 重复上一帧）——本次只动骨架不动算法，行为变化 = 接错。
3. 关窗退出干净不崩——专门验证坑 2 析构链：壳 dtor → delete backend → join 解码线程 → 清缓冲。
4. `[get]`/`[src A]` 临时日志保留（整体运行验证仍欠账）。

## 8. 与后续里程碑的衔接

- **M3 同步源**（图片/屏幕采集）：实现 `WLSourceProtocol`、覆写 `video_render()/get_width()/get_height()`，flags 不带 ASYNC 位 → 壳不给它分配缓冲，render 阶段分流直接调协议（分流形状抄 OBS `render_video`，obs-source.c:2906）。
- **M4 音频**：壳增设音频缓冲 + `output_audio()`（对齐 `obs_source_output_audio`），协议不动——壳/协议分工在音频上复用。
- OBS 对异步源的 `get_width` 返回壳记录的 `async_width`（喂帧时更新）而非问插件；我们暂时透传 backend，M3 需要布局尺寸时再对齐。
