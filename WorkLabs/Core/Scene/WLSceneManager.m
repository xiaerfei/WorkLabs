//
//  WLSceneManager.m
//  WorkLabs
//

#import "WLSceneManager.h"
#import "WLMediaSourceItem.h"
#import "WLCameraSource.h"
#import "WLCameraSourceConfig.h"
#import "WLMediaSource.h"
#import "WLEvent.h"
#import "WLPipelineManager.h"

@interface WLSceneManager ()

@property (nonatomic, strong) NSMutableArray<WLMediaSourceItem *> *mutableSources;
@property (nonatomic, strong, readwrite, nullable) WLMediaSourceItem *selectedSource;

@end

@implementation WLSceneManager

#pragma mark - Singleton

+ (instancetype)manager {
    static WLSceneManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[WLSceneManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableSources = [NSMutableArray array];
        _outputResolution = WLOutputResolution1080p;
    }
    return self;
}

#pragma mark - 输出分辨率

+ (CGSize)sizeForResolution:(WLOutputResolution)resolution {
    switch (resolution) {
        case WLOutputResolution360p:  return CGSizeMake(640, 360);
        case WLOutputResolution540p:  return CGSizeMake(960, 540);
        case WLOutputResolution720p:  return CGSizeMake(1280, 720);
        case WLOutputResolution1080p: return CGSizeMake(1920, 1080);
        case WLOutputResolution1440p: return CGSizeMake(2560, 1440);
        case WLOutputResolution4K:    return CGSizeMake(3840, 2160);
    }
}

+ (NSArray<NSNumber *> *)availableResolutions {
    return @[
        @(WLOutputResolution360p),
        @(WLOutputResolution540p),
        @(WLOutputResolution720p),
        @(WLOutputResolution1080p),
        @(WLOutputResolution1440p),
        @(WLOutputResolution4K),
    ];
}

+ (NSString *)displayNameForResolution:(WLOutputResolution)resolution {
    switch (resolution) {
        case WLOutputResolution360p:  return @"640x360 (360p)";
        case WLOutputResolution540p:  return @"960x540 (540p)";
        case WLOutputResolution720p:  return @"1280x720 (720p)";
        case WLOutputResolution1080p: return @"1920x1080 (1080p)";
        case WLOutputResolution1440p: return @"2560x1440 (1440p)";
        case WLOutputResolution4K:    return @"3840x2160 (4K)";
    }
}

- (void)setOutputResolution:(WLOutputResolution)outputResolution {
    if (_outputResolution == outputResolution) return;
    _outputResolution = outputResolution;
    WLSend().type(WLObserveSourceChange).payload(@{
        @"action": @"resolutionChange",
        @"resolution": @(outputResolution)
    }).send();
}

#pragma mark - 源管理 (只读)

- (NSArray<WLMediaSourceItem *> *)sources {
    return [self.mutableSources copy];
}

#pragma mark - 添加源

- (WLMediaSourceItem *)addCameraSourceWithConfig:(WLCameraSourceConfig *)config {
    WLMediaSourceItem *item = [[WLMediaSourceItem alloc] initWithType:WLMediaSourceTypeCamera
                                                                  name:config.device.localizedName];
    item.zOrder = self.mutableSources.count;

    WLCameraSource *cameraSource = [[WLCameraSource alloc] initWithConfig:config];
    item.sourceEngine = cameraSource;

    cameraSource.frameOutput = ^(CVPixelBufferRef pixelBuffer, Float64 pts) {
        // 帧回调 — 后续由 WLMediaSourcePreview 消费
    };

    [self.mutableSources addObject:item];
    [item start];

    WLSend().type(WLObserveSourceChange).payload(@{
        @"action": @"add",
        @"item": item
    }).send();

    return item;
}

- (WLMediaSourceItem *)addVideoSourceWithPath:(NSString *)path {
    NSString *name = [path lastPathComponent];
    WLMediaSourceItem *item = [[WLMediaSourceItem alloc] initWithType:WLMediaSourceTypeVideo
                                                                  name:name];
    item.zOrder = self.mutableSources.count;

    WLMediaSource *mediaSource = [[WLMediaSource alloc] initWithPath:path];
    item.sourceEngine = mediaSource;

    // 接入 WLPipelineManager
    WLPipelineManager *pipeline = [WLPipelineManager manager];
    [pipeline addVideoSource:mediaSource];
    [pipeline addAudioSource:mediaSource];

    [self.mutableSources addObject:item];
    [item start];

    WLSend().type(WLObserveSourceChange).payload(@{
        @"action": @"add",
        @"item": item
    }).send();

    return item;
}

- (WLMediaSourceItem *)addAudioSourceWithPath:(NSString *)path {
    NSString *name = [path lastPathComponent];
    WLMediaSourceItem *item = [[WLMediaSourceItem alloc] initWithType:WLMediaSourceTypeAudio
                                                                  name:name];
    item.zOrder = self.mutableSources.count;

    WLMediaSource *mediaSource = [[WLMediaSource alloc] initWithPath:path];
    item.sourceEngine = mediaSource;
    [self.mutableSources addObject:item];
    [item start];

    WLSend().type(WLObserveSourceChange).payload(@{
        @"action": @"add",
        @"item": item
    }).send();

    return item;
}

#pragma mark - 移除源

- (void)removeSource:(WLMediaSourceItem *)item {
    if (!item) return;
    NSUInteger index = [self.mutableSources indexOfObject:item];
    if (index == NSNotFound) return;
    [self removeSourceAtIndex:index];
}

- (void)removeSourceAtIndex:(NSUInteger)index {
    if (index >= self.mutableSources.count) return;

    WLMediaSourceItem *item = self.mutableSources[index];

    // 从 WLPipelineManager 移除
    if ([item.sourceEngine conformsToProtocol:@protocol(WLSource)]) {
        [[WLPipelineManager manager] removeSource:(id<WLSource>)item.sourceEngine];
    }

    [item stop];

    if (self.selectedSource == item) {
        self.selectedSource = nil;
    }

    [self.mutableSources removeObjectAtIndex:index];

    WLSend().type(WLObserveSourceChange).payload(@{
        @"action": @"remove",
        @"index": @(index)
    }).send();
}

#pragma mark - 选择

- (void)selectSource:(nullable WLMediaSourceItem *)item {
    if (self.selectedSource == item) return;

    self.selectedSource.isSelected = NO;
    self.selectedSource = item;
    item.isSelected = YES;

    WLSend().type(WLObserveSourceChange).payload(@{
        @"action": @"select",
        @"item": item ?: [NSNull null]
    }).send();
}

- (void)deselectAll {
    [self selectSource:nil];
}

#pragma mark - 排序

- (void)moveSourceAtIndex:(NSUInteger)from toIndex:(NSUInteger)to {
    if (from >= self.mutableSources.count || to >= self.mutableSources.count) return;
    if (from == to) return;

    WLMediaSourceItem *item = self.mutableSources[from];
    [self.mutableSources removeObjectAtIndex:from];
    [self.mutableSources insertObject:item atIndex:to];

    // 更新 zOrder
    for (NSUInteger i = 0; i < self.mutableSources.count; i++) {
        self.mutableSources[i].zOrder = i;
    }
}

#pragma mark - 全局控制

- (void)startAll {
    for (WLMediaSourceItem *item in self.mutableSources) {
        [item start];
    }
}

- (void)stopAll {
    for (WLMediaSourceItem *item in self.mutableSources) {
        [item stop];
    }
}

@end
