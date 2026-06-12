//
//  WLAudioLevelMeterView.m
//  WorkLabs
//

#import "WLAudioLevelMeterView.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static const float kMeterFloorDb  = -60.0f;  // 表底（低于此视为无声）
static const float kMeterYellowDb = -20.0f;  // 绿/黄分界（OBS 同款刻度）
static const float kMeterRedDb    = -9.0f;   // 黄/红分界（OBS 同款刻度）
static const float kDecayDbPerSec = 30.0f;   // 表针衰减速度（快攻击/慢衰减）
static const NSTimeInterval kPeakHoldSeconds = 1.5;  // 峰值线保持时长

@interface WLAudioLevelMeterView ()
@property (nonatomic, assign) float displayDb;            // 表针（衰减后）
@property (nonatomic, assign) float peakDb;               // 峰值保持线
@property (nonatomic, assign) CFTimeInterval lastUpdateTime;
@property (nonatomic, assign) CFTimeInterval peakSetTime;
@end

@implementation WLAudioLevelMeterView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _displayDb = kMeterFloorDb;
        _peakDb = kMeterFloorDb;
    }
    return self;
}

- (void)updateWithLinearPeak:(float)peak {
    float db = (peak > 1.0e-6f) ? 20.0f * log10f(peak) : kMeterFloorDb;
    if (db < kMeterFloorDb) db = kMeterFloorDb;
    if (db > 0) db = 0;   // 混音前样本可能 >1（增益放大），表顶钳到 0 dBFS

    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = (self.lastUpdateTime > 0) ? (now - self.lastUpdateTime) : 0;
    self.lastUpdateTime = now;

    // 表针：新值更高立即顶上去（快攻击）；否则按固定速度滑落（慢衰减）
    float fallen = self.displayDb - kDecayDbPerSec * (float)dt;
    self.displayDb = MAX(db, MAX(fallen, kMeterFloorDb));

    // 峰值保持：更高则刷新；超时则放掉、跟回当前值
    if (db >= self.peakDb || (now - self.peakSetTime) > kPeakHoldSeconds) {
        self.peakDb = db;
        self.peakSetTime = now;
    }

    self.needsDisplay = YES;
}

- (void)reset {
    self.displayDb = kMeterFloorDb;
    self.peakDb = kMeterFloorDb;
    self.lastUpdateTime = 0;
    self.peakSetTime = 0;
    self.needsDisplay = YES;
}

// dB → 横向填充比例（-60 dB → 0，0 dBFS → 1）
static inline CGFloat WLMeterFracForDb(float db) {
    return (CGFloat)((db - kMeterFloorDb) / (0.0f - kMeterFloorDb));
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    CGFloat w = NSWidth(b), h = NSHeight(b);
    CGFloat radius = h / 2.0;

    // 底槽
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:b xRadius:radius yRadius:radius];
    [[NSColor quaternaryLabelColor] setFill];
    [track fill];

    // 填充：裁剪到表针比例，再按固定刻度区间分绿/黄/红三段上色
    CGFloat levelFrac = WLMeterFracForDb(self.displayDb);
    if (levelFrac > 0.001) {
        [NSGraphicsContext saveGraphicsState];
        [track addClip];
        NSRectClip(NSMakeRect(0, 0, w * levelFrac, h));
        CGFloat yFrac = WLMeterFracForDb(kMeterYellowDb);
        CGFloat rFrac = WLMeterFracForDb(kMeterRedDb);
        [[NSColor systemGreenColor] setFill];
        NSRectFill(NSMakeRect(0, 0, w * yFrac, h));
        [[NSColor systemYellowColor] setFill];
        NSRectFill(NSMakeRect(w * yFrac, 0, w * (rFrac - yFrac), h));
        [[NSColor systemRedColor] setFill];
        NSRectFill(NSMakeRect(w * rFrac, 0, w * (1 - rFrac), h));
        [NSGraphicsContext restoreGraphicsState];
    }

    // 峰值保持线
    CGFloat pkFrac = WLMeterFracForDb(self.peakDb);
    if (pkFrac > 0.01) {
        CGFloat x = MIN(w * pkFrac, w - 2);
        [[NSColor labelColor] setFill];
        NSRectFill(NSMakeRect(x - 1, 0, 2, h));
    }
}

@end
