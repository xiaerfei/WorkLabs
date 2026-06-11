//
//  WLPerfMonitor.m
//  WorkLabs
//

#import "WLPerfMonitor.h"
#import "WLLog.h"
#import <libproc.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

static NSString * const kPerfTag = @"Perf";
static const NSTimeInterval kPerfInterval = 0.2; // 200ms

static dispatch_source_t sTimer;
static uint64_t sLastCPUTime;  // user+system 累计 CPU 时间（mach 时基）
static uint64_t sLastWallTime; // mach_absolute_time

// 进程累计 CPU 时间（user+system）。ri_* 与 mach_absolute_time 同时基
// （Apple Silicon 上时基≠1ns，不能当纳秒用），与墙钟做比值即免换算。
static uint64_t WLProcessCPUTime(void) {
    rusage_info_current ru;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, (rusage_info_t *)&ru) != 0) return 0;
    return ru.ri_user_time + ru.ri_system_time;
}

// 物理内存占用（phys_footprint，字节）
static uint64_t WLProcessFootprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

static void WLPerfTick(void) {
    uint64_t cpuTime = WLProcessCPUTime();
    uint64_t now = mach_absolute_time();

    double cpuPercent = 0;
    if (sLastWallTime != 0 && now > sLastWallTime && cpuTime >= sLastCPUTime) {
        cpuPercent = (double)(cpuTime - sLastCPUTime) / (double)(now - sLastWallTime) * 100.0;
    }
    sLastCPUTime = cpuTime;
    sLastWallTime = now;

    double memMB = WLProcessFootprint() / (1024.0 * 1024.0);
    WLLogI(kPerfTag, @"CPU %5.1f%% | 内存 %7.1f MB", cpuPercent, memMB);
}

@implementation WLPerfMonitor

+ (void)start {
    @synchronized (self) {
        if (sTimer) return;

        // 先采一次作基线，首条输出即为真实 200ms 窗口的 CPU
        sLastCPUTime = WLProcessCPUTime();
        sLastWallTime = mach_absolute_time();

        dispatch_queue_t q = dispatch_queue_create("com.worklabs.perf-monitor", DISPATCH_QUEUE_SERIAL);
        sTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(sTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPerfInterval * NSEC_PER_SEC)),
                                  (uint64_t)(kPerfInterval * NSEC_PER_SEC),
                                  (uint64_t)(kPerfInterval * NSEC_PER_SEC / 10));
        dispatch_source_set_event_handler(sTimer, ^{ WLPerfTick(); });
        dispatch_resume(sTimer);

        WLLogI(kPerfTag, @"性能监控开始（间隔 %.0fms）", kPerfInterval * 1000);
    }
}

+ (void)stop {
    @synchronized (self) {
        if (!sTimer) return;
        dispatch_source_cancel(sTimer);
        sTimer = nil;
        sLastCPUTime = 0;
        sLastWallTime = 0;
        WLLogI(kPerfTag, @"性能监控停止");
    }
}

@end
