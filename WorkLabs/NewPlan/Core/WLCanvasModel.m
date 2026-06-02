//
//  WLCanvasModel.m
//  WorkLabs
//

#import "WLCanvasModel.h"

@interface WLCanvasModel ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *layouts;
@property (nonatomic, strong) NSMutableArray<NSString *> *mutableOrder;
@end

@implementation WLCanvasModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _canvasSize = CGSizeMake(1920, 1080);
        _layouts = [NSMutableDictionary dictionary];
        _mutableOrder = [NSMutableArray array];
    }
    return self;
}

- (void)setLayoutFrame:(CGRect)frame forStreamID:(NSString *)streamID {
    if (streamID.length == 0) return;
    self.layouts[streamID] = [NSValue valueWithRect:frame];
}

- (CGRect)layoutFrameForStreamID:(NSString *)streamID {
    NSValue *v = self.layouts[streamID];
    return v ? v.rectValue : CGRectNull;
}

- (NSArray<NSString *> *)streamOrder {
    return [self.mutableOrder copy];
}

- (void)addStreamID:(NSString *)streamID {
    if (streamID.length == 0) return;
    if (![self.mutableOrder containsObject:streamID]) {
        [self.mutableOrder addObject:streamID];
    }
}

- (void)removeStreamID:(NSString *)streamID {
    if (streamID.length == 0) return;
    [self.mutableOrder removeObject:streamID];
    [self.layouts removeObjectForKey:streamID];
}

@end
