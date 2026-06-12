//
//  WLMicSource.m
//  WorkLabs
//

#import "WLMicSource.h"

@interface WLMicSource () <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong, readwrite) AVCaptureDevice *device;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDeviceInput *input;
@property (nonatomic, strong) AVCaptureAudioDataOutput *audioOutput;
// 注意必须 strong：ARC 下 dispatch_queue_t 是 ObjC 对象，assign 不持有 →
// init 创建的队列立刻被释放，悬垂指针交给 AVFoundation，采集线程投帧时跳垃圾地址崩溃
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@end

@implementation WLMicSource

- (void)dealloc { [self stop]; }
- (WLFromType)fromType { return WLFromTypeMic; }
- (WLNodeType)streamType { return WLNodeTypeAudio; }
- (NSString *)displayName { return self.device.localizedName ?: @"麦克风"; }

- (instancetype)initWithDevice:(AVCaptureDevice *)device {
    self = [super init];
    if (self) {
        _device = device;
        _session = [[AVCaptureSession alloc] init];
        _audioQueue = dispatch_queue_create("com.worklabs.mic.audio",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    }
    return self;
}

- (BOOL)start:(NSError * _Nullable __autoreleasing *)error {
    if (self.isRunning) return YES;
    if (!self.device) {
        if (error) *error = [NSError errorWithDomain:@"WLMicSource" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"未配置音频设备"}];
        return NO;
    }

    [self.session beginConfiguration];
    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:self.device error:&err];
    if (err || !input || ![self.session canAddInput:input]) {
        [self.session commitConfiguration];
        if (error) *error = err ?: [NSError errorWithDomain:@"WLMicSource" code:-2
                                                   userInfo:@{NSLocalizedDescriptionKey: @"无法创建音频输入"}];
        return NO;
    }
    [self.session addInput:input];
    self.input = input;

    self.audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    [self.audioOutput setSampleBufferDelegate:self queue:self.audioQueue];
    if ([self.session canAddOutput:self.audioOutput]) {
        [self.session addOutput:self.audioOutput];
    }
    [self.session commitConfiguration];

    self.running = YES;
    [self.session startRunning];
    NSLog(@"[WLMicSource] start: %@", self.device.localizedName);
    return YES;
}

- (void)stop {
    if (!self.isRunning) return;
    self.running = NO;
    [self.session stopRunning];
    [self.session beginConfiguration];
    if (self.input) { [self.session removeInput:self.input]; self.input = nil; }
    if (self.audioOutput) {
        [self.session removeOutput:self.audioOutput];
        [self.audioOutput setSampleBufferDelegate:nil queue:NULL];
        self.audioOutput = nil;
    }
    [self.session commitConfiguration];
}

#pragma mark - AVCaptureAudioDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (!self.isRunning || !sampleBuffer) return;
    id<WLStreamSourceDelegate> delegate = self.delegate;
    if (!delegate) return;
    // 约定：所有权转移给 delegate（与 WLMediaSource 一致，delegate 负责 CFRelease）
    CFRetain(sampleBuffer);
    [delegate source:self didOutputAudioBuffer:sampleBuffer];
}

@end
