//
//  WLSourcesDockViewController.mm
//  OBSLabs
//
//  源列表 Dock：源列表 + 底部 +/− 工具条。
//  选中/取消/切换由 NSTableView 原生处理，不自定义 rowView 绘制。
//

#import "WLSourcesDockViewController.h"
#import "WLDockManager.h"
#import "WLDockView.h"
#import "WLCore.hpp"
#import "WLSource.hpp"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// ══════════════ 颜色 ═══════════════

static NSColor *kBgIdle(void)         { return [NSColor colorWithWhite:0.07 alpha:1]; }
static NSColor *kBgHover(void)        { return [NSColor colorWithWhite:0.10 alpha:1]; }
static NSColor *kBgPress(void)        { return [NSColor colorWithWhite:0.06 alpha:1]; }
static NSColor *kBorderIdle(void)     { return [NSColor colorWithWhite:1.0 alpha:0.06]; }
static NSColor *kBorderHover(void)    { return [NSColor colorWithWhite:1.0 alpha:0.12]; }
static NSColor *kToolBtnTextIdle(void){ return [NSColor colorWithWhite:0.60 alpha:1]; }
static NSColor *kToolBtnTextHov(void) { return [NSColor colorWithWhite:0.90 alpha:1]; }
static NSColor *kEmptyTextColor(void) { return [NSColor colorWithWhite:0.35 alpha:1]; }
static NSColor *kTextNormal(void)     { return [NSColor colorWithWhite:0.85 alpha:1]; }

// ══════════════ 私有模型 ═══════════════

@interface WLSourceRow : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, copy)   NSString *type;
@property (nonatomic, assign) WLSource *src;
@end
@implementation WLSourceRow
@end

// ══════════════ 工具条按钮 ═══════════════

@interface WLToolButton : NSView
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) CALayer *bgLayer;
@property (nonatomic, assign) BOOL hovering;
@property (nonatomic, assign) BOOL pressed;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, weak)   id target;
@property (nonatomic, assign) SEL action;
@end

@implementation WLToolButton

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _enabled = YES;
        self.wantsLayer = YES;

        _bgLayer = [CALayer layer];
        _bgLayer.cornerRadius = 4.0;
        _bgLayer.borderWidth = 1.0;
        [self.layer addSublayer:_bgLayer];

        _label = [NSTextField labelWithString:title];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.alignment = NSTextAlignmentCenter;
        _label.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        [self addSubview:_label];

        [NSLayoutConstraint activateConstraints:@[
            [_label.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];

        NSTrackingArea *area = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                   owner:self
                userInfo:nil];
        [self addTrackingArea:area];

        [self updateAppearance:NO];
    }
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.bgLayer.frame = self.bounds;
    [CATransaction commit];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    self.alphaValue = enabled ? 1.0 : 0.35;
    [self updateAppearance:NO];
}

- (void)updateAppearance:(BOOL)animated {
    if (!animated) { [CATransaction begin]; [CATransaction setDisableActions:YES]; }

    NSColor *bg, *border, *text;
    if (!self.enabled) {
        bg = kBgIdle(); border = kBorderIdle(); text = kToolBtnTextIdle();
    } else if (self.pressed) {
        bg = kBgPress(); border = kBorderIdle(); text = kToolBtnTextHov();
    } else if (self.hovering) {
        bg = kBgHover(); border = kBorderHover(); text = kToolBtnTextHov();
    } else {
        bg = kBgIdle(); border = kBorderIdle(); text = kToolBtnTextIdle();
    }

    self.bgLayer.backgroundColor = bg.CGColor;
    self.bgLayer.borderColor    = border.CGColor;
    self.label.textColor        = text;

    if (!animated) [CATransaction commit];
}

- (void)mouseEntered:(NSEvent *)event {
    if (!self.enabled) return;
    self.hovering = YES; [self updateAppearance:YES];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovering = NO; [self updateAppearance:YES];
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) return;
    self.pressed = YES; [self updateAppearance:YES];
}

- (void)mouseUp:(NSEvent *)event {
    self.pressed = NO;
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL inside = NSPointInRect(loc, self.bounds);
    self.hovering = inside;
    [self updateAppearance:YES];
    if (inside && self.enabled && self.target && self.action) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.target performSelector:self.action withObject:self];
