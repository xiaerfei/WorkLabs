//
//  WLSceneViewController.m
//  WorkLabs
//

#import "WLSceneViewController.h"
#import "WLSceneManager.h"
#import "WLMediaSourceItem.h"
#import "WLMediaSourcePreview.h"
#import "WLEvent.h"
#import "NSView+BackgroundColor.h"

@interface WLSceneViewController ()

@property (nonatomic, strong) NSMutableDictionary<NSUUID *, WLMediaSourcePreview *> *previewMap;
@property (nonatomic, strong) WLEventDisposeBag *bag;

@end

@implementation WLSceneViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [NSColor blackColor];
    self.previewMap = [NSMutableDictionary dictionary];

    [self registerEventObservers];
}

- (void)dealloc {
    [self.bag dispose];
}

#pragma mark - Event Observers

- (void)registerEventObservers {
    __weak typeof(self) weakSelf = self;

    self.bag = [WLEventDisposeBag new];

    WLObserve(@[@(WLObserveSourceChange)])
        .mainQueue()
        .dispose(self.bag)
        .block(^(WLObserve type, id payload) {
            if (![payload isKindOfClass:[NSDictionary class]]) return;

            NSDictionary *dict = (NSDictionary *)payload;
            NSString *action = dict[@"action"];

            if ([action isEqualToString:@"add"]) {
                WLMediaSourceItem *item = dict[@"item"];
                if (item) {
                    [weakSelf addPreviewForItem:item];
                }
            } else if ([action isEqualToString:@"remove"]) {
                // 重新同步所有预览
                [weakSelf syncPreviews];
            } else if ([action isEqualToString:@"select"]) {
                [weakSelf updateSelection];
            }
        });
}

#pragma mark - Preview Management

- (void)addPreviewForItem:(WLMediaSourceItem *)item {
    if (self.previewMap[item.uuid]) return;

    WLMediaSourcePreview *preview = [[WLMediaSourcePreview alloc] initWithFrame:NSZeroRect];
    preview.item = item;
    preview.selected = item.isSelected;
    [preview updateTransform];

    if (item.type == WLMediaSourceTypeAudio) {
        [preview showAudioPlaceholder];
    }

    [self.view addSubview:preview];
    self.previewMap[item.uuid] = preview;

    [self reorderPreviewsByZOrder];
}

- (void)syncPreviews {
    NSArray<WLMediaSourceItem *> *sources = self.sceneManager.sources;

    // 移除不再存在的 preview
    NSMutableSet<NSUUID *> *currentUUIDs = [NSMutableSet set];
    for (WLMediaSourceItem *item in sources) {
        [currentUUIDs addObject:item.uuid];
    }

    NSArray<NSUUID *> *existingUUIDs = [self.previewMap.allKeys copy];
    for (NSUUID *uuid in existingUUIDs) {
        if (![currentUUIDs containsObject:uuid]) {
            WLMediaSourcePreview *preview = self.previewMap[uuid];
            [preview removeFromSuperview];
            [self.previewMap removeObjectForKey:uuid];
        }
    }

    // 添加新的 preview
    for (WLMediaSourceItem *item in sources) {
        [self addPreviewForItem:item];
    }

    [self reorderPreviewsByZOrder];
}

- (void)updateSelection {
    for (WLMediaSourceItem *item in self.sceneManager.sources) {
        WLMediaSourcePreview *preview = self.previewMap[item.uuid];
        preview.selected = item.isSelected;
    }
}

- (void)reorderPreviewsByZOrder {
    NSArray<WLMediaSourceItem *> *sorted = [self.sceneManager.sources sortedArrayUsingComparator:^NSComparisonResult(WLMediaSourceItem *a, WLMediaSourceItem *b) {
        if (a.zOrder < b.zOrder) return NSOrderedAscending;
        if (a.zOrder > b.zOrder) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    for (WLMediaSourceItem *item in sorted) {
        WLMediaSourcePreview *preview = self.previewMap[item.uuid];
        if (preview) {
            // 移除后重新添加以调整层级
            [preview removeFromSuperview];
            [self.view addSubview:preview];
        }
    }
}

- (void)reloadScene {
    [self syncPreviews];
}

#pragma mark - Mouse Events

- (void)mouseDown:(NSEvent *)event {
    // 点击空白区域取消选中
    NSPoint locationInView = [self.view convertPoint:event.locationInWindow fromView:nil];

    BOOL hitPreview = NO;
    for (WLMediaSourcePreview *preview in self.previewMap.allValues) {
        NSPoint localPoint = [preview convertPoint:event.locationInWindow fromView:nil];
        if (NSPointInRect(localPoint, preview.bounds)) {
            hitPreview = YES;
            // 选中该源
            if (preview.item) {
                [self.sceneManager selectSource:preview.item];
            }
            break;
        }
    }

    if (!hitPreview) {
        [self.sceneManager deselectAll];
    }
}

#pragma mark - Keyboard Events

- (void)keyDown:(NSEvent *)event {
    unsigned short keyCode = event.keyCode;
    // Delete / Backspace
    if (keyCode == 0x33 || keyCode == 0x75) {
        WLMediaSourceItem *selected = self.sceneManager.selectedSource;
        if (selected) {
            [self.sceneManager removeSource:selected];
        }
    } else {
        [super keyDown:event];
    }
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

@end
