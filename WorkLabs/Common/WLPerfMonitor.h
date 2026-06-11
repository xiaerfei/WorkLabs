//
//  WLPerfMonitor.h
//  WorkLabs
//
//  进程级 CPU / 内存观测：定时采样并经 WLLog 输出（tag=Perf）。
//  - CPU%：两次采样间 user+system CPU 时间增量 / 墙钟增量，单核=100%（多线程可超 100%），
//    与 top / 活动监视器口径一致。
//  - 内存：task_vm_info.phys_footprint，与 Xcode 内存仪表一致。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLPerfMonitor : NSObject

/// 开始采样（200ms 间隔）并打日志；已在运行则无效果。
+ (void)start;
+ (void)stop;

@end

NS_ASSUME_NONNULL_END
