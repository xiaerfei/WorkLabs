//
//  WLEventItem.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import <Foundation/Foundation.h>
#import "WLEventConst.h"

NS_ASSUME_NONNULL_BEGIN

@class WLEventDisposeBag, WLEvent;

@interface WLEventItem : NSObject
- (instancetype)initWithEvent:(WLEvent *)event;

- (WLEventItem *(^)(WLEventType type))type;
- (WLEventItem *(^)(id payload))payload;
- (WLEventItem *(^)(void))send;


- (WLEventItem *(^)(NSArray <NSNumber *>*events))subscribe;
- (WLEventItem *(^)(id owner))owner;
- (WLEventItem *(^)(void))mainQueue;
- (WLEventItem *(^)(dispatch_queue_t _Nullable queue))queue;
- (WLEventItem *(^)(void(^block)(WLEventType event, id payload)))block;

- (WLEventItem *(^)(WLEventDisposeBag *bag))dispose;
@end

NS_ASSUME_NONNULL_END
