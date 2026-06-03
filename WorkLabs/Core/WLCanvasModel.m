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

- (void)bringStreamIDToFront:(NSString *)streamID {
    if (![self.mutableOrder containsObject:streamID]) return;
    [self.mutableOrder removeObject:streamID];
    [self.mutableOrder addObject:streamID];
}

- (void)sendStreamIDToBack:(NSString *)streamID {
    if (![self.mutableOrder containsObject:streamID]) return;
    [self.mutableOrder removeObject:streamID];
    [self.mutableOrder insertObject:streamID atIndex:0];
}

- (void)moveStreamIDUp:(NSString *)streamID {
    NSUInteger i = [self.mutableOrder indexOfObject:streamID];
    if (i == NSNotFound || i + 1 >= self.mutableOrder.count) return;
    [self.mutableOrder exchangeObjectAtIndex:i withObjectAtIndex:i + 1];
}

- (void)moveStreamIDDown:(NSString *)streamID {
    NSUInteger i = [self.mutableOrder indexOfObject:streamID];
    if (i == NSNotFound || i == 0) return;
    [self.mutableOrder exchangeObjectAtIndex:i withObjectAtIndex:i - 1];
}

@end
