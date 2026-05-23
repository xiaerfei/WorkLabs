//
//  WLTestSourceController.m
//  WorkLabs
//
//  通用 Source 测试控制器
//

#import "WLTestSourceController.h"
#import "WLMediaSource.h"
#import "WLMediaSourcePreview.h"
#import "WLPreviewOutput.h"
#import "WLAudioOutput.h"
#import "WLViedoPreview.h"

@interface WLTestSourceController ()

@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *fpsLabel;
@property (nonatomic, strong) NSTextField *infoLabel;
@property (nonatomic, strong) NSButton *stopButton;

@property (nonatomic, strong) WLPreviewOutput *previewOutput;
@property (nonatomic, strong) WLAudioOutput *audioOutput;

@property (nonatomic, assign) NSUInteger videoFrameCount;
@property (nonatomic, assign) NSUInteger audioFrameCount;
@property (nonatomic, strong) NSDate *startTime;

@end

@implementation WLTestSourceController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [[NSColor blackColor] CGColor];
    [self setupUI];
}

- (void)dealloc {
    [self stopTest];
}

#pragma mark - Public

- (void)testWithSource:(id<WLStreamSourceProtocol>)source {
    [self stopTest];

    self.source = source;
    self.source.delegate = self;
    self.videoFrameCount = 0;
    self.audioFrameCount = 0;
    self.startTime = [NSDate date];

    // 设置预览
    self.previewOutput = [[WLPreviewOutput alloc] init];
    NSView *previewView = self.previewOutput.preview;
    previewView.frame = self.view.bounds;
    previewView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:previewView positioned:NSWindowBelow relativeTo:self.statusLabel];

    // 设置音频输出（仅对音频 Source 有效）
    if (source.streamType == WLNodeTypeAudio) {
        self.audioOutput = [[WLAudioOutput alloc] init];
        [self.audioOutput start];
    }

    // 更新信息
    NSString *sourceName = NSStringFromClass([source class]);
    self.infoLabel.stringValue = [NSString stringWithFormat:@"Source: %@ | Type: %@ | From: %ld",
                                  sourceName,
                                  source.streamType == WLNodeTypeVideo ? @"Video" : @"Audio",
                                  (long)source.fromType];

    [self updateStatus:@"Starting..." color:[NSColor yellowColor]];

    NSError *error = nil;
    BOOL started = [source start:&error];
    if (!started) {
        [self updateStatus:[NSString stringWithFormat:@"Start failed: %@", error.localizedDescription] color:[NSColor redColor]];
        return;
    }

    [self updateStatus:@"Running" color:[NSColor greenColor]];
    [self startFPSCounter];
}

- (void)stopTest {
    if (self.source.isRunning) {
        [self.source stop];
    }
    [self.audioOutput stop];
    self.audioOutput = nil;
    self.source.delegate = nil;
    self.source = nil;
    [self.previewOutput.preview removeFromSuperview];
    self.previewOutput = nil;
    [self updateStatus:@"Stopped" color:[NSColor grayColor]];
}

#pragma mark - WLStreamSourceDelegate

- (void)source:(id<WLStreamSourceProtocol>)source
    didOutputVideoFrame:(CVPixelBufferRef)pixelBuffer
                    pts:(Float64)pts {
    self.videoFrameCount++;
    [self.previewOutput displayPixelBuffer:pixelBuffer pts:pts];
}

- (void)source:(id<WLStreamSourceProtocol>)source
    didOutputAudioBuffer:(CMSampleBufferRef)sampleBuffer {
    self.audioFrameCount++;
    if (self.audioOutput) {
        [self.audioOutput playSampleBuffer:sampleBuffer];
    } else {
        CFRelease(sampleBuffer);
    }
}

- (void)source:(id<WLStreamSourceProtocol>)source didEncounterError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatus:[NSString stringWithFormat:@"Error: %@", error.localizedDescription] color:[NSColor redColor]];
    });
}

- (void)sourceDidStart:(id<WLStreamSourceProtocol>)source {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatus:@"Running" color:[NSColor greenColor]];
    });
}

- (void)sourceDidStop:(id<WLStreamSourceProtocol>)source {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatus:@"Stopped" color:[NSColor grayColor]];
    });
}

#pragma mark - UI

- (void)setupUI {
    // 状态标签
    self.statusLabel = [self createLabel:@"Idle" color:[NSColor grayColor] fontSize:14];
    self.statusLabel.frame = NSMakeRect(10, 10, 200, 24);
    [self.view addSubview:self.statusLabel];

    // FPS 标签
    self.fpsLabel = [self createLabel:@"-- fps" color:[NSColor whiteColor] fontSize:12];
    self.fpsLabel.frame = NSMakeRect(10, 36, 200, 20);
    [self.view addSubview:self.fpsLabel];

    // 信息标签
    self.infoLabel = [self createLabel:@"" color:[NSColor lightGrayColor] fontSize:12];
    self.infoLabel.frame = NSMakeRect(10, 58, 400, 20);
    [self.view addSubview:self.infoLabel];

    // 停止按钮
    self.stopButton = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopButtonClicked:)];
    self.stopButton.frame = NSMakeRect(10, 82, 80, 28);
    [self.view addSubview:self.stopButton];
}

- (NSTextField *)createLabel:(NSString *)text color:(NSColor *)color fontSize:(CGFloat)size {
    NSTextField *label = [NSTextField labelWithString:text];
    label.textColor = color;
    label.font = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightMedium];
    label.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.5];
    label.drawsBackground = YES;
    label.wantsLayer = YES;
    label.layer.cornerRadius = 4;
    return label;
}

- (void)updateStatus:(NSString *)text color:(NSColor *)color {
    self.statusLabel.stringValue = text;
    self.statusLabel.textColor = color;
}

- (void)startFPSCounter {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.source.isRunning) return;
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:self.startTime];
        if (elapsed > 0) {
            double fps = self.videoFrameCount / elapsed;
            self.fpsLabel.stringValue = [NSString stringWithFormat:@"Video: %lu frames (%.1f fps) | Audio: %lu frames",
                                         (unsigned long)self.videoFrameCount, fps,
                                         (unsigned long)self.audioFrameCount];
        }
        [self startFPSCounter];
    });
}

#pragma mark - Actions

- (void)stopButtonClicked:(id)sender {
    [self stopTest];
}

@end
