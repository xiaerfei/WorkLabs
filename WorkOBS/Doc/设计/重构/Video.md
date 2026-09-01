# WLSource 协议化重构设计

> 日期：2026-08-23
> 基线：commit c306166（dev 分支）
> 目标：对齐 OBS 三元结构（壳 + 协议 + 实现），用 C++ 纯虚基类替代 ObjC 语境下的 @protocol

---

## 1. 问题

当前 `WLSource` 是抽象基类，同时承担两个角色：

- **接口约定**（纯虚函数 Start/Stop/Pause/...）
- **共享实现**（async_frames 环形缓冲 + 挑帧）

`WLMediaSource` 继承它，既是"遵守协议"又是"复用缓冲"。这导致：

1. **协议不纯**——基类有数据成员，不是纯接口
2. **脆弱基类**——改 WLSource 的缓冲实现可能意外影响子类
3. **同步源白背缓冲**——M3 同步源（图片/屏幕）不需要 async 缓冲，但继承后被迫持有

## 2. OBS 三元结构回顾

```
obs_source_t（壳，libobs 核心）
 ├─ info          obs_source_info 按值拷贝：回调函数表 = protocol
 └─ context.data  插件私有对象（void*）；create(settings, source) 双参，
                  插件用 obs_source_output_video(source, frame) 回喂帧
```

核心思想：**壳持有共享状态（缓冲、挑帧），协议只声明接口，实现体只管产帧**。

## 3. 目标设计

### 3.1 三元拆分

```
WLSource（壳）                    WLSourceProtocol（纯协议）
├─ info（wl_source_type_info）    ├─ virtual ~WLSourceProtocol() {}
├─ async_frames 环形缓冲          ├─ virtual int  Start() = 0
├─ GetFrame() 挑帧                ├─ virtual void Stop()  = 0
├─ OutputVideo() 帧入口           ├─ Pause/Seek/Update    默认空
├─ backend* → 协议实现体           ├─ GetDuration → -1
└─ 控制透传 Start/Stop/...        └─ GetWidth/GetHeight → 0
```

| OBS | WorkOBS |
|-----|---------|
| `obs_source_t`（壳） | `WLSource`（非多态、不被继承） |
| `obs_source_info` 回调 | `WLSourceProtocol`（纯虚基类 = C++ 的 @protocol） |
| `context.data`（void*） | 协议实现类的 `this`（WLMediaSource） |
| `create(settings, source)` | 双参工厂：壳先建，再把壳给实现体 |
| `obs_source_output_video` | `source->output_video(pb, pts)`（壳的 public 方法） |

### 3.2 WLSourceProtocol（纯协议）

```cpp
class WLSourceProtocol {
public:
    virtual ~WLSourceProtocol() {}                    // 必须有：壳 delete backend 需要

    // ── 必选（= 0）──
    virtual int  Start() = 0;                         // 返回 0 成功
    virtual void Stop()  = 0;                         // 幂等

    // ── 可选（默认空 = @optional）──
    virtual void Pause(bool paused) {}
    virtual void Seek(int64_t seek_ts_us) {}
    virtual void Update(const char *settings) {}

    // ── 信息查询（默认值 = 不支持）──
    virtual int64_t GetDuration() { return -1; }
    virtual int     GetWidth()    { return 0; }
    virtual int     GetHeight()   { return 0; }

    // ── 同步源绘制（M3 占位）──
    virtual void VideoRender() {}
};
```

### 3.3 WLSource（壳）

