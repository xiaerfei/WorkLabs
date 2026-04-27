//
//  WLMediaSourceItem.m
//  WorkLabs
//

#import "WLMediaSourceItem.h"

@interface WLMediaSourceItem ()

@property (nonatomic, copy, readwrite) NSUUID *uuid;
@property (nonatomic, assign, readwrite) WLMediaSourceType type;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;

@end

@implementation WLMediaSourceItem

- (instancetype)initWithType:(WLMediaSourceType)type name:(NSString *)name {
    self = [super init];
    if (self) {
        _uuid = [NSUUID UUID];
        _type = type;
        _name = [name copy];
        _volume = 1.0;
        _muted = NO;
        _rotation = 0.0;
        _running = NO;
        _isSelected = NO;

        switch (type) {
            case WLMediaSourceTypeAudio:
                _size = CGSizeMake(160, 120);
                break;
            case WLMediaSourceTypeCamera:
            case WLMediaSourceTypeVideo:
            default:
                _size = CGSizeMake(320, 240);
                break;
        }
        _position = CGPointZero;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)start {
    if (self.running) return;
    if ([self.sourceEngine respondsToSelector:@selector(start)]) {
        [self.sourceEngine start];
    }
    self.running = YES;
}

- (void)stop {
    if (!self.running) return;
    if ([self.sourceEngine respondsToSelector:@selector(stop)]) {
        [self.sourceEngine stop];
    }
    self.running = NO;
}

- (void)pause {
    id engine = self.sourceEngine;
    if ([engine respondsToSelector:@selector(pause)]) {
        [engine performSelector:@selector(pause)];
    }
}

- (void)resume {
    id engine = self.sourceEngine;
    if ([engine respondsToSelector:@selector(resume)]) {
        [engine performSelector:@selector(resume)];
    }
}

@end
