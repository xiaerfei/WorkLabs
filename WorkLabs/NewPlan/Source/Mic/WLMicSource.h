//
//  WLMicSource.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLSourceProtocol.h"

@class WLMicSourceConfig;

NS_ASSUME_NONNULL_BEGIN

@interface WLMicSource : NSObject <WLAudioSource, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong, readonly) WLMicSourceConfig *config;
@property (nonatomic, copy, nullable) void (^sampleOutput)(CMSampleBufferRef sampleBuffer);
- (instancetype)initWithConfig:(WLMicSourceConfig *)config;
@end

NS_ASSUME_NONNULL_END
