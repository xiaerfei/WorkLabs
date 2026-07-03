//
//  wl_core.c
//  OBSLabs
//

#include "wl_core.h"
#include "wl_graphics.h"
#include "wl_media_source.h"
#include <pthread.h>
#include <stdio.h>

#define WL_CORE_MAX_SOURCES 64

// 全局单例（对标 OBS 的 extern struct obs_core *obs；我们直接静态实例，不暴露）
static struct {
    bool             started;
    wl_source_t     *sources[WL_CORE_MAX_SOURCES];
    int              count;
    pthread_mutex_t  mutex;        // 保护 sources/count；graphics tick 遍历也持这把锁
    wl_graphics_t   *graphics;
} g_core = {
    .mutex = PTHREAD_MUTEX_INITIALIZER,
};

// ---- 生命周期 ----

int wl_core_startup(int fps) {
    if (g_core.started) return 0;

    // 注册内置源类型（重复注册仅打 warning，安全）
    wl_media_source_register();

    g_core.graphics = wl_graphics_create(fps);
    if (!g_core.graphics) return -1;
    if (wl_graphics_start(g_core.graphics) != 0) {
        wl_graphics_free(g_core.graphics);
        g_core.graphics = NULL;
        return -1;
    }

    g_core.started = true;
    return 0;
}

void wl_core_shutdown(void) {
    if (!g_core.started) return;

    // 1. 先停节拍（join graphics 线程）——之后没人再遍历源列表
    wl_graphics_free(g_core.graphics);
    g_core.graphics = NULL;

    // 2. 快照并清空列表（锁内），销毁在锁外（destroy 会 join 解码线程，可能耗时）
    wl_source_t *snapshot[WL_CORE_MAX_SOURCES];
    pthread_mutex_lock(&g_core.mutex);
    int n = g_core.count;
    for (int i = 0; i < n; i++) snapshot[i] = g_core.sources[i];
    g_core.count = 0;
    pthread_mutex_unlock(&g_core.mutex);

    for (int i = 0; i < n; i++) wl_source_destroy(snapshot[i]);

    g_core.started = false;
}

// ---- 源管理 ----

wl_source_t *wl_core_add_source(const char *type_id, const char *settings) {
    if (!g_core.started) {
        fprintf(stderr, "[core] add_source before startup\n");
        return NULL;
    }

    wl_source_t *src = wl_source_create(type_id, settings);
    if (!src) return NULL;

    pthread_mutex_lock(&g_core.mutex);
    if (g_core.count == WL_CORE_MAX_SOURCES) {
        pthread_mutex_unlock(&g_core.mutex);
        fprintf(stderr, "[core] source list full (max %d)\n", WL_CORE_MAX_SOURCES);
        wl_source_destroy(src);
        return NULL;
    }
    g_core.sources[g_core.count++] = src;
    pthread_mutex_unlock(&g_core.mutex);

    return src;
}

void wl_core_remove_source(wl_source_t *src) {
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

    // 销毁在锁外：destroy 内部 join 解码线程可能耗时，别堵住 tick
    if (found) wl_source_destroy(src);
    else fprintf(stderr, "[core] remove_source: source not in list\n");
}

// ---- 遍历 ----

void wl_core_foreach_source(void (*fn)(wl_source_t *src, void *ctx), void *ctx) {
    pthread_mutex_lock(&g_core.mutex);
    for (int i = 0; i < g_core.count; i++) {
        fn(g_core.sources[i], ctx);
    }
    pthread_mutex_unlock(&g_core.mutex);
}
