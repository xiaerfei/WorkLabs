//
//  WLRenderingManager.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/29.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLViedoPreview.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLRenderingManager : NSObject

@property (nonatomic, strong, readonly) WLViedoPreview *videoPreview;

+ (instancetype)manager;

- (void)pixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
@end

NS_ASSUME_NONNULL_END
