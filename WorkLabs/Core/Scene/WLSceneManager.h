//
//  WLSceneManager.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class WLMediaSourceItem;
@class WLCameraSourceConfig;

NS_ASSUME_NONNULL_BEGIN

/// 输出分辨率预设
typedef NS_ENUM(NSUInteger, WLOutputResolution) {
    WLOutputResolution360p  = 0,   // 640x360
    WLOutputResolution540p  = 1,   // 960x540
    WLOutputResolution720p  = 2,   // 1280x720
    WLOutputResolution1080p = 3,   // 1920x1080 (默认)
    WLOutputResolution1440p = 4,   // 2560x1440
    WLOutputResolution4K    = 5,   // 3840x2160
};

@interface WLSceneManager : NSObject

/// 单例
+ (instancetype)manager;

#pragma mark - 输出分辨率

/// 场景输出分辨率 (影响合成画布、推流/录制尺寸，默认 1080p)
@property (nonatomic, assign) WLOutputResolution outputResolution;

/// 将枚举转为实际 CGSize
+ (CGSize)sizeForResolution:(WLOutputResolution)resolution;

/// 返回所有可用分辨率枚举值
+ (NSArray<NSNumber *> *)availableResolutions;

/// 分辨率枚举的显示名称 (如 "1920x1080 (1080p)")
+ (NSString *)displayNameForResolution:(WLOutputResolution)resolution;

#pragma mark - 源管理

/// 场景中的源列表
@property (nonatomic, strong, readonly) NSArray<WLMediaSourceItem *> *sources;

/// 当前选中的源
@property (nonatomic, strong, readonly, nullable) WLMediaSourceItem *selectedSource;

/// 添加摄像头源
- (WLMediaSourceItem *)addCameraSourceWithConfig:(WLCameraSourceConfig *)config;

/// 添加视频文件源
- (WLMediaSourceItem *)addVideoSourceWithPath:(NSString *)path;

/// 添加音频文件源
- (WLMediaSourceItem *)addAudioSourceWithPath:(NSString *)path;

/// 移除指定源
- (void)removeSource:(WLMediaSourceItem *)item;

/// 移除指定位置的源
- (void)removeSourceAtIndex:(NSUInteger)index;

#pragma mark - 选择

/// 选中指定源，传 nil 取消全部选中
- (void)selectSource:(nullable WLMediaSourceItem *)item;

/// 取消全部选中
- (void)deselectAll;

#pragma mark - 排序

/// 移动源的位置
- (void)moveSourceAtIndex:(NSUInteger)from toIndex:(NSUInteger)to;

#pragma mark - 全局控制

- (void)startAll;
- (void)stopAll;

@end

NS_ASSUME_NONNULL_END
