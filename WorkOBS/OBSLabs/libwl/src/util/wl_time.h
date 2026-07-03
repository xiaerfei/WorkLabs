//
//  wl_time.h
//  OBSLabs
//
//  时间工具。全库统一用 CLOCK_MONOTONIC 这一把"墙钟尺"：
//  只增不减、不受系统对时/NTP 回拨影响；所有模块（media_thread 的 pace、
//  wl_source 的挑帧、wl_graphics 的节拍）取自同一时钟，相互的差值才有意义。
//

#ifndef wl_time_h
#define wl_time_h

#include <stdbool.h>
#include <stdint.h>
#include <time.h>

// 单调时钟当前值（纳秒）
static inline int64_t wl_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// 睡到单调时钟的绝对时刻 target_ns。
// 返回 true = 确实睡了；false = target 已是过去（调用方按"落后"处理）。
// 实现为 nanosleep 差值（对标 OBS os_sleepto_ns 语义）；精度不够时可换 mach_wait_until。
static inline bool wl_sleep_to_ns(int64_t target_ns) {
    int64_t d = target_ns - wl_now_ns();
    if (d <= 0) return false;
    struct timespec req = {
        .tv_sec  = (time_t)(d / 1000000000LL),
        .tv_nsec = (long)  (d % 1000000000LL),
    };
    nanosleep(&req, NULL);
    return true;
}

#endif /* wl_time_h */
