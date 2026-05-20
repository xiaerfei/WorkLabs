//
//  WLMicSourceConfig.m
//  WorkLabs
//

#import "WLMicSourceConfig.h"

@implementation WLMicSourceConfig
+ (instancetype)defaultConfig { return [self configWithDevice:nil]; }
+ (instancetype)configWithDevice:(nullable AVCaptureDevice *)device {
    WLMicSourceConfig *config = [[WLMicSourceConfig alloc] init];
    config.device = device ?: [self defaultMicrophone];
    config.sessionPreset = AVCaptureSessionPresetHigh;
    return config;
}
+ (NSArray<AVCaptureDevice *> *)availableMicrophones {
    AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInMicrophone] mediaType:AVMediaTypeAudio position:AVCaptureDevicePositionUnspecified];
    return session.devices;
}
+ (nullable AVCaptureDevice *)defaultMicrophone {
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
}
@end
