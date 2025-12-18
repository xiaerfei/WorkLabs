//
//  WLEventObserveItem.m
//  WorkLabs
//
//  Created by erfeixia on 2025/12/18.
//

#import "WLEventObserveItem.h"
#import "WLEventDisposeBag.h"
#import "WLEvent.h"

@interface WLEvent ()
- (void)_sendEvent:(WLObserve)type payload:(id)payload;
- (void)_addObserve:(WLEventObserveItem *)sub;
- (void)_removeObserve:(WLEventObserveItem *)sub;
@end

@interface WLEventDisposeBag ()
- (void)_addToken:(id)token;
@end

@interface WLEventObserveItem ()
@property (nonatomic, weak) WLEvent *eventCenter;
@property (nonatomic, copy) NSArray<NSNumber *> *mevents;
@property (nonatomic, strong, nullable) dispatch_queue_t mcallbackQueue;
@property (nonatomic, copy) void(^mblock)(WLObserve event, id payload);
@property (nonatomic, copy) NSString *mname;
@end

@implementation WLEventObserveItem
- (instancetype)initWithEvent:(WLEvent *)event {
    self = [super init];
    if (self) {
        _eventCenter = event;
    }
    return self;
}
#pragma mark - Subscribe chain

- (WLEventObserveItem *(^)(NSArray<NSNumber *> *events))observe {
    return ^WLEventObserveItem *(NSArray<NSNumber *> *events) {
        self.mevents = events ?: @[];
        return self;
    };
}

- (WLEventObserveItem *(^)(void))mainQueue {
    return ^WLEventObserveItem *{
        self.mcallbackQueue = dispatch_get_main_queue();
        return self;
    };
}

- (WLEventObserveItem *(^)(dispatch_queue_t _Nullable queue))queue {
    return ^WLEventObserveItem *(dispatch_queue_t _Nullable queue) {
        self.mcallbackQueue = queue;
        return self;
    };
}

- (WLEventObserveItem *(^)(void(^block)(WLObserve event, id payload)))block {
    return ^WLEventObserveItem *(void(^block)(WLObserve event, id payload)) {
        self.mblock = block;
        [self.eventCenter _addObserve:self];
        return self;
    };
}

- (WLEventObserveItem *(^)(WLEventDisposeBag *bag))dispose {
    return ^WLEventObserveItem *(WLEventDisposeBag *bag) {
        [bag _addToken:self];
        return self;
    };
}

- (WLEventObserveItem *(^)(NSString * _Nullable name))name {
    return ^WLEventObserveItem *(NSString * _Nullable name) {
        self.mname = name;
        return self;
    };
}

#pragma mark - Private Methods
- (void)_disposeSelf {
    [self.eventCenter _removeObserve:self];
}

@end
