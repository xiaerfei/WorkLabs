//
//  WLMediaSourcePreview.h
//  WorkLabs
//

#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>

@class WLMediaSourceItem;

NS_ASSUME_NONNULL_BEGIN

@interface WLMediaSourcePreview : NSView

/// 关联的媒体源条目
@property (nonatomic, weak, nullable) WLMediaSourceItem *item;

/// 是否为选中状态 (控制边框显示)
@property (nonatomic, assign, getter=isSelected) BOOL selected;

/// 显示视频帧 (拷贝自 WLMetalPreview)
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer;

/// 显示音频占位视图
- (void)showAudioPlaceholder;

/// 根据 item 的 transform 更新 frame
- (void)updateTransform;

@end

NS_ASSUME_NONNULL_END
