//
//  WLVideoConcatStreams.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/27.
//

#import "WLVideoConcatStreams.h"
#import "WLPushStreamsManager.h"
#import "WLRenderingManager.h"
#import "WLNodeQueue.h"

@interface WLVideoConcatStreams ()
@property (nonatomic, strong) NSDictionary <NSNumber * ,WLNodeQueue *> *queueDict;
@property (nonatomic, assign, getter=isRendering) BOOL rendering;
@end

@implementation WLVideoConcatStreams

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

- (void)startConcat {
    if (self.isRendering) {
        return;
    }
    self.rendering = YES;
    [NSThread detachNewThreadSelector:@selector(encoderThread) toTarget:self withObject:nil];
}

- (void)stopConcat {
    self.rendering = NO;
}
#pragma mark - Thread
- (void)encoderThread {
    WLRenderingManager *manager = [WLRenderingManager manager];
    while (self.isRendering) {
        switch (self.videoRenderType) {
            case WLVideoRenderTypeCamera:
            {
                WLNodeQueue *queue = self.queueDict[@(WLFromTypeCamera)];
                WLNode *node = [queue deQueueWithBlock:NO];
                if (node == nil) { break; }
                break;
            }
            case WLVideoRenderTypeMedia:
            {
                WLNodeQueue *queue = self.queueDict[@(WLFromTypeMedia)];
                WLNode *node = [queue deQueueWithBlock:NO];
                if (node == nil) { break; }
                CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)node.frame->data[3];
                [manager pixelBuffer:pixelBuffer pts:node.pts];
                [node flush];
                break;
            }
            case WLVideoRenderTypeConcat:
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
    WLNodeQueue *lqueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:4];
    WLNodeQueue *cqueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:4];
    self.queueDict = @{
        @(WLFromTypeMedia) : lqueue,
        @(WLFromTypeCamera) : cqueue,
    };
}

- (void)setVideoRenderType:(WLVideoRenderType)videoRenderType {
    _videoRenderType = videoRenderType;
}

- (void)doExit {
    
}
@end
