//
//  WLSourcePanel.m
//  WorkLabs
//

#import "WLSourcePanel.h"
#import <Masonry.h>
#import "NSView+BackgroundColor.h"
#import "WLToolbarButton.h"
#import "WLSceneManager.h"
#import "WLMediaSourceItem.h"
#import "WLEvent.h"
#import "WLMenuPanelViewController.h"

@interface WLSourcePanel () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSView *titleBar;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSView *toolbarView;

@property (nonatomic, strong) NSTextField *iconLabel;
@property (nonatomic, strong) NSTextField *hintLabel;

@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;

@property (nonatomic, strong) WLToolbarButton *addButton;
@property (nonatomic, strong) WLEventDisposeBag *bag;
@property (nonatomic, strong) NSPopover *addPopover;

@end

@implementation WLSourcePanel

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    [self backgroundColorWithHex:0x1E1E1E];

    self.titleBar = [[NSView alloc] init];
    [self.titleBar backgroundColorWithHex:0x252525];
    [self addSubview:self.titleBar];
    [self.titleBar mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(self);
        make.height.mas_equalTo(30);
    }];

    NSImageView *iconView = [[NSImageView alloc] init];
    iconView.image = [NSImage imageWithSystemSymbolName:@"square.stack.3d.up" accessibilityDescription:nil];
    iconView.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.titleBar addSubview:iconView];
    [iconView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.titleBar).offset(8);
        make.centerY.equalTo(self.titleBar);
        make.width.height.mas_equalTo(14);
    }];

    NSTextField *titleLabel = [NSTextField labelWithString:@"源"];
    titleLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    titleLabel.font = [NSFont systemFontOfSize:12.0];
    [self.titleBar addSubview:titleLabel];
    [titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(iconView.mas_right).offset(5);
        make.centerY.equalTo(self.titleBar);
    }];

    self.toolbarView = [[NSView alloc] init];
    [self.toolbarView backgroundColorWithHex:0x1A1A1A];
    [self addSubview:self.toolbarView];
    [self.toolbarView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.left.right.equalTo(self);
        make.height.mas_equalTo(32);
    }];
    [self setupToolbar];

    NSView *topSep = [[NSView alloc] init];
    [topSep backgroundColorWithHex:0x3C3C3C];
    [self addSubview:topSep];
    [topSep mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.titleBar.mas_bottom);
        make.left.right.equalTo(self);
        make.height.mas_equalTo(1);
    }];

    NSView *bottomSep = [[NSView alloc] init];
    [bottomSep backgroundColorWithHex:0x3C3C3C];
    [self addSubview:bottomSep];
    [bottomSep mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.equalTo(self.toolbarView.mas_top);
        make.left.right.equalTo(self);
        make.height.mas_equalTo(1);
    }];

    self.contentView = [[NSView alloc] init];
    [self.contentView backgroundColorWithHex:0x1E1E1E];
    [self addSubview:self.contentView];
    [self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(topSep.mas_bottom);
        make.left.right.equalTo(self);
        make.bottom.equalTo(bottomSep.mas_top);
    }];

    [self setupEmptyState];
}

- (void)setupEmptyState {
    self.iconLabel = [NSTextField labelWithString:@"?"];
    self.iconLabel.font = [NSFont systemFontOfSize:36.0 weight:NSFontWeightThin];
    self.iconLabel.textColor = [NSColor colorWithWhite:0.35 alpha:1.0];
    self.iconLabel.alignment = NSTextAlignmentCenter;
    [self.contentView addSubview:self.iconLabel];
    [self.iconLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.equalTo(self.contentView);
        make.centerY.equalTo(self.contentView).offset(-20);
        make.width.mas_equalTo(50);
    }];

    self.hintLabel = [NSTextField labelWithString:@"您还没有添加任何源。\n点击下面的 + 按钮，\n或者右击此处添加一个。"];
    self.hintLabel.font = [NSFont systemFontOfSize:11.0];
    self.hintLabel.textColor = [NSColor colorWithWhite:0.45 alpha:1.0];
    self.hintLabel.alignment = NSTextAlignmentCenter;
    self.hintLabel.maximumNumberOfLines = 3;
    [self.contentView addSubview:self.hintLabel];
    [self.hintLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.iconLabel.mas_bottom).offset(6);
        make.left.equalTo(self.contentView).offset(8);
        make.right.equalTo(self.contentView).offset(-8);
    }];

    [self setupTableView];
    [self registerEventObservers];
    [self updateContentViewVisibility];
}

- (void)setupToolbar {
    self.addButton = [self makeToolbarButtonWithSymbolName:@"plus" action:@selector(showAddPopover)];
    [self.toolbarView addSubview:self.addButton];
    [self.addButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(self.toolbarView);
        make.left.equalTo(self.toolbarView).offset(6);
        make.width.height.mas_equalTo(24);
    }];

    WLToolbarButton *deleteBtn = [self makeToolbarButtonWithSymbolName:@"minus" action:@selector(deleteSource)];
    [self.toolbarView addSubview:deleteBtn];
    [deleteBtn mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(self.toolbarView);
        make.left.equalTo(self.addButton.mas_right).offset(2);
        make.width.height.mas_equalTo(24);
    }];
}

