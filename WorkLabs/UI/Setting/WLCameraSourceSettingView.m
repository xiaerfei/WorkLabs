
#import "WLCameraSourceSettingView.h"
#import "Masonry.h"
#import "NSView+BackgroundColor.h"

@interface WLCameraSourceSettingView () <NSComboBoxDataSource, NSComboBoxDelegate>

@property (nonatomic, strong) WLViedoPreview *previewView;
@property (nonatomic, strong) NSComboBox *deviceComboBox;
@property (nonatomic, strong) NSButton *usePresetCheckBox;
@property (nonatomic, strong) NSComboBox *presetComboBox;
@property (nonatomic, strong) NSButton *useBufferCheckBox;

@property (nonatomic, strong) NSButton *defaultButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *confirmButton;

@property (nonatomic, strong) NSArray<WLDeviceItem *> *devices;
@property (nonatomic, strong) NSString *currentDeviceID;

@property (nonatomic, strong) NSArray<NSString *> *presetItems;

@end

@implementation WLCameraSourceSettingView

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

    _presetItems = @[@"High", @"Medium", @"Low"];
    _devices = @[];

    [self setupUI];
}

- (void)setupUI {
    [self setupPreview];
    [self setupDeviceSelection];
    [self setupPresetCheckbox];
    [self setupPresetSelection];
    [self setupBufferOption];
    [self setupButtons];
}

- (void)setupPreview {
    self.previewView = [[WLViedoPreview alloc] init];
    self.previewView.wantsLayer = YES;
    self.previewView.layer.backgroundColor = [NSColor blackColor].CGColor;
    self.previewView.layer.cornerRadius = 4;

    [self addSubview:self.previewView];
    [self.previewView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self).offset(20);
        make.left.equalTo(self).offset(20);
        make.right.equalTo(self).offset(-20);
        make.height.mas_equalTo(300);
    }];
}

- (void)setupDeviceSelection {
    NSTextField *deviceLabel = [self createLabel:@"设备:"];
    [self addSubview:deviceLabel];
    [deviceLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.previewView.mas_bottom).offset(20);
        make.left.equalTo(self).offset(20);
        make.width.mas_equalTo(60);
    }];

    self.deviceComboBox = [self createComboBox];
    [self addSubview:self.deviceComboBox];
    [self.deviceComboBox mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(deviceLabel.mas_right).offset(5);
        make.centerY.equalTo(deviceLabel);
        make.right.equalTo(self).offset(-20);
        make.height.mas_equalTo(26);
    }];
}

- (void)setupPresetCheckbox {
    self.usePresetCheckBox = [self createCheckBox:@"使用预设"];
    self.usePresetCheckBox.state = NSControlStateValueOn;
    [self addSubview:self.usePresetCheckBox];
    [self.usePresetCheckBox mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.deviceComboBox.mas_bottom).offset(15);
        make.left.equalTo(self.deviceComboBox);
        make.height.mas_equalTo(22);
    }];

    [self.usePresetCheckBox setTarget:self];
    [self.usePresetCheckBox setAction:@selector(presetCheckBoxChanged:)];
}

- (void)setupPresetSelection {
    NSTextField *presetLabel = [self createLabel:@"预设:"];
    [self addSubview:presetLabel];
    [presetLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.usePresetCheckBox.mas_bottom).offset(10);
        make.left.equalTo(self).offset(20);
        make.width.mas_equalTo(60);
    }];

    self.presetComboBox = [self createComboBox];
    self.presetComboBox.enabled = YES;
    [self addSubview:self.presetComboBox];
    [self.presetComboBox mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(presetLabel.mas_right).offset(5);
        make.centerY.equalTo(presetLabel);
        make.right.equalTo(self).offset(-20);
        make.height.mas_equalTo(26);
    }];
}

- (void)setupBufferOption {
    self.useBufferCheckBox = [self createCheckBox:@"使用缓冲"];
    self.useBufferCheckBox.state = NSControlStateValueOff;
    [self addSubview:self.useBufferCheckBox];
    [self.useBufferCheckBox mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.presetComboBox.mas_bottom).offset(10);
        make.left.equalTo(self.presetComboBox);
        make.height.mas_equalTo(22);
    }];
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

    self.defaultButton = [self createButton:@"默认值"];
    [self addSubview:self.defaultButton];
    [self.defaultButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self).offset(20);
        make.bottom.equalTo(self).offset(-20);
        make.width.mas_equalTo(80);
        make.height.mas_equalTo(30);
    }];

    [self.defaultButton setTarget:self];
    [self.defaultButton setAction:@selector(defaultButtonClick)];

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

