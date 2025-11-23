//
//  WLMainWindowController.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/9.
//

#import "WLMainWindowController.h"
#import "NSWindow+WLExtend.h"
#import <ReactiveObjC.h>
@interface WLMainWindowController () <NSWindowDelegate>
@property (nonatomic, strong) NSTrackingArea *contentViewTrackingArea; // 存储 trackingArea
@end

@implementation WLMainWindowController

- (void)windowDidLoad {
    [super windowDidLoad];
    // 设置窗口代理以便接收尺寸变化通知
    self.window.delegate = self;
    
    [self setupTrackingArea];
    [self.window hideTitleBar];
    
    
    @weakify(self);
    [[[RACSignal merge:@[
        [[self rac_signalForSelector:@selector(mouseEntered:)] mapReplace:@YES],
        [[self rac_signalForSelector:@selector(mouseExited:)] flattenMap:^__kindof RACSignal * _Nullable(RACTuple * _Nullable value) {
            return [[RACSignal return:@NO] delay:5];
        }]
    ]] distinctUntilChanged] subscribeNext:^(NSNumber *visible) {
        @strongify(self);
        if (visible.boolValue) {
            [self.window showTitleBar];
        } else {
            [self.window hideTitleBar];
        }
    }];
}

- (void)setupTrackingArea {
    // 移除旧的 trackingArea (如果存在)
    if (self.contentViewTrackingArea) {
        [self.window.contentView removeTrackingArea:self.contentViewTrackingArea];
    }
    
    // 创建新的 trackingArea
    NSTrackingArea *trackingArea =
    [[NSTrackingArea alloc] initWithRect:self.window.contentView.bounds
                                 options:(NSTrackingMouseEnteredAndExited |
                                          NSTrackingActiveAlways |
                                          NSTrackingInVisibleRect)
                                   owner:self
                                userInfo:nil];
    [self.window.contentView addTrackingArea:trackingArea];
    self.contentViewTrackingArea = trackingArea; // 保存引用
}

// NSWindowDelegate 方法，窗口尺寸改变时调用
- (void)windowDidResize:(NSNotification *)notification {
    // 重新设置 trackingArea 以匹配新的窗口尺寸
    [self setupTrackingArea];
}

@end
