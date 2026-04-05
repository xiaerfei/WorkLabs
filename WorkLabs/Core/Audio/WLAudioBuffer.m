//
//  WLAudioBuffer.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/26.
//

#import "WLAudioBuffer.h"
#import <pthread.h>
#import <mach/mach_time.h>
#include <sys/time.h>

// 时间戳条目
@interface WLAudioBufferPTSItem : NSObject
@property (nonatomic, assign) Float64 pts;
@property (nonatomic, assign) UInt32 offset; // 在缓冲区中的起始偏移（字节）
@property (nonatomic, assign) UInt32 length; // 数据长度（字节）
@end

@implementation WLAudioBufferPTSItem
@end

@interface WLAudioBuffer () {
    pthread_mutex_t _mutex;
    pthread_cond_t _condNotEmpty;
    pthread_cond_t _condNotFull;

    UInt8 *_buffer;          // 环形缓冲区
    UInt32 _readPos;         // 读位置（字节）
    UInt32 _writePos;        // 写位置（字节）
    UInt32 _used;            // 已使用字节数
    UInt32 _capacity;        // 总容量（字节）

    NSMutableArray<WLAudioBufferPTSItem *> *_ptsQueue; // PTS队列
    AudioStreamBasicDescription _audioFormat;          // 音频格式

    // 统计
    UInt64 _totalBytesWritten;
    UInt64 _totalBytesRead;
    UInt32 _overflowCount;
    UInt32 _underflowCount;
}

@end

@implementation WLAudioBuffer

#pragma mark - 初始化与销毁

- (instancetype)initWithCapacity:(UInt32)capacity
                      audioFormat:(AudioStreamBasicDescription)format {
    self = [super init];
    if (self) {
        _capacity = capacity;
        _audioFormat = format;

        // 初始化锁和条件变量
        pthread_mutex_init(&_mutex, NULL);
        pthread_cond_init(&_condNotEmpty, NULL);
        pthread_cond_init(&_condNotFull, NULL);

        // 分配缓冲区
        _buffer = (UInt8 *)calloc(1, _capacity);
        if (!_buffer) {
            NSLog(@"WLAudioBuffer: Failed to allocate buffer");
            return nil;
        }

        _readPos = 0;
        _writePos = 0;
        _used = 0;

        _ptsQueue = [NSMutableArray array];

        // 默认设置
        _overflowPolicy = WLAudioBufferOverflowPolicyDiscardOldest;
        _underflowPolicy = WLAudioBufferUnderflowPolicyFillSilence;
        _timeout = 0.1; // 100ms超时

        // 自动设置水位线
        [self setWatermarksAuto];

        // 初始化统计
        [self resetStatistics];
    }
    return self;
}

- (instancetype)initWithAudioFormat:(AudioStreamBasicDescription)format {
    // 计算1秒的音频数据量
    UInt32 bytesPerSecond = format.mSampleRate * format.mBytesPerFrame;
    return [self initWithCapacity:bytesPerSecond audioFormat:format];
}

- (void)dealloc {
    // 销毁锁和条件变量
    pthread_mutex_destroy(&_mutex);
    pthread_cond_destroy(&_condNotEmpty);
    pthread_cond_destroy(&_condNotFull);

    // 释放缓冲区
    if (_buffer) {
        free(_buffer);
        _buffer = NULL;
    }
}

#pragma mark - 属性访问

- (UInt32)usedBytes {
    pthread_mutex_lock(&_mutex);
    UInt32 used = _used;
    pthread_mutex_unlock(&_mutex);
    return used;
}

- (UInt32)freeBytes {
    pthread_mutex_lock(&_mutex);
    UInt32 free = _capacity - _used;
    pthread_mutex_unlock(&_mutex);
    return free;
}

- (float)usage {
    pthread_mutex_lock(&_mutex);
    float usage = _capacity > 0 ? (float)_used / _capacity : 0.0f;
    pthread_mutex_unlock(&_mutex);
    return usage;
}

- (Float64)estimatedDuration {
    if (_audioFormat.mBytesPerFrame == 0 || _audioFormat.mSampleRate == 0) {
        return 0.0;
    }

    pthread_mutex_lock(&_mutex);
    Float64 duration = (Float64)_used / _audioFormat.mBytesPerFrame / _audioFormat.mSampleRate;
    pthread_mutex_unlock(&_mutex);
    return duration;
}

