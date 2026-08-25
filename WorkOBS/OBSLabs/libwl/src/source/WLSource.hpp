//
//  WLSource.hpp
//  OBSLabs
//
//  源壳（对齐 OBS obs_source_t）。
//
//  非多态、不被继承。持有：
//    - wl_source_type_info（类型元信息，按值拷贝）
//    - uuid_（实例唯一标识，全局递增）
//    - WLSourceProtocol *backend_（协议实现体指针）
//    - async_frames 环形缓冲（ASYNC 位条件分配）
//
//  控制方法透传 backend_，帧入口 OutputVideo 供实现体调用，
//  帧消费 GetFrame 供 tick 调用。
//
//  命名规范：对外 PascalCase，内部 camelCase。
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

class WLSourceProtocol;   // 前置声明（壳存指针够用，完整定义在 .cpp 解引用）

// ============================================================================
// 源类型元信息（对齐 OBS obs_source_info，obs-source.h:222）
// ============================================================================

// 源的大类（对齐 enum obs_source_type，obs-source.h:33）。
enum wl_source_type {
    WL_SOURCE_TYPE_INPUT,
};

// output_flags：声明"这类源产出什么、视频走哪条路"（对齐 obs-source.h:88-121）。
#define WL_SOURCE_VIDEO        (1 << 0)   // 产视频
#define WL_SOURCE_AUDIO        (1 << 1)   // 产音频
#define WL_SOURCE_ASYNC        (1 << 2)   // 视频异步：OutputVideo 入缓冲、tick 挑帧
#define WL_SOURCE_ASYNC_VIDEO  (WL_SOURCE_ASYNC | WL_SOURCE_VIDEO)

typedef struct wl_source_type_info {
    const char *id;             // 类型唯一标识，如 "media_file"
    enum wl_source_type type;   // 大类；目前恒 INPUT
    uint32_t output_flags;      // WL_SOURCE_* 位或
    const char *type_name;      // 显示名
    // 工厂：双参（对齐 OBS create(settings, source)）。
    // 把壳给实现体，实现体用 source->OutputVideo() 回喂帧。
    WLSourceProtocol *(*create)(const char *settings, class WLSource *source);
} wl_source_type_info;

class WLSource {
    // ── 实例标识（类型 ID + 实例 UUID）──
    wl_source_type_info  info_;           // 按值拷贝（ctor 时从参数拷入）
    uint32_t             uuid_;           // 全局递增计数器（线程安全原子自增）

    WLSourceProtocol    *backend_;        // 协议实现体指针

    // ── async_frames 缓冲（ASYNC 位条件分配）──
    wl_async_frame      *frames_;
    int                  capacity_;       // ASYNC 位无 → 0，不分配
    int                  head_;           // 最旧帧下标
    int                  count_;          // 当前帧数
    pthread_mutex_t      async_mutex_;

    // ── 挑帧状态 ──
    bool                 consume_anchored_;
    int64_t              consume_first_pts_;   // 媒体零点
    int64_t              consume_first_sys_;   // 墙钟零点
    CVPixelBufferRef     cur_frame_;
    int64_t              cur_frame_pts_;

    static uint32_t next_uuid_;             // 全局递增（__atomic_fetch_add）

public:
    // ctor：info 按值拷入 + 分配实例 UUID + 按 ASYNC 位决定是否分配缓冲
    WLSource(const wl_source_type_info *info);
    ~WLSource();                          // 非虚！第一行 delete backend_

    // ── 帧入口（生产端：实现体在自己的线程调用）──
    void OutputVideo(CVPixelBufferRef pixbuf, int64_t pts_ns);

    // ── 帧消费（tick 调用）──
    CVPixelBufferRef GetFrame(int64_t sys_time_ns, int64_t *out_pts_ns);

    // ── 绑定实现体（AddSource 流程中调用一次）──
    void SetBackend(WLSourceProtocol *backend) { backend_ = backend; }

    // ── 控制透传（带 backend NULL 防御，实现见 .cpp）──
    int  Start();
    void Stop();
    void Pause(bool paused);
    void Seek(int64_t seek_ts_us);
    void Update(const char *settings);

    // ── 信息透传 ──
    int64_t GetDuration();
    int     GetWidth();
    int     GetHeight();

    // ── info 访问 ──
    const wl_source_type_info &Info() const { return info_; }
    uint32_t UUID() const { return uuid_; }     // 实例 UUID（同类型多实例靠此区分）
};

#endif /* WLSource_hpp */
