//
//  WLMicSource.m
//  WorkLabs
//

#import "WLMicSource.h"
#import "WLMicSourceConfig.h"

@interface WLMicSource ()
@property (nonatomic, strong, readwrite) WLMicSourceConfig *config;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDeviceInput *micInput;
@property (nonatomic, strong) AVCaptureAudioDataOutput *audioOutput;
@property (nonatomic, assign) dispatch_queue_t audioQueue;
@end

@implementation WLMicSource

- (void)dealloc { [self stop]; }
- (WLFromType)fromType { return WLFromTypeMic; }
- (WLNodeType)streamType { return WLNodeTypeAudio; }

- (BOOL)start:(NSError * _Nullable __autoreleasing *)error {
    BOOL ok = [self start];
    if (!ok && error) {
        *error = [NSError errorWithDomain:@"WLMicSource" code:-1
                                 userInfo:@{NSLocalizedDescriptionKey: @"mic start failed"}];
    }
    return ok;
}

- (instancetype)initWithConfig:(WLMicSourceConfig *)config {
    self = [super init];
    if (!self) return nil;
    _config = config;
    _session = [[AVCaptureSession alloc] init];
    if (config.sessionPreset) { _session.sessionPreset = config.sessionPreset; }
    _audioQueue = dispatch_queue_create("com.wl-newplan.mic.audio",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    return self;
}

- (BOOL)start {
    if (self.isRunning) return YES;
    if (!self.config.device) { NSLog(@"[WLMicSource] No microphone device available"); return NO; }
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
        NSLog(@"[WLMicSource] Microphone access denied"); return NO;
    }
    if (status == AVAuthorizationStatusNotDetermined) {
        __block BOOL granted = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL g) { granted = g; dispatch_semaphore_signal(sem); }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        if (!granted) { NSLog(@"[WLMicSource] Microphone permission denied by user"); return NO; }
    }
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
    [self.session beginConfiguration];
    NSError *error = nil;
    AVCaptureDeviceInput *input = [[AVCaptureDeviceInput alloc] initWithDevice:self.config.device error:&error];
    if (error) { NSLog(@"[WLMicSource] mic input error: %@", error); [self.session commitConfiguration]; return; }
    if ([self.session canAddInput:input]) { [self.session addInput:input]; self.micInput = input; }
    self.audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    [self.audioOutput setSampleBufferDelegate:self queue:self.audioQueue];
    if ([self.session canAddOutput:self.audioOutput]) { [self.session addOutput:self.audioOutput]; }
    [self.session commitConfiguration];
}

- (void)teardownSession {
    [self.session beginConfiguration];
    if (self.micInput) { [self.session removeInput:self.micInput]; self.micInput = nil; }
    if (self.audioOutput) { [self.session removeOutput:self.audioOutput]; [self.audioOutput setSampleBufferDelegate:nil queue:NULL]; self.audioOutput = nil; }
    [self.session commitConfiguration];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (!self.isRunning) return;
    CFRetain(sampleBuffer);

    // 新协议优先
    id<WLStreamSourceDelegate> delegate = self.delegate;
    if (delegate) {
        [delegate source:self didOutputAudioBuffer:sampleBuffer];
    } else if (self.sampleOutput) {
        self.sampleOutput(sampleBuffer);
    } else {
        CFRelease(sampleBuffer);
    }
}

@end