#pragma mark - 数据操作

- (UInt32)writeData:(const void *)data
             length:(UInt32)length
                pts:(Float64)pts
              error:(NSError **)error {
    if (length == 0 || data == NULL) {
        if (error) *error = [self errorWithCode:WLAudioBufferErrorInvalidArgument
                                         message:@"Invalid write parameters"];
        return 0;
    }

    pthread_mutex_lock(&_mutex);

    // 检查是否有足够空间
    if (length > _capacity) {
        pthread_mutex_unlock(&_mutex);
        if (error) *error = [self errorWithCode:WLAudioBufferErrorInvalidArgument
                                         message:@"Data length exceeds buffer capacity"];
        return 0;
    }

    // 处理缓冲区满的情况
    if (_used + length > _capacity) {
        UInt32 discarded = 0;

        switch (_overflowPolicy) {
            case WLAudioBufferOverflowPolicyDiscardOldest: {
                // 丢弃最旧数据直到有足够空间
                while (_used + length > _capacity && _used > 0) {
                    discarded += [self discardOldestChunk];
                }
                _overflowCount++;
                if (_delegate && discarded > 0) {
                    [_delegate audioBufferOverflow:self discardedBytes:discarded];
                }
                break;
            }

            case WLAudioBufferOverflowPolicyDiscardNewest: {
                // 丢弃最新数据（即不写入）
                pthread_mutex_unlock(&_mutex);
                if (error) *error = [self errorWithCode:WLAudioBufferErrorOverflow
                                                 message:@"Buffer full (discard newest)"];
                return 0;
            }

            case WLAudioBufferOverflowPolicyBlock: {
                // 阻塞等待空间
                struct timespec timeout;
                [self getAbsTimeout:&timeout];

                while (_used + length > _capacity) {
                    int ret = pthread_cond_timedwait(&_condNotFull, &_mutex, &timeout);
                    if (ret == ETIMEDOUT) {
                        pthread_mutex_unlock(&_mutex);
                        if (error) *error = [self errorWithCode:WLAudioBufferErrorTimeout
                                                         message:@"Write timeout"];
                        return 0;
                    }
                }
                break;
            }

            case WLAudioBufferOverflowPolicyFail: {
                pthread_mutex_unlock(&_mutex);
                if (error) *error = [self errorWithCode:WLAudioBufferErrorOverflow
                                                 message:@"Buffer full"];
                return 0;
            }
        }
    }

    // 执行写入
    UInt32 written = [self writeToBuffer:data length:length];

    // 记录PTS信息
    if (written > 0) {
        WLAudioBufferPTSItem *item = [[WLAudioBufferPTSItem alloc] init];
        item.pts = pts;
        item.offset = (_writePos - written) % _capacity;
        item.length = written;
        [_ptsQueue addObject:item];
    }

    // 更新统计
    _totalBytesWritten += written;
    _used += written;

    // 通知等待的读取者
    if (written > 0) {
        pthread_cond_signal(&_condNotEmpty);
    }

    // 检查水位线并通知代理
    float usage = (float)_used / _capacity;
    if (_delegate) {
        [_delegate audioBuffer:self usageChanged:usage];
    }

    pthread_mutex_unlock(&_mutex);
    return written;
}

- (UInt32)readData:(void *)buffer
            length:(UInt32)length
               pts:(Float64 *)pts
             error:(NSError **)error {
    return [self readDataInternal:buffer length:length pts:pts blocking:YES error:error];
}

- (UInt32)readDataNonBlocking:(void *)buffer
                       length:(UInt32)length
                          pts:(Float64 *)pts
                        error:(NSError **)error {
    return [self readDataInternal:buffer length:length pts:pts blocking:NO error:error];
}

