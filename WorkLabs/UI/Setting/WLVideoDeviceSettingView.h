
#import <Cocoa/Cocoa.h>
#import "WLDevicesManager.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, WLVideoSourceType) {
    WLVideoSourceTypeMedia,
    WLVideoSourceTypeCamera,
};

@class WLVideoDeviceSettingView;

@protocol WLVideoDeviceSettingViewDelegate <NSObject>
@optional
- (void)videoDeviceSettingViewDidClickCancel:(WLVideoDeviceSettingView *)view;

- (void)videoDeviceSettingView:(WLVideoDeviceSettingView *)view
  didConfirmCameraWithDevice:(NSString *)deviceID
                       preset:(NSString *)preset
                    useBuffer:(BOOL)useBuffer;

- (void)videoDeviceSettingView:(WLVideoDeviceSettingView *)view
  didConfirmMediaWithFilePath:(NSString *)filePath;
@end

@interface WLVideoDeviceSettingView : NSView

@property (nonatomic, weak) id<WLVideoDeviceSettingViewDelegate> delegate;

- (void)switchToSourceType:(WLVideoSourceType)sourceType;
- (void)updateCameraDevices:(NSArray<WLDeviceItem *> *)devices
             currentDeviceID:(nullable NSString *)currentDeviceID;
- (void)updateMediaFilePath:(nullable NSString *)filePath;

@end

NS_ASSUME_NONNULL_END
