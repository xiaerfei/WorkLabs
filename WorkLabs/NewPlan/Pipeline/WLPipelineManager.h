//
//  WLPipelineManager.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import "WLSourceProtocol.h"

@class WLPreviewOutput;
@class WLAudioOutput;

NS_ASSUME_NONNULL_BEGIN

@interface WLPipelineManager : NSObject
+ (instancetype)manager;

- (void)addVideoSource:(id<WLVideoSource>)source;
- (void)addAudioSource:(id<WLAudioSource>)source;
- (void)removeSource:(id<WLSource>)source;
@property (nonatomic, strong, readonly) NSArray<id<WLSource>> *sources;

@property (nonatomic, strong, nullable) WLPreviewOutput *videoOutput;
@property (nonatomic, strong, nullable) WLAudioOutput *audioOutput;

- (BOOL)start;
- (void)stop;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
@end

NS_ASSUME_NONNULL_END
