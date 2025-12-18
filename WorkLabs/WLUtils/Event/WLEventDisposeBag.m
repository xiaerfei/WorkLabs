//
//  WLEventDisposeBag.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import "WLEventDisposeBag.h"
#import "WLEventObserveItem.h"
#import "WLEvent.h"

@interface WLEventObserveItem ()
- (void)_disposeSelf;
@end

@interface WLEventDisposeBag ()
@property (nonatomic, strong) dispatch_queue_t lockQueue;
@property (nonatomic, strong) NSHashTable <WLEventObserveItem *>*tokens; // weak or strong? token一般需要strong持有
@end

@implementation WLEventDisposeBag

- (instancetype)init {
    self = [super init];
    if (self) {
        _lockQueue = dispatch_queue_create("com.wl.event.disposebag.lock", DISPATCH_QUEUE_SERIAL);
        // token 用强引用，否则外部不持有会提前释放导致无法dispose
        _tokens = [NSHashTable hashTableWithOptions:NSHashTableStrongMemory];
    }
    return self;
}

/// 内部使用：加入一个可释放对象
- (void)_addToken:(id)token {
    if (!token) return;
    dispatch_sync(self.lockQueue, ^{
        [self.tokens addObject:token];
    });
}

- (void)disposeObserve:(id)observe {
    if (!observe) return;

    __block NSArray <WLEventObserveItem *>*all = nil;
    dispatch_sync(self.lockQueue, ^{
        all = self.tokens.allObjects;
    });

    for (WLEventObserveItem *obj in all) {
        if (obj == observe) {
            [obj _disposeSelf];
            break;
        }
    }
}

- (void)dispose {
    __block NSArray <WLEventObserveItem *>*all = nil;
    dispatch_sync(self.lockQueue, ^{
        all = self.tokens.allObjects;
        [self.tokens removeAllObjects];
    });

    for (WLEventObserveItem * obj in all) {
        [obj _disposeSelf];
    }
}

- (void)dealloc {
    [self dispose];
}
@end
