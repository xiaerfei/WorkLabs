//
//  WLVideoDeviceSettingWindowController.h
//  WorkLabs
//
//  Created by erfeixia on 2026/04/12.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class WLVideoDeviceSettingWindowController;

@protocol WLVideoDeviceSettingWindowControllerDelegate <NSObject>
@optional
- (void)videoDeviceSettingController:(WLVideoDeviceSettingWindowController *)controller
              didConfirmWithDevice:(NSString *)deviceID
                           preset:(NSString *)preset
                       useBuffer:(BOOL)useBuffer;
@end

@interface WLVideoDeviceSettingWindowController : NSWindowController

@property (nonatomic, weak) id<WLVideoDeviceSettingWindowControllerDelegate> delegate;

+ (instancetype)sharedController;
- (void)showWindowWithCurrentDevice:(NSString *)currentDeviceID;

@end

NS_ASSUME_NONNULL_END
