//
//  WLColorMediaSource.h
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//
//  纯色背景媒体源 —— 实现 WLMediaSourceProvider 协议

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "WLMediaSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

/**
 WLColorMediaSource —— 纯色/渐变背景媒体源
 
 生成指定颜色和尺寸的纯色画面，用作场景背景或色键源。
 */
@interface WLColorMediaSource : NSObject <WLMediaSourceProvider>

/** 背景颜色 */
@property (nonatomic, strong) NSColor *color;

/** 输出尺寸（像素） */
@property (nonatomic, assign) CGSize outputSize;

/**
 使用颜色和尺寸创建纯色媒体源
 
 @param color 背景颜色
 @param size 输出尺寸
 @return 实例
 */
- (instancetype)initWithColor:(NSColor *)color size:(CGSize)size;

@end

NS_ASSUME_NONNULL_END
