//
//  WLVideoDeviceManager.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/22.
//

#import "WLVideoDeviceManager.h"

@implementation WLVideoDeviceManager

+ (NSArray<AVCaptureDevice *> *)videoDevices {
    // 创建 Discovery Session
    AVCaptureDeviceDiscoverySession *session =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[
            AVCaptureDeviceTypeBuiltInWideAngleCamera,   // 内建摄像头
            AVCaptureDeviceTypeExternal           // 外接或虚拟摄像头
        ]
        mediaType:AVMediaTypeVideo
        position:AVCaptureDevicePositionUnspecified];

    return session.devices; // NSArray<AVCaptureDevice *>
}
@end
