//
//  ViewController.mm
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//
//  .mm（Objective-C++）：OC 方法体里直接调 C++ 类（WLCore）。
//
//  OBS 经典布局外壳（只做骨架 + WLCore 生命周期编排，业务各归其所）：
//  ┌──────────────────────────────────────────────┐
//  │              预览区                            │  ← WLPreviewViewController
//  ├──────┬──────┬──────────┬──────────┬───────────┤
//  │Scenes│Sources│Audio Mixer│Transitions│ Controls │  ← WLDockManager 管理的 5 dock
//  └──────┴──────┴──────────┴──────────┴───────────┘
//

#import "ViewController.h"
#import "WLDockManager.h"
#import "WLPreviewViewController.h"
#import "WLCore.hpp"

@interface ViewController ()
@property (nonatomic, strong) WLDockManager             *dockManager;
@property (nonatomic, strong) WLPreviewViewController   *previewVC;
@end

@implementation ViewController {
    BOOL _didSetInitialSize;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildUI];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    // Startup 幂等（started 守卫）：最小化→恢复会重入这里，只有首次真正启动
    if (WLCore::Startup(30) != 0) {
        NSLog(@"[ViewController] WLCore::Startup 失败");
        return;
    }
    NSWindow *win = self.view.window;
    win.title = @"OBSLabs";
    if (!_didSetInitialSize) {
        _didSetInitialSize = YES;
        [win setContentSize:NSMakeSize(960, 600)];
        [win center];
    }
    [self.previewVC startFrameOutput];   // startup 成功后才挂帧输出
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    // 只摘帧输出：窗口不可见（最小化/关闭）不拆管线，graphics 空转短路零浪费；
    // 恢复可见时 viewDidAppear 重挂，画面无缝衔接。
    // 管线的 shutdown 挂在 app 退出（AppDelegate.applicationWillTerminate）。
    [self.previewVC stopFrameOutput];
}

#pragma mark - UI 搭建（布局骨架）

- (void)buildUI {
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [NSColor colorWithWhite:0.10 alpha:1].CGColor;

    // ── 底部 dock 栏（事件总线也在 dockManager 上）──
    self.dockManager = [WLDockManager new];
    [self.dockManager setupDefaultDocks];
    NSStackView *dockBar = self.dockManager.dockBar;
    [self.view addSubview:dockBar];

    // ── 预览区（画布 + 浮层全在 previewVC 内部）──
    self.previewVC = [[WLPreviewViewController alloc] initWithDockManager:self.dockManager];
    [self addChildViewController:self.previewVC];
    NSView *previewArea = self.previewVC.view;
    previewArea.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:previewArea];

    const CGFloat pad = 8;
    [NSLayoutConstraint activateConstraints:@[
        [previewArea.topAnchor      constraintEqualToAnchor:self.view.topAnchor      constant:pad],
        [previewArea.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor  constant:pad],
        [previewArea.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [previewArea.bottomAnchor   constraintEqualToAnchor:dockBar.topAnchor        constant:-pad],
        [dockBar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor  constant:pad],
        [dockBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [dockBar.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor   constant:-pad],
        [dockBar.heightAnchor   constraintEqualToConstant:200],
        [self.view.widthAnchor  constraintGreaterThanOrEqualToConstant:800],
    ]];
}

@end
