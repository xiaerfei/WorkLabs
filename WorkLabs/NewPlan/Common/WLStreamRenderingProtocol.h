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

@protocol WLStreamRenderingDelegate <NSObject>
- (void)rendering:(id<WLStreamRenderingProtocol>)rendering didUpdateFrame:(CGRect)frame;
@end

@protocol WLStreamRenderingProtocol <WLVideoOutputProtocol>
@property (nonatomic, assign, readonly) CGRect frame; // 基于 output 分辨率的像素坐标
@property (nonatomic, weak, nullable) id<WLStreamRenderingDelegate> delegate;
@end

NS_ASSUME_NONNULL_END