#pragma clang diagnostic pop
    }
}

@end

// ══════════════ WLSourcesDockViewController ══════════════

static NSString *const kColName = @"SourceCol";
static NSString *const kCellID  = @"SourceCell";

@interface WLSourcesDockViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSMutableArray<WLSourceRow *> *rows;
@property (nonatomic, strong) NSTableView    *tableView;
@property (nonatomic, strong) WLToolButton   *addButton;
@property (nonatomic, strong) WLToolButton   *removeButton;
@property (nonatomic, strong) NSTextField    *emptyLabel;
@property (nonatomic, assign) NSUInteger      subTagSourceAdded;
@property (nonatomic, assign) NSUInteger      subTagSourceRemoved;
@property (nonatomic, assign) NSUInteger      subTagVisibilityChanged;
@property (nonatomic, assign) NSUInteger      subTagSourceSelection;
@property (nonatomic, assign) BOOL            suppressSelectionBroadcast;  // 收到外部选中事件时置 YES，防循环
@end

@implementation WLSourcesDockViewController

- (instancetype)init {
    return [self initWithTitle:@"源 Sources"];
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.rows = [NSMutableArray array];
    [self buildUI];
    [self subscribeEvents];
}

- (void)dealloc {
    [self.manager unsubscribeWithTag:self.subTagSourceAdded];
    [self.manager unsubscribeWithTag:self.subTagSourceRemoved];
    [self.manager unsubscribeWithTag:self.subTagVisibilityChanged];
    [self.manager unsubscribeWithTag:self.subTagSourceSelection];
}

#pragma mark - 事件订阅

- (void)subscribeEvents {
    __weak typeof(self) weakSelf = self;

    self.subTagSourceAdded = [self.manager subscribeEvent:WLEventTypeSourceAdded
                                                  handler:^(WLEventType event, id __nullable info) {
        [weakSelf handleSourceAdded:info];
    }];

    self.subTagSourceRemoved = [self.manager subscribeEvent:WLEventTypeSourceRemoved
                                                    handler:^(WLEventType event, id __nullable info) {
        [weakSelf handleSourceRemoved:info];
    }];

    self.subTagVisibilityChanged = [self.manager subscribeEvent:WLEventTypeDockVisibilityChanged
                                                        handler:^(WLEventType event, id __nullable info) {
        [weakSelf handleVisibilityChanged:info];
    }];

    self.subTagSourceSelection = [self.manager subscribeEvent:WLEventTypeSourceSelectionChanged
                                                      handler:^(WLEventType event, id __nullable info) {
        [weakSelf handleSourceSelectionFromCanvas:info];
    }];
}

- (void)handleSourceAdded:(NSDictionary *)info {
    NSValue *srcVal = info[@"sourcePtr"];
    NSString *name  = info[@"name"];
    NSString *type  = info[@"type"];
    if (!srcVal || !name) return;

    WLSource *src = (WLSource *)[srcVal pointerValue];
    for (WLSourceRow *existing in self.rows) {
        if (existing.src == src) return;
    }

    WLSourceRow *row = [WLSourceRow new];
    row.src  = src;
    row.name = name;
    row.type = type ?: @"—";
    [self.rows addObject:row];
    [self.tableView reloadData];
    NSInteger i = (NSInteger)self.rows.count - 1;
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
    [self.tableView scrollRowToVisible:i];
    self.removeButton.enabled = YES;
    [self updateEmptyLabel];
}

- (void)handleSourceRemoved:(NSDictionary *)info {
    NSValue *srcVal = info[@"sourcePtr"];
    if (!srcVal) return;
    WLSource *src = (WLSource *)[srcVal pointerValue];

    for (NSInteger i = 0; i < (NSInteger)self.rows.count; i++) {
        if (self.rows[i].src == src) {
            [self.rows removeObjectAtIndex:i];
            [self.tableView reloadData];
            self.removeButton.enabled = self.tableView.selectedRow >= 0;
            [self updateEmptyLabel];
            return;
        }
    }
}

- (void)handleVisibilityChanged:(NSDictionary *)info {
    // 保留供未来使用
}

