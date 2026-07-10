# OBS 采集源技术方案：摄像头 / 屏幕采集 / 静态图片

> 目的：为 WorkOBS 后续要加的三类「非媒体文件」源做技术预研——摄像头（`WLCameraSource`）、屏幕采集、静态图片。
> 讲清 OBS 各自用什么系统框架、数据怎么流、落到 libobs 哪条路径，必要处给伪代码。
> 已有的 media_file 源见《OBS_媒体源线程模型》，平台框架总览见《OBS_macOS平台代码全景》——本文是那一节的**深入版**。

---

## 0. 先建立钥匙：OBS 的两类视频源（同步 vs 异步）

这三类源怎么实现，**先分类再看细节**才不会乱。OBS 用源注册时的 `output_flags` 把视频源劈成两半（`libobs/obs-source.h`）：

```c
#define OBS_SOURCE_VIDEO        (1 << 0)   // 产出视频
#define OBS_SOURCE_ASYNC        (1 << 4)   // 异步交付
#define OBS_SOURCE_ASYNC_VIDEO  (OBS_SOURCE_ASYNC | OBS_SOURCE_VIDEO)
```

| | **异步源** `OBS_SOURCE_ASYNC_VIDEO` | **同步源** `OBS_SOURCE_VIDEO` |
|---|---|---|
| 帧怎么来 | 数据自己到达（另一个线程/回调），**带 PTS** | 合成 tick 主动来问「现在给我一帧」 |
| 源要实现什么 | 在自己线程调 `obs_source_output_video(frame)` | 实现 `video_render(effect)` 回调，当场画 |
| 谁管时间 | libobs：帧进 async_frames 队列，按 PTS 挑帧显示 | 无 PTS 概念，tick 到就画当前状态 |
| 有无缓冲 | 有（async_frames 环形缓冲，吸收抖动） | 无（画的就是"此刻"） |
| 典型 | **摄像头、媒体文件、网络流、NDI** | **图片、颜色块、文字、（部分）屏幕采集** |

**一句话记忆**：异步源是"**推**"（push，源往队列里塞带时间戳的帧，libobs 按时间放），同步源是"**拉**"（pull，合成 tick 每帧回来拉一次当前画面）。

这把钥匙直接决定三类源在 WorkOBS 里怎么落：

- **摄像头** → 异步源 → 天然复用现有的 `WLSource::output_video` + async_frames + `get_frame` 挑帧路径，**几乎零新增基础设施**。
- **图片** → 同步源 → 现有 `WLSource` 只有异步路径，需要**新增一条同步 render 通道**。
- **屏幕采集** → 数据到达是异步回调，但语义上是"当前屏幕"→ 可当异步源走缓冲（简单、复用现成），也可当同步源直接绑纹理（低延迟、省一次拷贝）——**是本文最需要权衡的一个**。

---

## 1. 摄像头采集（异步源）：`mac-avcapture`

### 1.1 框架与对象

macOS 上走 **AVFoundation** 的 `AVCaptureSession` 管线（对应插件 `plugins/mac-avcapture/`）：

```
AVCaptureDevice（摄像头设备）
   │ 包成 input
AVCaptureDeviceInput ──┐
                       ├──► AVCaptureSession（会话，串起输入输出）
AVCaptureVideoDataOutput ──┘
   │ 每帧回调（在专用 dispatch queue 上）
captureOutput:didOutputSampleBuffer:  ──►  CMSampleBuffer
```

### 1.2 数据流与伪代码

初始化（会话装配）与《macOS 平台全景》§2.1 一致，这里补**帧交付**这段关键路径——它就是"异步源如何往队列塞帧"的范本：

```objc
// AVFoundation 在采集队列上每帧回调一次
- (void)captureOutput:(AVCaptureOutput *)out
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)conn
{
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sampleBuffer);   // = CVPixelBuffer

    // CMTime → 纳秒。这就是进 async_frames 的 PTS。
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    uint64_t ts_ns = (uint64_t)(CMTimeGetSeconds(pts) * 1e9);

    struct obs_source_frame frame = {0};
    // 从 CVImageBuffer 填 data/linesize/width/height
    // 映射像素格式（如 420YpCbCr8BiPlanar → VIDEO_FORMAT_NV12）
    // 判定色彩空间/范围（BT.601/709、full/video range）
    frame.timestamp = ts_ns;

    obs_source_output_video(source, &frame);   // ← 入源的异步帧队列，libobs 按 PTS 挑帧
}
```

