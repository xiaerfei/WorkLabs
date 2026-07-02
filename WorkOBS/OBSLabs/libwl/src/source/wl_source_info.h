//
//  wl_source_info.h
//  OBSLabs
//
//  源类型描述（vtable）。每种源类型定义一个静态 wl_source_info 实例，
//  注册到全局表；运行时按 id 查找、创建实例。对齐 OBS obs_source_info。
//

#ifndef wl_source_info_h
#define wl_source_info_h

#include <stdbool.h>
#include <stdint.h>

// 前向声明：create 需要拿到它所属的 wl_source（用于 output 回调）
typedef struct wl_source      wl_source_t;
typedef struct wl_source_info wl_source_info_t;

struct wl_source_info {
    // ─── 标识 ───
    const char *id;          // 类型唯一标识，如 "media_file"
    const char *type_name;   // 显示名，如 "Media File"

    // ─── 生命周期 ───

    // 创建私有数据。source = 所属实例（源可存下来，output 时用）。返回 NULL = 失败。
    void *(*create)(const char *settings, wl_source_t *source);
    // 销毁私有数据（调用前必已 stop）。
    void  (*destroy)(void *data);

    // ─── 控制 ───
    int   (*start)(void *data);                 // 返回 0 成功
    void  (*stop)(void *data);                  // 停止产出帧
    void  (*pause)(void *data, bool paused);    // 可为 NULL（不支持暂停）
    void  (*seek)(void *data, int64_t seek_ts_us); // 可为 NULL（不支持 seek）

    // ─── 信息查询（可为 NULL）───
    int64_t (*get_duration)(void *data);              // 微秒；无意义返回 -1
    void    (*get_video_size)(void *data, int *w, int *h);
};

#endif /* wl_source_info_h */