- (void)handleSourceSelectionFromCanvas:(NSDictionary *)info {
    id srcVal = info[@"sourcePtr"];
    WLSource *selectedSrc = nil;
    if ([srcVal isKindOfClass:[NSValue class]]) {
        selectedSrc = (WLSource *)[srcVal pointerValue];
    }

    self.suppressSelectionBroadcast = YES;
    if (selectedSrc) {
        for (NSInteger i = 0; i < (NSInteger)self.rows.count; i++) {
            if (self.rows[i].src == selectedSrc) {
                [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
                [self.tableView scrollRowToVisible:i];
                break;
            }
        }
    } else {
        [self.tableView deselectAll:nil];
    }
    self.suppressSelectionBroadcast = NO;
}

#pragma mark - UI 搭建

- (void)buildUI {
    NSView *c = self.dockContent;

    // ── 表格 ──
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;

    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.dataSource = self;
    table.delegate = self;
    table.headerView = nil;
    table.backgroundColor = [NSColor clearColor];
    table.rowHeight = 44;
    table.intercellSpacing = NSMakeSize(0, 0);
    table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    table.allowsMultipleSelection = NO;
    table.focusRingType = NSFocusRingTypeNone;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:kColName];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [table addTableColumn:col];
    scroll.documentView = table;
    self.tableView = table;

    // ── 空态 ──
    NSTextField *empty = [NSTextField labelWithString:@"暂无源，点击 + 添加"];
    empty.translatesAutoresizingMaskIntoConstraints = NO;
    empty.textColor = kEmptyTextColor();
    empty.font = [NSFont systemFontOfSize:11];
    empty.alignment = NSTextAlignmentCenter;
    self.emptyLabel = empty;

    // ── 工具条 ──
    WLToolButton *add = [[WLToolButton alloc] initWithTitle:@"＋"];
    add.translatesAutoresizingMaskIntoConstraints = NO;
    add.target = self;
    add.action = @selector(pickAddSourceType:);
    self.addButton = add;

    WLToolButton *remove = [[WLToolButton alloc] initWithTitle:@"−"];
    remove.translatesAutoresizingMaskIntoConstraints = NO;
    remove.target = self;
    remove.action = @selector(removeSelectedSource:);
    remove.enabled = NO;
    self.removeButton = remove;

    NSView *sep = [NSView new];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.wantsLayer = YES;
    sep.layer.backgroundColor = kBorderIdle().CGColor;

    [c addSubview:scroll];
    [c addSubview:empty];
    [c addSubview:sep];
    [c addSubview:add];
    [c addSubview:remove];

    const CGFloat btnW = 28, btnH = 24;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor      constraintEqualToAnchor:c.topAnchor      constant:2],
        [scroll.leadingAnchor  constraintEqualToAnchor:c.leadingAnchor  constant:2],
        [scroll.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-2],
        [scroll.bottomAnchor   constraintEqualToAnchor:sep.topAnchor    constant:-2],
        [empty.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
        [empty.centerYAnchor constraintEqualToAnchor:scroll.centerYAnchor],
        [sep.leadingAnchor  constraintEqualToAnchor:c.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
        [sep.heightAnchor   constraintEqualToConstant:1],
        [sep.bottomAnchor   constraintEqualToAnchor:add.topAnchor constant:-4],
        [add.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:6],
        [add.bottomAnchor  constraintEqualToAnchor:c.bottomAnchor  constant:-4],
        [add.widthAnchor   constraintEqualToConstant:btnW],
        [add.heightAnchor  constraintEqualToConstant:btnH],
        [remove.leadingAnchor constraintEqualToAnchor:add.trailingAnchor constant:4],
        [remove.bottomAnchor  constraintEqualToAnchor:add.bottomAnchor],
        [remove.widthAnchor   constraintEqualToConstant:btnW],
        [remove.heightAnchor  constraintEqualToConstant:btnH],
    ]];

    [self updateEmptyLabel];
}

- (void)updateEmptyLabel {
    self.emptyLabel.hidden = self.rows.count > 0;
}

#pragma mark - 添加 / 删除源

