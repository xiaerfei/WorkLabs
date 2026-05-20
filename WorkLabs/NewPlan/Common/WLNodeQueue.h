//
//  WLNodeQueue.h
//  WorkLabs
//
//  NewPlan 线程安全队列（从 Core/Queue/WLNodeQueue 迁入）
//

#import <Foundation/Foundation.h>
#import "WLNode.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLNodeQueue : NSObject

@property (nonatomic, assign, readonly) WLNodeType type;
@property (nonatomic, assign, readonly) NSInteger nodeSize;
@property (nonatomic, assign) NSInteger allSize;
@property (nonatomic, assign, readonly) BOOL abortRequest;
@property (nonatomic, copy, nullable) NSString *queueName;
@property (nonatomic, strong) WLNode *head;
@property (nonatomic, strong) WLNode *tail;

- (instancetype)initWithType:(WLNodeType)type size:(int)size;
- (void)enQueue:(WLNode *)node;
- (BOOL)enQueueNonBlocking:(WLNode *)node;
- (nullable WLNode *)deQueueWithBlock:(BOOL)block;
- (nullable WLNode *)deQueueWithTimeout:(int)milliseconds;
- (nullable WLNode *)peek;
- (void)abort;
- (void)flush;
- (void)requeueFront:(WLNode *)node;
- (int)count;

@end

NS_ASSUME_NONNULL_END
