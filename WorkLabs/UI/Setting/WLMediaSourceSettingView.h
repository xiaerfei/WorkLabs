
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class WLMediaSourceSettingView;

@protocol WLMediaSourceSettingViewDelegate <NSObject>
@optional
- (void)mediaSourceSettingViewDidClickCancel:(WLMediaSourceSettingView *)view;
- (void)mediaSourceSettingView:(WLMediaSourceSettingView *)view
  didClickConfirmWithFilePath:(NSString *)filePath;
@end

@interface WLMediaSourceSettingView : NSView

@property (nonatomic, weak) id<WLMediaSourceSettingViewDelegate> delegate;

- (void)updateWithFilePath:(nullable NSString *)filePath;

@end

NS_ASSUME_NONNULL_END