- (void)pickAddSourceType:(id)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"添加源"];
    // 默认 autoenablesItems=YES 会按"target 是否响应 action"自动启用所有项，
    // 覆盖手动 enabled=NO——关掉才能让未实现的源类型真正置灰
    menu.autoenablesItems = NO;

    struct { NSString *title; NSString *icon; NSString *key; BOOL enabled; } items[] = {
        { @"媒体源",     @"film",                                     @"media_file", YES },
        { @"浏览器",     @"globe",                                    @"browser",    NO  },
        { @"视频采集设备", @"video.fill",                               @"camera",     NO  },
        { @"音频采集设备", @"mic.fill",                                 @"mic",        NO  },
        { @"屏幕采集",   @"display",                                  @"screen",     NO  },
        { @"图像",       @"photo.fill",                               @"image",      NO  },
    };

    for (int i = 0; i < 6; i++) {
        // keyEquivalent 是单字符快捷键位，类型 key 走 representedObject
        NSMenuItem *item = [menu addItemWithTitle:items[i].title
                                           action:@selector(addSourceFromMenu:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = items[i].key;
        item.enabled = items[i].enabled;
        if (@available(macOS 11.0, *)) {
            item.image = [NSImage imageWithSystemSymbolName:items[i].icon
                                 accessibilityDescription:items[i].title];
        }
    }

    if ([sender isKindOfClass:[NSView class]]) {
        NSView *btn = (NSView *)sender;
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(btn.bounds)) inView:btn];
    }
}

- (void)addSourceFromMenu:(NSMenuItem *)item {
    NSString *key = item.representedObject;
    if ([key isEqualToString:@"media_file"]) {
        [self showMediaFileProperties];
    } else {
        NSLog(@"[SourcesDock] 源类型 %@ 暂未实现", key);
    }
}

#pragma mark - 媒体文件属性面板

