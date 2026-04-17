//
//  WLMediaMixer.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import "WLMediaSource.h"
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLAudioSourceConfig : NSObject
@property (nonatomic, weak, nullable) id<WLMediaSource> source;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) BOOL muted;
+ (instancetype)configWithSource:(id<WLMediaSource>)source volume:(float)volume;
@end

@interface WLMediaMixer : NSObject
@property (nonatomic, strong, readonly) NSMutableArray<WLAudioSourceConfig *> *audioSources;
@property (nonatomic, assign) float masterVolume;
- (instancetype)init;
- (void)addAudioSource:(id<WLMediaSource>)source;
- (void)removeAudioSource:(id<WLMediaSource>)source;
- (void)setVolume:(float)volume forSource:(id<WLMediaSource>)source;
- (float)volumeForSource:(id<WLMediaSource>)source;
- (void)setMuted:(BOOL)muted forSource:(id<WLMediaSource>)source;
- (void)fadeInSource:(id<WLMediaSource>)source duration:(NSTimeInterval)duration;
- (void)fadeOutSource:(id<WLMediaSource>)source duration:(NSTimeInterval)duration;
- (nullable CMSampleBufferRef)mixAudio;
@end

NS_ASSUME_NONNULL_END
