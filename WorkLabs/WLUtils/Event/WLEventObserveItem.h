//
//  WLEventObserveItem.h
//  WorkLabs
//
//  Created by erfeixia on 2025/12/18.
//

#import <Foundation/Foundation.h>
#import "WLEventConst.h"

NS_ASSUME_NONNULL_BEGIN

@class WLEventDisposeBag, WLEvent;

@interface WLEventObserveItem : NSObject

- (instancetype)initWithEvent:(WLEvent *)event;

- (WLEventObserveItem *(^)(NSArray <NSNumber *>*events))observe;
- (WLEventObserveItem *(^)(void))mainQueue;
- (WLEventObserveItem *(^)(dispatch_queue_t _Nullable queue))queue;
- (WLEventObserveItem *(^)(void(^block)(WLObserve event, id payload)))block;
- (WLEventObserveItem *(^)(WLEventDisposeBag * _Nullable bag))dispose;
- (WLEventObserveItem *(^)(NSString * _Nullable name))name;
@end

NS_ASSUME_NONNULL_END
