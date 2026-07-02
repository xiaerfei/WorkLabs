//
//  wl_source_registry.h
//  OBSLabs
//
//  源类型全局注册表。对齐 OBS obs_register_source + get_source_info。
//  固定数组（源类型极少，编译期定上限，无 malloc）。线程安全。
//

#ifndef wl_source_registry_h
#define wl_source_registry_h

#include "wl_source_info.h"

// 注册一种源类型（通常在应用启动时调用）。重复 id → 覆盖并打 warning。
void wl_source_register(const wl_source_info_t *info);

// 注销一种源类型。
void wl_source_unregister(const char *id);

// 按 id 查找；未找到返回 NULL。
const wl_source_info_t *wl_source_find(const char *id);

#endif /* wl_source_registry_h */
