//
//  WLCanvasLayout.m
//  OBSLabs
//

#import "WLCanvasLayout.h"

@interface WLCanvasLayout ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *layouts;
@property (nonatomic, strong) NSMutableArray<NSString *> *order;  // bottom → top
@end

@implementation WLCanvasLayout

- (instancetype)init {
    self = [super init];
    if (self) {
        _canvasSize = CGSizeMake(1920, 1080);
        _layouts = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
    }
    return self;
}

- (void)setLayoutRect:(CGRect)rect forSourceID:(NSString *)sid {
    if (sid.length == 0) return;
    self.layouts[sid] = [NSValue valueWithRect:rect];
    if (![self.order containsObject:sid]) {
        [self.order addObject:sid];
    }
}

- (CGRect)layoutRectForSourceID:(NSString *)sid {
    NSValue *v = self.layouts[sid];
    return v ? v.rectValue : CGRectNull;
}

- (void)removeLayoutForSourceID:(NSString *)sid {
    [self.layouts removeObjectForKey:sid];
    [self.order removeObject:sid];
}

- (void)bringToFront:(NSString *)sid {
    [self.order removeObject:sid];
    [self.order addObject:sid];
}

- (void)sendToBack:(NSString *)sid {
    [self.order removeObject:sid];
    [self.order insertObject:sid atIndex:0];
}

- (void)moveUp:(NSString *)sid {
    NSUInteger idx = [self.order indexOfObject:sid];
    if (idx == NSNotFound || idx == self.order.count - 1) return;
    [self.order exchangeObjectAtIndex:idx withObjectAtIndex:idx + 1];
}

- (void)moveDown:(NSString *)sid {
    NSUInteger idx = [self.order indexOfObject:sid];
    if (idx == NSNotFound || idx == 0) return;
    [self.order exchangeObjectAtIndex:idx withObjectAtIndex:idx - 1];
}

- (NSArray<NSString *> *)sourceOrder {
    return [self.order copy];
}

@end
