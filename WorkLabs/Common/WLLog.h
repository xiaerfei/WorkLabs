//
//  WLLog.h
//  WorkLabs
//
//  轻量分级日志：级别 + tag + 运行时开关 + Release 裁剪。零依赖（底层 NSLog）。
//  现有裸 NSLog 暂不强制迁移；新观测/调试代码用此宏。
//
//  用法：
//    WLLogI(@"VideoMix", @"tick=%.0ffps", fps);
//    WLLogV(@"VideoMix", @"cold-start sid=%@ pts=%.3f", sid, pts);  // Release 下被裁剪
//  开关（如在 AppDelegate）：
//    [WLLog setGlobalLevel:WLLogLevelInfo];                 // 全局默认
//    [WLLog setLevel:WLLogLevelVerbose forTag:@"VideoMix"]; // 单独放开某模块
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WLLogLevel) {
    WLLogLevelError = 0,
    WLLogLevelWarn,
    WLLogLevelInfo,
    WLLogLevelDebug,
    WLLogLevelVerbose,
};

@interface WLLog : NSObject

/// 全局最低输出级别（默认 Info）：级别值 ≤ 阈值的才输出。
+ (void)setGlobalLevel:(WLLogLevel)level;
/// 某 tag 单独阈值（覆盖全局），用于「只放开某模块的 debug/verbose」。
+ (void)setLevel:(WLLogLevel)level forTag:(NSString *)tag;

/// 当前全局级别（设置界面回显用）。
+ (WLLogLevel)globalLevel;
/// 设置全局级别并持久化到 NSUserDefaults（设置界面用）。
+ (void)setGlobalLevelPersisted:(WLLogLevel)level;
/// App 启动时调用一次：恢复持久化的全局级别（无记录则保持默认 Info）。
+ (void)restorePersistedGlobalLevel;

+ (BOOL)shouldLog:(WLLogLevel)level tag:(NSString *)tag;
+ (void)log:(WLLogLevel)level tag:(NSString *)tag message:(NSString *)message;

@end

// 先 gate 再拼串：级别不够时连 stringWithFormat 都不执行（零开销）。
// 用 NSString stringWithFormat（Foundation 变参方法，解析可靠）拼好再传非变参的 log:tag:message:，
// 避免自定义变参 message 的解析坑。
// 形参不能叫 tag：会撞 selector 关键字 tag:，宏的 token 替换会把 tag: 也替掉 → shouldLog:: 报错
#define WLLog_EMIT(lvl, t, fmt, ...) \
    do { if ([WLLog shouldLog:(lvl) tag:(t)]) \
        [WLLog log:(lvl) tag:(t) message:[NSString stringWithFormat:(fmt), ##__VA_ARGS__]]; } while (0)

#define WLLogE(tag, fmt, ...) WLLog_EMIT(WLLogLevelError, (tag), (fmt), ##__VA_ARGS__)
#define WLLogW(tag, fmt, ...) WLLog_EMIT(WLLogLevelWarn,  (tag), (fmt), ##__VA_ARGS__)
#define WLLogI(tag, fmt, ...) WLLog_EMIT(WLLogLevelInfo,  (tag), (fmt), ##__VA_ARGS__)
#if DEBUG
  #define WLLogD(tag, fmt, ...) WLLog_EMIT(WLLogLevelDebug,   (tag), (fmt), ##__VA_ARGS__)
  #define WLLogV(tag, fmt, ...) WLLog_EMIT(WLLogLevelVerbose, (tag), (fmt), ##__VA_ARGS__)
#else
  #define WLLogD(tag, fmt, ...) do {} while (0)
  #define WLLogV(tag, fmt, ...) do {} while (0)
#endif

NS_ASSUME_NONNULL_END
