//
//  WLVideoDeviceSettingView.h
//  WorkLabs
//
//  Created by erfeixia on 2026/04/12.
//

#import <Cocoa/Cocoa.h>
#import "WLDevicesManager.h"
#import "WLViedoPreview.h"

NS_ASSUME_NONNULL_BEGIN

@class WLVideoDeviceSettingView;

@protocol WLVideoDeviceSettingViewDelegate <NSObject>
@optional
- (void)videoDeviceSettingViewDidClickCancel:(WLVideoDeviceSettingView *)view;
- (void)videoDeviceSettingViewDidClickDefault:(WLVideoDeviceSettingView *)view;
- (void)videoDeviceSettingView:(WLVideoDeviceSettingView *)view
      didClickConfirmWithDevice:(NSString *)deviceID
                         preset:(NSString *)preset
                      useBuffer:(BOOL)useBuffer;
@end

@interface WLVideoDeviceSettingView : NSView

@property (nonatomic, weak) id<WLVideoDeviceSettingViewDelegate> delegate;

- (void)updateWithDevices:(NSArray<WLDeviceItem *> *)devices currentDeviceID:(nullable NSString *)currentDeviceID;
- (void)resetToDefault;

@end

NS_ASSUME_NONNULL_END
