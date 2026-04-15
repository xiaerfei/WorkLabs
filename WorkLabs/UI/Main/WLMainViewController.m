//
//  WLMainViewController.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/9.
//

#import "WLMainViewController.h"
#include <libavformat/avformat.h>
#import "NSView+BackgroundColor.h"
#import "WLVideoManager.h"
#import "WLDevicesManager.h"
#import "WLViedoPreview.h"
#import <Masonry.h>
#import "TVUVideoManager.h"
#import <TVURSignal.h>

#import "WLEvent.h"

#import "WLMediaSource.h"
#import "WLRenderingManager.h"
#import "WLStreamsManager.h"
#import "WLNode.h"

#import "WLVideoDeviceSettingWindowController.h"
#import "WLVideoDeviceSettingView.h"

@interface WLTopNavigationBar : NSView
@property (nonatomic, strong) NSButton *sceneButton;
@property (nonatomic, strong) NSButton *compositorButton;
@property (nonatomic, strong) NSButton *transitionButton;
@property (nonatomic, strong) NSButton *effectButton;
@property (nonatomic, strong) NSButton *controlPanelButton;
@end

@implementation WLTopNavigationBar
- (instancetype)initWithFrame:(NSRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [NSColor colorWithRed:52.0/255.0 green:152.0/255.0 blue:219.0/255.0 alpha:1.0];
        
        self.sceneButton = [self createButtonWithTitle:@"场景" x:10];
        self.sceneButton.backgroundColor = [NSColor colorWithRed:41.0/255.0 green:128.0/255.0 blue:185.0/255.0 alpha:1.0];
        
        self.compositorButton = [self createButtonWithTitle:@"复合器" x:120];
        self.transitionButton = [self createButtonWithTitle:@"转场动画" x:230];
        self.effectButton = [self createButtonWithTitle:@"效果" x:340];
        self.controlPanelButton = [self createButtonWithTitle:@"控制面板" x:450];
    }
    return self;
}

- (NSButton *)createButtonWithTitle:(NSString *)title x:(CGFloat)x {
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, 10, 100, 20)];
    [button setButtonType:NSButtonTypeMomentaryPushIn];
    [button setTitle:title];
    [button setBezelStyle:NSBezelStyleRounded];
    [button setTarget:self];
    [button setAction:@selector(buttonClicked:)];
    [self addSubview:button];
    return button;
}

- (void)buttonClicked:(NSButton *)sender {
    NSLog(@"Button clicked: %@", [sender title]);
}
@end

@interface WLLeftSceneEditArea : NSView
@property (nonatomic, strong) NSView *mediaSourceTrack;
@property (nonatomic, strong) NSView *videoCaptureDeviceTrack;
@property (nonatomic, strong) NSView *toolbar;
@end

@implementation WLLeftSceneEditArea
- (instancetype)initWithFrame:(NSRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [NSColor colorWithRed:52.0/255.0 green:73.0/255.0 blue:94.0/255.0 alpha:1.0];
        
        self.mediaSourceTrack = [self createTrackViewWithTitle:@"媒体源轨道" y:20];
        self.videoCaptureDeviceTrack = [self createTrackViewWithTitle:@"视频采集设备轨道" y:90];
        self.toolbar = [self createToolbarView];
    }
    return self;
}

- (NSView *)createTrackViewWithTitle:(NSString *)title y:(CGFloat)y {
    NSView *trackView = [[NSView alloc] initWithFrame:NSMakeRect(10, y, 380, 60)];
    trackView.backgroundColor = [NSColor colorWithRed:39.0/255.0 green:174.0/255.0 blue:96.0/255.0 alpha:1.0];
    
    NSTextField *titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 40, 100, 15)];
    titleField.stringValue = title;
    titleField.backgroundColor = [NSColor clearColor];
    titleField.textColor = [NSColor whiteColor];
    titleField.editable = NO;
    [trackView addSubview:titleField];
    
    [self addSubview:trackView];
    return trackView;
}

