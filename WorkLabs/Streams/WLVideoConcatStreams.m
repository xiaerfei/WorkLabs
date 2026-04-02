//
//  WLVideoConcatStreams.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/27.
//

#import "WLVideoConcatStreams.h"
#import "WLNodeQueue.h"

@interface WLVideoConcatStreams ()
@property (nonatomic, strong) NSDictionary <NSNumber * ,WLNodeQueue *> *queueDict;
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
- (void)addNode:(WLDecodeNode *)node {
    WLNodeQueue *queue = self.queueDict[@(node.fromType)];
    [queue enQueue:node];
}
#pragma mark - Thread
- (void)encoderThread {
    
}
#pragma mark - Pirvate Methods
- (void)configure {
    WLNodeQueue *lqueue = [[WLNodeQueue alloc] initWithType:WLDecodeTypeVideo size:4];
    WLNodeQueue *cqueue = [[WLNodeQueue alloc] initWithType:WLDecodeTypeVideo size:4];
    self.queueDict = @{
        @(WLFromTypeMedia) : lqueue,
        @(WLFromTypeCamera) : cqueue,
    };
    
    dispatch_semaphore_t semphore = dispatch_semaphore_create(0);
    
    
    [NSThread detachNewThreadSelector:@selector(encoderThread) toTarget:self withObject:nil];
}


@end
