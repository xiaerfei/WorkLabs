//
//  WLStreamRenderingProtocol.h
//  WorkLabs
//
//  渲染协议 — Preview 用于本地预览 + 暴露合成参数
//

#import <Foundation/Foundation.h>
#import "WLStreamOutputProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@protocol WLStreamRenderingProtocol;

// 层级(z-order)调整动作
typedef NS_ENUM(NSInteger, WLZOrderAction) {
    WLZOrderActionFront,   // 置顶
    WLZOrderActionBack,    // 置底
    WLZOrderActionUp,      // 上移一层
    WLZOrderActionDown,    // 下移一层
};

@protocol WLStreamRenderingDelegate <NSObject>
- (void)rendering:(id<WLStreamRenderingProtocol>)rendering didUpdateFrame:(CGRect)frame;
@optional
// 浮层被点击，请求界面层做单选（选中本浮层、取消其它）
- (void)renderingDidRequestSelect:(id<WLStreamRenderingProtocol>)rendering;
// 浮层右键请求调整层级（z-order）
- (void)rendering:(id<WLStreamRenderingProtocol>)rendering didRequestZOrderAction:(WLZOrderAction)action;
// 浮层右键请求取消选中（画布被浮层占满、无空白处可点时的兜底）
- (void)renderingDidRequestDeselect:(id<WLStreamRenderingProtocol>)rendering;
@end

@protocol WLStreamRenderingProtocol <WLVideoOutputProtocol>
@property (nonatomic, assign, readonly) CGRect frame; // 基于 output 分辨率的像素坐标
@property (nonatomic, weak, nullable) id<WLStreamRenderingDelegate> delegate;
@end

NS_ASSUME_NONNULL_END
