//
//  WLEventDisposeBag.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import "WLEventDisposeBag.h"
#import "WLEventItem.h"
#import "WLEvent.h"

@interface WLEventItem ()
- (WLEventItem *(^)(id owner))remove;
@end

@interface WLEventDisposeBag ()
@property (nonatomic, strong) dispatch_queue_t lockQueue;
@property (nonatomic, strong) NSHashTable *tokens; // weak or strong? token一般需要strong持有
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

- (void)disposeOwner:(id)owner {
    if (!owner) return;

    __block NSArray *all = nil;
    dispatch_sync(self.lockQueue, ^{
        all = self.tokens.allObjects;
    });

    for (id obj in all) {
        // token 实际是 WLEventItem（作为订阅句柄），它实现了 remove(owner)
        if ([obj respondsToSelector:@selector(remove:)]) {
            WLEventItem *item = (WLEventItem *)obj;
            item.remove(owner);
        }
    }
}

- (void)dispose {
    __block NSArray *all = nil;
    dispatch_sync(self.lockQueue, ^{
        all = self.tokens.allObjects;
        [self.tokens removeAllObjects];
    });

    for (id obj in all) {
        if ([obj respondsToSelector:@selector(_disposeSelf)]) {
            // WLEventItem 内部方法，直接释放对应订阅
            [obj performSelector:@selector(_disposeSelf)];
        }
    }
}

- (void)dealloc {
    [self dispose];
}
@end
