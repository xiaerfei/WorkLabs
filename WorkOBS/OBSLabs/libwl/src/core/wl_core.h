//
//  wl_core.h
//  OBSLabs
//
//  全局核心（单例）。对标 OBS 的全局 obs 单例（obs_core）：
//  持有全局源列表 + 合成节拍线程 wl_graphics，管两者的生命周期与编排。
//
//  生命周期：startup(fps) → add_source / start / remove_source ... → shutdown。
//  - startup 注册内置源类型并立即启动 graphics（0 源时空转）
//  - add_source 只建源+入表，不自动 start（显式 wl_source_start）
//  - remove_source = 出表 + 销毁（core 拥有源的生命周期）
//

#ifndef wl_core_h
#define wl_core_h

#include "wl_source.h"

// ---- 生命周期 ----

// 初始化全局核心：注册内置源类型 → 创建并启动 wl_graphics(fps)。
// 返回 0 成功。重复调用安全（直接返回 0）。
int  wl_core_startup(int fps);

// 关停：停 graphics → 销毁所有剩余源 → 释放。之后可再次 startup。
void wl_core_shutdown(void);

// ---- 源管理 ----

// 创建源并加入全局列表（不自动 start）。失败返回 NULL。
wl_source_t *wl_core_add_source(const char *type_id, const char *settings);

// 从列表摘除并销毁（内部 stop + destroy，锁外执行不堵 tick）。
void wl_core_remove_source(wl_source_t *src);

// ---- 遍历（graphics tick 用）----

// 锁内遍历所有源。持锁期间 add/remove 会阻塞等待——因此 tick 摸不到已释放的源，
// 无需引用计数。回调内勿再调 add/remove（同一把锁，死锁）。
void wl_core_foreach_source(void (*fn)(wl_source_t *src, void *ctx), void *ctx);

#endif /* wl_core_h */
