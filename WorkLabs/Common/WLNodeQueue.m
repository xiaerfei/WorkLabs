//
//  WLNodeQueue.m
//  WorkLabs
//
//  NewPlan 线程安全队列（从 Core/Queue/WLNodeQueue 迁入）
//

#import "WLNodeQueue.h"
#import <pthread.h>
#import <time.h>

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
        // 相对超时：relative_np 基于单调钟，不受改系统时间影响（旧 CLOCK_REALTIME 会漂）
        struct timespec ts;
        ts.tv_sec = milliseconds / 1000;
        ts.tv_nsec = (milliseconds % 1000) * 1000000L;
        pthread_cond_timedwait_relative_np(&_cond, &_mutex, &ts);
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

- (WLNode *)peekBlocking {
    pthread_mutex_lock(&_mutex);
    while (!_head && !_abortRequest) {
        pthread_cond_wait(&_cond, &_mutex);   // 空队列阻塞等到入队/abort（检查+等同锁内，无丢失唤醒）
    }
    WLNode *node = _abortRequest ? nil : _head;   // 不出队，仅查看
    pthread_mutex_unlock(&_mutex);
    return node;
}

- (void)waitUntilDeadlineNs:(uint64_t)deadlineNs {
    pthread_mutex_lock(&_mutex);
    if (!_abortRequest) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);   // 与调用方 wl_mono_now_ns 同钟
        if (deadlineNs > now) {
            uint64_t rel = deadlineNs - now;
            struct timespec ts;
            ts.tv_sec  = (time_t)(rel / 1000000000ULL);
            ts.tv_nsec = (long)(rel % 1000000000ULL);
            pthread_cond_timedwait_relative_np(&_cond, &_mutex, &ts);   // 睡到 deadline 或被入队/abort 唤醒
        }
    }
    pthread_mutex_unlock(&_mutex);
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
