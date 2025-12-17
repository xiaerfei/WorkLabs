//
//  WLEventItem.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import "WLEventItem.h"
#import "WLEventSubscription.h"
#import "WLEventDisposeBag.h"
#import "WLEvent.h"

@interface WLEvent ()
- (void)_sendEvent:(WLEventType)type payload:(id)payload;
- (void)_addSubscription:(WLEventSubscription *)sub;
- (void)_removeSubscription:(WLEventSubscription *)sub;
- (void)_removeByOwner:(id)owner;
@end

@interface WLEventDisposeBag ()
- (void)_addToken:(id)token;
@end

@interface WLEventItem ()
@property (nonatomic, weak) WLEvent *eventCenter;

// send builder
@property (nonatomic, assign) WLEventType sendType;
@property (nonatomic, strong) id sendPayload;

// subscribe builder
@property (nonatomic, strong) WLEventSubscription *subscription;

// token state
@property (nonatomic, weak) WLEventDisposeBag *bag;
@end


@implementation WLEventItem
- (instancetype)initWithEvent:(WLEvent *)event {
    self = [super init];
    if (self) {
        _eventCenter = event;
    }
    return self;
}

#pragma mark - Send chain

- (WLEventItem *(^)(WLEventType type))type {
    return ^WLEventItem *(WLEventType type) {
        self.sendType = type;
        return self;
    };
}

- (WLEventItem *(^)(id payload))payload {
    return ^WLEventItem *(id payload) {
        self.sendPayload = payload;
        return self;
    };
}

- (WLEventItem *(^)(void))send {
    return ^WLEventItem *{
        [self.eventCenter _sendEvent:self.sendType payload:self.sendPayload];
        return self;
    };
}

#pragma mark - Subscribe chain

- (WLEventItem *(^)(NSArray<NSNumber *> *events))subscribe {
    return ^WLEventItem *(NSArray<NSNumber *> *events) {
        WLEventSubscription *sub = [WLEventSubscription new];
        sub.events = events ?: @[];
        sub.callbackQueue = nil;
        sub.disposed = NO;
        self.subscription = sub;
        return self;
    };
}

- (WLEventItem *(^)(id owner))owner {
    return ^WLEventItem *(id owner) {
        self.subscription.owner = owner;
        return self;
    };
}

- (WLEventItem *(^)(void))mainQueue {
    return ^WLEventItem *{
        self.subscription.callbackQueue = dispatch_get_main_queue();
        return self;
    };
}

- (WLEventItem *(^)(dispatch_queue_t _Nullable queue))queue {
    return ^WLEventItem *(dispatch_queue_t _Nullable queue) {
        self.subscription.callbackQueue = queue;
        return self;
    };
}

- (WLEventItem *(^)(void(^block)(WLEventType event, id payload)))block {
    return ^WLEventItem *(void(^block)(WLEventType event, id payload)) {
        self.subscription.block = block;
        // 完成订阅：写入中心
        if (self.subscription) {
            [self.eventCenter _addSubscription:self.subscription];
        }
        return self;
    };
}

#pragma mark - Dispose / Remove

- (WLEventItem *(^)(id owner))remove {
    return ^WLEventItem *(id owner) {
        [self.eventCenter _removeByOwner:owner];
        return self;
    };
}

- (WLEventItem *(^)(WLEventDisposeBag *bag))dispose {
    return ^WLEventItem *(WLEventDisposeBag *bag) {
        self.bag = bag;
        // bag 持有 token（即本 item），之后 bag.dealloc 触发 dispose
        [bag _addToken:self];
        return self;
    };
}

/// 供 DisposeBag 调用：释放本 item 对应的订阅
- (void)_disposeSelf {
    if (!self.subscription) return;
    self.subscription.disposed = YES;
    [self.eventCenter _removeSubscription:self.subscription];
    self.subscription = nil;
}

- (void)dealloc {
    [self _disposeSelf];
}

@end
