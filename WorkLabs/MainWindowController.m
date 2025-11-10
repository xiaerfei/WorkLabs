//
//  MainWindowController.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/9.
//

#import "MainWindowController.h"
#import <ReactiveObjC.h>

@interface MainWindowController ()

@end

@implementation MainWindowController

- (void)windowDidLoad {
    [super windowDidLoad];
    // 添加 trackingArea
    NSTrackingArea *trackingArea = [[NSTrackingArea alloc] initWithRect:self.window.contentView.bounds
                                                                options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
                                                                  owner:self
                                                               userInfo:nil];
    [self.window.contentView addTrackingArea:trackingArea];
    
//    [[RACSignal merge:@[
//            [[self rac_signalForSelector:@selector(mouseEntered:)] mapReplace:@YES],
//            [[self rac_signalForSelector:@selector(mouseExited:)] mapReplace:@NO]]
//     ] subscribeNext:^(NSNumber *visible) {
//        if (visible.boolValue) {
//            NSLog(@"显示");
//            [self showTitleBar];
//        } else {
//            NSLog(@"隐藏");
//            [self hideTitleBar];
//        }
//    }];
    
//    [[self rac_signalForSelector:@selector(mouseEntered:)]
//     subscribeNext:^(id  _Nullable x) {
//    
//    }];
//    
//    [[self rac_signalForSelector:@selector(mouseExited:)]
//     subscribeNext:^(id  _Nullable x) {
//        [self hideTitleBar];
//    }];
    [self hideTitleBar];
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    NSLog(@"------------> 进入");
    [self showTitleBar];
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    NSLog(@"------------> 移出");
    [self hideTitleBar];
}


- (void)showTitleBar {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 获取并修改 styleMask
        NSWindowStyleMask style = self.window.styleMask;
        style |= NSWindowStyleMaskTitled;                     // 确保有标题栏
        style &= ~NSWindowStyleMaskFullSizeContentView;       // 如果之前使用 fullSizeContentView，移除以恢复标准标题栏外观

        // 应用样式
        [self.window setStyleMask:style];

        // 显示标题文字并使用不透明的标题栏背景
        self.window.titleVisibility = NSWindowTitleVisible;
        self.window.titlebarAppearsTransparent = NO;

        // 确保红黄绿按钮可见
        [[self.window standardWindowButton:NSWindowCloseButton] setHidden:NO];
        [[self.window standardWindowButton:NSWindowMiniaturizeButton] setHidden:NO];
        [[self.window standardWindowButton:NSWindowZoomButton] setHidden:NO];

        // 如果希望可以拖拽窗口（当标题栏可见时通常不需要），可以根据需要设置：
        // [self setMovableByWindowBackground:NO];
    });
}

- (void)hideTitleBar {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 获取并修改 styleMask
        NSWindowStyleMask style = self.window.styleMask;
        style &= ~NSWindowStyleMaskTitled;                    // 移除标题栏标志
        style |= NSWindowStyleMaskFullSizeContentView;        // 让内容扩展到顶端（可选）

        // 应用样式
        [self.window setStyleMask:style];

        // 隐藏标题文字并使标题栏透明（内容可以延伸到原标题区域）
        self.window.titleVisibility = NSWindowTitleHidden;
        self.window.titlebarAppearsTransparent = YES;

        // 隐藏红黄绿按钮（移除 titled 后按钮通常也会消失，但显式隐藏更保险）
        [[self.window standardWindowButton:NSWindowCloseButton] setHidden:YES];
        [[self.window standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
        [[self.window standardWindowButton:NSWindowZoomButton] setHidden:YES];

        // 当没有标题栏时，如果希望仍能通过窗口背景拖动窗口：
        [self.window setMovableByWindowBackground:YES];
    });
}


@end
