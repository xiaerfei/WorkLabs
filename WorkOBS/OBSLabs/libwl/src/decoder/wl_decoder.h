//
//  wl_decoder.h
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//

#ifndef wl_decoder_h
#define wl_decoder_h

#include <stdio.h>
#include <stdlib.h>
#define MAX_HW_ACCELS 16

// 专门对接 UI 层的硬件加速列表结构体
typedef struct HWAccelList {
    const char *names[MAX_HW_ACCELS]; // 硬件加速名称字符串，如 "cuda", "videotoolbox"
    int count;                        // 当前系统实际支持的个数
} HWAccelList;

// 仅仅告诉外部有这个结构体类型，但不透露里面有什么
typedef struct wl_decoder_t wl_decoder_t;

/**
 * 创建解码器
 * @param path  媒体文件路径
 * @param hw_type  硬件加速类型名称（如 "videotoolbox"），传 NULL 则纯软解
 */
wl_decoder_t *wl_decoder_create(const char *path, const char *hw_type);
void wl_decoder_free(wl_decoder_t *decoder);


/**
 * 获取当前 FFmpeg 构建版本及当前主机系统真正支持的硬件加速列表
 * @return HWAccelList 结构体（值传递，无需外部手动 free）
 */
HWAccelList wl_decoder_get_supported_hwaccels(void);



#endif /* wl_decoder_h */
