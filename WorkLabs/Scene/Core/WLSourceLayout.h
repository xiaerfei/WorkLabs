//
//  WLSourceLayout.h
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//
//  媒体源布局信息 —— 描述一个媒体源在场景中的位置、大小和属性

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/**
 WLSourceLayout —— 描述媒体源在场景画布中的布局属性
 
 场景中每个媒体源都关联一个 Layout，用于控制：
 - 在画布中的位置和尺寸（frame）
 - 裁剪区域（crop）
 - 音量、可见性、层级顺序（zIndex）
 */
@interface WLSourceLayout : NSObject

/// 媒体源在画布中的位置和大小
@property (nonatomic, assign) CGRect frame;

/// 裁剪边距
@property (nonatomic, assign) CGFloat cropTop;
@property (nonatomic, assign) CGFloat cropBottom;
@property (nonatomic, assign) CGFloat cropLeft;
@property (nonatomic, assign) CGFloat cropRight;

/// 音量 (0.0 ~ 1.0)
@property (nonatomic, assign) CGFloat volume;

/// 是否可见
@property (nonatomic, assign) BOOL visible;

/// 层级顺序（值越大越靠上）
@property (nonatomic, assign) NSInteger zIndex;

+ (instancetype)layoutWithFrame:(CGRect)frame;

@end

NS_ASSUME_NONNULL_END
