//
//  WLCameraSource.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLSourceProtocol.h"
#import "WLStreamSourceProtocol.h"

@class WLCameraSourceConfig;

NS_ASSUME_NONNULL_BEGIN

@interface WLCameraSource : NSObject
    <WLVideoSource, WLStreamSourceProtocol, AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong, readonly) WLCameraSourceConfig *config;
@property (nonatomic, copy, nullable) void (^frameOutput)(CVPixelBufferRef pixelBuffer, Float64 pts);
@property (nonatomic, weak, nullable) id<WLStreamSourceDelegate> delegate;
- (instancetype)initWithConfig:(WLCameraSourceConfig *)config;
@end

NS_ASSUME_NONNULL_END
