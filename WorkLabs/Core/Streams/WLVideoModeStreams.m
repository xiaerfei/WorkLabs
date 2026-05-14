//
//  WLVideoModeStreams.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/27.
//

#import "WLVideoModeStreams.h"
#import "WLPushStreamsManager.h"
#import "WLRenderingManager.h"
#import "WLStreamsManager.h"
#import "WLNodeQueue.h"
#include <pthread.h>

#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>


@interface WLVideoModeStreams ()
@property (nonatomic, strong) NSDictionary <NSNumber * ,WLNodeQueue *> *queueDict;
@property (nonatomic, assign) BOOL rendering;
- (BOOL)isRendering;
- (void)setRendering:(BOOL)rendering;

@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@end

@implementation WLVideoModeStreams {
    pthread_mutex_t _rendering_mutex;
    pthread_mutex_t _wait_mutex;
    pthread_cond_t _wait_cond;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self configure];
    }
    return self;
}

- (BOOL)isRendering {
    pthread_mutex_lock(&_rendering_mutex);
    BOOL value = _rendering;
    pthread_mutex_unlock(&_rendering_mutex);
    return value;
}

- (void)setRendering:(BOOL)rendering {
    pthread_mutex_lock(&_rendering_mutex);
    _rendering = rendering;
    pthread_mutex_unlock(&_rendering_mutex);
}

- (void)dealloc {
    pthread_mutex_destroy(&_rendering_mutex);
    pthread_mutex_destroy(&_wait_mutex);
    pthread_cond_destroy(&_wait_cond);
}
#pragma mark - Public Methods
- (void)addNode:(WLNode *)node {
    if (!self.isRendering) {
        [node flush];
        return;
    }
    WLNodeQueue *queue = self.queueDict[@(node.fromType)];
    // 摄像头流使用非阻塞模式（丢弃旧帧策略）
    if (node.fromType == WLFromTypeCamera) {
        [queue enQueueNonBlocking:node];
    } else {
        // 媒体文件流使用阻塞模式
        [queue enQueue:node];
    }
    pthread_mutex_lock(&_wait_mutex);
    pthread_cond_signal(&_wait_cond);
    pthread_mutex_unlock(&_wait_mutex);
}

- (void)startConcat {
    if (self.isRendering) { return; }
    self.rendering = YES;
    [NSThread detachNewThreadSelector:@selector(encoderThread) toTarget:self withObject:nil];
}

- (void)stopConcat {
    self.rendering = NO;
    pthread_mutex_lock(&_wait_mutex);
    pthread_cond_broadcast(&_wait_cond);
    pthread_mutex_unlock(&_wait_mutex);
}
#pragma mark - Thread
- (void)encoderThread {
    static Float64 base_time = 0;
    WLRenderingManager *manager = [WLRenderingManager manager];
    WLStreamsManager *streams = [WLStreamsManager manager];
    while (self.isRendering) {
        pthread_mutex_lock(&_wait_mutex);
        while (self.isRendering && [self allQueueCount] == 0) {
            pthread_cond_wait(&_wait_cond, &_wait_mutex);
        }
        pthread_mutex_unlock(&_wait_mutex);
        
        if (self.isRendering == NO) break;
        
        
        
        
    }
    [self doExit];
}
#pragma mark - Pirvate Methods
- (void)configure {
    WLNodeQueue *lqueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:4];
    WLNodeQueue *cqueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:4];
    self.queueDict = @{
        @(WLFromTypeMedia) : lqueue,
        @(WLFromTypeCamera) : cqueue,
    };
    
    pthread_mutex_init(&_rendering_mutex, NULL);
    pthread_mutex_init(&_wait_mutex, NULL);
    pthread_cond_init(&_wait_cond, NULL);
}

- (NSInteger)allQueueCount {
    NSInteger count = 0;
    for (WLNodeQueue *queue in self.queueDict.allValues) {
        count += queue.count;
    }
    return count;
}

- (void)setVideoRenderType:(WLVideoRenderType)videoRenderType {
    _videoRenderType = videoRenderType;
}

- (void)doExit {
    
}
@end
