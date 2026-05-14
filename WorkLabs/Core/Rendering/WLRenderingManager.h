//
//  WLRenderingManager.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/29.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLViedoPreview.h"
#import <libavutil/frame.h>

NS_ASSUME_NONNULL_BEGIN
@class WLRenderingManager;
@protocol WLRenderingDelegate <NSObject>

- (void)manager:(WLRenderingManager *)manager cameraBuffer:(CMSampleBufferRef)cameraBuffer;
- (void)manager:(WLRenderingManager *)manager extBuffer:(CMSampleBufferRef)extBuffer;

@end


@interface WLRenderingManager : NSObject

@property (nonatomic, strong) id <WLRenderingDelegate> delegate;

+ (instancetype)manager;

- (void)addForCameraPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
- (void)addForExtPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;

@end

NS_ASSUME_NONNULL_END
