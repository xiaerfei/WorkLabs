//
//  WLMediaThread.h
//  OBSLabs
//
//  wl_media_thread 的 Objective-C 薄封装：驱动 per-source 解码主循环的生命周期。
//  M1 阶段用于测试 pacing —— 帧输出目前走 C 层临时日志（[V]/[A]），
//  本类只负责 create / start / pause / seek / 停止。
//  待 M3/M4 接入 async_frames 后，可在此扩展帧输出回调。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLMediaThread : NSObject

/// 创建（尚未启动）。底层 wl_decoder 打开失败时返回 nil。
/// @param path    媒体文件路径
/// @param hwType  硬件加速类型（如 @"videotoolbox"），nil = 纯软解
- (nullable instancetype)initWithPath:(NSString *)path hwType:(nullable NSString *)hwType;

/// 启动主循环线程。返回 YES 成功。
- (BOOL)start;

/// 暂停 / 恢复。
- (void)setPaused:(BOOL)paused;

/// Seek 到指定时间戳（微秒）。当前底层为 stub（仅 flush）。
- (void)seekToMicroseconds:(int64_t)us;

/// 停止并释放底层线程（内部 join 等线程退出）。幂等；dealloc 也会调用。
- (void)close;

@end

NS_ASSUME_NONNULL_END
