//
//  WLNodeQueue.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import "WLNodeQueue.h"
#import <pthread.h>

@implementation WLNodeQueue {
    pthread_mutex_t _mutex;
    pthread_cond_t _cond;
}

- (instancetype)initWithType:(WLNodeType)type size:(int)size {
    self = [super init];
    if (self) {
        _type = type;
        _allSize = size;
        pthread_mutex_init(&_mutex, NULL);
        pthread_cond_init(&_cond, NULL);
    }
    return self;
}

- (void)dealloc {
    // 最后的防线：确保即便外部逻辑漏掉 abort，dealloc 也会尝试唤醒
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

- (void)enQueue:(WLNode *)node {
    if (!node) return;
    pthread_mutex_lock(&_mutex);
    
    // 循环检查：队列满 且 未中止
    while (_nodeSize >= _allSize && !_abortRequest) {
        pthread_cond_wait(&_cond, &_mutex);
    }
    
    // 醒来后首要检查是否是因为 abort
    if (_abortRequest) {
        [node flush]; // 释放掉无法入队的数据
        pthread_mutex_unlock(&_mutex);
        return;
    }
    
    if (!_head) {
        _head = node;
    } else {
        _tail.next = node;
    }
    _tail = node;
    _nodeSize++;
    
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
}

- (WLNode *)deQueueWithBlock:(BOOL)block {
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
    
    WLNode *node = _head;
    _head = node.next;
    if (!_head) _tail = nil; // 修复 tail 悬挂指针问题
    
    node.next = nil;
    _nodeSize--;
    
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
    return node;
}

- (void)flush {
    pthread_mutex_lock(&_mutex);
    WLNode *node = _head;
    while (node) {
        WLNode *next = node.next;
        [node flush];
        node = next;
    }
    _head = nil;
    _tail = nil;
    _nodeSize = 0;
    pthread_cond_broadcast(&_cond);
    pthread_mutex_unlock(&_mutex);
}

- (WLNode *)peek {
    pthread_mutex_lock(&_mutex);
    // 仅仅查看，不改变 nodeSize 和指针偏移
    WLNode *node = _head;
    pthread_mutex_unlock(&_mutex);
    return node;
}

- (int)count {
    pthread_mutex_lock(&_mutex);
    // 在锁保护下读取，防止读取到修改一半的状态
    int size = (int)_nodeSize;
    pthread_mutex_unlock(&_mutex);
    return size;
}
@end
