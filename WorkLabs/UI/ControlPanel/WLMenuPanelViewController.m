//
//  WLMenuPanelViewController.m
//  WorkLabs
//

#import "WLMenuPanelViewController.h"
#import <Masonry.h>
#import "NSView+BackgroundColor.h"
#import "WLSceneManager.h"
#import "WLDevicesManager.h"
#import "WLCameraSourceConfig.h"
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSInteger, WLMenuItemType) {
    WLMenuItemTypeCamera,
    WLMenuItemTypeVideoFile,
    WLMenuItemTypeAudioFile,
};

@interface WLMenuPanelViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSArray<NSNumber *> *menuItems;

@end

@implementation WLMenuPanelViewController

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 64)];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.view backgroundColorWithHex:0x2A2A2A];
    [self setupItems];
    [self setupTableView];
}

- (void)setupItems {
    if (self.callerType == WLMenuPanelCallerTypeSource) {
        self.menuItems = @[@(WLMenuItemTypeCamera), @(WLMenuItemTypeVideoFile)];
    } else {
        self.menuItems = @[@(WLMenuItemTypeAudioFile)];
    }
    self.preferredContentSize = NSMakeSize(200, self.menuItems.count * 32.0);
}

- (void)setupTableView {
    self.tableView = [[NSTableView alloc] init];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.headerView = nil;
    self.tableView.backgroundColor = [NSColor clearColor];
    self.tableView.rowHeight = 32;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"item"];
    column.width = 200;
    [self.tableView addTableColumn:column];

    NSScrollView *scrollView = [[NSScrollView alloc] init];
    scrollView.documentView = self.tableView;
    scrollView.hasVerticalScroller = NO;
    scrollView.drawsBackground = NO;
    [self.view addSubview:scrollView];
    [scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.menuItems.count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    WLMenuItemType itemType = (WLMenuItemType)[self.menuItems[row] integerValue];

    NSString *title = nil;
    NSString *iconName = nil;
    BOOL hasArrow = NO;

    switch (itemType) {
        case WLMenuItemTypeCamera:
            title = @"摄像头";
            iconName = @"camera";
            hasArrow = YES;
            break;
        case WLMenuItemTypeVideoFile:
            title = @"视频文件";
            iconName = @"film";
            break;
        case WLMenuItemTypeAudioFile:
            title = @"音频文件";
            iconName = @"music.note";
            break;
    }

    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"MenuCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = @"MenuCell";

        NSImageView *iconView = [[NSImageView alloc] init];
        iconView.tag = 100;
        iconView.contentTintColor = [NSColor colorWithWhite:0.75 alpha:1.0];
        [cell addSubview:iconView];
        [iconView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(cell).offset(10);
            make.centerY.equalTo(cell);
            make.width.height.mas_equalTo(14);
        }];

        NSTextField *textField = [NSTextField labelWithString:@""];
        textField.tag = 200;
        textField.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
        textField.font = [NSFont systemFontOfSize:12.0];
        [cell addSubview:textField];
        [textField mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(iconView.mas_right).offset(6);
            make.centerY.equalTo(cell);
        }];

        NSTextField *arrowField = [NSTextField labelWithString:@"▸"];
        arrowField.tag = 300;
        arrowField.textColor = [NSColor colorWithWhite:0.55 alpha:1.0];
        arrowField.font = [NSFont systemFontOfSize:10.0];
        [cell addSubview:arrowField];
        [arrowField mas_makeConstraints:^(MASConstraintMaker *make) {
            make.right.equalTo(cell).offset(-8);
            make.centerY.equalTo(cell);
        }];
    }

    ((NSImageView *)[cell viewWithTag:100]).image = [NSImage imageWithSystemSymbolName:iconName accessibilityDescription:nil];
    ((NSTextField *)[cell viewWithTag:200]).stringValue = title;
    ((NSTextField *)[cell viewWithTag:300]).hidden = !hasArrow;

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.menuItems.count) return;

    WLMenuItemType itemType = (WLMenuItemType)[self.menuItems[row] integerValue];
    [self.tableView deselectAll:nil];

    switch (itemType) {
        case WLMenuItemTypeCamera:
            [self showCameraDeviceMenu];
            break;
        case WLMenuItemTypeVideoFile:
            [self addVideoFileSource];
            break;
        case WLMenuItemTypeAudioFile:
            [self addAudioFileSource];
            break;
    }
}

#pragma mark - Actions

- (void)showCameraDeviceMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    NSArray<WLDeviceItem *> *devices = [[WLDevicesManager manager] currentVideoDevices];

    if (devices.count > 0) {
        for (WLDeviceItem *device in devices) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:device.localizedName ?: @""
                                                         action:@selector(addCameraDevice:)
                                                  keyEquivalent:@""];
            item.target = self;
            item.representedObject = device.device;
            [menu addItem:item];
        }
    } else {
        NSMenuItem *noneItem = [[NSMenuItem alloc] initWithTitle:@"无可用摄像头" action:nil keyEquivalent:@""];
        noneItem.enabled = NO;
        [menu addItem:noneItem];
    }

    NSEvent *event = [NSApp currentEvent];
    [NSMenu popUpContextMenu:menu withEvent:event forView:self.tableView];
}

- (void)addCameraDevice:(NSMenuItem *)sender {
    AVCaptureDevice *device = sender.representedObject;
    if (!device) return;

    WLCameraSourceConfig *config = [[WLCameraSourceConfig alloc] init];
    config.device = device;
    config.sessionPreset = AVCaptureSessionPresetHigh;
    [[WLSceneManager manager] addCameraSourceWithConfig:config];

    [self dismissPopover];
}

- (void)addVideoFileSource {
    NSWindow *mainWindow = NSApp.mainWindow;
    [self dismissPopover];

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"mp4"],
        [UTType typeWithFilenameExtension:@"mov"],
        [UTType typeWithFilenameExtension:@"mkv"],
        [UTType typeWithFilenameExtension:@"avi"],
        [UTType typeWithFilenameExtension:@"m4v"],
    ];

    [panel beginSheetModalForWindow:mainWindow completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            [[WLSceneManager manager] addVideoSourceWithPath:panel.URL.path];
        }
    }];
}

- (void)addAudioFileSource {
    NSWindow *mainWindow = NSApp.mainWindow;
    [self dismissPopover];

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"mp3"],
        [UTType typeWithFilenameExtension:@"aac"],
        [UTType typeWithFilenameExtension:@"wav"],
        [UTType typeWithFilenameExtension:@"m4a"],
        [UTType typeWithFilenameExtension:@"flac"],
    ];

    [panel beginSheetModalForWindow:mainWindow completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            [[WLSceneManager manager] addAudioSourceWithPath:panel.URL.path];
        }
    }];
}

- (void)dismissPopover {
    if (self.dismissHandler) {
        self.dismissHandler();
    }
}

@end
