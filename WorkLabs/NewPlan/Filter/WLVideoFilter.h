//
//  WLVideoFilter.h
//  WorkLabs
//
//  CoreImage 视频 Filter — 缩放 / 裁剪 / 镜像
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "WLStreamFilterProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLVideoFilter : NSObject <WLVideoFilterProtocol>

// 输出分辨率，必须 > 0
@property (nonatomic, assign) CGSize outputResolution;

// 裁剪区域（输入坐标系，左下角为原点）。CGRectZero 表示不裁剪
@property (nonatomic, assign) CGRect cropRect;

// 水平镜像
@property (nonatomic, assign) BOOL enableMirror;

- (instancetype)initWithOutputResolution:(CGSize)outputResolution;

@end

NS_ASSUME_NONNULL_END
