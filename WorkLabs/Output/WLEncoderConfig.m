//
//  WLEncoderConfig.m
//  WorkLabs
//

#import "WLEncoderConfig.h"

static NSString * const kWLEncVideoBitrate     = @"WLEncVideoBitrate";
static NSString * const kWLEncKeyframeInterval = @"WLEncKeyframeInterval";
static NSString * const kWLEncFps              = @"WLEncFps";
static NSString * const kWLEncAudioBitrate     = @"WLEncAudioBitrate";

@implementation WLEncoderConfig

+ (instancetype)defaultConfig {
    WLEncoderConfig *c = [[WLEncoderConfig alloc] init];
    c.videoBitrate = 8000000;       // 8 Mbps
    c.keyframeIntervalSeconds = 2;  // 2 秒
    c.fps = 30;
    c.audioBitrate = 128000;        // 128 kbps
    return c;
}

+ (instancetype)loadFromDefaults {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    WLEncoderConfig *c = [WLEncoderConfig defaultConfig];
    if ([d objectForKey:kWLEncVideoBitrate])     c.videoBitrate = (int)[d integerForKey:kWLEncVideoBitrate];
    if ([d objectForKey:kWLEncKeyframeInterval]) c.keyframeIntervalSeconds = (int)[d integerForKey:kWLEncKeyframeInterval];
    if ([d objectForKey:kWLEncFps])              c.fps = (int)[d integerForKey:kWLEncFps];
    if ([d objectForKey:kWLEncAudioBitrate])     c.audioBitrate = (int)[d integerForKey:kWLEncAudioBitrate];
    // 兜底防非法值
    if (c.keyframeIntervalSeconds < 1) c.keyframeIntervalSeconds = 2;
    if (c.fps < 1) c.fps = 30;
    if (c.audioBitrate < 32000) c.audioBitrate = 128000;
    return c;
}

- (void)saveToDefaults {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:self.videoBitrate forKey:kWLEncVideoBitrate];
    [d setInteger:self.keyframeIntervalSeconds forKey:kWLEncKeyframeInterval];
    [d setInteger:self.fps forKey:kWLEncFps];
    [d setInteger:self.audioBitrate forKey:kWLEncAudioBitrate];
}

- (int)effectiveVideoBitrateForWidth:(int)w height:(int)h {
    if (self.videoBitrate > 0) return self.videoBitrate;
    return (int)((int64_t)w * h * 4);
}

@end
