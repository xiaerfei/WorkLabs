//
//  WLMenuPanelViewController.h
//  WorkLabs
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WLMenuPanelCallerType) {
    WLMenuPanelCallerTypeSource,
    WLMenuPanelCallerTypeAudioMixer,
};

@interface WLMenuPanelViewController : NSViewController

@property (nonatomic, assign) WLMenuPanelCallerType callerType;
@property (nonatomic, copy, nullable) void (^dismissHandler)(void);

@end

NS_ASSUME_NONNULL_END
