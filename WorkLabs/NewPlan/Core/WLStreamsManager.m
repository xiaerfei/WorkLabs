//
//  WLStreamsManager.m
//  WorkLabs
//

#import "WLStreamsManager.h"
#import "WLVideoMix.h"

@interface WLStreamsManager ()

@property (nonatomic, strong) NSMutableArray<id<WLStreamSourceProtocol>> *sources;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<WLVideoFilterProtocol>> *perStreamFilters;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<WLVideoOutputProtocol>> *previewOutputs;

@property (nonatomic, strong) WLVideoMix *mix;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;

@end

@implementation WLStreamsManager

+ (instancetype)manager {
    static WLStreamsManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[WLStreamsManager alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _canvasSize = CGSizeMake(1920, 1080);
        _sources = [NSMutableArray array];
        _perStreamFilters = [NSMutableDictionary dictionary];
        _previewOutputs = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Mix lazy init

- (WLVideoMix *)mix {
    if (!_mix) {
        _mix = [[WLVideoMix alloc] initWithCanvasSize:self.canvasSize];
        __weak typeof(self) wself = self;
        _mix.output = ^(CVPixelBufferRef pb, Float64 pts) {
            __strong typeof(wself) sself = wself;
            if (!sself) { CVPixelBufferRelease(pb); return; }
            [sself handleMixedFrame:pb pts:pts];
        };
    }
    return _mix;
}

- (void)handleMixedFrame:(CVPixelBufferRef)pb pts:(Float64)pts {
    CVPixelBufferRef toForward = pb;

    if (self.postFilter) {
        CVPixelBufferRef out = [self.postFilter processVideoFrame:pb pts:pts];
        CVPixelBufferRelease(pb);
        if (!out) return;
        toForward = out;
    }

    id<WLVideoOutputProtocol> output = self.mainPreviewOutput;
    if (output) {
        [output receiveVideoFrame:toForward pts:pts];
    }
    CVPixelBufferRelease(toForward);
}

#pragma mark - Source mgmt

- (NSString *)streamIDForSource:(id<WLStreamSourceProtocol>)source {
    return [NSString stringWithFormat:@"%p", source];
}

- (void)addSource:(id<WLStreamSourceProtocol>)source
   previewOutput:(nullable id<WLVideoOutputProtocol>)preview {
    if (!source || [self.sources containsObject:source]) return;

    source.delegate = self;
    [self.sources addObject:source];

    NSString *sid = [self streamIDForSource:source];
    if (preview) {
        self.previewOutputs[sid] = preview;

        // 浮层 Preview 拖动/缩放时自动同步到 Mix
        if ([preview conformsToProtocol:@protocol(WLStreamRenderingProtocol)]) {
            id<WLStreamRenderingProtocol> rendering = (id<WLStreamRenderingProtocol>)preview;
            rendering.delegate = self;
            [self.mix setLayoutFrame:rendering.frame forStreamID:sid];
        }
    }
}

- (void)removeSource:(id<WLStreamSourceProtocol>)source {
    if (!source) return;
    if (source.isRunning) [source stop];

    NSString *sid = [self streamIDForSource:source];
    [self.perStreamFilters removeObjectForKey:sid];
    [self.previewOutputs removeObjectForKey:sid];
    [self.mix removeStreamID:sid];

    if (source.delegate == self) {
        source.delegate = nil;
    }
    [self.sources removeObject:source];
}

- (void)setFilter:(nullable id<WLVideoFilterProtocol>)filter
        forSource:(id<WLStreamSourceProtocol>)source {
    if (!source) return;
    NSString *sid = [self streamIDForSource:source];
    if (filter) {
        self.perStreamFilters[sid] = filter;
    } else {
        [self.perStreamFilters removeObjectForKey:sid];
    }
}

- (void)setLayoutFrame:(CGRect)frame forSource:(id<WLStreamSourceProtocol>)source {
    if (!source) return;
    [self.mix setLayoutFrame:frame forStreamID:[self streamIDForSource:source]];
}

#pragma mark - Lifecycle

- (BOOL)start {
    if (self.running) return YES;
    for (id<WLStreamSourceProtocol> source in self.sources) {
        NSError *err = nil;
        if (![source start:&err]) {
            NSLog(@"[WLStreamsManager] Source start failed: %@ err=%@", source, err);
            [self stop];
            return NO;
        }
    }
    self.running = YES;
    return YES;
}

- (void)stop {
    if (!self.running) return;
    for (id<WLStreamSourceProtocol> source in self.sources) {
        if (source.isRunning) [source stop];
    }
    self.running = NO;
}

#pragma mark - WLStreamSourceDelegate (video)

- (void)source:(id<WLStreamSourceProtocol>)source
    didOutputVideoFrame:(CVPixelBufferRef)pixelBuffer
                    pts:(Float64)pts {
    if (!pixelBuffer) return;

    NSString *sid = [self streamIDForSource:source];
    if (sid.length == 0) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    // 当前所有权挂在 toFork 上
    CVPixelBufferRef toFork = pixelBuffer;

    id<WLVideoFilterProtocol> filter = self.perStreamFilters[sid];
    if (filter) {
        CVPixelBufferRef out = [filter processVideoFrame:pixelBuffer pts:pts];
        CVPixelBufferRelease(pixelBuffer);
        if (!out) return;
        toFork = out;
    }

    // Fork 1: 小预览
    id<WLVideoOutputProtocol> preview = self.previewOutputs[sid];
    if (preview) {
        [preview receiveVideoFrame:toFork pts:pts];
    }

    // Fork 2: 进入 Mix（Mix 内部会 retain）
    [self.mix inputVideoFrame:toFork pts:pts streamID:sid];

    CVPixelBufferRelease(toFork);
}

#pragma mark - WLStreamSourceDelegate (audio, 暂未接入 Preview 管线)

- (void)source:(id<WLStreamSourceProtocol>)source
    didOutputAudioBuffer:(CMSampleBufferRef)sampleBuffer {
    // Preview 管线只处理视频；音频后续接 AudioMixer 时再实现。
    if (sampleBuffer) CFRelease(sampleBuffer);
}

#pragma mark - WLStreamRenderingDelegate

- (void)rendering:(id<WLStreamRenderingProtocol>)rendering didUpdateFrame:(CGRect)frame {
    // 反查 source 并把新 layout 推给 Mix
    for (id<WLStreamSourceProtocol> source in self.sources) {
        NSString *sid = [self streamIDForSource:source];
        if (self.previewOutputs[sid] == (id)rendering) {
            [self.mix setLayoutFrame:frame forStreamID:sid];
            return;
        }
    }
}

@end
