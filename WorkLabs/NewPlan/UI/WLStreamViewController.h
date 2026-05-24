//
//  WLStreamViewController.h
//  WorkLabs
//
//  推流主界面
//

#import <Cocoa/Cocoa.h>

@class WLStreamPreview;

NS_ASSUME_NONNULL_BEGIN

@interface WLStreamViewController : NSViewController

- (void)addPreview:(WLStreamPreview *)preview;
- (void)removePreview:(WLStreamPreview *)preview;

@end

NS_ASSUME_NONNULL_END
