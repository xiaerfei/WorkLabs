//
//  WLAudioLevelMeterView.h
//  WorkLabs
//
//  音频电平表（dBFS 横条）— 绿/黄/红分段 + 峰值保持线。
//  外部按固定频率喂入线性峰值（0~1+，增益后），内部做「快攻击/慢衰减」的
//  表针动态（ballistics）与峰值保持（peak hold），并转 dBFS 绘制。
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLAudioLevelMeterView : NSView

// 喂入一次线性峰值（0~1+）；视图转 dBFS、更新表针并重绘
- (void)updateWithLinearPeak:(float)peak;

// 当前表针位置（dBFS，衰减后；-60 为表底）。供旁边的数值标签回显。
@property (nonatomic, assign, readonly) float displayDb;

// 复位到表底（切源/停止轮询时调用）
- (void)reset;

@end

NS_ASSUME_NONNULL_END