- (void)showMediaFileProperties {
    NSWindow *hostWindow = self.view.window;
    if (!hostWindow) return;

    // ── 面板窗口（作为 sheet 附加到主窗口）──
    NSWindow *panel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 520)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    panel.title = @"媒体文件属性";
    panel.releasedWhenClosed = NO;

    NSView *content = panel.contentView;
    content.wantsLayer = YES;

    // ── 预览区占位 ──
    NSView *previewBox = [NSView new];
    previewBox.translatesAutoresizingMaskIntoConstraints = NO;
    previewBox.wantsLayer = YES;
    previewBox.layer.backgroundColor = [NSColor colorWithWhite:0.08 alpha:1].CGColor;
    previewBox.layer.cornerRadius = 4;
    previewBox.layer.borderWidth = 1;
    previewBox.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.06].CGColor;
    [content addSubview:previewBox];

    NSTextField *previewLabel = [NSTextField labelWithString:@"预览"];
    previewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    previewLabel.textColor = [NSColor colorWithWhite:0.30 alpha:1];
    previewLabel.font = [NSFont systemFontOfSize:12];
    [previewBox addSubview:previewLabel];

    // ── 本地文件 checkbox ──
    NSButton *localFileCheck = [NSButton checkboxWithTitle:@"本地文件" target:nil action:nil];
    localFileCheck.translatesAutoresizingMaskIntoConstraints = NO;
    localFileCheck.state = NSControlStateValueOn;
    [content addSubview:localFileCheck];

    // ── 文件路径 ──
    NSTextField *pathField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    pathField.translatesAutoresizingMaskIntoConstraints = NO;
    pathField.placeholderString = @"请选择媒体文件…";
    pathField.editable = YES;
    [content addSubview:pathField];

    NSButton *browseBtn = [NSButton buttonWithTitle:@"浏览" target:self action:@selector(browseForMediaFile:)];
    browseBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:browseBtn];

    // ── 选项 checkboxes（未接入 libwl 的先置灰，避免"勾了没反应"）──
    NSButton *loopCheck = [NSButton checkboxWithTitle:@"循环" target:nil action:nil];
    loopCheck.translatesAutoresizingMaskIntoConstraints = NO;
    loopCheck.enabled = NO;   // TODO: libwl loop 落地后接入并启用
    loopCheck.toolTip = @"暂未实现";
    [content addSubview:loopCheck];

    NSButton *hwCheck = [NSButton checkboxWithTitle:@"在可用时使用硬件解码" target:nil action:nil];
    hwCheck.translatesAutoresizingMaskIntoConstraints = NO;
    hwCheck.state = NSControlStateValueOn;   // 解码侧现在无条件走 VideoToolbox，先展示默认开
    hwCheck.enabled = NO;
    hwCheck.toolTip = @"暂未实现（当前始终使用硬件解码）";
    [content addSubview:hwCheck];

    NSButton *autoRemoveCheck = [NSButton checkboxWithTitle:@"播放结束后自动移除" target:nil action:nil];
    autoRemoveCheck.translatesAutoresizingMaskIntoConstraints = NO;
    autoRemoveCheck.enabled = NO;
    autoRemoveCheck.toolTip = @"暂未实现";
    [content addSubview:autoRemoveCheck];

    // ── 速度滑块 ──
    NSTextField *speedLabel = [NSTextField labelWithString:@"速度"];
    speedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    speedLabel.textColor = [NSColor secondaryLabelColor];
    [content addSubview:speedLabel];

    NSSlider *speedSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    speedSlider.translatesAutoresizingMaskIntoConstraints = NO;
    speedSlider.minValue = 0.25;
    speedSlider.maxValue = 4.0;
    speedSlider.doubleValue = 1.0;
    speedSlider.continuous = YES;
    speedSlider.enabled = NO;   // TODO: 变速播放未实现
    speedSlider.toolTip = @"暂未实现";
    [content addSubview:speedSlider];

    NSTextField *speedValue = [NSTextField labelWithString:@"100%"];
    speedValue.translatesAutoresizingMaskIntoConstraints = NO;
    speedValue.textColor = [NSColor secondaryLabelColor];
    speedValue.alignment = NSTextAlignmentRight;
    speedValue.tag = 300;
    [content addSubview:speedValue];

    speedSlider.target = self;
    speedSlider.action = @selector(speedSliderChanged:);

    // ── 分隔线 ──
    NSView *bottomSep = [NSView new];
    bottomSep.translatesAutoresizingMaskIntoConstraints = NO;
    bottomSep.wantsLayer = YES;
    bottomSep.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.08].CGColor;
    [content addSubview:bottomSep];

    // ── 取消 / 确定 ──
    NSButton *cancelBtn = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelMediaFilePanel:)];
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:cancelBtn];

    NSButton *okBtn = [NSButton buttonWithTitle:@"确定" target:self action:@selector(confirmMediaFilePanel:)];
    okBtn.translatesAutoresizingMaskIntoConstraints = NO;
    okBtn.keyEquivalent = @"\r";
    [content addSubview:okBtn];

    // ── 关联到面板，方便后续取值 ──
    pathField.tag     = 301;
    loopCheck.tag     = 302;
    hwCheck.tag       = 303;
    autoRemoveCheck.tag = 304;
    okBtn.tag         = 305;
    cancelBtn.tag     = 306;

    // ── 布局 ──
    const CGFloat pad = 16;
    [NSLayoutConstraint activateConstraints:@[
        // 预览区
        [previewBox.topAnchor      constraintEqualToAnchor:content.topAnchor      constant:pad],
        [previewBox.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor  constant:pad],
        [previewBox.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
        [previewBox.heightAnchor   constraintEqualToConstant:200],
        [previewLabel.centerXAnchor constraintEqualToAnchor:previewBox.centerXAnchor],
        [previewLabel.centerYAnchor constraintEqualToAnchor:previewBox.centerYAnchor],
        // 本地文件
        [localFileCheck.topAnchor      constraintEqualToAnchor:previewBox.bottomAnchor constant:14],
        [localFileCheck.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor   constant:pad],
        // 路径行
        [pathField.topAnchor      constraintEqualToAnchor:localFileCheck.bottomAnchor constant:10],
        [pathField.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor      constant:pad],
        [pathField.trailingAnchor constraintEqualToAnchor:browseBtn.leadingAnchor    constant:-8],
        [pathField.heightAnchor   constraintEqualToConstant:24],
        [browseBtn.centerYAnchor constraintEqualToAnchor:pathField.centerYAnchor],
        [browseBtn.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
        // checkboxes
        [loopCheck.topAnchor      constraintEqualToAnchor:pathField.bottomAnchor     constant:14],
        [loopCheck.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor      constant:pad],
        [hwCheck.topAnchor        constraintEqualToAnchor:loopCheck.bottomAnchor      constant:8],
        [hwCheck.leadingAnchor    constraintEqualToAnchor:content.leadingAnchor      constant:pad],
        [autoRemoveCheck.topAnchor     constraintEqualToAnchor:hwCheck.bottomAnchor         constant:8],
        [autoRemoveCheck.leadingAnchor constraintEqualToAnchor:content.leadingAnchor        constant:pad],
        // 速度行
        [speedLabel.topAnchor     constraintEqualToAnchor:autoRemoveCheck.bottomAnchor constant:18],
        [speedLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor       constant:pad],
        [speedSlider.topAnchor    constraintEqualToAnchor:speedLabel.topAnchor],
        [speedSlider.leadingAnchor constraintEqualToAnchor:speedLabel.trailingAnchor  constant:10],
        [speedSlider.trailingAnchor constraintEqualToAnchor:speedValue.leadingAnchor constant:-8],
        [speedValue.topAnchor     constraintEqualToAnchor:speedLabel.topAnchor],
        [speedValue.trailingAnchor constraintEqualToAnchor:content.trailingAnchor    constant:-pad],
        [speedValue.widthAnchor   constraintEqualToConstant:40],
        // 分隔线
        [bottomSep.topAnchor      constraintEqualToAnchor:speedSlider.bottomAnchor  constant:18],
        [bottomSep.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor    constant:pad],
        [bottomSep.trailingAnchor constraintEqualToAnchor:content.trailingAnchor   constant:-pad],
        [bottomSep.heightAnchor   constraintEqualToConstant:1],
        // 按钮行
        [okBtn.topAnchor      constraintEqualToAnchor:bottomSep.bottomAnchor   constant:14],
        [okBtn.trailingAnchor constraintEqualToAnchor:content.trailingAnchor   constant:-pad],
        [cancelBtn.topAnchor      constraintEqualToAnchor:okBtn.topAnchor],
        [cancelBtn.trailingAnchor constraintEqualToAnchor:okBtn.leadingAnchor  constant:-12],
        [okBtn.bottomAnchor       constraintEqualToAnchor:content.bottomAnchor constant:-pad],
    ]];

    [hostWindow beginSheet:panel completionHandler:nil];
}

- (void)speedSliderChanged:(NSSlider *)sender {
    // 更新速度百分比标签
    NSTextField *label = [sender.window.contentView viewWithTag:300];
    label.stringValue = [NSString stringWithFormat:@"%d%%", (int)(sender.doubleValue * 100)];
}

- (void)browseForMediaFile:(id)sender {
    NSWindow *panel = [(NSView *)sender window];
    NSTextField *pathField = [panel.contentView viewWithTag:301];

    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.title = @"选择媒体文件";
    openPanel.allowsMultipleSelection = NO;
    openPanel.canChooseDirectories = NO;
    openPanel.canChooseFiles = YES;
    [openPanel beginSheetModalForWindow:panel completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            pathField.stringValue = openPanel.URLs.firstObject.path ?: @"";
        }
    }];
}

