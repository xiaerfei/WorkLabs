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
@property (nonatomic, strong) NSHashTable<id<WLCameraCaptureSubscriber>> *subscribers;
@end

@implementation WLCameraCaptureManager

+ (instancetype)manager {
    static WLCameraCaptureManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[WLCameraCaptureManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _subscribers = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

#pragma mark - Public Methods

- (void)startCapture {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    switch (status) {
        case AVAuthorizationStatusAuthorized:
            [self setupSession];
            [self.session startRunning];
            break;
        case AVAuthorizationStatusNotDetermined: {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                if (granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self setupSession];
                        [self.session startRunning];
                    });
                } else {
                    NSLog(@"用户拒绝了摄像头访问权限");
                }
            }];
            break;
        }
        case AVAuthorizationStatusDenied:
        case AVAuthorizationStatusRestricted:
            NSLog(@"没有摄像头访问权限，请在系统偏好设置中开启");
            break;
    }
}

- (void)stopCapture {
    if (self.session.isRunning) {
        [self.session stopRunning];
    }
}

- (void)addSubscriber:(id<WLCameraCaptureSubscriber>)subscriber {
    @synchronized (self.subscribers) {
        [self.subscribers addObject:subscriber];
    }
}

- (void)removeSubscriber:(id<WLCameraCaptureSubscriber>)subscriber {
    @synchronized (self.subscribers) {
        [self.subscribers removeObject:subscriber];
    }
}

#pragma mark - Private Setup

- (void)setupSession {
    if (self.session) return;

    self.session = [[AVCaptureSession alloc] init];
    self.session.sessionPreset = AVCaptureSessionPresetHigh;

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input && [self.session canAddInput:input]) {
        [self.session addInput:input];
    }

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.videoSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    dispatch_queue_t queue = dispatch_queue_create("WLCameraQueue", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:self queue:queue];

    if ([self.session canAddOutput:output]) {
        [self.session addOutput:output];
    }

    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection {
    @synchronized (self.subscribers) {
        for (id<WLCameraCaptureSubscriber> subscriber in self.subscribers) {
            if ([subscriber respondsToSelector:@selector(cameraCaptureManager:didOutputSampleBuffer:)]) {
                [subscriber cameraCaptureManager:self didOutputSampleBuffer:sampleBuffer];
            }
        }
    }
}

@end
