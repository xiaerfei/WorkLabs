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

// 主预览：合成后画面铺满整个画布，底层、不拦截鼠标
@property (nonatomic, strong, readonly) WLStreamPreview *mainPreview;

// 浮层 Preview（每路 Source 一个）：可拖动/缩放，叠加在 mainPreview 之上
- (void)addOverlayPreview:(WLStreamPreview *)preview;
- (void)removeOverlayPreview:(WLStreamPreview *)preview;

@end

NS_ASSUME_NONNULL_END