- (UInt32)readDataInternal:(void *)buffer
                    length:(UInt32)length
                       pts:(Float64 *)pts
                  blocking:(BOOL)blocking
                     error:(NSError **)error {
    if (length == 0 || buffer == NULL) {
        if (error) *error = [self errorWithCode:WLAudioBufferErrorInvalidArgument
                                         message:@"Invalid read parameters"];
        return 0;
    }

    pthread_mutex_lock(&_mutex);

    // 处理缓冲区空的情况
    if (_used < length) {
        if (!blocking) {
            // 非阻塞模式：读取尽可能多的数据
            length = _used;
        } else {
            switch (_underflowPolicy) {
                case WLAudioBufferUnderflowPolicyFillSilence: {
                    // 填充静音
                    pthread_mutex_unlock(&_mutex);
                    [self fillSilence:buffer length:length];
                    if (pts) *pts = 0;
                    _underflowCount++;
                    if (_delegate) {
                        [_delegate audioBufferUnderflow:self];
                    }
                    return length;
                }

                case WLAudioBufferUnderflowPolicyBlock: {
                    // 阻塞等待数据
                    struct timespec timeout;
                    [self getAbsTimeout:&timeout];

                    while (_used < length) {
                        int ret = pthread_cond_timedwait(&_condNotEmpty, &_mutex, &timeout);
                        if (ret == ETIMEDOUT) {
                            pthread_mutex_unlock(&_mutex);
                            if (error) *error = [self errorWithCode:WLAudioBufferErrorTimeout
                                                             message:@"Read timeout"];
                            return 0;
                        }
                    }
                    break;
                }

                case WLAudioBufferUnderflowPolicyFail: {
                    pthread_mutex_unlock(&_mutex);
                    if (error) *error = [self errorWithCode:WLAudioBufferErrorUnderflow
                                                     message:@"Insufficient data"];
                    return 0;
                }
            }
        }
    }

    // 实际可读取的长度
    UInt32 readable = MIN(length, _used);
    if (readable == 0) {
        pthread_mutex_unlock(&_mutex);
        return 0;
    }

    // 获取PTS
    if (pts) {
        *pts = [self getPTSForReadLength:readable];
    }

    // 执行读取
    UInt32 read = [self readFromBuffer:buffer length:readable];

    // 更新统计
    _totalBytesRead += read;
    _used -= read;

    // 清理PTS队列
    [self cleanupPTSQueueAfterRead:read];

    // 通知等待的写入者
    if (read > 0) {
        pthread_cond_signal(&_condNotFull);
    }

    // 检查水位线并通知代理
    float usage = (float)_used / _capacity;
    if (_delegate) {
        [_delegate audioBuffer:self usageChanged:usage];
    }

    pthread_mutex_unlock(&_mutex);
    return read;
}

- (UInt32)peekData:(void *)buffer
            length:(UInt32)length
               pts:(Float64 *)pts
             error:(NSError **)error {
    if (length == 0 || buffer == NULL) {
        if (error) *error = [self errorWithCode:WLAudioBufferErrorInvalidArgument
                                         message:@"Invalid peek parameters"];
        return 0;
    }

    pthread_mutex_lock(&_mutex);

    // 实际可查看的长度
    UInt32 peekable = MIN(length, _used);
    if (peekable == 0) {
        pthread_mutex_unlock(&_mutex);
        return 0;
    }

    // 获取PTS
    if (pts) {
        *pts = [self getPTSForReadLength:peekable];
    }

    // 执行查看（不移动读指针）
    UInt32 bytesCopied = 0;
    UInt32 remaining = peekable;
    UInt32 currentPos = _readPos;

    while (remaining > 0) {
        UInt32 chunkSize = MIN(remaining, _capacity - currentPos);
        memcpy((UInt8 *)buffer + bytesCopied, _buffer + currentPos, chunkSize);

        bytesCopied += chunkSize;
        remaining -= chunkSize;
        currentPos = (currentPos + chunkSize) % _capacity;
    }

    pthread_mutex_unlock(&_mutex);
    return bytesCopied;
}

- (UInt32)discardData:(UInt32)length error:(NSError **)error {
    if (length == 0) {
        return 0;
    }

    pthread_mutex_lock(&_mutex);

    UInt32 discardable = MIN(length, _used);
    if (discardable == 0) {
        pthread_mutex_unlock(&_mutex);
        return 0;
    }

    // 更新读指针
    _readPos = (_readPos + discardable) % _capacity;
    _used -= discardable;

    // 清理PTS队列
    [self cleanupPTSQueueAfterRead:discardable];

    // 通知等待的写入者
    pthread_cond_signal(&_condNotFull);

    pthread_mutex_unlock(&_mutex);
    return discardable;
}

