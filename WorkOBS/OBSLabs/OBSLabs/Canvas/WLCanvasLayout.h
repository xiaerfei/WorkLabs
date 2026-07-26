//
//  WLCanvasLayout.h
//  OBSLabs
//
//  画布布局模型：canvas size + per-source layout rect + z-order。
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLCanvasLayout : NSObject

@property (nonatomic, assign) CGSize canvasSize;  // 默认 1920×1080

- (void)setLayoutRect:(CGRect)rect forSourceID:(NSString *)sid;
- (CGRect)layoutRectForSourceID:(NSString *)sid;
- (void)removeLayoutForSourceID:(NSString *)sid;

- (void)bringToFront:(NSString *)sid;
- (void)sendToBack:(NSString *)sid;
- (void)moveUp:(NSString *)sid;
- (void)moveDown:(NSString *)sid;

/// bottom → top 顺序
- (NSArray<NSString *> *)sourceOrder;

@end

NS_ASSUME_NONNULL_END
