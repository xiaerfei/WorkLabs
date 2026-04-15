
#import "WLMediaSourceSettingView.h"
#import "Masonry.h"
#import "NSView+BackgroundColor.h"

@interface WLMediaSourceSettingView ()

@property (nonatomic, strong) NSTextField *pathTextField;
@property (nonatomic, strong) NSButton *browseButton;

@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *confirmButton;

@end

@implementation WLMediaSourceSettingView

#pragma mark - Init

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    [self backgroundColorWithHexString:@"#1a1a1a"];
    [self setupUI];
}

- (void)setupUI {
    [self setupPathInput];
    [self setupButtons];
}

- (void)setupPathInput {
    NSTextField *pathLabel = [self createLabel:@"文件路径:"];
    [self addSubview:pathLabel];
    [pathLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self).offset(30);
        make.left.equalTo(self).offset(20);
        make.width.mas_equalTo(70);
    }];

    self.pathTextField = [[NSTextField alloc] init];
    self.pathTextField.font = [NSFont systemFontOfSize:13];
    self.pathTextField.placeholderString = @"请输入或选择本地视频文件路径";
    self.pathTextField.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self addSubview:self.pathTextField];
    [self.pathTextField mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(pathLabel.mas_right).offset(5);
        make.centerY.equalTo(pathLabel);
        make.right.equalTo(self).offset(-110);
        make.height.mas_equalTo(26);
    }];

    self.browseButton = [self createButton:@"浏览..."];
    [self addSubview:self.browseButton];
    [self.browseButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.pathTextField.mas_right).offset(10);
        make.centerY.equalTo(pathLabel);
        make.width.mas_equalTo(80);
        make.height.mas_equalTo(28);
    }];

    [self.browseButton setTarget:self];
    [self.browseButton setAction:@selector(browseButtonClick)];
}

- (void)setupButtons {
    self.confirmButton = [self createButton:@"确定"];
    [self addSubview:self.confirmButton];
    [self.confirmButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.right.equalTo(self).offset(-20);
        make.bottom.equalTo(self).offset(-20);
        make.width.mas_equalTo(80);
        make.height.mas_equalTo(30);
    }];

    self.cancelButton = [self createButton:@"取消"];
    [self addSubview:self.cancelButton];
    [self.cancelButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.right.equalTo(self.confirmButton.mas_left).offset(-15);
        make.bottom.equalTo(self).offset(-20);
        make.width.mas_equalTo(80);
        make.height.mas_equalTo(30);
    }];

    [self.cancelButton setTarget:self];
    [self.cancelButton setAction:@selector(cancelButtonClick)];

    [self.confirmButton setTarget:self];
    [self.confirmButton setAction:@selector(confirmButtonClick)];
}

#pragma mark - Helper Methods

- (NSTextField *)createLabel:(NSString *)text {
    NSTextField *label = [[NSTextField alloc] init];
    label.stringValue = text;
    label.textColor = [NSColor whiteColor];
    label.font = [NSFont systemFontOfSize:13];
    label.alignment = NSTextAlignmentRight;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    return label;
}

- (NSButton *)createButton:(NSString *)title {
    NSButton *button = [[NSButton alloc] init];
    button.title = title;
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

#pragma mark - Public Methods

- (void)updateWithFilePath:(nullable NSString *)filePath {
    if (filePath) {
        self.pathTextField.stringValue = filePath;
    } else {
        self.pathTextField.stringValue = @"";
    }
}

#pragma mark - Action Methods

- (void)browseButtonClick {
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = NO;
    openPanel.allowsMultipleSelection = NO;
    openPanel.title = @"选择视频文件";

    openPanel.allowedFileTypes = @[
        @"mp4", @"mov", @"mkv", @"avi", @"flv", @"wmv", @"webm", @"m4v", @"ts", @"mts"
    ];

    [openPanel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *selectedURL = openPanel.URLs.firstObject;
            if (selectedURL) {
                self.pathTextField.stringValue = selectedURL.path;
            }
        }
    }];
}

- (void)cancelButtonClick {
    if (self.delegate && [self.delegate respondsToSelector:@selector(mediaSourceSettingViewDidClickCancel:)]) {
        [self.delegate mediaSourceSettingViewDidClickCancel:self];
    }
}

- (void)confirmButtonClick {
    NSString *rawValue = self.pathTextField.stringValue;
    NSString *filePath = [rawValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (filePath.length == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"请输入视频文件路径";
        alert.informativeText = @"文件路径不能为空";
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"确定"];
        [alert runModal];
        return;
    }

    if (self.delegate && [self.delegate respondsToSelector:@selector(mediaSourceSettingView:didClickConfirmWithFilePath:)]) {
        [self.delegate mediaSourceSettingView:self didClickConfirmWithFilePath:filePath];
    }
}

@end