- (void)clear {
    pthread_mutex_lock(&_mutex);

    _readPos = 0;
    _writePos = 0;
    _used = 0;
    [_ptsQueue removeAllObjects];

    // 通知所有等待的线程
    pthread_cond_broadcast(&_condNotFull);
    pthread_cond_broadcast(&_condNotEmpty);

    pthread_mutex_unlock(&_mutex);
}

#pragma mark - 状态查询

- (BOOL)needsMoreData {
    pthread_mutex_lock(&_mutex);
    BOOL result = _watermarkLow > 0 && _used < _watermarkLow;
    pthread_mutex_unlock(&_mutex);
    return result;
}

- (BOOL)needsDiscardData {
    pthread_mutex_lock(&_mutex);
    BOOL result = _watermarkHigh > 0 && _used > _watermarkHigh;
    pthread_mutex_unlock(&_mutex);
    return result;
}

- (Float64)oldestPTS {
    pthread_mutex_lock(&_mutex);
    Float64 pts = _ptsQueue.firstObject.pts;
    pthread_mutex_unlock(&_mutex);
    return pts;
}

- (Float64)newestPTS {
    pthread_mutex_lock(&_mutex);
    Float64 pts = _ptsQueue.lastObject.pts;
    pthread_mutex_unlock(&_mutex);
    return pts;
}

- (UInt32)discardDataBeforePTS:(Float64)pts error:(NSError **)error {
    pthread_mutex_lock(&_mutex);

    UInt32 totalDiscarded = 0;

    // 丢弃所有PTS小于指定值的数据块
    while (_ptsQueue.count > 0) {
        WLAudioBufferPTSItem *item = _ptsQueue.firstObject;
        if (item.pts < pts) {
            // 丢弃这个数据块
            UInt32 toDiscard = item.length;
            _readPos = (_readPos + toDiscard) % _capacity;
            _used -= toDiscard;
            totalDiscarded += toDiscard;

            [_ptsQueue removeObjectAtIndex:0];
        } else {
            break;
        }
    }

    if (totalDiscarded > 0) {
        pthread_cond_signal(&_condNotFull);
    }

    pthread_mutex_unlock(&_mutex);
    return totalDiscarded;
}

#pragma mark - 配置

- (void)setWatermarksAuto {
    pthread_mutex_lock(&_mutex);
    _watermarkLow = _capacity / 4;      // 25%
    _watermarkHigh = _capacity * 3 / 4; // 75%
    pthread_mutex_unlock(&_mutex);
}

- (void)setWatermarkLow:(UInt32)low high:(UInt32)high {
    pthread_mutex_lock(&_mutex);
    _watermarkLow = MIN(low, _capacity);
    _watermarkHigh = MIN(high, _capacity);
    pthread_mutex_unlock(&_mutex);
}

#pragma mark - 维护

- (void)resetStatistics {
    pthread_mutex_lock(&_mutex);
    _totalBytesWritten = 0;
    _totalBytesRead = 0;
    _overflowCount = 0;
    _underflowCount = 0;
    pthread_mutex_unlock(&_mutex);
}

- (NSString *)statusDescription {
    pthread_mutex_lock(&_mutex);

    NSString *status = [NSString stringWithFormat:
                       @"WLAudioBuffer Status:\n"
                       "  Capacity: %u bytes\n"
                       "  Used: %u bytes (%.1f%%)\n"
                       "  Free: %u bytes\n"
                       "  Read Pos: %u\n"
                       "  Write Pos: %u\n"
                       "  Watermarks: Low=%u, High=%u\n"
                       "  PTS Items: %lu\n"
                       "  Stats: Written=%llu, Read=%llu, Overflow=%u, Underflow=%u\n"
                       "  Est. Duration: %.3fs",
                       _capacity, _used, (float)_used/_capacity*100,
                       _capacity - _used, _readPos, _writePos,
                       _watermarkLow, _watermarkHigh,
                       (unsigned long)_ptsQueue.count,
                       _totalBytesWritten, _totalBytesRead,
                       _overflowCount, _underflowCount,
                       self.estimatedDuration];

    pthread_mutex_unlock(&_mutex);
    return status;
}

