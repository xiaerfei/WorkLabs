//
//  WLEventSendItem.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import "WLEventSendItem.h"
#import "WLEventDisposeBag.h"
#import "WLEvent.h"

@interface WLEvent ()
- (void)_sendEvent:(WLObserve)type payload:(id)payload;
@end

@interface WLEventDisposeBag ()
- (void)_addToken:(id)token;
@end

@interface WLEventSendItem ()
@property (nonatomic, weak) WLEvent *eventCenter;

// send builder
@property (nonatomic, assign) WLObserve sendType;
@property (nonatomic, strong) id sendPayload;
// token state
@property (nonatomic, weak) WLEventDisposeBag *bag;
@end


@implementation WLEventSendItem
- (instancetype)initWithEvent:(WLEvent *)event {
    self = [super init];
    if (self) {
        _eventCenter = event;
    }
    return self;
}

#pragma mark - Send chain

- (WLEventSendItem *(^)(WLObserve type))type {
    return ^WLEventSendItem *(WLObserve type) {
        self.sendType = type;
        return self;
    };
}

- (WLEventSendItem *(^)(id payload))payload {
    return ^WLEventSendItem *(id payload) {
        self.sendPayload = payload;
        return self;
    };
}

- (WLEventSendItem *(^)(void))send {
    return ^WLEventSendItem *{
        [self.eventCenter _sendEvent:self.sendType payload:self.sendPayload];
        return self;
    };
}

@end
