//
//  WLCameraSource.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLSourceProtocol.h"

@class WLCameraSourceConfig;

NS_ASSUME_NONNULL_BEGIN

@interface WLCameraSource : NSObject <WLVideoSource, AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong, readonly) WLCameraSourceConfig *config;
@property (nonatomic, copy, nullable) void (^frameOutput)(CVPixelBufferRef pixelBuffer, Float64 pts);
- (instancetype)initWithConfig:(WLCameraSourceConfig *)config;
@end

NS_ASSUME_NONNULL_END
