//
//  wl_source_registry.c
//  OBSLabs
//

#include "wl_source_registry.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define MAX_SOURCE_TYPES 64

static struct {
    const wl_source_info_t *entries[MAX_SOURCE_TYPES];
    int                     count;
    pthread_mutex_t         mutex;
} g_registry = {
    .count = 0,
    .mutex = PTHREAD_MUTEX_INITIALIZER,
};

void wl_source_register(const wl_source_info_t *info) {
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

void wl_source_unregister(const char *id) {
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

const wl_source_info_t *wl_source_find(const char *id) {
    if (!id) return NULL;

    pthread_mutex_lock(&g_registry.mutex);
    const wl_source_info_t *found = NULL;
    for (int i = 0; i < g_registry.count; i++) {
        if (strcmp(g_registry.entries[i]->id, id) == 0) {
            found = g_registry.entries[i];
            break;
        }
    }
    pthread_mutex_unlock(&g_registry.mutex);
    return found;
}
