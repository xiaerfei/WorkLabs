//
//  WLPipelineManager.m
//  WorkLabs
//

#import "WLPipelineManager.h"
#import "WLPreviewOutput.h"
#import "WLAudioOutput.h"

@interface WLPipelineManager ()
@property (nonatomic, strong) NSMutableArray<id<WLSource>> *mutableSources;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@end

@implementation WLPipelineManager

+ (instancetype)manager {
    static WLPipelineManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[WLPipelineManager alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) { _mutableSources = [NSMutableArray array]; }
    return self;
}

- (void)addVideoSource:(id<WLVideoSource>)source {
    if ([self.mutableSources containsObject:source]) return;
    [self.mutableSources addObject:source];
    [self bindVideoSource:source];
}

- (void)addAudioSource:(id<WLAudioSource>)source {
    if ([self.mutableSources containsObject:source]) return;
    [self.mutableSources addObject:source];
    [self bindAudioSource:source];
}

- (void)removeSource:(id<WLSource>)source {
    if (self.isRunning && source.isRunning) { [source stop]; }
    [self.mutableSources removeObject:source];
}

- (NSArray<id<WLSource>> *)sources { return [self.mutableSources copy]; }

- (void)bindVideoSource:(id<WLVideoSource>)source {
    __weak typeof(self) weakSelf = self;
    source.frameOutput = ^(CVPixelBufferRef pixelBuffer, Float64 pts) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { CVPixelBufferRelease(pixelBuffer); return; }
        [strongSelf.videoOutput displayPixelBuffer:pixelBuffer pts:pts];
        CVPixelBufferRelease(pixelBuffer);
    };
}

- (void)bindAudioSource:(id<WLAudioSource>)source {
    __weak typeof(self) weakSelf = self;
    source.sampleOutput = ^(CMSampleBufferRef sampleBuffer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { CFRelease(sampleBuffer); return; }
        [strongSelf.audioOutput playSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    };
}

- (BOOL)start {
    if (self.isRunning) return YES;
    if (self.audioOutput) {
        if (![self.audioOutput start]) { NSLog(@"[WLPipelineManager] Audio output start failed"); return NO; }
    }
    for (id<WLSource> source in self.mutableSources) {
        if (![source start]) { NSLog(@"[WLPipelineManager] Source start failed: %@", source); [self stop]; return NO; }
    }
    self.running = YES;
    return YES;
}

- (void)stop {
    if (!self.isRunning) return;
    for (id<WLSource> source in self.mutableSources) {
        if (source.isRunning) { [source stop]; }
    }
    [self.audioOutput stop];
    self.running = NO;
}

@end
