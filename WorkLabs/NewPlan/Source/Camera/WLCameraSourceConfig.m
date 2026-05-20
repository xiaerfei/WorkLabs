//
//  WLCameraSourceConfig.m
//  WorkLabs
//

#import "WLCameraSourceConfig.h"

@implementation WLCameraSourceConfig
+ (instancetype)configWithDevice:(AVCaptureDevice *)device {
    return [self configWithDevice:device sessionPreset:nil];
}
+ (instancetype)configWithDevice:(AVCaptureDevice *)device sessionPreset:(nullable NSString *)sessionPreset {
    WLCameraSourceConfig *config = [[WLCameraSourceConfig alloc] init];
    config.device = device;
    config.sessionPreset = sessionPreset;
    return config;
}
@end
