//
//  WLNodeQueue.h
//  WorkLabs
//
//  NewPlan 线程安全队列（从 Core/Queue/WLNodeQueue 迁入）
//
//  职责单一：生产者/消费者之间的阻塞式 FIFO 容器 + 背压。
//  不掺杂播放节流/时基——节流是消费者（render 线程）自己的事，队列只管存取。
//

#import <Foundation/Foundation.h>
#import "WLNode.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLNodeQueue : NSObject

/// 调试标识（仅用于日志区分各队列）
@property (nonatomic, copy, nullable) NSString *queueName;

/// type 仅作语义标识；size 为容量上限，入队达到上限即触发背压
- (instancetype)initWithType:(WLNodeType)type size:(int)size;

/// 入队：队满则阻塞等待消费者腾位；abort 时丢弃该节点直接返回（背压来源）
- (void)enQueue:(WLNode *)node;

/// 出队：block=YES 空队列阻塞到有数据或 abort；block=NO 空队列立即返回 nil。
/// 阻塞模式下返回 nil ⟺ 已 abort（语义唯一，调用方据此退出）。
- (nullable WLNode *)deQueueWithBlock:(BOOL)block;

/// 出队：最多等 milliseconds（单调钟，不受改系统时间影响）；有数据/abort 提前返回；超时或 abort 返回 nil
- (nullable WLNode *)deQueueWithTimeout:(int)milliseconds;

/// 唤醒所有等待者并拒绝后续入队/出队（出队恒返回 nil），用于停止
- (void)abort;

/// 清空并释放所有节点底层数据，broadcast 唤醒等待者
- (void)flush;

@end

NS_ASSUME_NONNULL_END
