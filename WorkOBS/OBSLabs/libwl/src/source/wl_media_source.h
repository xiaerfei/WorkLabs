//
//  wl_media_source.h
//  OBSLabs
//
//  本地媒体文件源（"media_file"）：内部持有 wl_media_thread，
//  把解码帧提取成 CVPixelBufferRef 交给 wl_source_output_video。
//

#ifndef wl_media_source_h
#define wl_media_source_h

#ifdef __cplusplus
extern "C" {   // 实现已迁到 WLMediaSource.cpp（C++），注册入口保持 C 链接名给 wl_core.c
#endif

// 注册 "media_file" 源类型到全局表（应用启动时调用一次）。
void wl_media_source_register(void);

#ifdef __cplusplus
}
#endif

#endif /* wl_media_source_h */
