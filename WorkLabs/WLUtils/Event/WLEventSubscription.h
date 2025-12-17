//
//  WLEventSubscription.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import <Foundation/Foundation.h>
#import "WLEventConst.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLEventSubscription : NSObject
@property (nonatomic, copy) NSArray<NSNumber *> *events;
@property (nonatomic, weak) id owner;
@property (nonatomic, strong, nullable) dispatch_queue_t callbackQueue; // nil 表示当前线程/直接调用
@property (nonatomic, copy) void(^block)(WLEventType event, id payload);
@property (nonatomic, assign) BOOL disposed;
@end

NS_ASSUME_NONNULL_END
