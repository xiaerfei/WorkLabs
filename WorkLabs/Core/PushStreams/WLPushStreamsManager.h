//
//  WLPushStreamsManager.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/29.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLPushStreamsManager : NSObject
- (void)pixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
@end

NS_ASSUME_NONNULL_END
