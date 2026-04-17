//
//  WLMediaSource.m
//  WorkLabs
//

#import "WLMediaSource.h"

@implementation WLBaseMediaSource

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _name = name ?: @"Unnamed Source";
        _identifier = [[NSUUID UUID] UUIDString];
        _volume = 1.0f;
        _active = YES;
        _running = NO;
        _intrinsicSize = CGSizeZero;
    }
    return self;
}

- (void)start {
    self.running = YES;
}

- (void)stop {
    self.running = NO;
}

- (nullable CMSampleBufferRef)nextVideoFrame {
    return nil;
}

- (nullable CMSampleBufferRef)nextAudioFrame {
    return nil;
}

@end
