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
/// 阻塞查看队头（不出队）：空队列时等到有数据或 abort；abort 返回 nil。无丢失唤醒。
- (nullable WLNode *)peekBlocking;
/// 等待到指定单调时刻（CLOCK_UPTIME_RAW 纳秒）或被入队/abort 提前唤醒；不出队。
- (void)waitUntilDeadlineNs:(uint64_t)deadlineNs;
- (void)abort;
- (void)flush;
- (void)requeueFront:(WLNode *)node;
- (int)count;

@end

NS_ASSUME_NONNULL_END
