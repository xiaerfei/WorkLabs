//
//  WLCameraSource.m
//  WorkLabs
//

#import "WLCameraSource.h"
#import "WLCameraSourceConfig.h"

@interface WLCameraSource ()
@property (nonatomic, strong, readwrite) WLCameraSourceConfig *config;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDeviceInput *currentInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, assign) dispatch_queue_t videoQueue;
@end

@implementation WLCameraSource

- (void)dealloc { [self stop]; }
- (WLFromType)fromType { return WLFromTypeCamera; }

- (instancetype)initWithConfig:(WLCameraSourceConfig *)config {
    self = [super init];
    if (!self) return nil;
    _config = config;
    _session = [[AVCaptureSession alloc] init];
    if (config.sessionPreset) { _session.sessionPreset = config.sessionPreset; }
    _videoQueue = dispatch_queue_create("com.wl-newplan.camera.video",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    return self;
}

- (BOOL)start {
    if (self.isRunning) return YES;
    if (!self.config.device) { NSLog(@"[WLCameraSource] No device configured"); return NO; }
    [self configureSession];
    self.running = YES;
    [self.session startRunning];
    return YES;
}

- (void)stop {
    if (!self.isRunning) return;
    self.running = NO;
    [self.session stopRunning];
    [self teardownSession];
}

- (void)configureSession {
    AVCaptureDevice *device = self.config.device;
    if (!device) return;
    [self.session beginConfiguration];
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (error) { NSLog(@"[WLCameraSource] device input error: %@", error); [self.session commitConfiguration]; return; }
    if ([self.session canAddInput:input]) { [self.session addInput:input]; self.currentInput = input; }
    [self setupOutput];
    [self.session commitConfiguration];
}

- (void)setupOutput {
    if (self.videoOutput) { [self.session removeOutput:self.videoOutput]; }
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
    self.videoOutput.videoSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };
    [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
    if ([self.session canAddOutput:self.videoOutput]) { [self.session addOutput:self.videoOutput]; }
}

- (void)teardownSession {
    [self.session beginConfiguration];
    if (self.currentInput) { [self.session removeInput:self.currentInput]; self.currentInput = nil; }
    if (self.videoOutput) { [self.session removeOutput:self.videoOutput]; [self.videoOutput setSampleBufferDelegate:nil queue:NULL]; self.videoOutput = nil; }
    [self.session commitConfiguration];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (!self.isRunning) return;
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;
    CVPixelBufferRetain(pixelBuffer);
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    Float64 pts = CMTimeGetSeconds(presentationTime);
    if (self.frameOutput) {
        self.frameOutput(pixelBuffer, pts);
    } else {
        CVPixelBufferRelease(pixelBuffer);
    }
}

@end