- (NSView *)createToolbarView {
    NSView *toolbarView = [[NSView alloc] initWithFrame:NSMakeRect(10, 160, 380, 40)];
    toolbarView.backgroundColor = [NSColor colorWithRed:127.0/255.0 green:140.0/255.0 blue:141.0/255.0 alpha:1.0];
    
    NSButton *addButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 10, 20, 20)];
    [addButton setButtonType:NSButtonTypeMomentaryPushIn];
    [addButton setTitle:@"+"];
    [addButton setBezelStyle:NSBezelStyleRounded];
    [toolbarView addSubview:addButton];
    
    NSButton *deleteButton = [[NSButton alloc] initWithFrame:NSMakeRect(40, 10, 20, 20)];
    [deleteButton setButtonType:NSButtonTypeMomentaryPushIn];
    [deleteButton setTitle:@"-"];
    [deleteButton setBezelStyle:NSBezelStyleRounded];
    [toolbarView addSubview:deleteButton];
    
    [self addSubview:toolbarView];
    return toolbarView;
}
@end

@interface WLRightDeviceControlPanel : NSView
@property (nonatomic, strong) NSView *videoCaptureDeviceSection;
@property (nonatomic, strong) NSView *mediaSourceSection;
@property (nonatomic, strong) NSView *operationButtonsSection;
@end

@implementation WLRightDeviceControlPanel
- (instancetype)initWithFrame:(NSRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [NSColor colorWithRed:52.0/255.0 green:73.0/255.0 blue:94.0/255.0 alpha:1.0];
        
        self.videoCaptureDeviceSection = [self createSectionViewWithTitle:@"视频采集设备" y:20];
        self.mediaSourceSection = [self createSectionViewWithTitle:@"媒体源" y:70];
        self.operationButtonsSection = [self createOperationButtonsSection];
    }
    return self;
}

- (NSView *)createSectionViewWithTitle:(NSString *)title y:(CGFloat)y {
    NSView *sectionView = [[NSView alloc] initWithFrame:NSMakeRect(10, y, 280, 40)];
    sectionView.backgroundColor = [NSColor colorWithRed:142.0/255.0 green:68.0/255.0 blue:173.0/255.0 alpha:1.0];
    
    NSTextField *titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 12, 100, 15)];
    titleField.stringValue = title;
    titleField.backgroundColor = [NSColor clearColor];
    titleField.textColor = [NSColor whiteColor];
    titleField.editable = NO;
    [sectionView addSubview:titleField];
    
    NSButton *toggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(200, 10, 30, 20)];
    [toggleButton setButtonType:NSButtonTypeSwitch];
    [sectionView addSubview:toggleButton];
    
    [self addSubview:sectionView];
    return sectionView;
}

- (NSView *)createOperationButtonsSection {
    NSView *operationView = [[NSView alloc] initWithFrame:NSMakeRect(10, 120, 280, 180)];
    operationView.backgroundColor = [NSColor colorWithRed:192.0/255.0 green:57.0/255.0 blue:43.0/255.0 alpha:1.0];
    
    NSArray *buttonTitles = @[@"开始直播", @"开始录制", @"启动虚拟摄像机", @"工作模式", @"设置", @"退出"];
    for (int i = 0; i < buttonTitles.count; i++) {
        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(10, 10 + i * 28, 260, 25)];
        [button setButtonType:NSButtonTypeMomentaryPushIn];
        [button setTitle:buttonTitles[i]];
        [button setBezelStyle:NSBezelStyleRounded];
        [operationView addSubview:button];
    }
    
    [self addSubview:operationView];
    return operationView;
}
@end

@interface WLBottomStatusBar : NSView
@property (nonatomic, strong) NSTextField *timecodeField;
@property (nonatomic, strong) NSTextField *cpuUsageField;
@property (nonatomic, strong) NSTextField *fpsField;
@end

@implementation WLBottomStatusBar
- (instancetype)initWithFrame:(NSRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [NSColor colorWithRed:44.0/255.0 green:62.0/255.0 blue:80.0/255.0 alpha:1.0];
        
        self.timecodeField = [self createStatusFieldWithText:@"00:00:00 / 00:00:00" x:10];
        self.cpuUsageField = [self createStatusFieldWithText:@"CPU: 6.3%" x:150];
        self.fpsField = [self createStatusFieldWithText:@"30.00 / 30.00 FPS" x:250];
    }
    return self;
}

