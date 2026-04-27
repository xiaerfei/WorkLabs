//
//  WLMediaSourceItem.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, WLMediaSourceType) {
    WLMediaSourceTypeCamera,
    WLMediaSourceTypeVideo,
    WLMediaSourceTypeAudio
};

@interface WLMediaSourceItem : NSObject

/// 唯一标识
@property (nonatomic, copy, readonly) NSUUID *uuid;

/// 显示名称
@property (nonatomic, copy) NSString *name;

/// 源类型
@property (nonatomic, assign, readonly) WLMediaSourceType type;

/// 源引擎引用 (WLCameraSource 或 WLMediaSource)
@property (nonatomic, strong, nullable) id sourceEngine;

/// 画布中的位置 (中心点)
@property (nonatomic, assign) CGPoint position;

/// 预览尺寸
@property (nonatomic, assign) CGSize size;

/// Z 轴顺序 (越大越靠上)
@property (nonatomic, assign) NSUInteger zOrder;

/// 旋转角度 (弧度)
@property (nonatomic, assign) CGFloat rotation;

/// 音量 (0.0 ~ 1.0)
@property (nonatomic, assign) CGFloat volume;

/// 是否静音
@property (nonatomic, assign, getter=isMuted) BOOL muted;

/// 运行状态
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

/// 是否被选中
@property (nonatomic, assign) BOOL isSelected;

- (instancetype)initWithType:(WLMediaSourceType)type name:(NSString *)name;

- (void)start;
- (void)stop;
- (void)pause;
- (void)resume;

@end

NS_ASSUME_NONNULL_END
