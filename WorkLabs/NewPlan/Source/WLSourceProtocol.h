//
//  WLSourceProtocol.h
//  WorkLabs
//
//  NewPlan 统一输入源协议
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLDefines.h"

NS_ASSUME_NONNULL_BEGIN

@protocol WLSource <NSObject>
@property (nonatomic, assign, readonly) WLFromType fromType;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
- (BOOL)start;
- (void)stop;
@end

@protocol WLVideoSource <WLSource>
@property (nonatomic, copy, nullable) void (^frameOutput)(CVPixelBufferRef pixelBuffer, Float64 pts);
@end

@protocol WLAudioSource <WLSource>
@property (nonatomic, copy, nullable) void (^sampleOutput)(CMSampleBufferRef sampleBuffer);
@end

NS_ASSUME_NONNULL_END
