//
//  WLCanvasView.h
//  OBSLabs
//
//  画布容器：管理浮层叠放、点击空白取消选中。
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLCanvasView : NSView

/// 点击画布空白区域（非浮层）时回调
@property (nonatomic, copy, nullable) void (^onBackgroundClick)(void);

@end

NS_ASSUME_NONNULL_END
