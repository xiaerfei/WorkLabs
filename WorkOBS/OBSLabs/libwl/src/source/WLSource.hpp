//
//  WLSource.hpp
//  OBSLabs
//
//  源抽象基类（原 wl_source.c + wl_source_info.h 的合体）。
//
//  C 版用 wl_source_info_t 手写函数指针表模拟继承（对齐 OBS obs_source_info，
//  OBS 因 C ABI / 插件边界必须如此）；C with Class 下这套 vtable 的语言级
//  对应物就是虚函数——编译器替我们生成虚表，7 个桥接函数消失：
//
//      C 版                          C++ 版
//      info->start(data)      →      虚函数 start()（编译器查虚表）
//      data（void* 私有数据）  →      子类成员（this 就是 source，反向引用消失）
//      pause 可为 NULL         →      基类空默认实现
//
//  基类持有所有源共用的东西：async_frames 环形缓冲（生产端 output_video）
//  + 消费端挑帧（get_frame）。子类（WLMediaSource / 将来的 Camera 等）只管
//  产帧：在自己的线程里调 output_video 即可。
//

#ifndef WLSource_hpp
#define WLSource_hpp

#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <CoreVideo/CoreVideo.h>   // CVPixelBufferRef

// 环形缓冲的一个 slot
typedef struct wl_async_frame {
    CVPixelBufferRef pixbuf;   // retain 持有
    int64_t          pts_ns;
} wl_async_frame;

class WLSource;

// ============================================================================
// 源类型元信息（对齐 OBS obs_source_info，obs-source.h:222）
//
// OBS 的 obs_source_info 是"元数据 + 手写 vtable"合一的结构；C++ 化后
// vtable 那半边变成了 WLSource 虚函数，剩下的元数据半边就是这个结构
// （外加 create 工厂——它是"类型级"操作，没有实例可挂，留在这里）。
// ============================================================================

// 源的大类（对齐 enum obs_source_type，obs-source.h:33）。
// OBS 有 INPUT/FILTER/TRANSITION/SCENE 四类——"一切皆源"：滤镜、转场也走
// 同一套注册/生命周期。现在只有 INPUT，其余等真出现时再加枚举值。
enum wl_source_type {
    WL_SOURCE_TYPE_INPUT,
};

// output_flags：声明"这类源产出什么、视频走哪条路"（对齐 obs-source.h:88-121）。
// ASYNC 位是合成分流的唯一依据（obs-source.c:1367 同款判断）。注意 OBS 在
// render 侧还能靠"info->video_render 回调是否 NULL"分流（:2933 vs :2942）；
// C++ 虚函数没有"未被 override"这个可查状态（默认实现兜底、永远可调），
// 所以这个 bit 在我们这儿比在 OBS 里更加必不可少。
#define WL_SOURCE_VIDEO        (1 << 0)   // 产视频
#define WL_SOURCE_AUDIO        (1 << 1)   // 产音频
#define WL_SOURCE_ASYNC        (1 << 2)   // 视频异步：output_video 入缓冲、tick 挑帧
#define WL_SOURCE_ASYNC_VIDEO  (WL_SOURCE_ASYNC | WL_SOURCE_VIDEO)
// 同步源 = 有 VIDEO 无 ASYNC：不产帧，render 阶段 video_render() 现画
// （M3 图片源/屏幕采集启用；见《OBS_采集源技术方案》§1）。

typedef struct wl_source_type_info {
    const char *id;             // 类型唯一标识，如 "media_file"
    enum wl_source_type type;   // 大类；目前恒 INPUT
    uint32_t output_flags;      // WL_SOURCE_* 位或
    const char *type_name;      // 显示名。OBS 的 get_name() 是函数指针，为的是
                                // 本地化（运行时查语言包）；我们静态串够用
    // 工厂：创建该类型的源实例（new 子类），失败返回 NULL。
    // 失败检查（如 decoder 打不开）在工厂内做完，调用方拿到即可用。
    WLSource *(*create)(const char *settings);
} wl_source_type_info;

