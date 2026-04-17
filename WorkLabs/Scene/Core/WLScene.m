//
//  WLScene.m
//  WorkLabs
//

#import "WLScene.h"
#import "WLSourceView.h"

@implementation WLSourceLayout
+ (instancetype)layoutWithSource:(id<WLMediaSource>)source frame:(CGRect)frame {
    WLSourceLayout *layout = [[WLSourceLayout alloc] init];
    layout.source = source;
    layout.frame = frame;
    layout.cropTop = 0;
    layout.cropBottom = 0;
    layout.cropLeft = 0;
    layout.cropRight = 0;
    layout.volume = 1.0f;
    layout.visible = YES;
    layout.zIndex = 0;
    return layout;
}
@end

@interface WLScene ()
@property (nonatomic, strong, readwrite) NSMutableArray<id<WLMediaSource>> *sources;
@property (nonatomic, strong, readwrite) NSMutableArray<WLSourceLayout *> *sourceLayouts;
@property (nonatomic, strong, readwrite) WLMediaMixer *audioMixer;
@property (nonatomic, strong, readwrite) NSView *sceneView;
@end

@implementation WLScene

- (instancetype)initWithName:(NSString *)name canvasSize:(CGSize)size {
    self = [super init];
    if (self) {
        _name = name ?: @"Untitled Scene";
        _identifier = [[NSUUID UUID] UUIDString];
        _canvasSize = size;
        _sources = [NSMutableArray array];
        _sourceLayouts = [NSMutableArray array];
        _audioMixer = [[WLMediaMixer alloc] init];
        _sceneView = [[NSView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
    }
    return self;
}

- (void)addSource:(id<WLMediaSource>)source atRect:(CGRect)rect {
    if (!source || ![self.sources containsObject:source]) {
        [self.sources addObject:source];
        WLSourceLayout *layout = [WLSourceLayout layoutWithSource:source frame:rect];
        layout.zIndex = self.sourceLayouts.count;
        [self.sourceLayouts addObject:layout];
        [self.audioMixer addAudioSource:source];
    }
}

- (void)removeSource:(id<WLMediaSource>)source {
    if (!source) return;
    [self.sources removeObject:source];
    WLSourceLayout *layoutToRemove = nil;
    for (WLSourceLayout *layout in self.sourceLayouts) {
        if (layout.source == source) { layoutToRemove = layout; break; }
    }
    if (layoutToRemove) { [self.sourceLayouts removeObject:layoutToRemove]; }
    [self.audioMixer removeAudioSource:source];
    if ([source isRunning]) { [source stop]; }
}

- (void)updateLayoutForSource:(id<WLMediaSource>)source layout:(WLSourceLayout *)layout {
    for (WLSourceLayout *existing in self.sourceLayouts) {
        if (existing.source == source) {
            existing.frame = layout.frame;
            existing.cropTop = layout.cropTop;
            existing.cropBottom = layout.cropBottom;
            existing.cropLeft = layout.cropLeft;
            existing.cropRight = layout.cropRight;
            existing.volume = layout.volume;
            existing.visible = layout.visible;
            existing.zIndex = layout.zIndex;
            break;
        }
    }
}

- (nullable WLSourceLayout *)layoutForSource:(id<WLMediaSource>)source {
    for (WLSourceLayout *layout in self.sourceLayouts) {
        if (layout.source == source) { return layout; }
    }
    return nil;
}

- (CMSampleBufferRef)renderFrame { return nil; }

- (void)start {
    for (id<WLMediaSource> source in self.sources) {
        if (![source isRunning]) { [source start]; }
    }
}

- (void)stop {
    for (id<WLMediaSource> source in self.sources) {
        if ([source isRunning]) { [source stop]; }
    }
}

@end
