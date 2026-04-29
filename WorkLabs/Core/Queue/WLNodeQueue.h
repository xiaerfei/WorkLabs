//
//  WLNodeQueue.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import <Foundation/Foundation.h>
#import "WLNode.h"

NS_ASSUME_NONNULL_BEGIN

/**
 WLNodeQueue: 基于 pthread 的音视频解码数据同步队列
 采用 IJKPlayer/ffplay 的 abort_request 机制，确保线程安全退出。
 */
@interface WLNodeQueue : NSObject

/// 队列存储的数据类型（视频/音频）
@property (nonatomic, assign, readonly) WLNodeType type;

/// 队列当前存储的节点数量
@property (nonatomic, assign, readonly) NSInteger nodeSize;

/// 队列允许的最大容量（通常视频设为 30-60，音频设为 100+）
@property (nonatomic, assign) NSInteger allSize;

/// 中止请求标志。一旦为 YES，所有阻塞的 enQueue/deQueue 将立即返回。
@property (nonatomic, assign, readonly) BOOL abortRequest;

/// 队列调试名称
@property (nonatomic, copy, nullable) NSString *queueName;

@property (nonatomic, strong) WLNode *head;
@property (nonatomic, strong) WLNode *tail;

/**
 初始化队列
 @param type 节点类型
 @param size 最大容量上限
 */
- (instancetype)initWithType:(WLNodeType)type size:(int)size;

/**
 入队（生产）：如果队列满则阻塞，直到有空间或 abortRequest 为 YES。
 @param node 待入队节点。若 abortRequest 为 YES，方法内部会自动 flush 该 node。
 */
- (void)enQueue:(WLNode *)node;

/**
 非阻塞入队：如果队列满则丢弃最旧的帧，然后添加新帧
 @param node 待入队节点
 @return 是否成功入队（队列满时丢弃旧帧也算成功）
 */
- (BOOL)enQueueNonBlocking:(WLNode *)node;

/**
 出队（消费）：从队头获取节点。
 @param block 是否阻塞。若为 YES 且队列为空，则挂起线程直到有数据或被中止。
 @return 成功返回节点，中止或非阻塞且为空时返回 nil。
 */
- (nullable WLNode *)deQueueWithBlock:(BOOL)block;

/**
 带超时的阻塞出队。队列为空时阻塞等待，超时后返回 nil。
 若期间队列被 flush，pthread_cond_broadcast 会提前唤醒并返回 nil。
 @param milliseconds 最大等待毫秒数
 @return 成功返回节点，超时或队列为空时返回 nil。
 */
- (nullable WLNode *)deQueueWithTimeout:(int)milliseconds;

/**
 查看队头节点（不移除）
 */
- (nullable WLNode *)peek;

/**
 中止队列：唤醒所有阻塞线程并标记 abortRequest。
 调用此方法后，队列将不再接受新数据，工作线程应根据此状态安全退出。
 */
- (void)abort;

/**
 清空队列：释放当前所有已缓存的 AVPacket/AVFrame。
 */
- (void)flush;

/**
 将节点重新放回队头（用于帧时间未到的场景）
 @param node 待放回的节点
 */
- (void)requeueFront:(WLNode *)node;

/**
 当前队列中的节点总数
 */
- (int)count;

@end

NS_ASSUME_NONNULL_END
