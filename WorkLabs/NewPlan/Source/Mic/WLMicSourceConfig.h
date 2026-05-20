//
//  WLMicSourceConfig.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLMicSourceConfig : NSObject
@property (nonatomic, strong, nullable) AVCaptureDevice *device;
@property (nonatomic, copy, nullable) NSString *sessionPreset;
+ (instancetype)defaultConfig;
+ (instancetype)configWithDevice:(nullable AVCaptureDevice *)device;
+ (NSArray<AVCaptureDevice *> *)availableMicrophones;
+ (nullable AVCaptureDevice *)defaultMicrophone;
@end

NS_ASSUME_NONNULL_END