### 1.3 映射到 WorkOBS

**这是三类里最省事的**：WorkOBS 的 `WLSource` 基类已经有 `output_video(CVPixelBufferRef, pts_ns)` + async_frames + `get_frame` 追赶挑帧的完整异步路径（`WLMediaSource` 正在用）。摄像头源只需：

```cpp
class WLCameraSource : public WLSource {
    // 持有 AVCaptureSession（用一个 OC 对象桥接，.mm 编译）
    // delegate 回调里：
    //   CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    //   int64_t pts = CMSampleBufferGetPresentationTimeStamp → ns;
    //   output_video(pb, pts);   // ← 直接调基类，复用全部缓冲/挑帧逻辑
    int  start() override;   // [session startRunning]
    void stop()  override;   // [session stopRunning]
};
```

⚠️ **一个时间戳的坑**（WorkLabs 主项目踩过，见规划 changelog v0.14）：摄像头 PTS 来自系统时钟（`mach_absolute_time` 系），**不从 0 起**；媒体文件 PTS 从 0 起。两类源混入同一合成/录制时间轴时会时长爆炸。WorkOBS 里合成端已统一用 `WLTime`（`CLOCK_MONOTONIC`）作墙钟，摄像头 PTS 需换算到同一把尺；这条到接摄像头时要专门验证。

---

## 2. 屏幕采集：`mac-capture`（ScreenCaptureKit）

### 2.1 框架演进

```
旧：CGDisplayStream（Core Graphics）  ── macOS 10.8+，回调给 IOSurface；已被弃用趋势
新：ScreenCaptureKit（SCStream）      ── macOS 12.3+，Apple 主推，OBS 新版优先
```

OBS 现版本（`plugins/mac-capture/mac-screen-capture.m`）主用 **ScreenCaptureKit**，支持三种粒度：整显示器 / 单窗口 / 单应用。

### 2.2 三个核心对象 + 数据流

```
SCShareableContent      枚举「可采集的东西」（displays / windows / applications）
   │ 选一个目标，构造过滤器
SCContentFilter         「采什么」（哪个显示器/窗口/应用，排除哪些窗口）
SCStreamConfiguration   「怎么采」（分辨率、像素格式、帧率上限、是否含光标、queueDepth）
   │
SCStream（filter + config + delegate）
   │ 每帧回调（异步）
stream:didOutputSampleBuffer:ofType:  ──►  CMSampleBuffer → IOSurface
```

### 2.3 伪代码

```objc
// 1. 枚举可采集内容（异步）
[SCShareableContent getShareableContentWithCompletionHandler:
    ^(SCShareableContent *content, NSError *err) {
        SCDisplay *display = content.displays.firstObject;

        // 2. 过滤器：采这个显示器（可排除自己的窗口，防"镜中镜"无限反馈）
        SCContentFilter *filter =
            [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];

        // 3. 配置
        SCStreamConfiguration *conf = [[SCStreamConfiguration alloc] init];
        conf.width       = display.width;
        conf.height      = display.height;
        conf.pixelFormat = 'BGRA';                 // 或 'l10r' 走 HDR
        conf.showsCursor = YES;
        conf.queueDepth  = 8;                      // 内部帧队列深度
        conf.minimumFrameInterval = CMTimeMake(1, 60);  // 帧率上限 60fps

        // 4. 建流 + 加输出 + 启动
        SCStream *stream = [[SCStream alloc] initWithFilter:filter
                                              configuration:conf delegate:self];
        [stream addStreamOutput:self type:SCStreamOutputTypeScreen
             sampleHandlerQueue:captureQueue error:&err];
        [stream startCaptureWithCompletionHandler:^(NSError *e){ /* ... */ }];
    }];

// 帧交付：拿到的直接是 GPU 侧的 IOSurface（零拷贝，可直接包成纹理）
- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sb
                   ofType:(SCStreamOutputType)type
{
    if (type != SCStreamOutputTypeScreen) return;

    // 检查帧状态附件：屏幕没变化时 SCK 会发 .idle/.blank，不带新画面，跳过
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(img);
    // → 包成纹理交给合成
}
```

