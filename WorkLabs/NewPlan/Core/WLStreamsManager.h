//
//  WLStreamsManager.h
//  WorkLabs
//
//  推流管线编排器：Source → perStreamFilter → fork(Preview + Mix) → PostFilter → MainPreview
//

#import <Foundation/Foundation.h>
#import "WLStreamSourceProtocol.h"
#import "WLStreamOutputProtocol.h"
#import "WLStreamFilterProtocol.h"
#import "WLStreamRenderingProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLStreamsManager : NSObject <WLStreamSourceDelegate, WLStreamRenderingDelegate>

+ (instancetype)manager;

// 固定画布尺寸，默认 1920×1080。需在添加 Source 前设置。
@property (nonatomic, assign) CGSize canvasSize;

// 主预览输出：接收 Mix + PostFilter 处理后的合成画面
@property (nonatomic, weak, nullable) id<WLVideoOutputProtocol> mainPreviewOutput;

// 合成之后再过的最终 Filter（如美颜/水印）；nil 时跳过
@property (nonatomic, strong, nullable) id<WLVideoFilterProtocol> postFilter;

#pragma mark - Source

// 注册 Source；同时指定其小预览输出（如 WLStreamPreview，nil 表示不需要小预览）。
// 内部会把 source.delegate 设为 self，因此 Source 的 delegate 由 Manager 接管。
- (void)addSource:(id<WLStreamSourceProtocol>)source
   previewOutput:(nullable id<WLVideoOutputProtocol>)preview;

- (void)removeSource:(id<WLStreamSourceProtocol>)source;

// 为某路 Source 设置 perStreamFilter（缩放/裁剪/镜像）；nil 表示透传
- (void)setFilter:(nullable id<WLVideoFilterProtocol>)filter
        forSource:(id<WLStreamSourceProtocol>)source;

// 设置某路 Source 在画布上的 layout（画布像素坐标，左下角原点）
- (void)setLayoutFrame:(CGRect)frame forSource:(id<WLStreamSourceProtocol>)source;

#pragma mark - Lifecycle

@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
