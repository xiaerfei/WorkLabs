//
//  WLAudioMixStreams.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/27.
//

#import "WLAudioMixStreams.h"
#import "WLPushStreamsManager.h"
#import "WLRenderingManager.h"
#import "WLStreamsManager.h"
#import "WLNodeQueue.h"

@interface WLAudioMixStreams ()
@property (nonatomic, strong) NSDictionary <NSNumber * ,WLNodeQueue *> *queueDict;
@property (nonatomic, assign, getter=isRendering) BOOL rendering;
@end

@implementation WLAudioMixStreams

- (instancetype)init {
    self = [super init];
    if (self) {
        [self configure];
    }
    return self;
}
#pragma mark - Public Methods

- (void)addNode:(WLNode *)node {
    WLNodeQueue *queue = self.queueDict[@(node.fromType)];
    [queue enQueue:node];
}

- (void)startMix {
    if (self.isRendering) {
        return;
    }
    self.rendering = YES;
    [NSThread detachNewThreadSelector:@selector(encoderThread) toTarget:self withObject:nil];
}

- (void)stopMix {
    self.rendering = NO;
}
#pragma mark - Thread
- (void)encoderThread {
    static Float64 base_time = 0;
    WLRenderingManager *manager = [WLRenderingManager manager];
    while (self.isRendering) {
        WLAudioRenderType audioRenderType = [WLStreamsManager manager].audioRenderType;
        
        switch (audioRenderType) {
            case WLAudioRenderTypeMic:
            {
                WLNodeQueue *queue = self.queueDict[@(WLFromTypeCamera)];
                WLNode *node = [queue deQueueWithBlock:NO];
                if (node == nil) { break; }
                break;
            }
            case WLAudioRenderTypeMeida:
            {
                WLNodeQueue *queue = self.queueDict[@(WLFromTypeMedia)];
                WLNode *node = [queue deQueueWithBlock:NO];
                if (node == nil) { break; }
                Float64 current_time = CFAbsoluteTimeGetCurrent();
                if (base_time == 0) {
                    base_time = current_time;
                }
                
                [node flush];
                break;
            }
            case WLAudioRenderTypeMix:
            {
                break;
            }
                
            default: break;
        }
        usleep(5 * 1000);
    }
    [self doExit];
}
#pragma mark - Pirvate Methods
- (void)configure {
    WLNodeQueue *lqueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:20];
    WLNodeQueue *cqueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:20];
    self.queueDict = @{
        @(WLFromTypeMedia) : lqueue,
        @(WLFromTypeCamera) : cqueue,
    };
}

- (void)setAudioRenderType:(WLAudioRenderType)audioRenderType {
    _audioRenderType = audioRenderType;
}

- (void)doExit {
    
}
@end