- (WLToolbarButton *)makeToolbarButtonWithSymbolName:(NSString *)symbolName action:(SEL)action {
    WLToolbarButton *btn = [[WLToolbarButton alloc] init];
    btn.bezelStyle = NSBezelStyleSmallSquare;
    btn.bordered = NO;
    btn.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    btn.imagePosition = NSImageOnly;
    btn.target = self;
    btn.action = action;
    [btn setContentTintColor:[NSColor whiteColor]];

    NSTrackingArea *trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                                options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect | NSViewWidthSizable | NSViewHeightSizable)
                                                                  owner:btn
                                                               userInfo:nil];
    [btn addTrackingArea:trackingArea];
    return btn;
}

#pragma mark - Toolbar Actions

- (void)showAddPopover {
    WLMenuPanelViewController *menuVC = [[WLMenuPanelViewController alloc] init];
    menuVC.callerType = WLMenuPanelCallerTypeSource;

    self.addPopover = [[NSPopover alloc] init];
    self.addPopover.contentViewController = menuVC;
    self.addPopover.behavior = NSPopoverBehaviorTransient;

    __weak typeof(self) weakSelf = self;
    menuVC.dismissHandler = ^{
        [weakSelf.addPopover close];
        weakSelf.addPopover = nil;
    };

    [self.addPopover showRelativeToRect:self.addButton.bounds
                                 ofView:self.addButton
                          preferredEdge:NSRectEdgeMaxY];
}

- (void)deleteSource {
    WLMediaSourceItem *selected = [WLSceneManager manager].selectedSource;
    if (selected) {
        [[WLSceneManager manager] removeSource:selected];
    }
}

#pragma mark - TableView Setup

- (void)setupTableView {
    self.tableView = [[NSTableView alloc] init];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.headerView = nil;
    self.tableView.backgroundColor = [NSColor colorWithWhite:0.12 alpha:1.0];
    self.tableView.rowHeight = 28;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"source"];
    column.width = 200;
    [self.tableView addTableColumn:column];

    self.scrollView = [[NSScrollView alloc] init];
    self.scrollView.documentView = self.tableView;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.drawsBackground = NO;
    self.scrollView.hidden = YES;
    [self.contentView addSubview:self.scrollView];
    [self.scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.contentView);
    }];
}

#pragma mark - Event Observers

- (void)registerEventObservers {
    __weak typeof(self) weakSelf = self;
    self.bag = [WLEventDisposeBag new];

    WLObserve(@[@(WLObserveSourceChange)])
        .mainQueue()
        .dispose(self.bag)
        .block(^(WLObserve type, id payload) {
            [weakSelf.tableView reloadData];
            [weakSelf updateContentViewVisibility];
        });
}

- (void)updateContentViewVisibility {
    BOOL hasSources = [self filteredSources].count > 0;
    self.iconLabel.hidden = hasSources;
    self.hintLabel.hidden = hasSources;
    self.scrollView.hidden = !hasSources;
}

- (NSArray<WLMediaSourceItem *> *)filteredSources {
    return [[WLSceneManager manager].sources filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(WLMediaSourceItem *item, NSDictionary *bindings) {
            return item.type != WLMediaSourceTypeAudio;
        }]];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [self filteredSources].count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSArray<WLMediaSourceItem *> *sources = [self filteredSources];
    if (row < 0 || row >= (NSInteger)sources.count) return nil;

    WLMediaSourceItem *item = sources[row];

    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"SourceCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = @"SourceCell";

        NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(4, 4, 16, 16)];
        iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        iconView.tag = 100;
        [cell addSubview:iconView];

        NSTextField *textField = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 2, 180, 20)];
        textField.editable = NO;
        textField.bordered = NO;
        textField.backgroundColor = [NSColor clearColor];
        textField.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
        textField.font = [NSFont systemFontOfSize:11.0];
        textField.tag = 200;
        [cell addSubview:textField];
    }

    NSImageView *iconView = [cell viewWithTag:100];
    NSString *iconName = nil;
    switch (item.type) {
        case WLMediaSourceTypeCamera: iconName = @"camera.fill"; break;
        case WLMediaSourceTypeVideo:  iconName = @"film";        break;
        default:                      iconName = @"questionmark"; break;
    }
    iconView.image = [NSImage imageWithSystemSymbolName:iconName accessibilityDescription:nil];
    iconView.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];

    NSTextField *textField = [cell viewWithTag:200];
    textField.stringValue = item.name ?: @"";

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.tableView.selectedRow;
    NSArray<WLMediaSourceItem *> *sources = [self filteredSources];
    if (row >= 0 && row < (NSInteger)sources.count) {
        [[WLSceneManager manager] selectSource:sources[row]];
    } else {
        [[WLSceneManager manager] deselectAll];
    }
}

@end
