//
//  WLVideoSelectView.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import "WLVideoSelectView.h"
#import "Masonry.h"


@implementation WLVideoSelectView {
    NSComboBox *_deviceCombo;
    NSComboBox *_resolutionCombo;
    NSComboBox *_frameRateCombo;

    NSArray<WLDeviceItem *> *_deviceItems;

    NSInteger _selectedDeviceIndex;
    NSInteger _selectedFormatIndex;
    NSInteger _selectedFrameRateIndex;

    BOOL _suppressCallback;
}

#pragma mark - Init

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _selectedDeviceIndex = NSNotFound;
    _selectedFormatIndex = NSNotFound;
    _selectedFrameRateIndex = NSNotFound;

    _deviceCombo = [self newComboBox];
    _resolutionCombo = [self newComboBox];
    _frameRateCombo = [self newComboBox];

    [self addSubview:_deviceCombo];
    [self addSubview:_resolutionCombo];
    [self addSubview:_frameRateCombo];

    // Masonry (macOS 用 mas_ 前缀属性)
    CGFloat spacing = 8.0;
    CGFloat height = 26.0;

    [_deviceCombo mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.mas_left);
        make.centerY.equalTo(self.mas_centerY);
        make.height.mas_equalTo(height);
    }];

    [_resolutionCombo mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(_deviceCombo.mas_right).offset(spacing);
        make.centerY.equalTo(self.mas_centerY);
        make.height.mas_equalTo(height);
        make.width.equalTo(_deviceCombo.mas_width);
    }];

    [_frameRateCombo mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(_resolutionCombo.mas_right).offset(spacing);
        make.right.equalTo(self.mas_right);
        make.centerY.equalTo(self.mas_centerY);
        make.height.mas_equalTo(height);
        make.width.equalTo(_deviceCombo.mas_width);
    }];

    // 让第一个也等宽（避免约束不完整）
    [_deviceCombo mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.equalTo(_resolutionCombo.mas_width);
    }];
}

- (NSComboBox *)newComboBox {
    NSComboBox *cb = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    cb.usesDataSource = YES;
    cb.dataSource = self;
    cb.delegate = self;
    cb.editable = NO;
    cb.selectable = YES;
    cb.completes = NO;
    cb.buttonBordered = YES;
    return cb;
}

#pragma mark - Public

- (void)updateWithDeviceItems:(NSArray<WLDeviceItem *> *)deviceItems {
    _deviceItems = deviceItems ?: @[];

    // 尽量保留旧选择
    NSString *prevUniqueID = [self currentDevice].uniqueID;
    CMVideoDimensions prevDim = [self currentFormat].dimension;
    NSNumber *prevFps = [self currentFrameRate];

    _suppressCallback = YES;

    [_deviceCombo reloadData];
    [_resolutionCombo reloadData];
    [_frameRateCombo reloadData];

    _selectedDeviceIndex = NSNotFound;
    _selectedFormatIndex = NSNotFound;
    _selectedFrameRateIndex = NSNotFound;

    if (prevUniqueID.length > 0) {
        [self setSelectedDeviceByUniqueID:prevUniqueID];
    } else if (_deviceItems.count > 0) {
        [self selectDeviceIndex:0];
    }

    if (_selectedDeviceIndex != NSNotFound) {
        if (prevDim.width > 0 && prevDim.height > 0) {
            [self setSelectedResolution:prevDim];
        } else {
            [self selectFormatIndex:0];
        }

        if (prevFps != nil) {
            [self setSelectedFrameRate:prevFps];
        } else {
            [self selectFrameRateIndex:0];
        }
    }

    _suppressCallback = NO;
    [self fireSelectionChanged];
}

- (void)setSelectedDeviceByUniqueID:(NSString *)uniqueID {
    if (uniqueID.length == 0) return;
    NSInteger idx = NSNotFound;
    for (NSInteger i = 0; i < _deviceItems.count; i++) {
        if ([_deviceItems[i].uniqueID isEqualToString:uniqueID]) { idx = i; break; }
    }
    if (idx == NSNotFound) return;
    [self selectDeviceIndex:idx];
    [self fireSelectionChangedIfNeeded];
}

- (void)setSelectedDeviceByLocalizedName:(NSString *)localizedName {
    if (localizedName.length == 0) return;
    NSInteger idx = NSNotFound;
    for (NSInteger i = 0; i < _deviceItems.count; i++) {
        if ([_deviceItems[i].localizedName isEqualToString:localizedName]) { idx = i; break; }
    }
    if (idx == NSNotFound) return;
    [self selectDeviceIndex:idx];
    [self fireSelectionChangedIfNeeded];
}

- (void)setSelectedResolution:(CMVideoDimensions)dimension {
    WLDeviceItem *d = [self currentDevice];
    if (!d) return;

    NSInteger idx = NSNotFound;
    for (NSInteger i = 0; i < d.formats.count; i++) {
        CMVideoDimensions dim = d.formats[i].dimension;
        if (dim.width == dimension.width && dim.height == dimension.height) { idx = i; break; }
    }
    if (idx == NSNotFound) return;

    [self selectFormatIndex:idx];
    [self fireSelectionChangedIfNeeded];
}