class WLSource {
    // async_frames：堆分配环形缓冲（容量运行期固定），生产者(解码线程)/消费者(tick) 共享
    wl_async_frame  *frames;
    int              capacity;      // ctor 时定；0 = 分配失败，缓冲不可用
    int              head;          // 最旧帧下标
    int              count;         // 当前帧数
    pthread_mutex_t  async_mutex;

    // 消费端挑帧的时钟基准（首次 get_frame 锚定）+ 当前显示帧（source 持有）
    bool             consume_anchored;
    int64_t          consume_first_pts;   // 媒体零点
    int64_t          consume_first_sys;   // 墙钟零点
    CVPixelBufferRef cur_frame;
    int64_t          cur_frame_pts;

protected:
    WLSource();   // 抽象类：只能被子类构造

    // 视频帧入口（生产端：子类在自己的线程调用）。所有源统一走这里
    // （解码源提取出 CVPixelBufferRef、采集源天然就是）。
    // retain 一份 push 进环形缓冲；满则丢最旧（drop-oldest，非阻塞）。
    void output_video(CVPixelBufferRef pixbuf, int64_t pts_ns);

public:
    // 类型元信息：实例持有一份按值拷贝（对齐 OBS source->info = *info，
    // obs-source.c:450），WLCore::add_source 创建后填。按值而非存指针，
    // 是为了与注册表解耦——类型被 unregister 后实例照常活（OBS 的动机是
    // 插件卸载）。工厂直接 new 出来、未经 add_source 的裸实例此字段为空。
    wl_source_type_info info;

    // 必须 virtual：WLCore 存的是 WLSource*，delete 基类指针时非虚析构
    // 不会调子类 dtor —— 解码线程不 join、decoder 泄漏。
    // 注意基类 dtor 里不能调虚函数 stop()（析构期间虚表已退化到本类层级），
    // 所以契约是：子类 dtor 自己先停自己的线程。C++ 的析构顺序（子类先、
    // 基类后）恰好保证"先停生产者、再清缓冲"。
    virtual ~WLSource();

    // ---- 控制（原 vtable 条目；start/stop 必须实现，其余可选）----
    virtual int  start() = 0;                   // 返回 0 成功
    virtual void stop()  = 0;                   // 停止产出帧（幂等）
    virtual void pause(bool paused);            // 默认空实现 = 不支持暂停
    virtual void seek(int64_t seek_ts_us);      // 默认空实现 = 不支持 seek

    // settings 变更（对应 OBS .update；默认空 = 不支持运行时改参）。
    // 语义是"不重建实例、就地换参数"（如摄像头切设备/分辨率）。媒体文件源
    // 改路径 = 换内容，走删旧建新更合理，所以不 override。
    virtual void update(const char *settings);

    // ---- 信息查询（默认实现 = 不支持）----
    // get_width/height 对应 OBS 同名回调，其注释原话："Required if this is
    // an input source and has non-async video"——异步源尺寸随帧走、连宽高都
    // 不用报，所以默认回 0；同步源（M3）必须 override。
    virtual int64_t get_duration();             // 微秒；无意义返回 -1
    virtual int     get_width();
    virtual int     get_height();

    // ---- 同步源绘制（对应 OBS .video_render；默认空 = 异步源不用管）----
    // 同步源（无 ASYNC 位）没有帧队列，每 tick 由 render 阶段调用现画。
    // M3 Metal 合成接入后才有真正的调用方（签名届时补渲染上下文参数），
    // 先立形状占位。
    virtual void video_render();

    // ---- 消费端（渲染 tick 调用）----
    // 按系统时钟（纳秒，CLOCK_MONOTONIC）挑"当前该显示的帧"：追赶式跳过并
    // 释放过期帧，缓冲空时重复上一帧。返回 owned（+1 引用，调用者用完必须
    // release，对齐 obs_source_get_frame/release_frame 对），无帧返回 NULL。
    // out_pts_ns 可为 NULL。retain 在锁内做：出锁后其他消费者推进（release
    // cur_frame）也动不了调用者手里这份。
    CVPixelBufferRef get_frame(int64_t sys_time_ns, int64_t *out_pts_ns);
};

#endif /* WLSource_hpp */
