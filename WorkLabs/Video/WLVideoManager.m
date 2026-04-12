#import "WLVideoManager.h"
#import <CoreMedia/CoreMedia.h>

@interface WLVideoManager () <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    dispatch_queue_t _videoQueue;
    NSHashTable<id<WLCameraCaptureSubscriber>> *_subscribers;
}

@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) AVCaptureDevice *currentDevice;
@property (nonatomic, strong) AVCaptureDeviceInput *currentInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;

@end

@implementation WLVideoManager

+ (instancetype)manager {
    static WLVideoManager *m;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        m = [[WLVideoManager alloc] init];
    });
    return m;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _subscribers = [NSHashTable weakObjectsHashTable];

    _videoQueue = dispatch_queue_create("com.wl.camera.video",
                                       dispatch_queue_attr_make_with_qos_class(
                                               DISPATCH_QUEUE_SERIAL,
                                               QOS_CLASS_USER_INTERACTIVE,
                                               0));

    _session = [[AVCaptureSession alloc] init];

    return self;
}

#pragma mark - Camera Selection (FaceTime 风格)

/// FaceTime 风格：优先 NV12，其次 420f，不使用 MJPEG
- (AVCaptureDeviceFormat *)bestFormatForDevice:(AVCaptureDevice *)device {

    NSArray<AVCaptureDeviceFormat *> *formats = device.formats;
    AVCaptureDeviceFormat *best = nil;

    for (AVCaptureDeviceFormat *format in formats) {

        FourCharCode subtype = CMVideoFormatDescriptionGetCodecType(format.formatDescription);

        BOOL isNV12 = (subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                       subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

        BOOL is420f = (subtype == kCVPixelFormatType_420YpCbCr8PlanarFullRange ||
                       subtype == kCVPixelFormatType_420YpCbCr8Planar);

        BOOL isMJPEG = (subtype == kCVPixelFormatType_422YpCbCr8);

        if (isMJPEG) continue;
        if (!isNV12 && !is420f) continue;

        CMVideoDimensions dim =
        CMVideoFormatDescriptionGetDimensions(format.formatDescription);

        // FaceTime 选 720p + NV12
        if (dim.width == 1280 && dim.height == 720 && isNV12) {
            best = format;
            break;
        }

        // 其他尺寸也可以接受
        if (!best) best = format;
    }

    return best ?: formats.firstObject;
}

#pragma mark - Device Setup

- (void)switchWithDevice:(AVCaptureDevice *)device {
    if (!device) return;

    [self.session beginConfiguration];

    if (self.currentInput) {
        [self.session removeInput:self.currentInput];
    }

    NSError *error = nil;
    self.currentInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (error) {
        NSLog(@"Device input error: %@", error);
        return;
    }

    if ([self.session canAddInput:self.currentInput]) {
        [self.session addInput:self.currentInput];
    }

    self.currentDevice = device;

//    // 🔥 选择 FaceTime 风格最佳格式
//    AVCaptureDeviceFormat *bestFormat = [self bestFormatForDevice:device];
//    [device lockForConfiguration:nil];
//    device.activeFormat = bestFormat;
//    device.activeVideoMinFrameDuration = CMTimeMake(1, 30);
//    device.activeVideoMaxFrameDuration = CMTimeMake(1, 30);
//    [device unlockForConfiguration];

    [self setupOutput];

    [self.session commitConfiguration];
}

#pragma mark - Output

- (void)setupOutput {
    if (self.videoOutput) {
        [self.session removeOutput:self.videoOutput];
    }

    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;

    // 🔥 FaceTime 风格：输出 BGRA（方便 Metal）
    self.videoOutput.videoSettings =
    @{ (NSString *)kCVPixelBufferPixelFormatTypeKey :
           @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };

    [self.videoOutput setSampleBufferDelegate:self queue:_videoQueue];

    if ([self.session canAddOutput:self.videoOutput]) {
        [self.session addOutput:self.videoOutput];
    }
}

#pragma mark - Start / Stop

- (void)startCapture {
    if (!self.session.isRunning) {
        [self.session startRunning];
    }
}

- (void)stopCapture {
    if (self.session.isRunning) {
        [self.session stopRunning];
    }
}

- (BOOL)isRunning {
    return self.session.isRunning;
}

#pragma mark - Subscriber

- (void)subscriber:(id<WLCameraCaptureSubscriber>)subscriber {
    if (!subscriber) return;
    @synchronized (_subscribers) {
        [_subscribers addObject:subscriber];
    }
}

- (void)unsubscriber:(id<WLCameraCaptureSubscriber>)subscriber {
    if (!subscriber) return;
    @synchronized (_subscribers) {
        [_subscribers removeObject:subscriber];
    }
}

#pragma mark - Delegate (FaceTime pipeline)

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection
{
    NSArray *subs = nil;

    @synchronized (_subscribers) {
        subs = _subscribers.allObjects;
    }

    for (id<WLCameraCaptureSubscriber> s in subs) {
        [s cameraCaptureManager:self didOutputSampleBuffer:sampleBuffer];
    }
}

@end

