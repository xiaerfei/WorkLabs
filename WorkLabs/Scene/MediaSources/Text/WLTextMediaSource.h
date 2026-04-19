//
//  WLTextMediaSource.h
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//
//  文字叠加媒体源 —— 实现 WLMediaSourceProvider 协议

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "WLMediaSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

/**
 WLTextMediaSource —— 文字/字幕叠加媒体源
 
 将文字渲染为 CVPixelBuffer，作为视频源叠加到场景中。
 支持自定义字体、颜色、对齐方式等。
 */
@interface WLTextMediaSource : NSObject <WLMediaSourceProvider>

/** 显示文本 */
@property (nonatomic, copy) NSString *text;

/** 字体 */
@property (nonatomic, strong) NSFont *font;

/** 文字颜色 */
@property (nonatomic, strong) NSColor *textColor;

/** 背景色（透明则不填充背景） */
@property (nonatomic, strong) NSColor *backgroundColor;

/** 输出尺寸（像素） */
@property (nonatomic, assign) CGSize outputSize;

/**
 使用文本和尺寸创建文字媒体源
 
 @param text 显示文本
 @param size 输出尺寸
 @return 实例
 */
- (instancetype)initWithText:(NSString *)text size:(CGSize)size;

/** 重新渲染（文本/字体/颜色变化后调用） */
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