- (NSTextField *)createStatusFieldWithText:(NSString *)text x:(CGFloat)x {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(x, 5, 120, 20)];
    field.stringValue = text;
    field.backgroundColor = [NSColor clearColor];
    field.textColor = [NSColor whiteColor];
    field.editable = NO;
    [self addSubview:field];
    return field;
}
@end

@interface WLMainViewController () <WLCameraCaptureSubscriber, TVUCameraManagerDelegate, WLVideoDeviceSettingWindowControllerDelegate>
@property (nonatomic, strong) WLTopNavigationBar *topNavigationBar;
@property (nonatomic, strong) WLLeftSceneEditArea *leftSceneEditArea;
@property (nonatomic, strong) WLRightDeviceControlPanel *rightDeviceControlPanel;
@property (nonatomic, strong) WLBottomStatusBar *bottomStatusBar;
@property (nonatomic, strong) WLViedoPreview *videoPreview;
@property (nonatomic, strong) WLEventDisposeBag *bag;
@property (nonatomic, strong) WLMediaSource *mediaSource;
@property (nonatomic, strong) WLVideoDeviceSettingWindowController *settingWindowController;
@property (nonatomic, strong) NSString *currentVideoDeviceID;
@end

@implementation WLMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    unsigned int ver = avformat_version();
    int major = (ver >> 16) & 0xFF;
    int minor = (ver >> 8) & 0xFF;
    int micro = ver & 0xFF;

    printf("libavformat version: %d.%d.%d\n", major, minor, micro);
    
    self.view.backgroundColor = [NSColor blackColor];
    
    // 创建顶部导航栏
    self.topNavigationBar = [[WLTopNavigationBar alloc] initWithFrame:NSMakeRect(0, 0, self.view.frame.size.width, 40)];
    [self.view addSubview:self.topNavigationBar];
    
    // 创建左侧场景编辑区
    self.leftSceneEditArea = [[WLLeftSceneEditArea alloc] initWithFrame:NSMakeRect(0, 40, 400, self.view.frame.size.height - 70)];
    [self.view addSubview:self.leftSceneEditArea];
    
    // 创建右侧设备控制面板
    self.rightDeviceControlPanel = [[WLRightDeviceControlPanel alloc] initWithFrame:NSMakeRect(400, 40, self.view.frame.size.width - 400, self.view.frame.size.height - 70)];
    [self.view addSubview:self.rightDeviceControlPanel];
    
    // 创建底部状态栏
    self.bottomStatusBar = [[WLBottomStatusBar alloc] initWithFrame:NSMakeRect(0, self.view.frame.size.height - 30, self.view.frame.size.width, 30)];
    [self.view addSubview:self.bottomStatusBar];
    
    // 初始化媒体源
    NSString *path = @"/Users/erfeixia/Downloads/Test-4K.mp4";
    self.mediaSource = [[WLMediaSource alloc] initWithPath:path];
    
    [WLStreamsManager manager].videoRenderType = WLVideoRenderTypeCamera;
    [WLStreamsManager manager].audioRenderType = WLAudioRenderTypeMic;
    [[WLStreamsManager manager] start];
}

#pragma mark - Action Methods
- (IBAction)settingButtonAction:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *mediaItem = [menu addItemWithTitle:@"媒体源（本地视频）"
                                           action:@selector(mediaSourceSelected:)
                                    keyEquivalent:@""];
    mediaItem.target = self;

    NSMenuItem *cameraItem = [menu addItemWithTitle:@"摄像头"
                                             action:@selector(cameraSourceSelected:)
                                      keyEquivalent:@""];
    cameraItem.target = self;

    NSPoint point = NSMakePoint(0, NSHeight(sender.bounds));
    [menu popUpMenuPositioningItem:nil atLocation:point inView:sender];
}

