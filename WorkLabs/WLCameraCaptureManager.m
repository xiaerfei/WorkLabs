//
//  WLCameraCaptureManager.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/11/10.
//

#import "WLCameraCaptureManager.h"

@interface WLCameraCaptureManager ()
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) AVCaptureDevice *currentDevice;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;

// 多播订阅者
@property (nonatomic, strong) NSHashTable<id<WLCameraCaptureSubscriber>> *subscribers;

// 串行队列保证线程安全
@property (nonatomic, strong) dispatch_queue_t subscriberQueue;
@property (nonatomic, strong) dispatch_queue_t captureQueue;

// 设备监听
@property (nonatomic, strong) id deviceConnectedObserver;
@property (nonatomic, strong) id deviceDisconnectedObserver;
@end


@implementation WLCameraCaptureManager

+ (instancetype)manager {
    static WLCameraCaptureManager *m;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        m = [[self alloc] init];
    });
    return m;
}

- (instancetype)init {
    if (self = [super init]) {
        _session = [[AVCaptureSession alloc] init];
        _session.sessionPreset = AVCaptureSessionPresetHigh;
        
        _captureQueue = dispatch_queue_create("WLCameraCapture.capture", DISPATCH_QUEUE_SERIAL);
        _subscriberQueue = dispatch_queue_create("WLCameraCapture.subscribers", DISPATCH_QUEUE_SERIAL);

        _subscribers = [NSHashTable weakObjectsHashTable];

        [self setupDeviceNotifications];
        [self setupDefaultDevice];
        [self setupPreviewLayer];
    }
    return self;
}

#pragma mark - Device Setup

- (void)setupDefaultDevice {
    AVCaptureDeviceDiscoverySession *session =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[
            AVCaptureDeviceTypeBuiltInWideAngleCamera,   // 内建摄像头
            AVCaptureDeviceTypeExternal           // 外接或虚拟摄像头
        ]
        mediaType:AVMediaTypeVideo
        position:AVCaptureDevicePositionUnspecified];

    AVCaptureDevice *device = session.devices.lastObject;
    self.currentDevice = device;
    if (device) {
        [self configureSessionWithDevice:device];
    }
}

- (void)setupPreviewLayer {
    _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
}

#pragma mark - Capture Session Config

- (void)configureSessionWithDevice:(AVCaptureDevice *)device {
    [self.session beginConfiguration];
    
    for (AVCaptureInput *input in self.session.inputs) {
        [self.session removeInput:input];
    }
    for (AVCaptureOutput *output in self.session.outputs) {
        [self.session removeOutput:output];
    }

    NSError *error;
    AVCaptureDeviceInput *input =
        [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];

    if (!error && [self.session canAddInput:input]) {
        [self.session addInput:input];
    }

    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.alwaysDiscardsLateVideoFrames = NO;

    [self.videoOutput setSampleBufferDelegate:self queue:self.captureQueue];

    NSDictionary *settings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    };
    self.videoOutput.videoSettings = settings;

    if ([self.session canAddOutput:self.videoOutput]) {
        [self.session addOutput:self.videoOutput];
    }

    self.currentDevice = device;

    [self.session commitConfiguration];
}

