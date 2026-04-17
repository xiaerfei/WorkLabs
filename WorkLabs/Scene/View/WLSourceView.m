//
//  WLSourceView.m
//  WorkLabs
//

#import "WLSourceView.h"
#import <AVFoundation/AVFoundation.h>

@interface WLSourceView ()
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@end

@implementation WLSourceView

- (instancetype)initWithSource:(id<WLMediaSource>)source frame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _source = source;
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        _displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
        _displayLayer.frame = self.bounds;
        _displayLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        [self.layer addSublayer:_displayLayer];
        self.layer.borderColor = [NSColor lightGrayColor].CGColor;
        self.layer.borderWidth = 1.0;
    }
    return self;
}

- (void)renderWithSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) { return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.displayLayer isReadyForMoreMediaData]) {
            [self.displayLayer enqueueSampleBuffer:sampleBuffer];
        }
    });
}

- (void)clearFrame {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.displayLayer flushAndRemoveImage];
    });
}

- (void)layout {
    [super layout];
    self.displayLayer.frame = self.bounds;
}

@end
