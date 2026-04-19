//
//  WLNodeFrameQueue.h
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//
//  线程安全的帧队列（参照 WLNodeQueue 实现）
//  用于存储解码后的 WLNodeFrame，供外部消费者拉取

#import <Foundation/Foundation.h>
#import "WLNodeFrame.h"

NS_ASSUME_NONNULL_BEGIN

/**
 WLNodeFrameQueue: 基于 pthread 的音视频帧同步队列
 采用 IJKPlayer/ffplay 的 abort_request 机制，确保线程安全退出。
 存储元素为 WLNodeFrame（统一音视频帧容器）。
 */
@interface WLNodeFrameQueue : NSObject

/// 队列当前存储的帧数量
@property (nonatomic, assign, readonly) NSInteger nodeSize;

/// 队列允许的最大容量（通常视频设为 4-6，音频设为 20+）
@property (nonatomic, assign) NSInteger allSize;

/// 中止请求标志。一旦为 YES，所有阻塞的 enQueue/deQueue 将立即返回。
@property (nonatomic, assign, readonly) BOOL abortRequest;

/// 队列调试名称
@property (nonatomic, copy, nullable) NSString *queueName;

@property (nonatomic, strong, nullable) WLNodeFrame *head;
@property (nonatomic, strong, nullable) WLNodeFrame *tail;

/**
 初始化队列
 @param size 最大容量上限
 */
- (instancetype)initWithSize:(int)size;

/**
 入队（生产）：如果队列满则阻塞，直到有空间或 abortRequest 为 YES。
 @param frame 待入队帧。若 abortRequest 为 YES，方法内部会自动 flush 该 frame。
 */
- (void)enQueue:(WLNodeFrame *)frame;

/**
 非阻塞入队：如果队列满则丢弃最旧的帧，然后添加新帧
 @param frame 待入队帧
 @return 是否成功入队（队列满时丢弃旧帧也算成功）
 */
- (BOOL)enQueueNonBlocking:(WLNodeFrame *)frame;

/**
 出队（消费）：从队头获取帧。
 @param block 是否阻塞。若为 YES 且队列为空，则挂起线程直到有数据或被中止。
 @return 成功返回帧，中止或非阻塞且为空时返回 nil。
 */
- (nullable WLNodeFrame *)deQueueWithBlock:(BOOL)block;

/**
 查看队头帧（不移除）
 */
- (nullable WLNodeFrame *)peek;

/**
 中止队列：唤醒所有阻塞线程并标记 abortRequest。
 调用此方法后，队列将不再接受新数据，工作线程应根据此状态安全退出。
 */
- (void)abort;

/**
 清空队列：释放当前所有已缓存的帧数据。
 */
- (void)flush;

/**
 当前队列中的帧总数
 */
- (int)count;

@end

NS_ASSUME_NONNULL_END