### 2.4 屏幕采集的特殊性：帧从哪来 vs 谁在等

屏幕采集**天生只在"画面变化时"才产帧**（SCK 的 idle 帧不带新内容）。这跟摄像头（恒定帧率吐帧）不同，带来一个设计选择——它到底算异步源还是同步源？

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A. 当异步源** | 回调里 `output_video` 入 async_frames，合成端挑帧 | 复用现成路径、与其它源统一 | IOSurface→CVPixelBuffer 进队列多一层持有；静止画面靠 `get_frame` 缓冲空重复上一帧兜底 |
| **B. 当同步源** | 回调只更新"最新 IOSurface 指针"，合成 tick 时直接绑该 surface 为纹理画 | 零拷贝、零缓冲、最低延迟；静止时天然复用同一纹理 | 需要 `WLSource` 长一条同步 render 路径（现在没有）；回调与 tick 的 surface 读写要加锁 |

**OBS 的取法**：屏幕采集在 libobs 里走 texture 直绘（同步语义），SCK 交付的 IOSurface 直接转纹理，不进异步帧队列——即偏 B。这样静止桌面不会反复入队相同帧，也省一次像素搬运。

**对 WorkOBS 的建议**：M3 Metal 合成阶段会引入"源 → 纹理"的通用通道；届时屏幕采集走 B 最自然（IOSurface 本就是 GPU 资源）。**在此之前若想先跑通，可临时走 A**（IOSurface 包 CVPixelBuffer 塞进现有 async_frames），零新增代码，代价是多一层拷贝——属于"先能用，M3 再优化"的合理过渡。

---

## 3. 静态图片源（同步源）：`image-source`

### 3.1 定位

`plugins/image-source/image-source.c` 里其实住着三个源：**图片源**、**颜色源**、**幻灯片（slideshow）**。这里只看图片源。它是**同步源的教科书范例**：没有线程、没有 PTS、没有缓冲——图就在那儿，tick 到就画。

支持 PNG / JPEG / BMP / TGA / **GIF / WebP**（后两者可能是动画）。

### 3.2 三个回调 + 伪代码

图片源的全部逻辑就是 `load` / `tick` / `render` 三个回调（对照异步源"另起线程 push 帧"，这里干净得多）：

```c
struct image_source {
    obs_source_t   *source;
    char           *file;
    gs_image_file4_t if4;              // 图片文件包装（含纹理、动画帧数组）
    // 动画计时
    float           update_time_elapsed;
    uint64_t        last_time;
};

// (1) 加载：解码文件 → 上传为 GPU 纹理。动画格式一次解全部帧。
static void image_source_load(struct image_source *ctx) {
    gs_image_file4_init(&ctx->if4, ctx->file, ...);   // 认后缀选解码器
    obs_enter_graphics();
    gs_image_file4_init_texture(&ctx->if4);           // 建纹理
    obs_leave_graphics();
}

// (2) tick：每帧调一次，只为动画推进；静态图直接返回。
static void image_source_tick(void *data, float seconds) {
    struct image_source *ctx = data;
    if (!ctx->if4...is_animated_gif) return;          // ← 静态图：什么都不做

    ctx->update_time_elapsed += seconds;              // 累积经过时间
    if (ctx->update_time_elapsed >= frame_delay) {    // 到了这帧该显示的时长
        ctx->update_time_elapsed -= frame_delay;
        gs_image_file4_update_frame(&ctx->if4);       // 切到下一帧纹理（环绕）
    }
}

// (3) render：合成 tick 在这里问"给我画面"。就画那张当前纹理。
static void image_source_render(void *data, gs_effect_t *effect) {
    struct image_source *ctx = data;
    if (!ctx->if4...texture) return;
    gs_effect_set_texture(gs_effect_get_param_by_name(effect, "image"),
                          ctx->if4...texture);
    gs_draw_sprite(ctx->if4...texture, 0, cx, cy);    // 画一个铺满的 sprite
}
```