- (AVCaptureDeviceFormat *)bestFormatForDevice:(AVCaptureDevice *)device {
    NSArray<AVCaptureDeviceFormat *> *formats = device.formats;

    NSMutableArray<AVCaptureDeviceFormat *> *yuvFormats = [NSMutableArray array];
    NSMutableArray<AVCaptureDeviceFormat *> *otherFormats = [NSMutableArray array];

    for (AVCaptureDeviceFormat *format in formats) {
        FourCharCode code = CMFormatDescriptionGetMediaSubType(format.formatDescription);

        // MJPEG → 必须排除
        if (code == kCMVideoCodecType_JPEG) {
            continue;
        }

        // 常见的高性能格式：420f / 420v (NV12)
        if (code == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            code == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            [yuvFormats addObject:format];
        } else {
            [otherFormats addObject:format];
        }
    }

    // 优先选择 YUV 格式
    NSArray<AVCaptureDeviceFormat *> *preferred = yuvFormats.count > 0 ? yuvFormats : otherFormats;

    // 按 Resolution + MaxFPS 排序
    AVCaptureDeviceFormat *best = [preferred sortedArrayUsingComparator:^NSComparisonResult(AVCaptureDeviceFormat *f1, AVCaptureDeviceFormat *f2) {

        CMVideoDimensions dim1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription);
        CMVideoDimensions dim2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription);

        int area1 = dim1.width * dim1.height;
        int area2 = dim2.width * dim2.height;

        if (area1 != area2) {
            return area1 > area2 ? NSOrderedAscending : NSOrderedDescending;
        }

        // 比较最大帧率
        float maxFPS1 = [self maxFPSForFormat:f1];
        float maxFPS2 = [self maxFPSForFormat:f2];

        return maxFPS1 > maxFPS2 ? NSOrderedAscending : NSOrderedDescending;

    }].firstObject;

    return best;
}

- (float)maxFPSForFormat:(AVCaptureDeviceFormat *)format {
    float maxFPS = 0;

    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
        if (range.maxFrameRate > maxFPS) {
            maxFPS = range.maxFrameRate;
        }
    }

    return maxFPS;
}

- (void)applyFormat:(AVCaptureDeviceFormat *)format toDevice:(AVCaptureDevice *)device {
    if (!format) return;

    NSError *error = nil;
    if ([device lockForConfiguration:&error]) {
        device.activeFormat = format;

        // 设置最佳帧率（使用 format 的最高帧率）
        AVFrameRateRange *range = format.videoSupportedFrameRateRanges.firstObject;

//        if (range) {
//            device.activeVideoMinFrameDuration = CMTimeMake(1, (int32_t)range.maxFrameRate);
//            device.activeVideoMaxFrameDuration = CMTimeMake(1, (int32_t)range.maxFrameRate);
//        }

        [device unlockForConfiguration];
    } else {
        NSLog(@"applyFormat failed: %@", error);
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

#pragma mark - Switch Device

- (void)switchWithDevice:(AVCaptureDevice *)device {
    if (!device || device == self.currentDevice) return;
    [self configureSessionWithDevice:device];
}

#pragma mark - Subscribers (Combine-style)

- (void)subscriber:(id<WLCameraCaptureSubscriber>)subscriber {
    if (!subscriber) return;
    dispatch_sync(self.subscriberQueue, ^{
        [self.subscribers addObject:subscriber];
    });
}

- (void)unsubscriber:(id<WLCameraCaptureSubscriber>)subscriber {
    if (!subscriber) return;
    dispatch_sync(self.subscriberQueue, ^{
        [self.subscribers removeObject:subscriber];
    });
}

#pragma mark - Output

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    __weak typeof(self) weakSelf = self;
    dispatch_sync(self.subscriberQueue, ^{
        for (id<WLCameraCaptureSubscriber> s in weakSelf.subscribers) {
            [s cameraCaptureManager:weakSelf didOutputSampleBuffer:sampleBuffer];
        }
    });
}

#pragma mark - Device Notifications

- (void)setupDeviceNotifications {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

    __weak typeof(self) weakSelf = self;

    self.deviceConnectedObserver =
        [center addObserverForName:AVCaptureDeviceWasConnectedNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification * _Nonnull note) {
        NSLog(@"Camera Connected: %@", note.object);
        // 可在这里提示用户或自动切换
    }];

    self.deviceDisconnectedObserver =
        [center addObserverForName:AVCaptureDeviceWasDisconnectedNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification * _Nonnull note) {
        NSLog(@"Camera Disconnected: %@", note.object);
        // 可自动切换到其他设备
    }];
}

- (void)dealloc {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.deviceConnectedObserver)
        [center removeObserver:self.deviceConnectedObserver];
    if (self.deviceDisconnectedObserver)
        [center removeObserver:self.deviceDisconnectedObserver];
}

@end
