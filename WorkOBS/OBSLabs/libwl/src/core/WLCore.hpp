//
//  WLCore.hpp
//  OBSLabs
//
//  全局核心（原 wl_core，对标 OBS 的全局 obs 单例）。
//  全 static 方法：调用点 WLCore::startup(30) 与 C 版 wl_core_startup(30)
//  一一对应；单例数据藏在 .cpp 的文件内 static（对标 C 版 g_core，不暴露）。
//
//  职责：拥有所有 WLSource 的生命周期 + 拥有 WLGraphics 节拍线程。
//  graphics / preview 只消费源，不拥有。
//

#ifndef WLCore_hpp
#define WLCore_hpp

#include "WLGraphics.hpp"   // wl_frame_output_cb（转发给 graphics 的输出回调类型）

class WLSource;

class WLCore {
public:
    // 启动：注册内置源类型 + 创建并启动 graphics 节拍（空转等源）。
    // fps = 合成节拍帧率（必须 > 0）。幂等：已启动直接返回 0。
    static int startup(int fps);

    // 关停：先停节拍（join graphics 线程），再销毁所有源。幂等。
    static void shutdown();

    // 按注册表 type_id 创建源并入表。不自动 start（显式 src->start()）。
    // 返回的指针由 WLCore 拥有；remove/shutdown 后不可再用。失败返回 NULL。
    static WLSource *add_source(const char *type_id, const char *settings);

    // 摘除即销毁：出表（与 tick 遍历互斥）后 delete。
    static void remove_source(WLSource *src);

    // 锁内遍历所有源（graphics tick 用）。回调内勿 add/remove —— 同一把锁，会死锁。
    static void foreach_source(void (*fn)(WLSource *src, void *ctx), void *ctx);

    // 注册 per-source 帧输出回调，转发给内部 graphics（对齐 OBS 走全局 API，不直接暴露内部）。
    // 须在 startup 之后调用；未 startup 时忽略。cb=NULL 注销。
    static void set_frame_output(wl_frame_output_cb cb, void *ctx);
};

#endif /* WLCore_hpp */