#pragma mark - 私有方法

/// 写入数据到环形缓冲区
- (UInt32)writeToBuffer:(const void *)data length:(UInt32)length {
    UInt32 bytesWritten = 0;
    UInt32 remaining = length;

    while (remaining > 0) {
        UInt32 chunkSize = MIN(remaining, _capacity - _writePos);
        memcpy(_buffer + _writePos, (const UInt8 *)data + bytesWritten, chunkSize);

        bytesWritten += chunkSize;
        remaining -= chunkSize;
        _writePos = (_writePos + chunkSize) % _capacity;
    }

    return bytesWritten;
}

/// 从环形缓冲区读取数据
- (UInt32)readFromBuffer:(void *)buffer length:(UInt32)length {
    UInt32 bytesRead = 0;
    UInt32 remaining = length;

    while (remaining > 0) {
        UInt32 chunkSize = MIN(remaining, _capacity - _readPos);
        memcpy((UInt8 *)buffer + bytesRead, _buffer + _readPos, chunkSize);

        bytesRead += chunkSize;
        remaining -= chunkSize;
        _readPos = (_readPos + chunkSize) % _capacity;
    }

    return bytesRead;
}

/// 丢弃最旧的数据块
- (UInt32)discardOldestChunk {
    if (_ptsQueue.count == 0) {
        // 没有PTS信息，丢弃一部分数据
        UInt32 toDiscard = MIN(_used, _capacity / 10); // 最多丢弃10%
        _readPos = (_readPos + toDiscard) % _capacity;
        _used -= toDiscard;
        return toDiscard;
    }

    // 丢弃第一个PTS条目对应的数据
    WLAudioBufferPTSItem *item = _ptsQueue.firstObject;
    UInt32 toDiscard = item.length;
    _readPos = (_readPos + toDiscard) % _capacity;
    _used -= toDiscard;
    [_ptsQueue removeObjectAtIndex:0];

    return toDiscard;
}

/// 清理PTS队列（读取后）
- (void)cleanupPTSQueueAfterRead:(UInt32)bytesRead {
    if (_ptsQueue.count == 0) return;

    UInt32 remaining = bytesRead;

    while (remaining > 0 && _ptsQueue.count > 0) {
        WLAudioBufferPTSItem *item = _ptsQueue.firstObject;

        if (item.length <= remaining) {
            // 整个条目都被读取了
            remaining -= item.length;
            [_ptsQueue removeObjectAtIndex:0];
        } else {
            // 只有部分被读取，更新条目
            item.offset = (item.offset + remaining) % _capacity;
            item.length -= remaining;
            remaining = 0;
        }
    }
}

/// 获取读取指定长度数据的PTS
- (Float64)getPTSForReadLength:(UInt32)length {
    if (_ptsQueue.count == 0) return 0.0;

    // 返回第一个数据块的PTS
    return _ptsQueue.firstObject.pts;
}

/// 填充静音数据
- (void)fillSilence:(void *)buffer length:(UInt32)length {
    if (_audioFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger) {
        // 有符号整数格式：填充0
        memset(buffer, 0, length);
    } else if (_audioFormat.mFormatFlags & kAudioFormatFlagIsFloat) {
        // 浮点格式：填充0.0
        memset(buffer, 0, length);
    } else {
        // 未知格式：填充0
        memset(buffer, 0, length);
    }
}

/// 获取绝对超时时间
- (void)getAbsTimeout:(struct timespec *)timeout {
    struct timeval now;
    gettimeofday(&now, NULL);

    timeout->tv_sec = now.tv_sec + (time_t)_timeout;
    timeout->tv_nsec = now.tv_usec * 1000 + (long)((_timeout - (NSInteger)_timeout) * 1e9);

    if (timeout->tv_nsec >= 1000000000) {
        timeout->tv_sec += 1;
        timeout->tv_nsec -= 1000000000;
    }
}

/// 创建错误对象
- (NSError *)errorWithCode:(WLAudioBufferError)code message:(NSString *)message {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: message ?: @""};
    return [NSError errorWithDomain:@"WLAudioBuffer" code:code userInfo:userInfo];
}

@end