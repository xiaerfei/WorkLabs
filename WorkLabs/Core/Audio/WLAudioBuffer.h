//
//  WLAudioBuffer.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/26.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

// 错误码定义
typedef NS_ENUM(NSInteger, WLAudioBufferError) {
    WLAudioBufferErrorOverflow = -1,          // 缓冲区上溢
    WLAudioBufferErrorUnderflow = -2,         // 缓冲区下溢
    WLAudioBufferErrorInvalidArgument = -3,   // 无效参数
    WLAudioBufferErrorTimeout = -4,           // 操作超时
    WLAudioBufferErrorInternal = -5           // 内部错误
};

// 缓冲区满时的处理策略
typedef NS_ENUM(NSUInteger, WLAudioBufferOverflowPolicy) {
    WLAudioBufferOverflowPolicyDiscardOldest, // 丢弃最旧数据
    WLAudioBufferOverflowPolicyDiscardNewest, // 丢弃最新数据
    WLAudioBufferOverflowPolicyBlock,         // 阻塞等待空间
    WLAudioBufferOverflowPolicyFail           // 失败返回
};

// 缓冲区空时的处理策略
typedef NS_ENUM(NSUInteger, WLAudioBufferUnderflowPolicy) {
    WLAudioBufferUnderflowPolicyFillSilence,  // 填充静音
    WLAudioBufferUnderflowPolicyBlock,        // 阻塞等待数据
    WLAudioBufferUnderflowPolicyFail          // 失败返回
};

@class WLAudioBuffer;

@protocol WLAudioBufferDelegate <NSObject>
@optional
/// 缓冲区使用率变化通知
- (void)audioBuffer:(WLAudioBuffer *)buffer usageChanged:(float)usage;
/// 缓冲区上溢事件
- (void)audioBufferOverflow:(WLAudioBuffer *)buffer discardedBytes:(UInt32)bytes;
/// 缓冲区下溢事件
- (void)audioBufferUnderflow:(WLAudioBuffer *)buffer;
@end

/// 线程安全的环形音频缓冲区
@interface WLAudioBuffer : NSObject

/// 缓冲区总容量（字节）
@property (nonatomic, assign, readonly) UInt32 capacity;
/// 当前已使用字节数
@property (nonatomic, assign, readonly) UInt32 usedBytes;
/// 当前可用字节数
@property (nonatomic, assign, readonly) UInt32 freeBytes;
/// 缓冲区使用率 (0.0 - 1.0)
@property (nonatomic, assign, readonly) float usage;
/// 低水位线（字节），低于此值会触发 needsMoreData
@property (nonatomic, assign) UInt32 watermarkLow;
/// 高水位线（字节），高于此值会触发 needsDiscardData
@property (nonatomic, assign) UInt32 watermarkHigh;
/// 缓冲区满时的处理策略
@property (nonatomic, assign) WLAudioBufferOverflowPolicy overflowPolicy;
/// 缓冲区空时的处理策略
@property (nonatomic, assign) WLAudioBufferUnderflowPolicy underflowPolicy;
/// 操作超时时间（秒）
@property (nonatomic, assign) NSTimeInterval timeout;
/// 代理
@property (nonatomic, weak, nullable) id<WLAudioBufferDelegate> delegate;

/// 统计信息
@property (nonatomic, assign, readonly) UInt64 totalBytesWritten;
@property (nonatomic, assign, readonly) UInt64 totalBytesRead;
@property (nonatomic, assign, readonly) UInt32 overflowCount;
@property (nonatomic, assign, readonly) UInt32 underflowCount;
@property (nonatomic, assign, readonly) Float64 estimatedDuration; // 估计的音频时长（秒）

#pragma mark - 初始化

/// 使用指定容量初始化缓冲区
/// @param capacity 缓冲区容量（字节）
/// @param format 音频格式描述（用于计算时长）
- (instancetype)initWithCapacity:(UInt32)capacity
                       audioFormat:(AudioStreamBasicDescription)format;

/// 使用默认容量（1秒的44.1kHz立体声16位音频）初始化
/// @param format 音频格式描述
- (instancetype)initWithAudioFormat:(AudioStreamBasicDescription)format;

#pragma mark - 数据操作

/// 写入数据到缓冲区
/// @param data 要写入的数据指针
/// @param length 数据长度（字节）
/// @param pts 时间戳（秒）
/// @param error 错误输出
/// @return 成功写入的字节数，0表示失败
- (UInt32)writeData:(const void *)data
             length:(UInt32)length
                pts:(Float64)pts
              error:(NSError **)error;

/// 从缓冲区读取数据
/// @param buffer 接收数据的缓冲区
/// @param length 请求读取的长度（字节）
/// @param pts 输出时间戳（秒），可为NULL
/// @param error 错误输出
/// @return 实际读取的字节数，0表示失败
- (UInt32)readData:(void *)buffer
            length:(UInt32)length
               pts:(Float64 *)pts
             error:(NSError **)error;

/// 非阻塞读取：如果数据不足，立即返回
- (UInt32)readDataNonBlocking:(void *)buffer
                       length:(UInt32)length
                          pts:(Float64 *)pts
                        error:(NSError **)error;

/// 查看但不消费数据
- (UInt32)peekData:(void *)buffer
            length:(UInt32)length
               pts:(Float64 *)pts
             error:(NSError **)error;

/// 丢弃指定长度的数据
- (UInt32)discardData:(UInt32)length error:(NSError **)error;

/// 清空缓冲区
- (void)clear;

#pragma mark - 状态查询

/// 检查是否需要更多数据（低于低水位线）
- (BOOL)needsMoreData;

/// 检查是否需要丢弃数据（高于高水位线）
- (BOOL)needsDiscardData;

/// 获取当前缓冲区中最旧的PTS
- (Float64)oldestPTS;

/// 获取当前缓冲区中最新的PTS
- (Float64)newestPTS;

/// 根据PTS丢弃早于指定时间的数据
- (UInt32)discardDataBeforePTS:(Float64)pts error:(NSError **)error;

#pragma mark - 配置

/// 设置水位线（自动计算：低=25%，高=75%）
- (void)setWatermarksAuto;

/// 设置水位线
/// @param low 低水位线（字节），0表示禁用
/// @param high 高水位线（字节），0表示禁用
- (void)setWatermarkLow:(UInt32)low high:(UInt32)high;

#pragma mark - 维护

/// 重置统计信息
- (void)resetStatistics;

/// 获取缓冲区状态描述
- (NSString *)statusDescription;

@end

NS_ASSUME_NONNULL_END