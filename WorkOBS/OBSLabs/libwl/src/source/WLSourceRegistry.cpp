//
//  WLSourceRegistry.cpp
//  OBSLabs
//
//  原 wl_source_registry.c 的类化：查找/覆盖/补位逻辑逐行保持不变，
//  数据仍是文件内 static（对标 C 版 g_registry，不进头文件）。
//

#include "WLSourceRegistry.hpp"
#include "WLSource.hpp"       // wl_source_type_info 完整定义（要解引用读 id）
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define MAX_SOURCE_TYPES 64

static struct {
    const wl_source_type_info *entries[MAX_SOURCE_TYPES];
    int                        count;
    pthread_mutex_t            mutex;
} g_registry = {
    {0},
    0,
    PTHREAD_MUTEX_INITIALIZER,
};

void WLSourceRegistry::RegisterType(const wl_source_type_info *info) {
    if (!info || !info->id) return;

    pthread_mutex_lock(&g_registry.mutex);

    // 重复 id → 覆盖
    for (int i = 0; i < g_registry.count; i++) {
        if (strcmp(g_registry.entries[i]->id, info->id) == 0) {
            fprintf(stderr, "[registry] warning: source '%s' already registered, overwriting\n",
                    info->id);
            g_registry.entries[i] = info;
            pthread_mutex_unlock(&g_registry.mutex);
            return;
        }
    }

    if (g_registry.count < MAX_SOURCE_TYPES) {
        g_registry.entries[g_registry.count++] = info;
    } else {
        fprintf(stderr, "[registry] error: source type table full (max %d)\n", MAX_SOURCE_TYPES);
    }

    pthread_mutex_unlock(&g_registry.mutex);
}

void WLSourceRegistry::UnregisterType(const char *id) {
    if (!id) return;

    pthread_mutex_lock(&g_registry.mutex);
    for (int i = 0; i < g_registry.count; i++) {
        if (strcmp(g_registry.entries[i]->id, id) == 0) {
            // 用最后一个填补空位（顺序无所谓）
            g_registry.entries[i] = g_registry.entries[--g_registry.count];
            break;
        }
    }
    pthread_mutex_unlock(&g_registry.mutex);
}

const wl_source_type_info *WLSourceRegistry::Find(const char *id) {
    if (!id) return NULL;

    pthread_mutex_lock(&g_registry.mutex);
    const wl_source_type_info *found = NULL;
    for (int i = 0; i < g_registry.count; i++) {
        if (strcmp(g_registry.entries[i]->id, id) == 0) {
            found = g_registry.entries[i];
            break;
        }
    }
    pthread_mutex_unlock(&g_registry.mutex);
    return found;
}
