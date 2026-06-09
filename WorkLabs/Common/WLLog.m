//
//  WLLog.m
//  WorkLabs
//

#import "WLLog.h"

@implementation WLLog

static WLLogLevel sGlobalLevel = WLLogLevelInfo;
static NSMutableDictionary<NSString *, NSNumber *> *sTagLevels = nil;

+ (void)setGlobalLevel:(WLLogLevel)level {
    sGlobalLevel = level;
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
