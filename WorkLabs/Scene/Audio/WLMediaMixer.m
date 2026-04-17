//
//  WLMediaMixer.m
//  WorkLabs
//

#import "WLMediaMixer.h"

@implementation WLAudioSourceConfig
+ (instancetype)configWithSource:(id<WLMediaSource>)source volume:(float)volume {
    WLAudioSourceConfig *config = [[WLAudioSourceConfig alloc] init];
    config.source = source;
    config.volume = volume;
    config.muted = NO;
    return config;
}
@end

@interface WLMediaMixer ()
@property (nonatomic, strong, readwrite) NSMutableArray<WLAudioSourceConfig *> *audioSources;
@end

@implementation WLMediaMixer

- (instancetype)init {
    self = [super init];
    if (self) {
        _audioSources = [NSMutableArray array];
        _masterVolume = 1.0f;
    }
    return self;
}

- (void)addAudioSource:(id<WLMediaSource>)source {
    if (!source) return;
    for (WLAudioSourceConfig *config in self.audioSources) {
        if (config.source == source) { return; }
    }
    WLAudioSourceConfig *config = [WLAudioSourceConfig configWithSource:source volume:source.volume];
    [self.audioSources addObject:config];
}

- (void)removeAudioSource:(id<WLMediaSource>)source {
    WLAudioSourceConfig *configToRemove = nil;
    for (WLAudioSourceConfig *config in self.audioSources) {
        if (config.source == source) { configToRemove = config; break; }
    }
    if (configToRemove) { [self.audioSources removeObject:configToRemove]; }
}

- (void)setVolume:(float)volume forSource:(id<WLMediaSource>)source {
    for (WLAudioSourceConfig *config in self.audioSources) {
        if (config.source == source) { config.volume = MAX(0.0f, MIN(1.0f, volume)); break; }
    }
}

- (float)volumeForSource:(id<WLMediaSource>)source {
    for (WLAudioSourceConfig *config in self.audioSources) {
        if (config.source == source) { return config.muted ? 0.0f : config.volume; }
    }
    return 0.0f;
}

- (void)setMuted:(BOOL)muted forSource:(id<WLMediaSource>)source {
    for (WLAudioSourceConfig *config in self.audioSources) {
        if (config.source == source) { config.muted = muted; break; }
    }
}

- (void)fadeInSource:(id<WLMediaSource>)source duration:(NSTimeInterval)duration { [self setMuted:NO forSource:source]; }
- (void)fadeOutSource:(id<WLMediaSource>)source duration:(NSTimeInterval)duration { [self setMuted:YES forSource:source]; }

- (nullable CMSampleBufferRef)mixAudio {
    NSMutableArray<CMSampleBufferRef> *frames = [NSMutableArray array];
    for (WLAudioSourceConfig *config in self.audioSources) {
        if (!config.muted && config.source.isActive && config.source.isRunning) {
            CMSampleBufferRef frame = [config.source nextAudioFrame];
            if (frame) { [frames addObject:frame]; }
        }
    }
    return frames.count == 1 ? frames.firstObject : nil;
}

@end
