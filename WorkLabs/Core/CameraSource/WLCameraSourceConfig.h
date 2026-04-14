
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLCameraSourceConfig : NSObject

@property (nonatomic, strong) AVCaptureDevice *device;
@property (nonatomic, copy, nullable) NSString *sessionPreset;

+ (instancetype)configWithDevice:(AVCaptureDevice *)device;
+ (instancetype)configWithDevice:(AVCaptureDevice *)device
                    sessionPreset:(nullable NSString *)sessionPreset;

@end

NS_ASSUME_NONNULL_END
