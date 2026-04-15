//
//  WLScenePanel.m
//  WorkLabs
//

#import "WLScenePanel.h"
#import <Masonry.h>
#import "NSView+BackgroundColor.h"
#import "WLEvent.h"

@interface WLScenePanel () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSView *titleBar;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSView *toolbarView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSString *> *scenes;

@end

@implementation WLScenePanel

- (instancetype)init {
    self = [super init];
    if (self) {
        _scenes = [@[@"场景"] mutableCopy];
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    [self backgroundColorWithHex:0x1E1E1E];

    // 标题栏
    self.titleBar = [[NSView alloc] init];
    [self.titleBar backgroundColorWithHex:0x252525];
    [self addSubview:self.titleBar];
    [self.titleBar mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.right.equalTo(self);
        make.height.mas_equalTo(30);
    }];

    NSImageView *iconView = [[NSImageView alloc] init];
    iconView.image = [NSImage imageWithSystemSymbolName:@"photo.on.rectangle"
                                  accessibilityDescription:nil];
    iconView.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.titleBar addSubview:iconView];
    [iconView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.titleBar).offset(8);
        make.centerY.equalTo(self.titleBar);
        make.width.height.mas_equalTo(14);
    }];

    NSTextField *titleLabel = [NSTextField labelWithString:@"场景"];
    titleLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    titleLabel.font = [NSFont systemFontOfSize:12.0];
    [self.titleBar addSubview:titleLabel];
    [titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(iconView.mas_right).offset(5);
        make.centerY.equalTo(self.titleBar);
    }];

    // 底部工具栏
    self.toolbarView = [[NSView alloc] init];
    [self.toolbarView backgroundColorWithHex:0x1A1A1A];
    [self addSubview:self.toolbarView];
    [self.toolbarView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.left.right.equalTo(self);
        make.height.mas_equalTo(32);
    }];
    [self setupToolbar];

    // 标题栏底部分隔线
    NSView *topSep = [[NSView alloc] init];
    [topSep backgroundColorWithHex:0x3C3C3C];
    [self addSubview:topSep];
    [topSep mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.titleBar.mas_bottom);
        make.left.right.equalTo(self);
        make.height.mas_equalTo(1);
    }];

    // 工具栏顶部分隔线
    NSView *bottomSep = [[NSView alloc] init];
    [bottomSep backgroundColorWithHex:0x3C3C3C];
    [self addSubview:bottomSep];
    [bottomSep mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.equalTo(self.toolbarView.mas_top);
        make.left.right.equalTo(self);
        make.height.mas_equalTo(1);
    }];

    // 内容区
    self.contentView = [[NSView alloc] init];
    [self.contentView backgroundColorWithHex:0x1E1E1E];
    [self addSubview:self.contentView];
    [self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(topSep.mas_bottom);
        make.left.right.equalTo(self);
        make.bottom.equalTo(bottomSep.mas_top);
    }];

    [self setupTableView];
}

- (void)setupTableView {
    NSScrollView *scrollView = [[NSScrollView alloc] init];
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.drawsBackground = NO;
    scrollView.borderType = NSNoBorder;
    [self.contentView addSubview:scrollView];
    [scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.contentView);
    }];

    self.tableView = [[NSTableView alloc] init];
    self.tableView.backgroundColor = [NSColor clearColor];
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.tableView.headerView = nil;
    self.tableView.rowHeight = 28.0;
    self.tableView.gridStyleMask = NSTableViewGridNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"SceneColumn"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    column.minWidth = 10;
    [self.tableView addTableColumn:column];

    scrollView.documentView = self.tableView;

    // 默认选中第一行
    if (self.scenes.count > 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
    }
}

- (void)setupToolbar {
    NSArray *configs = @[
        @[@"+",  NSStringFromSelector(@selector(addScene))],
        @[@"−",  NSStringFromSelector(@selector(deleteScene))],
        @[@"❐",  NSStringFromSelector(@selector(duplicateScene))],
        @[@"∧",  NSStringFromSelector(@selector(moveSceneUp))],
        @[@"∨",  NSStringFromSelector(@selector(moveSceneDown))],
    ];

    NSView *prev = nil;
    for (NSArray *cfg in configs) {
        NSButton *btn = [self makeToolbarButtonWithTitle:cfg[0]
                                                 action:NSSelectorFromString(cfg[1])];
        [self.toolbarView addSubview:btn];
        [btn mas_makeConstraints:^(MASConstraintMaker *make) {
            make.centerY.equalTo(self.toolbarView);
            make.width.height.mas_equalTo(24);
            if (prev) {
                make.left.equalTo(prev.mas_right).offset(2);
            } else {
                make.left.equalTo(self.toolbarView).offset(6);
            }
        }];
        prev = btn;
    }
}

- (NSButton *)makeToolbarButtonWithTitle:(NSString *)title action:(SEL)action {
    NSButton *btn = [[NSButton alloc] init];
    btn.title = title;
    btn.bezelStyle = NSBezelStyleSmallSquare;
    btn.bordered = NO;
    btn.font = [NSFont systemFontOfSize:13.0];
    btn.target = self;
    btn.action = action;
    [btn setContentTintColor:[NSColor colorWithWhite:0.65 alpha:1.0]];
    return btn;
}

#pragma mark - Toolbar Actions

- (void)addScene {
    NSString *name = [NSString stringWithFormat:@"场景 %lu", (unsigned long)(self.scenes.count + 1)];
    [self.scenes addObject:name];
    [self.tableView reloadData];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:self.scenes.count - 1]
                byExtendingSelection:NO];
    WLSend().type(WLObserveSceneChange).payload(name).send();
}

- (void)deleteScene {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || self.scenes.count <= 1) return;
    [self.scenes removeObjectAtIndex:row];
    [self.tableView reloadData];
    NSInteger newRow = MIN(row, (NSInteger)self.scenes.count - 1);
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow]
                byExtendingSelection:NO];
}

- (void)duplicateScene {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0) return;
    NSString *copy = [NSString stringWithFormat:@"%@ 副本", self.scenes[row]];
    [self.scenes insertObject:copy atIndex:row + 1];
    [self.tableView reloadData];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row + 1]
                byExtendingSelection:NO];
}

- (void)moveSceneUp {
    NSInteger row = self.tableView.selectedRow;
    if (row <= 0) return;
    [self.scenes exchangeObjectAtIndex:row withObjectAtIndex:row - 1];
    [self.tableView reloadData];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row - 1]
                byExtendingSelection:NO];
}

- (void)moveSceneDown {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.scenes.count - 1) return;
    [self.scenes exchangeObjectAtIndex:row withObjectAtIndex:row + 1];
    [self.tableView reloadData];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row + 1]
                byExtendingSelection:NO];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.scenes.count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(nullable NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"SceneCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        NSTextField *label = [NSTextField labelWithString:@""];
        label.identifier = @"SceneCellLabel";
        label.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
        label.font = [NSFont systemFontOfSize:12.0];
        [cell addSubview:label];
        cell.textField = label;
        [label mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(cell).offset(10);
            make.centerY.equalTo(cell);
            make.right.equalTo(cell).offset(-8);
        }];
        cell.identifier = @"SceneCell";
    }
    cell.textField.stringValue = self.scenes[row];
    return cell;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return 28.0;
}

@end
