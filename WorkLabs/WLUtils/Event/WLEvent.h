//
//  WLEvent.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import <Foundation/Foundation.h>
#import "WLEventSubscription.h"
#import "WLEventDisposeBag.h"
#import "WLEventConst.h"
#import "WLEventItem.h"

NS_ASSUME_NONNULL_BEGIN
@interface WLEvent : NSObject

+ (instancetype)event;

- (WLEventItem *)subscribe;

/*
 发送：
 WLEventObserve()
    .type(WLEventTypeVideoDeviceChange)
    .payload(@[])
    .send();
 */


/*
 订阅
 
 WLEventDisposeBag *bag = WLEventDisposeBag.new;
 
 WLEventObserve()
    .subscribe(@[])
    .owner(self)
    .mainQueue()
    .dispose(bag)
    .block(^(WLEventType type, id payload) {

    });
 */

- (void)removeOwner:(id)owner;

@end
NS_ASSUME_NONNULL_END
