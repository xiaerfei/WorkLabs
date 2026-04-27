//
//  WLCameraSource.h
//  WorkLabs
//
//  Created by erfeixia on 13/04/2026.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@class WLCameraSourceConfig;

NS_ASSUME_NONNULL_BEGIN

@interface WLCameraSource : NSObject

@property (nonatomic, strong, readonly) WLCameraSourceConfig *config;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

/// 视频帧输出回调 (CVPixelBufferRef 由调用方负责释放)
@property (nonatomic, copy, nullable) void (^frameOutput)(CVPixelBufferRef pixelBuffer, Float64 pts);

- (instancetype)initWithConfig:(WLCameraSourceConfig *)config;
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
