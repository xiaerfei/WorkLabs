//
//  WLCore.cpp
//  OBSLabs
//
//  原 wl_core.c 的类化。锁的形状不变：sources 列表一把 mutex，
//  tick 遍历全程持锁；remove 拿同一把锁自然互斥，销毁在锁外
//  （dtor 会 join 解码线程，可能耗时，别堵住 tick）。
//
//  C 版 wl_source_create 的职责在这里拆开了：
//    registry 查找 + 工厂调用 → add_source（本文件）
//    缓冲分配                 → WLSource 基类 ctor
//    失败清理                 → 工厂内 delete（见 WLMediaSource.cpp）
//

#include "WLCore.hpp"
#include "WLGraphics.hpp"
#include "WLSource.hpp"
#include "WLSourceRegistry.hpp"
#include "WLMediaSource.hpp"
#include <pthread.h>
#include <stdio.h>

#define WL_CORE_MAX_SOURCES 64

// 全局单例（对标 OBS 的 extern struct obs_core *obs；我们直接静态实例，不暴露）
static struct {
    bool             started;
    WLSource        *sources[WL_CORE_MAX_SOURCES];
    int              count;
    pthread_mutex_t  mutex;        // 保护 sources/count；graphics tick 遍历也持这把锁
    WLGraphics      *graphics;
} g_core = {
    false,
    {0},
    0,
    PTHREAD_MUTEX_INITIALIZER,
    NULL,
};

// ---- 生命周期 ----

int WLCore::startup(int fps) {
    if (g_core.started) return 0;
    if (fps <= 0) return -1;   // C 版这个检查在 wl_graphics_create 里，移到入口处

    // 注册内置源类型（重复注册仅打 warning，安全）
    WLMediaSource::register_type();

    g_core.graphics = new WLGraphics(fps);
    if (g_core.graphics->start() != 0) {
        delete g_core.graphics;
        g_core.graphics = NULL;
        return -1;
    }

    g_core.started = true;
    return 0;
}

void WLCore::shutdown() {
    if (!g_core.started) return;

    // 1. 先停节拍（dtor 内 join graphics 线程）——之后没人再遍历源列表
    delete g_core.graphics;
    g_core.graphics = NULL;

    // 2. 快照并清空列表（锁内），销毁在锁外（dtor 会 join 解码线程，可能耗时）
    WLSource *snapshot[WL_CORE_MAX_SOURCES];
    pthread_mutex_lock(&g_core.mutex);
    int n = g_core.count;
    for (int i = 0; i < n; i++) snapshot[i] = g_core.sources[i];
    g_core.count = 0;
    pthread_mutex_unlock(&g_core.mutex);

    // delete 走虚析构链：子类 dtor 停解码线程 → 基类 dtor 清缓冲
    for (int i = 0; i < n; i++) delete snapshot[i];

    g_core.started = false;
}

// ---- 源管理 ----

WLSource *WLCore::add_source(const char *type_id, const char *settings) {
    if (!g_core.started) {
        fprintf(stderr, "[core] add_source before startup\n");
        return NULL;
    }

    const wl_source_type_info *info = WLSourceRegistry::find(type_id);
    if (!info) {
        fprintf(stderr, "[core] unknown source type '%s'\n", type_id ? type_id : "(null)");
        return NULL;
    }

    WLSource *src = info->create(settings);   // 工厂内已做失败检查（失败返回 NULL）
    if (!src) {
        fprintf(stderr, "[core] create failed for type '%s'\n", info->id);
        return NULL;
    }

    pthread_mutex_lock(&g_core.mutex);
    if (g_core.count == WL_CORE_MAX_SOURCES) {
        pthread_mutex_unlock(&g_core.mutex);
        fprintf(stderr, "[core] source list full (max %d)\n", WL_CORE_MAX_SOURCES);
        delete src;
        return NULL;
    }
    g_core.sources[g_core.count++] = src;
    pthread_mutex_unlock(&g_core.mutex);

    return src;
}

void WLCore::remove_source(WLSource *src) {
    if (!src) return;

    // 出表（锁内）。拿锁即与 tick 遍历互斥：返回时保证 tick 不再触碰 src。
    bool found = false;
    pthread_mutex_lock(&g_core.mutex);
    for (int i = 0; i < g_core.count; i++) {
        if (g_core.sources[i] == src) {
            // 尾元素补位（不保序；z-order 等编排职责 M3 持有层再管）
            g_core.sources[i] = g_core.sources[--g_core.count];
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&g_core.mutex);

    // 销毁在锁外：dtor 内部 join 解码线程可能耗时，别堵住 tick
    if (found) delete src;
    else fprintf(stderr, "[core] remove_source: source not in list\n");
}

// ---- 遍历 ----

void WLCore::foreach_source(void (*fn)(WLSource *src, void *ctx), void *ctx) {
    pthread_mutex_lock(&g_core.mutex);
    for (int i = 0; i < g_core.count; i++) {
        fn(g_core.sources[i], ctx);
    }
    pthread_mutex_unlock(&g_core.mutex);
}