注册时的 flags：`OBS_SOURCE_VIDEO`（**不带** ASYNC）。缺 ASYNC 意味着 libobs 不给它建异步帧队列，而是每合成 tick 直接调它的 `video_render`。

### 3.3 静态 vs 动画的分野

- **静态图**（PNG/JPG）：`tick` 空转，`render` 永远画同一张纹理。零成本。
- **动画**（GIF/WebP）：`load` 时解出**所有帧 + 每帧 delay**，`tick` 用累积时间切帧。注意它**不追实时墙钟**（不像视频 pace），就是"按每帧 delay 顺序播"，慢了也不丢帧——因为没人在乎图片的绝对时间轴。

### 3.4 映射到 WorkOBS

图片源逼出 `WLSource` 目前缺的那条**同步路径**。建议在 M3 Metal 合成落地"源→纹理"通道时，给基类补一个同步出口，与现有异步 `get_frame` 并列：

```cpp
class WLSource {
    // 现有（异步源用）：解码/采集线程 push，tick 挑帧
    void output_video(CVPixelBufferRef, int64_t pts_ns);      // 生产端
    CVPixelBufferRef get_frame(int64_t sys_ns, int64_t *pts); // 消费端（异步）

    // 新增（同步源用）：tick 时直接问纹理，无缓冲无 PTS
    virtual id<MTLTexture> render_texture() { return nil; }   // 默认无（异步源不实现）
};

class WLImageSource : public WLSource {
    id<MTLTexture> _tex;   // load 时一次上传；静态图恒定
    int  start() override { /* 加载文件 → _tex */ return 0; }
    void stop()  override {}
    id<MTLTexture> render_texture() override { return _tex; }   // tick 直接拿去画
    // 动画 GIF：另存帧数组 + delay，在合成 tick 回调里按累积时间切 _tex
};
```

合成 tick 遍历源时按类型分流：异步源走 `get_frame`（拿 CVPixelBuffer 转纹理），同步源走 `render_texture`（直接拿纹理）。两条路在 Metal 里最终汇到同一个"纹理 → 画布合成"步骤。

---

## 4. 三类源总对比

| | 摄像头 | 屏幕采集 | 静态图片 |
|---|---|---|---|
| macOS 框架 | AVFoundation `AVCaptureSession` | ScreenCaptureKit `SCStream` | `gs_image_file`（图片解码） |
| OBS 插件 | `mac-avcapture` | `mac-capture` | `image-source` |
| 源类型 | 异步 `ASYNC_VIDEO` | 同步（texture 直绘）| 同步 `VIDEO` |
| 帧来源 | 恒定帧率回调 push | 画面变化时回调 push | 无（tick 拉当前纹理）|
| 带 PTS | ✅ 系统时钟（不从0） | ~（有但语义弱）| ❌ |
| 进 async_frames | ✅ | OBS 否 / WorkOBS 可临时是 | ❌ |
| WorkOBS 复用度 | **高**（直接用现有异步路径）| 中（M3 前可临时走异步）| 低（需新增同步 render 路径）|
| 动画/变化 | 实时流 | 实时屏幕 | GIF 按 delay 切帧，不追墙钟 |

## 5. 给 WorkOBS 的落地顺序建议

1. **先摄像头**：异步路径现成，`WLCameraSource : WLSource` 在 delegate 回调里调 `output_video` 即可，是验证"多源接入 + 时间戳统一"的最小增量；重点验摄像头 PTS 与 `WLTime` 墙钟对齐（时长爆炸坑）。
2. **图片源与 M3 绑定**：它逼出同步 render 通道，正好和 Metal 合成"源→纹理"一起设计，别单独硬凑。
3. **屏幕采集最后**：ScreenCaptureKit 交付 IOSurface 本就是 GPU 资源，等 M3 有了纹理通道走同步路径最省；M3 前若要 demo 可临时塞异步队列。

---

*参考：`plugins/mac-avcapture/`、`plugins/mac-capture/mac-screen-capture.m`、`plugins/image-source/image-source.c`、`libobs/obs-source.h`（output_flags）。伪代码为说明数据流而简化，具体字段/错误处理以源码为准。*