```cpp
class WLSource {
    // ── 实例标识（类型 ID + 实例 UUID）──
    wl_source_type_info  info_;           // 按值拷贝（ctor 时从参数拷入）
    uint32_t             uuid_;           // 全局递增计数器（线程安全原子自增）

    WLSourceProtocol    *backend_;        // 协议实现体指针

    // ── async_frames 缓冲（ASYNC 位条件分配）──
    wl_async_frame      *frames_;
    int                  capacity_;       // ASYNC 位无 → 0，不分配
    int                  head_, count_;
    pthread_mutex_t      async_mutex_;

    // ── 挑帧状态 ──
    bool                 consume_anchored_;
    int64_t              consume_first_pts_, consume_first_sys_;
    CVPixelBufferRef     cur_frame_;
    int64_t              cur_frame_pts_;

    static uint32_t next_uuid_;             // 全局递增（atomic_fetch_add）

public:
    // ctor：info 按值拷入 + 分配实例 ID + 按 ASYNC 位决定是否分配缓冲
    WLSource(const wl_source_type_info *info);
    ~WLSource();                          // 非虚！第一行 delete backend_

    // ── 帧入口（生产端：实现体在自己的线程调用）──
    void OutputVideo(CVPixelBufferRef pixbuf, int64_t pts_ns);

    // ── 帧消费（tick 调用）──
    CVPixelBufferRef GetFrame(int64_t sys_time_ns, int64_t *out_pts_ns);

    // ── 控制透传（带 backend NULL 防御）──
    int  Start()    { return backend_ ? backend_->Start()    : -1; }
    void Stop()     {        if (backend_) backend_->Stop();       }
    void Pause(bool p)       { if (backend_) backend_->Pause(p);  }
    void Seek(int64_t ts)    { if (backend_) backend_->Seek(ts);  }
    void Update(const char *s) { if (backend_) backend_->Update(s); }

    // ── 信息透传 ──
    int64_t GetDuration() { return backend_ ? backend_->GetDuration() : -1; }
    int     GetWidth()    { return backend_ ? backend_->GetWidth()    : 0; }
    int     GetHeight()   { return backend_ ? backend_->GetHeight()   : 0; }

    // ── info 访问 ──
    const wl_source_type_info &Info() const { return info_; }
    uint32_t UUID() const { return uuid_; }     // 实例 UUID（同类型多实例靠此区分）
};
```

### 3.4 WLMediaSource（协议实现体）

```cpp
class WLMediaSource : public WLSourceProtocol {
    WLSource   *source_;        // 反向引用壳（用于回喂帧）
    char       *path_;
    WLDecoder  *decoder_;
    pthread_t   thread_;
    bool        thread_running_;
    atomic_bool should_stop_;
    // ... 其余成员同当前

public:
    // 三参 ctor：settings + hw_type + 壳指针
    WLMediaSource(const char *path, const char *hw_type, WLSource *source);
    ~WLMediaSource();

    // ── WLSourceProtocol 实现 ──
    int  Start() override;
    void Stop()  override;
    void Pause(bool paused) override;
    void Seek(int64_t seek_ts_us) override;
};
```

关键改动：**产帧点从 `OutputVideo(pb, pts)` 改为 `source_->OutputVideo(pb, pts)`**。

### 3.5 wl_source_type_info 工厂签名

```cpp
// 旧：单参
WLSource *(*create)(const char *settings);

// 新：双参（对齐 OBS create(settings, source)）
WLSourceProtocol *(*create)(const char *settings, WLSource *source);
```

## 4. 关键流程

### 4.1 源创建流程

```
WLCore::AddSource("media_file", "/path/to/video.mp4")
  │
  ├─ 1. registry 查找 → 得到 wl_source_type_info *info
  │
  ├─ 2. new WLSource(info)         ← 壳先建
  │     ├─ uuid_ = atomic_fetch_add(&next_uuid_, 1) ← 分配实例 UUID
  │     ├─ info_ = *info                              ← 拷入类型信息
  │     └─ capacity_ = (flags & ASYNC) ? 30 : 0   ← 按 ASYNC 位分配缓冲
  │
  ├─ 3. info->create(settings, src) ← 双参工厂：壳给实现体
  │     └─ new WLMediaSource(path, hw, src)
  │         └─ this->source_ = src  ← 反向引用
  │
  ├─ 4. src->SetBackend(backend)   ← 绑定后入表
  │
  └─ 5. return src                  ← 调用方拿到壳指针
```

