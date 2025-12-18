//
//  WLEvent.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import <Foundation/Foundation.h>
#import "WLEventObserveItem.h"
#import "WLEventDisposeBag.h"
#import "WLEventSendItem.h"
#import "WLEventConst.h"

#define WLSend() [[WLEvent event] send]

#define WLObserve(Events) [[WLEvent event] observe].observe(Events)

NS_ASSUME_NONNULL_BEGIN
@interface WLEvent : NSObject

+ (instancetype)event;

- (WLEventSendItem *)send;
- (WLEventObserveItem *)observe;

- (void)removeObserve:(id)observe;

@end
NS_ASSUME_NONNULL_END