- (void)cancelMediaFilePanel:(id)sender {
    NSWindow *panel = [(NSView *)sender window];
    [panel.sheetParent endSheet:panel returnCode:NSModalResponseCancel];
}

- (void)confirmMediaFilePanel:(id)sender {
    NSWindow *panel = [(NSView *)sender window];
    NSTextField *pathField = [panel.contentView viewWithTag:301];
    NSButton *loopCheck     = [panel.contentView viewWithTag:302];

    NSString *path = pathField.stringValue;
    if (path.length == 0) {
        [self warn:@"请选择媒体文件"];
        return;
    }

    [panel.sheetParent endSheet:panel returnCode:NSModalResponseOK];

    WLSource *src = WLCore::AddSource("media_file", path.fileSystemRepresentation);
    if (!src) { [self warn:[NSString stringWithFormat:@"添加失败：%@", path.lastPathComponent]]; return; }
    if (src->Start() != 0) {
        WLCore::RemoveSource(src);
        [self warn:[NSString stringWithFormat:@"启动失败：%@", path.lastPathComponent]];
        return;
    }

    (void)loopCheck; // TODO: 接入 loop 设置

    [self.manager sendEvent:WLEventTypeSourceAdded info:@{
        @"sourcePtr": [NSValue valueWithPointer:src],
        @"name":      path.lastPathComponent,
        @"type":      src->Info().type_name ? @(src->Info().type_name) : @"—"
    }];
}

