//
//  WLNodeQueue.m
//  WorkLabs
//
//  NewPlan 线程安全队列（从 Core/Queue/WLNodeQueue 迁入）
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
    [self abort];
    [self flush];
    pthread_mutex_destroy(&_mutex);
    pthread_cond_destroy(&_cond);
}

- (void)abort {
    pthread_mutex_lock(&_mutex);
    _abortRequest = YES;
    pthread_cond_broadcast(&_cond);
    pthread_mutex_unlock(&_mutex);
}

- (void)enQueue:(WLNode *)node {
    if (!node) return;
    pthread_mutex_lock(&_mutex);
    while (_nodeSize >= _allSize && !_abortRequest) {
        pthread_cond_wait(&_cond, &_mutex);
    }
    if (_abortRequest) {
        [node flush];
        pthread_mutex_unlock(&_mutex);
        return;
    }
    if (!_head) { _head = node; } else { _tail.next = node; }
    _tail = node;
    _nodeSize++;
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
}

- (BOOL)enQueueNonBlocking:(WLNode *)node {
    if (!node) return NO;
    pthread_mutex_lock(&_mutex);
    if (_abortRequest) { [node flush]; pthread_mutex_unlock(&_mutex); return NO; }
    if (_nodeSize >= _allSize) {
        WLNode *oldNode = _head;
        if (oldNode) { _head = oldNode.next; if (!_head) _tail = nil; _nodeSize--; [oldNode flush]; }
    }
    if (!_head) { _head = node; } else { _tail.next = node; }
    _tail = node;
    _nodeSize++;
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
    return YES;
}

- (WLNode *)deQueueWithBlock:(BOOL)block {
    pthread_mutex_lock(&_mutex);
    while (!_head && !_abortRequest) {
        if (!block) { pthread_mutex_unlock(&_mutex); return nil; }
        pthread_cond_wait(&_cond, &_mutex);
    }
    if (_abortRequest || !_head) { pthread_mutex_unlock(&_mutex); return nil; }
    WLNode *node = _head;
    _head = node.next;
    if (!_head) _tail = nil;
    node.next = nil;
    _nodeSize--;
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
    return node;
}

- (void)flush {
    pthread_mutex_lock(&_mutex);
    WLNode *node = _head;
    while (node) { WLNode *next = node.next; [node flush]; node = next; }
    _head = nil; _tail = nil; _nodeSize = 0;
    pthread_cond_broadcast(&_cond);
    pthread_mutex_unlock(&_mutex);
}

- (nullable WLNode *)deQueueWithTimeout:(int)milliseconds {
    pthread_mutex_lock(&_mutex);
    if (!_head && !_abortRequest) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += milliseconds / 1000;
        ts.tv_nsec += (milliseconds % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
        pthread_cond_timedwait(&_cond, &_mutex, &ts);
    }
    if (_abortRequest || !_head) { pthread_mutex_unlock(&_mutex); return nil; }
    WLNode *node = _head;
    _head = node.next;
    if (!_head) _tail = nil;
    node.next = nil;
    _nodeSize--;
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
    return node;
}

- (WLNode *)peek {
    pthread_mutex_lock(&_mutex);
    WLNode *node = _head;
    pthread_mutex_unlock(&_mutex);
    return node;
}

- (void)requeueFront:(WLNode *)node {
    if (!node) return;
    pthread_mutex_lock(&_mutex);
    node.next = _head; _head = node;
    if (!_tail) _tail = node;
    _nodeSize++;
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
}

- (int)count {
    pthread_mutex_lock(&_mutex);
    int size = (int)_nodeSize;
    pthread_mutex_unlock(&_mutex);
    return size;
}

@end
