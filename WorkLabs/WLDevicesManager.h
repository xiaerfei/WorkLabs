//
//  WLDevicesManager.h
//  WorkLabs
//
//  Created by erfeixia on 2025/11/22.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <ReactiveObjC.h>

NS_ASSUME_NONNULL_BEGIN
@interface WLDeviceFormat : NSObject
///< 分辨率
@property(nonatomic, assign) CMVideoDimensions dimension;
///< 帧率
@property(nonatomic,   copy) NSArray <NSNumber *> *frameRate;
@end

@interface WLDeviceItem : NSObject
@property(nonatomic, assign) AVMediaType mediaType;
@property(nonatomic,   copy) NSString *uniqueID;
@property(nonatomic,   copy) NSString *modelID;
@property(nonatomic,   copy) NSString *localizedName;
@property(nonatomic,   copy) NSString *manufacturer;
@property(nonatomic, assign) int32_t  transportType;
///< Video 信息(分辨率以及支持的帧率)
@property(nonatomic,   copy) NSArray <WLDeviceFormat *> *formats;

@property(nonatomic, strong) AVCaptureDevice *device;
@end


@interface WLDevicesManager : NSObject
+ (instancetype)manager;
///< 订阅 Video 设备变化
@property (nonatomic, strong, readonly) RACSignal <WLDeviceItem *>*videoSignal;
///< 订阅 Audio 设备变化
@property (nonatomic, strong, readonly) RACSignal <WLDeviceItem *>*audioSignal;

- (NSArray <WLDeviceFormat *> * _Nullable)currentVideoDevices;
- (NSArray <WLDeviceFormat *> * _Nullable)currentAudioDevices;
@end

NS_ASSUME_NONNULL_END
