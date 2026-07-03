//
//  wl_graphics.h
//  OBSLabs
//
//  全局合成节拍线程。对标 OBS obs_graphics_thread（libobs/obs-video.c:1161）。
//  每 1/fps 秒醒来：遍历 wl_core 的源列表逐源挑帧 → 合成（阶段二 Metal）→ 输出。
//  源列表由 wl_core 持有，本模块只消费（wl_core_foreach_source）。
//  设计见 Doc/wl_graphics_thread_设计文档.md。
//

#ifndef wl_graphics_h
#define wl_graphics_h

typedef struct wl_graphics wl_graphics_t;

// 创建（尚未启动）。fps = 合成输出帧率（如 30）。
wl_graphics_t *wl_graphics_create(int fps);

// 启动节拍线程。返回 0 成功。
int  wl_graphics_start(wl_graphics_t *g);

// 停止并 join（幂等）。
void wl_graphics_stop(wl_graphics_t *g);

// 释放（内部先 stop）。
void wl_graphics_free(wl_graphics_t *g);

#endif /* wl_graphics_h */
