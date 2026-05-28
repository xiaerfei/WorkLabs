//
//  WLMicSource.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLSourceProtocol.h"
#import "WLStreamSourceProtocol.h"

@class WLMicSourceConfig;

NS_ASSUME_NONNULL_BEGIN

@interface WLMicSource : NSObject
    <WLAudioSource, WLStreamSourceProtocol, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong, readonly) WLMicSourceConfig *config;
@property (nonatomic, copy, nullable) void (^sampleOutput)(CMSampleBufferRef sampleBuffer);
@property (nonatomic, weak, nullable) id<WLStreamSourceDelegate> delegate;
- (instancetype)initWithConfig:(WLMicSourceConfig *)config;
@end

NS_ASSUME_NONNULL_END
