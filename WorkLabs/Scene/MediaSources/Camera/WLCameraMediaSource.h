//
//  WLCameraMediaSource.h
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//
//  摄像头媒体源 —— 包装 WLVideoManager，实现 WLMediaSourceProvider 协议

#import <Foundation/Foundation.h>
#import "WLMediaSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

@class WLVideoManager;

/**
 WLCameraMediaSource —— 摄像头捕获媒体源
 
 内部持有 WLVideoManager，将 CMSampleBufferRef 转换为 WLNodeFrame。
 使用方式:
 1. initWithDevice: 创建实例
 2. start / stop 控制采集
 3. nextVideoFrame 获取视频帧
 */
@interface WLCameraMediaSource : NSObject <WLMediaSourceProvider>

/** 采集设备唯一标识 */
@property (nonatomic, copy, readonly) NSString *deviceID;

/**
 使用指定设备创建摄像头媒体源
 
 @param deviceID AVCaptureDevice 的 uniqueID
 @return 实例，如果设备不可用返回 nil
 */
- (nullable instancetype)initWithDeviceID:(NSString *)deviceID;

@end

NS_ASSUME_NONNULL_END
