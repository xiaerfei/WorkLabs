//
//  WLLog.m
//  WorkLabs
//

#import "WLLog.h"

@implementation WLLog

static WLLogLevel sGlobalLevel = WLLogLevelInfo;
static NSMutableDictionary<NSString *, NSNumber *> *sTagLevels = nil;
static NSString * const kWLLogGlobalLevelKey = @"WLLogGlobalLevel";

+ (void)setGlobalLevel:(WLLogLevel)level {
    sGlobalLevel = level;
}

+ (WLLogLevel)globalLevel {
    return sGlobalLevel;
}

+ (void)setGlobalLevelPersisted:(WLLogLevel)level {
    sGlobalLevel = level;
    [[NSUserDefaults standardUserDefaults] setInteger:level forKey:kWLLogGlobalLevelKey];
}

+ (void)restorePersistedGlobalLevel {
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:kWLLogGlobalLevelKey];
    if (!saved) return;
    NSInteger v = saved.integerValue;
    if (v < WLLogLevelError || v > WLLogLevelVerbose) return; // 脏数据保持默认
    sGlobalLevel = (WLLogLevel)v;
}

+ (void)setLevel:(WLLogLevel)level forTag:(NSString *)tag {
    if (tag.length == 0) return;
    @synchronized (self) {
        if (!sTagLevels) sTagLevels = [NSMutableDictionary dictionary];
        sTagLevels[tag] = @(level);
    }
}

+ (BOOL)shouldLog:(WLLogLevel)level tag:(NSString *)tag {
    WLLogLevel threshold = sGlobalLevel;
    if (tag.length) {
        @synchronized (self) {
            NSNumber *t = sTagLevels[tag];
            if (t) threshold = (WLLogLevel)t.integerValue;
        }
    }
    return level <= threshold;
}

+ (void)log:(WLLogLevel)level tag:(NSString *)tag message:(NSString *)message {
    static const char *kNames[] = { "E", "W", "I", "D", "V" };
    NSUInteger idx = (level >= 0 && level <= WLLogLevelVerbose) ? (NSUInteger)level : WLLogLevelInfo;
    NSLog(@"[%s][%@] %@", kNames[idx], tag.length ? tag : @"-", message);
}

@end
