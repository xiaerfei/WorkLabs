//
//  ViewController.mm
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//
//  .mm（Objective-C++）：OC 方法体里直接调 C++ 类（WLCore / WLSource）。
//

#import "ViewController.h"
#import "WLCore.hpp"
#import "WLSource.hpp"

@implementation ViewController {
    WLSource *_source;   // 由 WLCore 拥有；remove/shutdown 后不可再用
    BOOL      _didPrompt;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (_didPrompt) return;         // view 每次出现都触发，只弹一次
    _didPrompt = YES;

    // 全局核心：注册内置源类型 + 启动 30fps 合成节拍（graphics 空转等源）
    if (WLCore::startup(30) != 0) {
        NSLog(@"[ViewController] WLCore::startup 失败");
        return;
    }
    [self chooseAndPlay];
}

- (void)chooseAndPlay {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择媒体文件（测试 WLCore + graphics 节拍）";
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;

    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *path = panel.URLs.firstObject.path;
        if (path.length == 0) return;

        self->_source = WLCore::add_source("media_file", path.fileSystemRepresentation);
        if (!self->_source) {
            NSLog(@"[ViewController] add_source 失败: %@", path);
            return;
        }
        if (self->_source->start() != 0) {
            NSLog(@"[ViewController] source start 失败");
            WLCore::remove_source(self->_source);
            self->_source = NULL;
            return;
        }
        NSLog(@"[ViewController] 开始播放（graphics tick 驱动，看 [get]/[gfx] 日志）: %@", path);
    }];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    WLCore::shutdown();   // 停 graphics → 销毁所有源（含 _source）
    _source = NULL;
}

@end