- (void)setSelectedFrameRate:(NSNumber *)frameRate {
    WLDeviceFormat *f = [self currentFormat];
    if (!f || frameRate == nil) return;

    NSInteger idx = NSNotFound;
    for (NSInteger i = 0; i < f.frameRate.count; i++) {
        if (fabs(f.frameRate[i].doubleValue - frameRate.doubleValue) < 0.0001) { idx = i; break; }
    }
    if (idx == NSNotFound) return;

    [self selectFrameRateIndex:idx];
    [self fireSelectionChangedIfNeeded];
}

#pragma mark - Internal select

- (void)selectDeviceIndex:(NSInteger)idx {
    if (idx < 0 || idx >= _deviceItems.count) return;

    _selectedDeviceIndex = idx;
    [_deviceCombo selectItemAtIndex:idx];

    [_resolutionCombo reloadData];
    _selectedFormatIndex = NSNotFound;
    [self selectFormatIndex:0];
}

- (void)selectFormatIndex:(NSInteger)idx {
    WLDeviceItem *d = [self currentDevice];
    if (!d) return;
    if (idx < 0 || idx >= d.formats.count) return;

    _selectedFormatIndex = idx;
    [_resolutionCombo selectItemAtIndex:idx];

    [_frameRateCombo reloadData];
    _selectedFrameRateIndex = NSNotFound;
    [self selectFrameRateIndex:0];
}

- (void)selectFrameRateIndex:(NSInteger)idx {
    WLDeviceFormat *f = [self currentFormat];
    if (!f) return;
    if (idx < 0 || idx >= f.frameRate.count) return;

    _selectedFrameRateIndex = idx;
    [_frameRateCombo selectItemAtIndex:idx];
}

#pragma mark - Current

- (WLDeviceItem *)currentDevice {
    if (_selectedDeviceIndex == NSNotFound) return nil;
    if (_selectedDeviceIndex < 0 || _selectedDeviceIndex >= _deviceItems.count) return nil;
    return _deviceItems[_selectedDeviceIndex];
}

- (WLDeviceFormat *)currentFormat {
    WLDeviceItem *d = [self currentDevice];
    if (!d) return nil;
    if (_selectedFormatIndex == NSNotFound) return nil;
    if (_selectedFormatIndex < 0 || _selectedFormatIndex >= d.formats.count) return nil;
    return d.formats[_selectedFormatIndex];
}

- (NSNumber *)currentFrameRate {
    WLDeviceFormat *f = [self currentFormat];
    if (!f) return nil;
    if (_selectedFrameRateIndex == NSNotFound) return nil;
    if (_selectedFrameRateIndex < 0 || _selectedFrameRateIndex >= f.frameRate.count) return nil;
    return f.frameRate[_selectedFrameRateIndex];
}

#pragma mark - Callback

- (void)fireSelectionChangedIfNeeded {
    if (_suppressCallback) return;
    [self fireSelectionChanged];
}

- (void)fireSelectionChanged {
    if (!self.onSelectionChanged) return;
    self.onSelectionChanged([self currentDevice], [self currentFormat], [self currentFrameRate]);
}

#pragma mark - NSComboBoxDataSource

- (NSInteger)numberOfItemsInComboBox:(NSComboBox *)comboBox {
    if (comboBox == _deviceCombo) return _deviceItems.count;
    if (comboBox == _resolutionCombo) return [self currentDevice].formats.count;
    if (comboBox == _frameRateCombo) return [self currentFormat].frameRate.count;
    return 0;
}

- (id)comboBox:(NSComboBox *)comboBox objectValueForItemAtIndex:(NSInteger)index {
    if (comboBox == _deviceCombo) {
        if (index < 0 || index >= _deviceItems.count) return @"";
        return _deviceItems[index].localizedName ?: @"";
    }
    if (comboBox == _resolutionCombo) {
        WLDeviceItem *d = [self currentDevice];
        if (!d || index < 0 || index >= d.formats.count) return @"";
        CMVideoDimensions dim = d.formats[index].dimension;
        return [NSString stringWithFormat:@"%d x %d", dim.width, dim.height];
    }
    if (comboBox == _frameRateCombo) {
        WLDeviceFormat *f = [self currentFormat];
        if (!f || index < 0 || index >= f.frameRate.count) return @"";
        NSNumber *fps = f.frameRate[index];
        double v = fps.doubleValue;
        if (fabs(v - round(v)) < 0.0001) return [NSString stringWithFormat:@"%.0f fps", v];
        return [NSString stringWithFormat:@"%.2f fps", v];
    }
    return @"";
}

#pragma mark - NSComboBoxDelegate

- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    NSComboBox *cb = notification.object;

    if (cb == _deviceCombo) {
        NSInteger idx = cb.indexOfSelectedItem;
        if (idx != NSNotFound) {
            [self selectDeviceIndex:idx];
            [self fireSelectionChangedIfNeeded];
        }
        return;
    }

    if (cb == _resolutionCombo) {
        NSInteger idx = cb.indexOfSelectedItem;
        if (idx != NSNotFound) {
            [self selectFormatIndex:idx];
            [self fireSelectionChangedIfNeeded];
        }
        return;
    }

    if (cb == _frameRateCombo) {
        NSInteger idx = cb.indexOfSelectedItem;
        if (idx != NSNotFound) {
            [self selectFrameRateIndex:idx];
            [self fireSelectionChangedIfNeeded];
        }
        return;
    }
}

@end