### 4.2 帧生产流程（解码线程）

```
WLMediaSource::ThreadLoop()（解码线程）
  │
  ├─ decoder_->ReceiveVideo(&vframe, &vpts)
  │
  ├─ PaceVideo(vpts)                ← pts 节流
  │
  └─ source_->OutputVideo(pb, vpts) ← 通过反向引用调壳的方法
       │
       └─ WLSource::OutputVideo()
            ├─ retain pb
            ├─ lock async_mutex_
            ├─ 写入 frames_[head_]  ← 环形缓冲
            └─ unlock
```

### 4.3 帧消费流程（tick 线程）

```
WLGraphics tick（合成线程）
  │
  └─ src->GetFrame(sys_time_ns, &pts)
       │
       ├─ lock async_mutex_
       ├─ 按系统时钟挑帧（追赶式跳过过期帧）
       ├─ retain cur_frame_（出锁后其他消费者动不了）
       └─ return owned CVPixelBufferRef
```

### 4.4 销毁流程（⚠️ 最危险）

```
WLCore::RemoveSource(src) / Shutdown()
  │
  └─ delete src                    ← 调壳的析构函数
       │
       ├─ WLSource::~WLSource()
       │    ├─ delete backend_     ← 第一行！触发虚析构链
       │    │    └─ WLMediaSource::~WLMediaSource()
       │    │         └─ Stop()    ← join 解码线程（生产者死透）
       │    │         └─ delete decoder_, free(path_), ...
       │    │
       │    ├─ 清 frames_ 缓冲     ← 生产者已死，无并发
       │    └─ destroy mutex
       │
       └─ （壳内存释放）
```

**⚠️ 坑：`delete backend_` 必须是析构函数第一行。**
写反（先清缓冲再 delete backend）= 生产线程还在写已释放缓冲 = 崩溃。

### 4.5 生命周期关系

```
时间轴 ──────────────────────────────────────────────────►

WLSource（壳）:    |████████████████████████████████████████|
                    创建                                销毁

WLSourceProtocol:      |████████████████████████████████|
 (backend)            set_backend                  delete backend_
                                                  (壳 dtor 第一行)

解码线程:              |████████████████████████████|
                       Start()                    Stop()
                                                  (backend dtor 内 join)

缓冲 frames_:       |████████████████████████████████████|
                    分配                          清释放
                    (壳 ctor)                    (壳 dtor，backend 删除之后)
```

规则：**壳 always 比实现体活得长**（先创建、后销毁）。

## 5. 文件改动清单

| 文件 | 动作 | 说明 |
|------|------|------|
| `source/WLSourceProtocol.hpp` | **新建** | 纯协议，无 .cpp |
| `source/WLSource.hpp` | **重写** | 删 virtual，加 backend + 透传 |
| `source/WLSource.cpp` | **重写** | ctor 收 info 参数 + ASYNC 位条件分配；dtor 第一行 delete backend |
| `source/WLMediaSource.hpp` | 改 | `: public WLSourceProtocol`，加 `WLSource *source_` 成员 |
| `source/WLMediaSource.cpp` | 改 | ctor 三参，产帧点改 `source_->OutputVideo()` |
| `core/WLCore.cpp` | 改 | AddSource 走双参创建流程 |

**零改动**：WLGraphics、WLSourceRegistry、ViewController（已 grep 验证）。

## 6. 待确认项

- [x] **壳的 `OutputVideo` 改 public** — 暂时 public，后续再收紧。
- [x] **`GetWidth`/`GetHeight` 在实现体中实现** — 先透传 backend，由各实现体（如 WLMediaSource）自行管理尺寸。
- [x] **info.create 签名改动** — WLSourceRegistry 只存指针，不调 create，零改动。改动范围：WLSource.hpp（typedef）+ WLCore.cpp（调用处）+ WLMediaSource.cpp（工厂实现）。