- (void)mediaSourceSelected:(NSMenuItem *)sender {
    if (!self.settingWindowController) {
        self.settingWindowController = [WLVideoDeviceSettingWindowController sharedController];
        self.settingWindowController.delegate = self;
    }
    [self.settingWindowController showWindowWithSourceType:WLVideoSourceTypeMedia];
}

- (void)cameraSourceSelected:(NSMenuItem *)sender {
    if (!self.settingWindowController) {
        self.settingWindowController = [WLVideoDeviceSettingWindowController sharedController];
        self.settingWindowController.delegate = self;
    }
    [self.settingWindowController showWindowWithSourceType:WLVideoSourceTypeCamera];
}

- (IBAction)startButtonAction:(NSButton *)sender {
    [self.mediaSource start];
}

- (IBAction)startCamera:(id)sender {
    [self startWLCamera];
}

#pragma mark - Private Methods
- (void)startWLCamera {
    WLVideoManager *manager = [WLVideoManager manager];
    [manager subscriber:self];
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    [manager switchWithDevice:device];
    // 启动采集
    [manager startCapture];
}

#pragma mark - WLCameraCaptureSubscriber
- (void)cameraCaptureManager:(WLVideoManager *)manager
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // 获取视频的流信息
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }
    
    // 由于 sampleBuffer 会被系统回收，需要手动 retain pixelBuffer
    CVPixelBufferRetain(pixelBuffer);
    
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    Float64 pts = CMTimeGetSeconds(presentationTime);
    
    // 创建视频节点并添加到流管理器
    WLNode *videoNode = [[WLNode alloc] init];
    videoNode.type = WLNodeTypeVideo;
    videoNode.fromType = WLFromTypeCamera;
    videoNode.data = pixelBuffer;
    videoNode.pts = pts;
    
    WLStreamsManager *streams = [WLStreamsManager manager];
    [streams addVideoNode:videoNode];
}

- (void)tvuCaptureOutput:(AVCaptureOutput *)output
   didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
          fromConnection:(AVCaptureConnection *)connection {
    // 暂时不实现
}

#pragma mark - WLMediaSourceDelegate
- (void)mediaSource:(WLMediaSource *)source didOutputVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    // 暂时不实现
}

- (void)mediaSource:(WLMediaSource *)source didOutputAudioFrame:(AVFrame *)frame pts:(Float64)pts {
    // TODO: 音频播放实现
}

#pragma mark - Private Methods (MediaSource)
- (CMSampleBufferRef)sampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts {
    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    if (status != noErr) return NULL;

    CMSampleTimingInfo timingInfo;
    timingInfo.duration = kCMTimeInvalid;
    timingInfo.presentationTimeStamp = CMTimeMakeWithSeconds(pts, 600);
    timingInfo.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                      pixelBuffer,
                                                      formatDescription,
                                                      &timingInfo,
                                                      &sampleBuffer);
    CFRelease(formatDescription);
    return (status == noErr) ? sampleBuffer : NULL;
}

#pragma mark - WLVideoDeviceSettingWindowControllerDelegate

- (void)videoDeviceSettingController:(WLVideoDeviceSettingWindowController *)controller
              didConfirmWithDevice:(NSString *)deviceID
                           preset:(NSString *)preset
                       useBuffer:(BOOL)useBuffer {
    NSLog(@"确认设置 - 设备：%@, 预设：%@, 使用缓冲：%@", deviceID, preset, @(useBuffer));
    
    self.currentVideoDeviceID = deviceID;
    
    if (deviceID && deviceID.length > 0) {
        NSArray *devices = [[WLDevicesManager manager] currentVideoDevices];
        for (WLDeviceItem *item in devices) {
            if ([item.uniqueID isEqualToString:deviceID]) {
                WLVideoManager *manager = [WLVideoManager manager];
                [manager switchWithDevice:item.device];
                break;
            }
        }
    }
}

- (void)videoDeviceSettingController:(WLVideoDeviceSettingWindowController *)controller
          didConfirmWithMediaPath:(NSString *)mediaPath {
    NSLog(@"确认设置 - 媒体源路径：%@", mediaPath);

    if (mediaPath.length > 0) {
        self.mediaSource = [[WLMediaSource alloc] initWithPath:mediaPath];
    }
}

@end