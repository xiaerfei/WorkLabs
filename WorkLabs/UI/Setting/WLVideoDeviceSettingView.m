
#import "WLVideoDeviceSettingView.h"
#import "WLCameraSourceSettingView.h"
#import "WLMediaSourceSettingView.h"
#import "Masonry.h"
#import "NSView+BackgroundColor.h"

@interface WLVideoDeviceSettingView () <WLCameraSourceSettingViewDelegate, WLMediaSourceSettingViewDelegate>

@property (nonatomic, assign) WLVideoSourceType currentSourceType;

@property (nonatomic, strong) WLCameraSourceSettingView *cameraView;
@property (nonatomic, strong) WLMediaSourceSettingView *mediaView;

@property (nonatomic, strong) NSView *activeView;

@end

@implementation WLVideoDeviceSettingView

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

    _cameraView = [[WLCameraSourceSettingView alloc] initWithFrame:self.bounds];
    _cameraView.delegate = self;

    _mediaView = [[WLMediaSourceSettingView alloc] initWithFrame:self.bounds];
    _mediaView.delegate = self;
}

#pragma mark - Public Methods

- (void)switchToSourceType:(WLVideoSourceType)sourceType {
    self.currentSourceType = sourceType;

    if (self.activeView) {
        [self.activeView removeFromSuperview];
        self.activeView = nil;
    }

    NSView *view = (sourceType == WLVideoSourceTypeCamera) ? self.cameraView : self.mediaView;

    [self addSubview:view];
    [view mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self);
    }];

    self.activeView = view;
}

- (void)updateCameraDevices:(NSArray<WLDeviceItem *> *)devices
             currentDeviceID:(nullable NSString *)currentDeviceID {
    [self.cameraView updateWithDevices:devices currentDeviceID:currentDeviceID];
}

- (void)updateMediaFilePath:(nullable NSString *)filePath {
    [self.mediaView updateWithFilePath:filePath];
}

#pragma mark - WLCameraSourceSettingViewDelegate

- (void)cameraSourceSettingViewDidClickCancel:(WLCameraSourceSettingView *)view {
    if (self.delegate && [self.delegate respondsToSelector:@selector(videoDeviceSettingViewDidClickCancel:)]) {
        [self.delegate videoDeviceSettingViewDidClickCancel:self];
    }
}

- (void)cameraSourceSettingViewDidClickDefault:(WLCameraSourceSettingView *)view {
}

- (void)cameraSourceSettingView:(WLCameraSourceSettingView *)view
       didClickConfirmWithDevice:(NSString *)deviceID
                         preset:(NSString *)preset
                      useBuffer:(BOOL)useBuffer {
    if (self.delegate && [self.delegate respondsToSelector:@selector(videoDeviceSettingView:didConfirmCameraWithDevice:preset:useBuffer:)]) {
        [self.delegate videoDeviceSettingView:self
                     didConfirmCameraWithDevice:deviceID
                                        preset:preset
                                     useBuffer:useBuffer];
    }
}

#pragma mark - WLMediaSourceSettingViewDelegate

- (void)mediaSourceSettingViewDidClickCancel:(WLMediaSourceSettingView *)view {
    if (self.delegate && [self.delegate respondsToSelector:@selector(videoDeviceSettingViewDidClickCancel:)]) {
        [self.delegate videoDeviceSettingViewDidClickCancel:self];
    }
}

- (void)mediaSourceSettingView:(WLMediaSourceSettingView *)view
  didClickConfirmWithFilePath:(NSString *)filePath {
    if (self.delegate && [self.delegate respondsToSelector:@selector(videoDeviceSettingView:didConfirmMediaWithFilePath:)]) {
        [self.delegate videoDeviceSettingView:self didConfirmMediaWithFilePath:filePath];
    }
}

@end