- (NSComboBox *)createComboBox {
    NSComboBox *comboBox = [[NSComboBox alloc] init];
    comboBox.usesDataSource = YES;
    comboBox.dataSource = self;
    comboBox.delegate = self;
    comboBox.editable = NO;
    return comboBox;
}

- (NSButton *)createCheckBox:(NSString *)title {
    NSButton *checkBox = [[NSButton alloc] init];
    checkBox.title = title;
    checkBox.bezelStyle = NSBezelStyleRegularSquare;
    checkBox.buttonType = NSButtonTypeSwitch;
    checkBox.state = NSControlStateValueOff;
    checkBox.contentTintColor = [NSColor whiteColor];
    return checkBox;
}

- (NSButton *)createButton:(NSString *)title {
    NSButton *button = [[NSButton alloc] init];
    button.title = title;
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

#pragma mark - Public Methods

- (void)updateWithDevices:(NSArray<WLDeviceItem *> *)devices currentDeviceID:(nullable NSString *)currentDeviceID {
    _devices = devices ?: @[];
    _currentDeviceID = currentDeviceID;

    [self.deviceComboBox reloadData];
    [self.presetComboBox reloadData];

    if (currentDeviceID && currentDeviceID.length > 0) {
        for (NSInteger i = 0; i < devices.count; i++) {
            if ([devices[i].uniqueID isEqualToString:currentDeviceID]) {
                [self.deviceComboBox selectItemAtIndex:i];
                break;
            }
        }
    } else if (devices.count > 0) {
        [self.deviceComboBox selectItemAtIndex:0];
    }

    [self.presetComboBox selectItemAtIndex:0];
}

- (void)resetToDefault {
    self.usePresetCheckBox.state = NSControlStateValueOn;
    self.presetComboBox.enabled = YES;
    [self.presetComboBox selectItemAtIndex:0];

    self.useBufferCheckBox.state = NSControlStateValueOff;

    if (self.devices.count > 0) {
        [self.deviceComboBox selectItemAtIndex:0];
    }
}

#pragma mark - Action Methods

- (void)presetCheckBoxChanged:(NSButton *)sender {
    self.presetComboBox.enabled = (sender.state == NSControlStateValueOn);
}

- (void)defaultButtonClick {
    [self resetToDefault];
    if (self.delegate && [self.delegate respondsToSelector:@selector(cameraSourceSettingViewDidClickDefault:)]) {
        [self.delegate cameraSourceSettingViewDidClickDefault:self];
    }
}

- (void)cancelButtonClick {
    if (self.delegate && [self.delegate respondsToSelector:@selector(cameraSourceSettingViewDidClickCancel:)]) {
        [self.delegate cameraSourceSettingViewDidClickCancel:self];
    }
}

- (void)confirmButtonClick {
    NSInteger deviceIndex = self.deviceComboBox.indexOfSelectedItem;
    NSInteger presetIndex = self.presetComboBox.indexOfSelectedItem;

    NSString *deviceID = nil;
    if (deviceIndex != NSNotFound && deviceIndex < self.devices.count) {
        deviceID = self.devices[deviceIndex].uniqueID;
    }

    NSString *preset = nil;
    if (presetIndex != NSNotFound && presetIndex < self.presetItems.count) {
        preset = self.presetItems[presetIndex];
    }

    BOOL useBuffer = (self.useBufferCheckBox.state == NSControlStateValueOn);

    if (self.delegate && [self.delegate respondsToSelector:@selector(cameraSourceSettingView:didClickConfirmWithDevice:preset:useBuffer:)]) {
        [self.delegate cameraSourceSettingView:self
                     didClickConfirmWithDevice:deviceID
                                        preset:preset
                                     useBuffer:useBuffer];
    }
}

#pragma mark - NSComboBoxDataSource

- (NSInteger)numberOfItemsInComboBox:(NSComboBox *)comboBox {
    if (comboBox == self.deviceComboBox) {
        return self.devices.count;
    } else if (comboBox == self.presetComboBox) {
        return self.presetItems.count;
    }
    return 0;
}

- (id)comboBox:(NSComboBox *)comboBox objectValueForItemAtIndex:(NSInteger)index {
    if (comboBox == self.deviceComboBox) {
        if (index < 0 || index >= self.devices.count) return @"";
        return self.devices[index].localizedName ?: @"";
    } else if (comboBox == self.presetComboBox) {
        if (index < 0 || index >= self.presetItems.count) return @"";
        return self.presetItems[index];
    }
    return @"";
}

#pragma mark - NSComboBoxDelegate

- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
}

@end
