//
//  NSWindow+WLExtend.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/10.
//

#import "NSWindow+WLExtend.h"

@implementation NSWindow (WLExtend)
- (void)showTitleBar {
    // 获取并修改 styleMask
    NSWindowStyleMask style = self.styleMask;
    style |= NSWindowStyleMaskTitled;                     // 确保有标题栏
    style &= ~NSWindowStyleMaskFullSizeContentView;       // 如果之前使用 fullSizeContentView，移除以恢复标准标题栏外观

    // 应用样式
    [self setStyleMask:style];

    // 显示标题文字并使用不透明的标题栏背景
    self.titleVisibility = NSWindowTitleVisible;
    self.titlebarAppearsTransparent = NO;

    // 确保红黄绿按钮可见
    [[self standardWindowButton:NSWindowCloseButton] setHidden:NO];
    [[self standardWindowButton:NSWindowMiniaturizeButton] setHidden:NO];
    [[self standardWindowButton:NSWindowZoomButton] setHidden:NO];
}

- (void)hideTitleBar {
    // 获取并修改 styleMask
    NSWindowStyleMask style = self.styleMask;
    style &= ~NSWindowStyleMaskTitled;                    // 移除标题栏标志
    style |= NSWindowStyleMaskFullSizeContentView;        // 让内容扩展到顶端（可选）

    // 应用样式
    [self setStyleMask:style];

    // 隐藏标题文字并使标题栏透明（内容可以延伸到原标题区域）
    self.titleVisibility = NSWindowTitleHidden;
    self.titlebarAppearsTransparent = YES;

    // 隐藏红黄绿按钮（移除 titled 后按钮通常也会消失，但显式隐藏更保险）
    [[self standardWindowButton:NSWindowCloseButton] setHidden:YES];
    [[self standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
    [[self standardWindowButton:NSWindowZoomButton] setHidden:YES];
}
@end
