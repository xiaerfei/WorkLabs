//
//  WLEvent.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import "WLEvent.h"


@interface WLEvent ()
@property (nonatomic, strong) dispatch_queue_t isolationQueue; // 并发 + barrier
@property (nonatomic, strong) NSMutableArray<WLEventSubscription *> *subscriptions;
@end

#pragma mark - WLEvent
@implementation WLEvent

+ (instancetype)event {
    static WLEvent *e;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        e = [[WLEvent alloc] init];
    });
    return e;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isolationQueue = dispatch_queue_create("com.wl.event.isolation", DISPATCH_QUEUE_CONCURRENT);
        _subscriptions = [NSMutableArray array];
    }
    return self;
}

- (WLEventItem *)subscribe {
    return [[WLEventItem alloc] initWithEvent:self];
}

- (void)removeOwner:(id)owner {
    [self _removeByOwner:owner];
}
#pragma mark - internal

- (void)_addSubscription:(WLEventSubscription *)sub {
    if (!sub) return;
    dispatch_barrier_async(self.isolationQueue, ^{
        [self.subscriptions addObject:sub];
    });
}

- (void)_removeSubscription:(WLEventSubscription *)sub {
    if (!sub) return;
    dispatch_barrier_async(self.isolationQueue, ^{
        [self.subscriptions removeObject:sub];
    });
}

- (void)_removeByOwner:(id)owner {
    if (!owner) return;
    dispatch_barrier_async(self.isolationQueue, ^{
        NSIndexSet *set = [self.subscriptions indexesOfObjectsPassingTest:^BOOL(WLEventSubscription * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            return obj.owner == owner;
        }];
        if (set.count) {
            [self.subscriptions removeObjectsAtIndexes:set];
        }
    });
}

- (void)_sendEvent:(WLEventType)type payload:(id)payload {
    // 快照，避免回调中修改订阅导致崩溃
    __block NSArray<WLEventSubscription *> *snapshot = nil;
    dispatch_sync(self.isolationQueue, ^{
        snapshot = [self.subscriptions copy];
    });

    for (WLEventSubscription *sub in snapshot) {
        if (sub.disposed) continue;

        // owner 已释放则自动清理（延后 barrier 清理）
        if (sub.owner == nil) {
            [self _removeSubscription:sub];
            continue;
        }

        BOOL match = NO;
        for (NSNumber *n in sub.events) {
            if (n.unsignedIntegerValue == type) {
                match = YES;
                break;
            }
        }
        if (!match) continue;

        void (^invoke)(void) = ^{
            if (sub.disposed) return;
            if (sub.block) sub.block(type, payload);
        };

        if (sub.callbackQueue) {
            dispatch_async(sub.callbackQueue, invoke);
        } else {
            invoke();
        }
    }
}

@end
