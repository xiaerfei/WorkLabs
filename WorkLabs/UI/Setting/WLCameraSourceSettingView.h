
#import <Cocoa/Cocoa.h>
#import "WLDevicesManager.h"
#import "WLViedoPreview.h"

NS_ASSUME_NONNULL_BEGIN

@class WLCameraSourceSettingView;

@protocol WLCameraSourceSettingViewDelegate <NSObject>
@optional
- (void)cameraSourceSettingViewDidClickCancel:(WLCameraSourceSettingView *)view;
- (void)cameraSourceSettingViewDidClickDefault:(WLCameraSourceSettingView *)view;
- (void)cameraSourceSettingView:(WLCameraSourceSettingView *)view
       didClickConfirmWithDevice:(NSString *)deviceID
                         preset:(NSString *)preset
                      useBuffer:(BOOL)useBuffer;
@end

@interface WLCameraSourceSettingView : NSView

@property (nonatomic, weak) id<WLCameraSourceSettingViewDelegate> delegate;

- (void)updateWithDevices:(NSArray<WLDeviceItem *> *)devices
          currentDeviceID:(nullable NSString *)currentDeviceID;
- (void)resetToDefault;

@end

NS_ASSUME_NONNULL_END