- (void)removeSelectedSource:(id)sender {
    NSInteger idx = self.tableView.selectedRow;
    if (idx < 0 || idx >= (NSInteger)self.rows.count) return;
    WLSourceRow *row = self.rows[idx];
    WLSource *src = row.src;

    [self.manager sendEvent:WLEventTypeSourceRemoved info:@{
        @"sourcePtr": [NSValue valueWithPointer:src],
        @"name":      row.name
    }];

    WLCore::RemoveSource(src);
}

- (void)warn:(NSString *)msg {
    NSLog(@"[SourcesDock] %@", msg);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = msg;
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.rows.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)column
                  row:(NSInteger)rowIndex {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:kCellID owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = kCellID;

        // 左侧 icon：play.fill
        NSImageView *leftIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        leftIcon.translatesAutoresizingMaskIntoConstraints = NO;
        leftIcon.imageScaling = NSImageScaleProportionallyDown;
        if (@available(macOS 11.0, *)) {
            leftIcon.image = [NSImage imageWithSystemSymbolName:@"play.fill"
                                     accessibilityDescription:@"源"];
        }
        leftIcon.contentTintColor = [NSColor colorWithWhite:0.55 alpha:1];
        leftIcon.tag = 200;
        [cell addSubview:leftIcon];

        // 名称
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell addSubview:tf];
        cell.textField = tf;

        // 右侧 icon：ellipsis
        NSImageView *rightIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        rightIcon.translatesAutoresizingMaskIntoConstraints = NO;
        rightIcon.imageScaling = NSImageScaleProportionallyDown;
        if (@available(macOS 11.0, *)) {
            rightIcon.image = [NSImage imageWithSystemSymbolName:@"ellipsis"
                                      accessibilityDescription:@"更多"];
        }
        rightIcon.contentTintColor = [NSColor colorWithWhite:0.40 alpha:1];
        rightIcon.tag = 201;
        [cell addSubview:rightIcon];

        [NSLayoutConstraint activateConstraints:@[
            [leftIcon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
            [leftIcon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [leftIcon.widthAnchor   constraintEqualToConstant:18],
            [leftIcon.heightAnchor  constraintEqualToConstant:18],
            [tf.leadingAnchor  constraintEqualToAnchor:leftIcon.trailingAnchor constant:8],
            [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
            [tf.trailingAnchor constraintEqualToAnchor:rightIcon.leadingAnchor constant:-6],
            [rightIcon.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-12],
            [rightIcon.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
            [rightIcon.widthAnchor    constraintEqualToConstant:16],
            [rightIcon.heightAnchor   constraintEqualToConstant:16],
        ]];
    }

    WLSourceRow *row = self.rows[rowIndex];
    cell.textField.stringValue = row.name;
    cell.textField.toolTip = [NSString stringWithFormat:@"%@（%@）", row.name, row.type];
    cell.textField.textColor = kTextNormal();

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    BOOL hasSelection = self.tableView.selectedRow >= 0;
    self.removeButton.enabled = hasSelection;

    // 广播选中变更（仅用户点击时，收到外部事件时不广播以防循环）
    if (!self.suppressSelectionBroadcast) {
        NSInteger idx = self.tableView.selectedRow;
        WLSource *src = (idx >= 0 && idx < (NSInteger)self.rows.count) ? self.rows[idx].src : NULL;
        [self.manager sendEvent:WLEventTypeSourceSelectionChanged info:@{
            @"sourcePtr": src ? [NSValue valueWithPointer:src] : [NSNull null]
        }];
    }
}

@end
