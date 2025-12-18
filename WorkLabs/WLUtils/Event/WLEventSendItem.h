//
//  WLEventSendItem.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import <Foundation/Foundation.h>
#import "WLEventConst.h"

NS_ASSUME_NONNULL_BEGIN

@class WLEventDisposeBag, WLEvent;

@interface WLEventSendItem : NSObject

- (instancetype)initWithEvent:(WLEvent *)event;

- (WLEventSendItem *(^)(WLObserve type))type;
- (WLEventSendItem *(^)(id payload))payload;
- (WLEventSendItem *(^)(void))send;

@end

NS_ASSUME_NONNULL_END
