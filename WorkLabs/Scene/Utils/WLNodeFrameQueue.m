//
//  WLNodeFrameQueue.m
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//

#import "WLNodeFrameQueue.h"
#import <pthread.h>

@implementation WLNodeFrameQueue {
    pthread_mutex_t _mutex;
    pthread_cond_t _cond;
}

- (instancetype)initWithSize:(int)size {
    self = [super init];
    if (self) {
        _allSize = size;
        pthread_mutex_init(&_mutex, NULL);
        pthread_cond_init(&_cond, NULL);
    }
    return self;
}

- (void)dealloc {
    // 最后防线：确保即便外部逻辑漏掉 abort，dealloc 也会尝试唤醒
    [self abort];
    [self flush];
    
    pthread_mutex_destroy(&_mutex);
    pthread_cond_destroy(&_cond);
}

#pragma mark - 核心退出控制

- (void)abort {
    pthread_mutex_lock(&_mutex);
    _abortRequest = YES;
    pthread_cond_broadcast(&_cond); // 唤醒所有存/取线程
    pthread_mutex_unlock(&_mutex);
}

#pragma mark - 生产与消费

- (void)enQueue:(WLNodeFrame *)frame {
    if (!frame) return;
    pthread_mutex_lock(&_mutex);
    
    // 循环检查：队列满 且 未中止
    while (_nodeSize >= _allSize && !_abortRequest) {
        pthread_cond_wait(&_cond, &_mutex);
    }
    
    // 醒来后首要检查是否是因为 abort
    if (_abortRequest) {
        [frame flush]; // 释放掉无法入队的帧
        pthread_mutex_unlock(&_mutex);
        return;
    }
    
    if (!_head) {
        _head = frame;
    } else {
        _tail.next = frame;
    }
    _tail = frame;
    _nodeSize++;
    
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
}

- (BOOL)enQueueNonBlocking:(WLNodeFrame *)frame {
    if (!frame) return NO;
    pthread_mutex_lock(&_mutex);
    
    // 检查是否中止
    if (_abortRequest) {
        [frame flush]; // 释放掉无法入队的帧
        pthread_mutex_unlock(&_mutex);
        return NO;
    }
    
    // 队列满时丢弃最旧的帧
    if (_nodeSize >= _allSize) {
        WLNodeFrame *oldFrame = _head;
        if (oldFrame) {
            _head = oldFrame.next;
            if (!_head) _tail = nil;
            _nodeSize--;
            [oldFrame flush]; // 释放丢弃的帧
        }
    }
    
    // 添加新帧
    if (!_head) {
        _head = frame;
    } else {
        _tail.next = frame;
    }
    _tail = frame;
    _nodeSize++;
    
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
    return YES;
}

- (WLNodeFrame *)deQueueWithBlock:(BOOL)block {
    pthread_mutex_lock(&_mutex);
    
    while (!_head && !_abortRequest) {
        if (!block) {
            pthread_mutex_unlock(&_mutex);
            return nil;
        }
        pthread_cond_wait(&_cond, &_mutex);
    }
    
    if (_abortRequest || !_head) {
        pthread_mutex_unlock(&_mutex);
        return nil;
    }
    
    WLNodeFrame *frame = _head;
    _head = frame.next;
    if (!_head) _tail = nil; // 修复 tail 悬挂指针问题
    
    frame.next = nil;
    _nodeSize--;
    
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
    return frame;
}

- (void)flush {
    pthread_mutex_lock(&_mutex);
    WLNodeFrame *frame = _head;
    while (frame) {
        WLNodeFrame *next = frame.next;
        [frame flush];
        frame = next;
    }
    _head = nil;
    _tail = nil;
    _nodeSize = 0;
    pthread_cond_broadcast(&_cond);
    pthread_mutex_unlock(&_mutex);
}

- (WLNodeFrame *)peek {
    pthread_mutex_lock(&_mutex);
    // 仅仅查看，不改变 nodeSize 和指针偏移
    WLNodeFrame *frame = _head;
    pthread_mutex_unlock(&_mutex);
    return frame;
}

- (int)count {
    pthread_mutex_lock(&_mutex);
    // 在锁保护下读取，防止读取到修改一半的状态
    int size = (int)_nodeSize;
    pthread_mutex_unlock(&_mutex);
    return size;
}

@end
