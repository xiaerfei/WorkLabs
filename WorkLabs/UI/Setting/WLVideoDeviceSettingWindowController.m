
#import "WLVideoDeviceSettingWindowController.h"
#import "WLVideoDeviceSettingView.h"
#import "WLDevicesManager.h"
#import "Masonry.h"

@interface WLVideoDeviceSettingWindowController () <WLVideoDeviceSettingViewDelegate>

@property (nonatomic, strong) WLVideoDeviceSettingView *settingView;

@end

@implementation WLVideoDeviceSettingWindowController

+ (instancetype)sharedController {
    static WLVideoDeviceSettingWindowController *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[WLVideoDeviceSettingWindowController alloc] initWithWindow:nil];
    });
    return instance;
}

- (instancetype)initWithWindow:(nullable NSWindow *)window {
    self = [super initWithWindow:window];
    if (self) {
        [self setupWindow];
    }
    return self;
}

- (void)setupWindow {
    NSRect contentRect = NSMakeRect(0, 0, 800, 600);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:contentRect
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.minSize = NSMakeSize(600, 500);
    window.level = NSNormalWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorManaged;

    self.window = window;
}

- (void)loadWindow {
    [self setupWindow];
}

- (void)windowDidLoad {
    [super windowDidLoad];

    self.settingView = [[WLVideoDeviceSettingView alloc] initWithFrame:self.window.contentView.bounds];
    self.settingView.delegate = self;

    [self.window.contentView addSubview:self.settingView];
    [self.settingView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.window.contentView);
    }];
}

- (void)showWindowWithSourceType:(NSUInteger)sourceType {
    if (!self.settingView) {
        [self windowDidLoad];
    }

    WLVideoSourceType type = (WLVideoSourceType)sourceType;

    self.window.title = (type == WLVideoSourceTypeCamera)
        ? @"设置 \"视频采集设备\""
        : @"设置 \"媒体源\"";

    [self.settingView switchToSourceType:type];

    if (type == WLVideoSourceTypeCamera) {
        NSArray *devices = [[WLDevicesManager manager] currentVideoDevices];
        [self.settingView updateCameraDevices:devices currentDeviceID:nil];
    } else {
        [self.settingView updateMediaFilePath:nil];
    }

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - WLVideoDeviceSettingViewDelegate

- (void)videoDeviceSettingViewDidClickCancel:(WLVideoDeviceSettingView *)view {
    [self.window close];
}

- (void)videoDeviceSettingView:(WLVideoDeviceSettingView *)view
  didConfirmCameraWithDevice:(NSString *)deviceID
                       preset:(NSString *)preset
                    useBuffer:(BOOL)useBuffer {
    if (self.delegate && [self.delegate respondsToSelector:@selector(videoDeviceSettingController:didConfirmWithDevice:preset:useBuffer:)]) {
        [self.delegate videoDeviceSettingController:self
                             didConfirmWithDevice:deviceID
                                           preset:preset
                                        useBuffer:useBuffer];
    }

    [self.window close];
}

- (void)videoDeviceSettingView:(WLVideoDeviceSettingView *)view
  didConfirmMediaWithFilePath:(NSString *)filePath {
    if (self.delegate && [self.delegate respondsToSelector:@selector(videoDeviceSettingController:didConfirmWithMediaPath:)]) {
        [self.delegate videoDeviceSettingController:self didConfirmWithMediaPath:filePath];
    }

    [self.window close];
}

@end
