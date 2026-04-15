
#import <Cocoa/Cocoa.h>

@class WLVideoDeviceSettingWindowController;

@protocol WLVideoDeviceSettingWindowControllerDelegate <NSObject>
@optional
- (void)videoDeviceSettingController:(WLVideoDeviceSettingWindowController *)controller
              didConfirmWithDevice:(NSString *)deviceID
                           preset:(NSString *)preset
                       useBuffer:(BOOL)useBuffer;

- (void)videoDeviceSettingController:(WLVideoDeviceSettingWindowController *)controller
          didConfirmWithMediaPath:(NSString *)mediaPath;
@end

@interface WLVideoDeviceSettingWindowController : NSWindowController

@property (nonatomic, weak) id<WLVideoDeviceSettingWindowControllerDelegate> delegate;

+ (instancetype)sharedController;
- (void)showWindowWithSourceType:(NSUInteger)sourceType;

@end
