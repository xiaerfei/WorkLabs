//
//  WLCanvasModel.h
//  WorkLabs
//
//  画布数据源 — 背景(色/图) + 各路 layout / z-order 的单一数据源。
//  Render 画布 UI 与 WLVideoMix 共同消费，保证「所见」=「所推」。
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLCanvasModel : NSObject

// 输出画布尺寸，默认 1920×1080
@property (nonatomic, assign) CGSize canvasSize;

// 画布纯色背景（nil 表示无）
@property (nonatomic, strong, nullable) NSColor *backgroundColor;

// 整张铺满的背景图（nil 表示无）
@property (nonatomic, strong, nullable) NSImage *backgroundImage;

// 各路 Stream 在画布上的布局（画布像素坐标，左下角原点）
- (void)setLayoutFrame:(CGRect)frame forStreamID:(NSString *)streamID;
- (CGRect)layoutFrameForStreamID:(NSString *)streamID; // 无则返回 CGRectNull

// z-order：数组顺序即从底到顶
@property (nonatomic, copy, readonly) NSArray<NSString *> *streamOrder;
- (void)addStreamID:(NSString *)streamID;   // 追加到顶层（已存在则忽略）
- (void)removeStreamID:(NSString *)streamID;

@end

NS_ASSUME_NONNULL_END
