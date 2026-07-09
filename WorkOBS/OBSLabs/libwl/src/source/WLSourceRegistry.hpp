//
//  WLSourceRegistry.hpp
//  OBSLabs
//
//  源类型全局注册表（原 wl_source_registry + wl_source_info 的合体）。
//  对齐 OBS obs_register_source + get_source_info：按字符串 id 注册/查找，
//  运行时用 id 创建源实例——这是 OBS 注册机制的核心价值，保留；
//  而 C 版 info 里那排控制函数指针（start/stop/…）已被 WLSource 虚函数
//  取代，条目只剩"身份 + 工厂"。
//
//  固定数组（源类型极少，编译期定上限，无 malloc）。线程安全。
//

#ifndef WLSourceRegistry_hpp
#define WLSourceRegistry_hpp

class WLSource;

// 源类型描述：每种源类型定义一个静态实例注册进全局表
typedef struct wl_source_type_info {
    const char *id;          // 类型唯一标识，如 "media_file"
    const char *type_name;   // 显示名，如 "Media File"

    // 工厂：创建该类型的源实例（new 子类），失败返回 NULL。
    // 失败检查（如 decoder 打不开）在工厂内做完，调用方拿到即可用。
    WLSource *(*create)(const char *settings);
} wl_source_type_info;

class WLSourceRegistry {
public:
    // 注册一种源类型（通常在应用启动时调用）。重复 id → 覆盖并打 warning。
    // （方法名不叫 register：那是 C/C++ 保留字。）
    static void register_type(const wl_source_type_info *info);

    // 注销一种源类型。
    static void unregister_type(const char *id);

    // 按 id 查找；未找到返回 NULL。
    static const wl_source_type_info *find(const char *id);
};

#endif /* WLSourceRegistry_hpp */
