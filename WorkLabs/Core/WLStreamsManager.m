//
//  WLStreamsManager.m
//  WorkLabs
//

#import "WLStreamsManager.h"
#import "WLVideoMix.h"
#import "WLAudioRenderer.h"
#import "WLAudioMixer.h"

@interface WLStreamsManager ()

@property (nonatomic, strong, readwrite) WLCanvasModel *canvas;
@property (nonatomic, strong) NSMutableArray<id<WLStreamSourceProtocol>> *sources;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<WLVideoFilterProtocol>> *perStreamFilters;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<WLVideoOutputProtocol>> *previewOutputs;

@property (nonatomic, strong) WLVideoMix *mix;
@property (nonatomic, strong) WLAudioRenderer *audioRenderer;
@property (nonatomic, strong) WLAudioMixer *mixer;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;

@end

@implementation WLStreamsManager

- (instancetype)initWithCanvas:(WLCanvasModel *)canvas {
    self = [super init];
    if (self) {
        _canvas = canvas ?: [[WLCanvasModel alloc] init];
        _sources = [NSMutableArray array];
        _perStreamFilters = [NSMutableDictionary dictionary];
        _previewOutputs = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)init {
    return [self initWithCanvas:[[WLCanvasModel alloc] init]];
}

#pragma mark - Mix lazy init

- (WLVideoMix *)mix {
    if (!_mix) {
        _mix = [[WLVideoMix alloc] initWithCanvasSize:self.canvas.canvasSize];
        [_mix setBackgroundColor:self.canvas.backgroundColor];
        [_mix setBackgroundImage:self.canvas.backgroundImage];
        __weak typeof(self) wself = self;
        _mix.output = ^(CVPixelBufferRef pb, Float64 pts) {
            __strong typeof(wself) sself = wself;
            if (!sself) { CVPixelBufferRelease(pb); return; }
            if (sself.mixedFrameOutput) {
                sself.mixedFrameOutput(pb, pts); // 所有权转移给 block
            } else {
                CVPixelBufferRelease(pb);
            }
        };
    }
    return _mix;
}

- (WLAudioRenderer *)audioRenderer {
    if (!_audioRenderer) {
        _audioRenderer = [[WLAudioRenderer alloc] init];
    }
    return _audioRenderer;
}

- (WLAudioMixer *)mixer {
    if (!_mixer) {
        _mixer = [[WLAudioMixer alloc] init];
        __weak typeof(self) wself = self;
        _mixer.mixedOutput = ^(CMSampleBufferRef sb) {
            __strong typeof(wself) sself = wself;
            if (!sself) { CFRelease(sb); return; }
            [sself.audioRenderer enqueueSampleBuffer:sb];           // 播放
            if (sself.audioBufferOutput) sself.audioBufferOutput(sb); // 录制（借用）
            CFRelease(sb);                                          // mixer 转移所有权
        };
        [_mixer start];
    }
    return _mixer;
}

#pragma mark - Source mgmt

- (NSString *)streamIDForSource:(id<WLStreamSourceProtocol>)source {
    return [NSString stringWithFormat:@"%p", source];
}

- (NSString *)addSource:(id<WLStreamSourceProtocol>)source
          previewOutput:(nullable id<WLVideoOutputProtocol>)preview {
    if (!source) return @"";
    NSString *sid = [self streamIDForSource:source];
    if ([self.sources containsObject:source]) return sid;

    source.delegate = self;
    [self.sources addObject:source];
    [self.mixer addInput:sid];   // 所有源汇入音频混音（无音频则该路恒空，混音时跳过）

    // 纯音频源（如 Mic）不参与画布合成
    if (source.streamType == WLNodeTypeAudio) {
        return sid;
    }

    [self.canvas addStreamID:sid];

    if (preview) {
        self.previewOutputs[sid] = preview;
    }

    // 初始 layout：缺省铺满画布
    CGRect layout = [self.canvas layoutFrameForStreamID:sid];
    if (CGRectIsNull(layout)) {
        layout = CGRectMake(0, 0, self.canvas.canvasSize.width, self.canvas.canvasSize.height);
        [self.canvas setLayoutFrame:layout forStreamID:sid];
    }
    [self.mix setLayoutFrame:layout forStreamID:sid];
    [self.mix setStreamOrder:self.canvas.streamOrder];
    return sid;
}

- (void)removeSource:(id<WLStreamSourceProtocol>)source {
    if (!source) return;
    if (source.isRunning) [source stop];

    NSString *sid = [self streamIDForSource:source];
    [self.mixer removeInput:sid];
    [self.perStreamFilters removeObjectForKey:sid];
    [self.previewOutputs removeObjectForKey:sid];
    if (source.streamType != WLNodeTypeAudio) {
        [self.canvas removeStreamID:sid];
        [self.mix removeStreamID:sid];
        [self.mix setStreamOrder:self.canvas.streamOrder];
    }

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

#pragma mark - Layout / Background

- (void)setLayoutFrame:(CGRect)frame forStreamID:(NSString *)streamID {
    if (streamID.length == 0) return;
    [self.canvas setLayoutFrame:frame forStreamID:streamID];
    [self.mix setLayoutFrame:frame forStreamID:streamID];
}

- (void)setBackgroundColor:(nullable NSColor *)color {
    self.canvas.backgroundColor = color;
    [self.mix setBackgroundColor:color];
}

- (void)setBackgroundImage:(nullable NSImage *)image {
    self.canvas.backgroundImage = image;
    [self.mix setBackgroundImage:image];
}

- (void)setCanvasSize:(CGSize)canvasSize {
    if (canvasSize.width <= 0 || canvasSize.height <= 0) return;
    CGSize old = self.canvas.canvasSize;
    if (CGSizeEqualToSize(old, canvasSize)) return;

    // 按新旧尺寸比例缩放各路 layout，保持相对布局
    CGFloat sx = canvasSize.width / old.width;
    CGFloat sy = canvasSize.height / old.height;
    for (NSString *sid in self.canvas.streamOrder) {
        CGRect l = [self.canvas layoutFrameForStreamID:sid];
        if (CGRectIsNull(l)) continue;
        CGRect nl = CGRectMake(l.origin.x * sx, l.origin.y * sy,
                               l.size.width * sx, l.size.height * sy);
        [self.canvas setLayoutFrame:nl forStreamID:sid];
        [self.mix setLayoutFrame:nl forStreamID:sid];
    }

    self.canvas.canvasSize = canvasSize;
    [self.mix updateCanvasSize:canvasSize];
}

#pragma mark - Z-order（同步 canvas + mix）

- (void)bringStreamToFront:(NSString *)streamID {
    if (streamID.length == 0) return;
    [self.canvas bringStreamIDToFront:streamID];
    [self.mix setStreamOrder:self.canvas.streamOrder];
}

- (void)sendStreamToBack:(NSString *)streamID {
    if (streamID.length == 0) return;
    [self.canvas sendStreamIDToBack:streamID];
    [self.mix setStreamOrder:self.canvas.streamOrder];
}

- (void)moveStreamUp:(NSString *)streamID {
    if (streamID.length == 0) return;
    [self.canvas moveStreamIDUp:streamID];
    [self.mix setStreamOrder:self.canvas.streamOrder];
}

- (void)moveStreamDown:(NSString *)streamID {
    if (streamID.length == 0) return;
    [self.canvas moveStreamIDDown:streamID];
    [self.mix setStreamOrder:self.canvas.streamOrder];
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
    [_audioRenderer stop];
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

    // Fork 1: Render 画布预览
    id<WLVideoOutputProtocol> preview = self.previewOutputs[sid];
    if (preview) {
        [preview receiveVideoFrame:toFork pts:pts];
    }

    // Fork 2: 进入 Mix（Mix 内部会 retain）
    [self.mix inputVideoFrame:toFork pts:pts streamID:sid];

    CVPixelBufferRelease(toFork);
}

#pragma mark - WLStreamSourceDelegate (audio, 本阶段单路播放)

- (void)source:(id<WLStreamSourceProtocol>)source
    didOutputAudioBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;
    // 汇入混音器对应输入；播放/录制由 mixer.mixedOutput 统一驱动
    [self.mixer writeSampleBuffer:sampleBuffer forInput:[self streamIDForSource:source]];
    CFRelease(sampleBuffer);
}

@end
