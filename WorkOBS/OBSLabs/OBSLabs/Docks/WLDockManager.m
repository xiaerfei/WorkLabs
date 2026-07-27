//
//  WLDockManager.m
//  OBSLabs
//
//  Dock 管理器 + 事件总线实现。
//

#import "WLDockManager.h"
#import "WLDockViewController.h"
#import "WLDockView.h"
#import "WLSourcesDockViewController.h"
#import "WLControlsDockViewController.h"
#import "WLScenesDockViewController.h"
#import "WLAudioMixerDockViewController.h"
#import "WLTransitionsDockViewController.h"

// ── 内部订阅记录 ──
@interface _WLSubscription : NSObject
@property (nonatomic, assign) NSUInteger tag;
@property (nonatomic, copy) void(^handler)(WLEventType event, id __nullable info);
@end
@implementation _WLSubscription
@end

// ── 内部可见性记录 ──
@interface _WLDockRecord : NSObject
@property (nonatomic, strong) WLDockViewController *dock;
@property (nonatomic, assign) BOOL visible;
@end
@implementation _WLDockRecord
- (instancetype)initWithDock:(WLDockViewController *)dock {
    self = [super init];
    if (self) { _dock = dock; _visible = YES; }
    return self;
}
@end

#pragma mark -

@interface WLDockManager ()
@property (nonatomic, strong) NSStackView *dockBar;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, _WLDockRecord *> *docks;   // identifier → record
@property (nonatomic, strong) NSMutableArray<NSNumber *> *dockOrder;                       // 显示顺序
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<_WLSubscription *> *> *subscriptions;
@property (nonatomic, assign) NSUInteger nextTag;
@end

@implementation WLDockManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _docks = [NSMutableDictionary dictionary];
        _dockOrder = [NSMutableArray array];
        _subscriptions = [NSMutableDictionary dictionary];
        _nextTag = 1;
    }
    return self;
}

#pragma mark - 事件总线

- (NSUInteger)subscribeEvent:(WLEventType)event
                     handler:(void(^)(WLEventType event, id __nullable info))handler {
    NSParameterAssert(handler);
    NSUInteger tag = self.nextTag++;
    _WLSubscription *sub = [_WLSubscription new];
    sub.tag = tag;
    sub.handler = handler;
    NSNumber *key = @(event);
    NSMutableArray *list = self.subscriptions[key];
    if (!list) {
        list = [NSMutableArray array];
        self.subscriptions[key] = list;
    }
    [list addObject:sub];
    return tag;
}

- (void)unsubscribeWithTag:(NSUInteger)tag {
    for (NSMutableArray *list in self.subscriptions.allValues) {
        NSIndexSet *toRemove = [list indexesOfObjectsPassingTest:^BOOL(_WLSubscription *sub, NSUInteger, BOOL *) {
            return sub.tag == tag;
        }];
        [list removeObjectsAtIndexes:toRemove];
    }
}

- (void)sendEvent:(WLEventType)event info:(id __nullable)info {
    NSArray<_WLSubscription *> *list = [self.subscriptions[@(event)] copy];
    for (_WLSubscription *sub in list) {
        if (sub.handler) sub.handler(event, info);
    }
}

#pragma mark - dockBar

- (NSStackView *)dockBar {
    if (!_dockBar) {
        _dockBar = [NSStackView stackViewWithViews:@[]];
        _dockBar.translatesAutoresizingMaskIntoConstraints = NO;
        _dockBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        _dockBar.distribution = NSStackViewDistributionFillEqually;
        _dockBar.spacing = 6;
        [self rebuildDockBar];
    }
    return _dockBar;
}

- (void)rebuildDockBar {
    if (!self.dockBar) return;   // 尚未访问过
    // 清空当前 arranged subviews
    for (NSView *sub in [self.dockBar.arrangedSubviews copy]) {
        [self.dockBar removeArrangedSubview:sub];
    }
    // 按 dockOrder 添加可见 dock 的 view
    for (NSNumber *ident in self.dockOrder) {
        _WLDockRecord *rec = self.docks[ident];
        if (rec.visible) [self.dockBar addArrangedSubview:rec.dock.view];
    }
}

#pragma mark - 命令式 API

- (void)addDock:(WLDockViewController *)dock forIdentifier:(WLDockIdentifier)identifier {
    NSNumber *key = @(identifier);
    if (self.docks[key]) {
        NSLog(@"[WLDockManager] addDock: identifier %ld 已存在，先移除", (long)identifier);
        [self removeDockForIdentifier:identifier];
    }
    dock.manager = self;
    _WLDockRecord *rec = [[_WLDockRecord alloc] initWithDock:dock];
    self.docks[key] = rec;
    [self.dockOrder addObject:key];
    [self rebuildDockBar];

    [self sendEvent:WLEventTypeDockDidAdd info:@{
        @"identifier": key,
        @"dock": dock
    }];
}

- (void)removeDockForIdentifier:(WLDockIdentifier)identifier {
    NSNumber *key = @(identifier);
    _WLDockRecord *rec = self.docks[key];
    if (!rec) return;
    WLDockViewController *dock = rec.dock;
    [self.docks removeObjectForKey:key];
    [self.dockOrder removeObject:key];
    [self rebuildDockBar];

    [self sendEvent:WLEventTypeDockDidRemove info:@{
        @"identifier": key,
        @"dock": dock
    }];
}

- (void)replaceDockForIdentifier:(WLDockIdentifier)identifier
                        withDock:(WLDockViewController *)newDock {
    NSNumber *key = @(identifier);
    _WLDockRecord *rec = self.docks[key];
    WLDockViewController *oldDock = rec.dock;
    BOOL visible = rec.visible;

    newDock.manager = self;
    rec.dock = newDock;
    rec.visible = visible;
    [self rebuildDockBar];

    [self sendEvent:WLEventTypeDockDidReplace info:@{
        @"identifier": key,
        @"oldDock": oldDock ?: [NSNull null],
        @"newDock": newDock
    }];
}

- (void)setVisible:(BOOL)visible forIdentifier:(WLDockIdentifier)identifier {
    NSNumber *key = @(identifier);
    _WLDockRecord *rec = self.docks[key];
    if (!rec || rec.visible == visible) return;
    rec.visible = visible;
    [self rebuildDockBar];

    [self sendEvent:WLEventTypeDockVisibilityChanged info:@{
        @"identifier": key,
        @"visible": @(visible)
    }];
}

- (nullable WLDockViewController *)dockForIdentifier:(WLDockIdentifier)identifier {
    return self.docks[@(identifier)].dock;
}

#pragma mark - 默认 Docks

- (void)setupDefaultDocks {
    [self addDock:[[WLScenesDockViewController alloc] init]      forIdentifier:WLDockIdentifierScenes];
    [self addDock:[[WLSourcesDockViewController alloc] init]     forIdentifier:WLDockIdentifierSources];
    [self addDock:[[WLAudioMixerDockViewController alloc] init]  forIdentifier:WLDockIdentifierAudioMixer];
    [self addDock:[[WLTransitionsDockViewController alloc] init] forIdentifier:WLDockIdentifierTransitions];
    [self addDock:[[WLControlsDockViewController alloc] init]    forIdentifier:WLDockIdentifierControls];
}

@end
