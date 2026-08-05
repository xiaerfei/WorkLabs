//
//  WLSourceRegistry.hpp
//  OBSLabs
//
//  源类型全局注册表。对齐 OBS obs_register_source + get_source_info：
//  按字符串 id 注册/查找，运行时用 id 创建源实例。
//  wl_source_type_info 本体定义在 WLSource.hpp（对齐 OBS 的组织：
//  obs_source_info 定义在 obs-source.h，注册 API 在 obs.h/obs.c）。
//
//  固定数组（源类型极少，编译期定上限，无 malloc）。线程安全。
//

#ifndef WLSourceRegistry_hpp
#define WLSourceRegistry_hpp

struct wl_source_type_info;   // 定义见 WLSource.hpp（接口只碰指针，前置声明够用）

class WLSourceRegistry {
public:
    // 注册一种源类型（通常在应用启动时调用）。重复 id → 覆盖并打 warning。
    static void RegisterType(const wl_source_type_info *info);

    // 注销一种源类型。
    static void UnregisterType(const char *id);

    // 按 id 查找；未找到返回 NULL。
    static const wl_source_type_info *Find(const char *id);
};

#endif /* WLSourceRegistry_hpp */
