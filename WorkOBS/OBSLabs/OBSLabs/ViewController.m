//
//  ViewController.m
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//

#import "ViewController.h"
#import "wl_core.h"

@implementation ViewController {
    wl_source_t *_source;   // 由 wl_core 拥有；remove/shutdown 后不可再用
    BOOL         _didPrompt;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (_didPrompt) return;         // view 每次出现都触发，只弹一次
    _didPrompt = YES;

    // 全局核心：注册内置源类型 + 启动 30fps 合成节拍（graphics 空转等源）
    if (wl_core_startup(30) != 0) {
        NSLog(@"[ViewController] wl_core_startup 失败");
        return;
    }
    [self chooseAndPlay];
}

- (void)chooseAndPlay {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择媒体文件（测试 wl_core + graphics 节拍）";
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;

    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *path = panel.URLs.firstObject.path;
        if (path.length == 0) return;

        self->_source = wl_core_add_source("media_file", path.fileSystemRepresentation);
        if (!self->_source) {
            NSLog(@"[ViewController] add_source 失败: %@", path);
            return;
        }
        if (wl_source_start(self->_source) != 0) {
            NSLog(@"[ViewController] source start 失败");
            wl_core_remove_source(self->_source);
            self->_source = NULL;
            return;
        }
        NSLog(@"[ViewController] 开始播放（graphics tick 驱动，看 [get]/[gfx] 日志）: %@", path);
    }];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    wl_core_shutdown();   // 停 graphics → 销毁所有源（含 _source）
    _source = NULL;
}

@end
