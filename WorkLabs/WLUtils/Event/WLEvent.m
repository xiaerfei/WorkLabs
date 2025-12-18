//
//  WLEvent.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import "WLEvent.h"

@interface WLEventObserveItem ()
@property (nonatomic, copy) NSArray<NSNumber *> *mevents;
@property (nonatomic, strong, nullable) dispatch_queue_t mcallbackQueue;
@property (nonatomic, copy) void(^mblock)(WLObserve event, id payload);
@property (nonatomic, copy) NSString *mname;
@end

@interface WLEvent ()
@property (nonatomic, strong) dispatch_queue_t isolationQueue; // 并发 + barrier
@property (nonatomic, strong) NSMutableArray<WLEventObserveItem *> *subscriptions;
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

- (WLEventSendItem *)subscribe {
    return [[WLEventSendItem alloc] initWithEvent:self];
}

- (WLEventSendItem *)send {
    return [[WLEventSendItem alloc] initWithEvent:self];
}

- (WLEventObserveItem *)observe {
    return [[WLEventObserveItem alloc] initWithEvent:self];
}

- (void)removeObserve:(id)observe {
    if (!observe) return;
    dispatch_barrier_async(self.isolationQueue, ^{
        [self.subscriptions removeObject:observe];
    });
}

#pragma mark - internal

- (void)_addObserve:(WLEventObserveItem *)sub {
    if (!sub) return;
    dispatch_barrier_async(self.isolationQueue, ^{
        [self.subscriptions addObject:sub];
    });
}

- (void)_removeObserve:(WLEventObserveItem *)sub {
    if (!sub) return;
    dispatch_barrier_async(self.isolationQueue, ^{
        [self.subscriptions removeObject:sub];
    });
}

- (void)_sendEvent:(WLObserve)type payload:(id)payload {
    // 快照，避免回调中修改订阅导致崩溃
    __block NSArray<WLEventObserveItem *> *snapshot = nil;
    dispatch_sync(self.isolationQueue, ^{
        snapshot = [self.subscriptions copy];
    });

    for (WLEventObserveItem *sub in snapshot) {
        BOOL match = NO;
        for (NSNumber *n in sub.mevents) {
            if (n.unsignedIntegerValue == type) {
                match = YES;
                break;
            }
        }
        if (!match) continue;

        void (^invoke)(void) = ^{
            if (sub.mblock) sub.mblock(type, payload);
        };

        if (sub.mcallbackQueue) {
            dispatch_async(sub.mcallbackQueue, invoke);
        } else {
            invoke();
        }
    }
}

@end
