//
//  WLSceneViewController.m
//  WorkLabs
//

#import "WLSceneViewController.h"
#import "WLSceneManager.h"
#import "WLMediaSourceItem.h"
#import "WLMediaSourcePreview.h"
#import "WLMediaSource.h"
#import "WLEvent.h"
#import "NSView+BackgroundColor.h"

@interface WLSceneViewController () <NSDraggingDestination>

@property (nonatomic, strong) NSMutableDictionary<NSUUID *, WLMediaSourcePreview *> *previewMap;
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, WLMediaSourceItem *> *itemMap;
@property (nonatomic, strong) WLEventDisposeBag *bag;

@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, weak) WLMediaSourcePreview *draggingPreview;
@property (nonatomic, assign) NSPoint dragOffset;

@end

@implementation WLSceneViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [NSColor blackColor];
    self.previewMap = [NSMutableDictionary dictionary];
    self.itemMap = [NSMutableDictionary dictionary];

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
                [weakSelf syncPreviews];
            } else if ([action isEqualToString:@"select"]) {
                [weakSelf updateSelection];
            }
        });
}

#pragma mark - Preview Management

- (void)addPreviewForItem:(WLMediaSourceItem *)item {
    if (self.previewMap[item.uuid]) return;

    WLMediaSourcePreview *preview = nil;

    if ([item.sourceEngine isKindOfClass:[WLMediaSource class]]) {
        WLMediaSource *mediaSource = (WLMediaSource *)item.sourceEngine;
        preview = mediaSource.preview;
    } else {
        preview = [[WLMediaSourcePreview alloc] initWithFrame:NSZeroRect];
    }

    preview.selected = item.isSelected;

    self.itemMap[item.uuid] = item;
    [self updatePreviewFrame:preview forItem:item];

    if (item.type == WLMediaSourceTypeAudio) {
        [self showAudioPlaceholderForPreview:preview];
    }

    [self.view addSubview:preview];
    self.previewMap[item.uuid] = preview;

    [self reorderPreviewsByZOrder];
}

- (void)syncPreviews {
    NSArray<WLMediaSourceItem *> *sources = self.sceneManager.sources;

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
            [self.itemMap removeObjectForKey:uuid];
        }
    }

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
            [preview removeFromSuperview];
            [self.view addSubview:preview];
        }
    }
}

- (void)reloadScene {
    [self syncPreviews];
}

#pragma mark - Frame & Overlay Helpers

- (void)updatePreviewFrame:(WLMediaSourcePreview *)preview forItem:(WLMediaSourceItem *)item {
    NSRect frame = NSMakeRect(item.position.x - item.size.width / 2,
                               item.position.y - item.size.height / 2,
                               item.size.width,
                               item.size.height);
    preview.frame = frame;
}

- (WLMediaSourceItem *)itemForPreview:(WLMediaSourcePreview *)preview {
    for (NSUUID *uuid in self.previewMap) {
        if (self.previewMap[uuid] == preview) {
            return self.itemMap[uuid];
        }
    }
    return nil;
}

- (void)showAudioPlaceholderForPreview:(WLMediaSourcePreview *)preview {
    NSView *placeholder = [[NSView alloc] initWithFrame:preview.bounds];
    placeholder.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    placeholder.wantsLayer = YES;
    placeholder.layer.backgroundColor = [[NSColor colorWithWhite:0.15 alpha:1.0] CGColor];

    NSImageView *audioIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
    audioIcon.image = [NSImage imageWithSystemSymbolName:@"music.note"
                                    accessibilityDescription:nil];
    audioIcon.contentTintColor = [NSColor colorWithWhite:0.5 alpha:0.6];
    audioIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    audioIcon.frame = NSMakeRect((preview.bounds.size.width - 32) / 2,
                                  (preview.bounds.size.height - 32) / 2,
                                  32, 32);

    [placeholder addSubview:audioIcon];
    [preview addSubview:placeholder];
}

#pragma mark - Mouse Events

- (void)mouseDown:(NSEvent *)event {
    NSPoint locationInView = [self.view convertPoint:event.locationInWindow fromView:nil];

    BOOL hitPreview = NO;
    for (WLMediaSourcePreview *preview in self.previewMap.allValues) {
        NSPoint localPoint = [preview convertPoint:event.locationInWindow fromView:nil];
        if (NSPointInRect(localPoint, preview.bounds)) {
            hitPreview = YES;

            WLMediaSourceItem *item = [self itemForPreview:preview];
            if (item) {
                [self.sceneManager selectSource:item];
            }

            self.isDragging = YES;
            self.draggingPreview = preview;
            self.dragOffset = NSMakePoint(localPoint.x - preview.bounds.size.width / 2,
                                           localPoint.y - preview.bounds.size.height / 2);
            break;
        }
    }

    if (!hitPreview) {
        [self.sceneManager deselectAll];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.isDragging || !self.draggingPreview) return;

    WLMediaSourceItem *item = [self itemForPreview:self.draggingPreview];
    if (!item) return;

    NSPoint locationInSuperview = [self.view convertPoint:event.locationInWindow fromView:nil];
    CGFloat newX = locationInSuperview.x - self.dragOffset.x;
    CGFloat newY = locationInSuperview.y - self.dragOffset.y;

    newX = MAX(0, MIN(newX, self.view.bounds.size.width));
    newY = MAX(0, MIN(newY, self.view.bounds.size.height));

    item.position = NSMakePoint(newX, newY);
    [self updatePreviewFrame:self.draggingPreview forItem:item];
}

- (void)mouseUp:(NSEvent *)event {
    self.isDragging = NO;
    self.draggingPreview = nil;
}

#pragma mark - Keyboard Events

- (void)keyDown:(NSEvent *)event {
    unsigned short keyCode = event.keyCode;
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
