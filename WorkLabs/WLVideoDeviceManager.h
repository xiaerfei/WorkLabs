//
//  WLVideoDeviceManager.h
//  WorkLabs
//
//  Created by erfeixia on 2025/11/22.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLVideoDeviceManager : NSObject
/// 获取当前所有可用视频设备（摄像头）
/// 返回数组元素为 AVCaptureDevice
+ (NSArray *)videoDevices;
@end

NS_ASSUME_NONNULL_END
