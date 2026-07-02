//
//  ViewController.m
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//

#import "ViewController.h"
#import "wl_source.h"
#import "wl_media_source.h"

@implementation ViewController {
    wl_source_t *_source;   // 当前测试源（C 层，手动管理生命周期）
    BOOL         _didPrompt;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (_didPrompt) return;         // view 每次出现都触发，只弹一次
    _didPrompt = YES;

    wl_media_source_register();     // 注册 "media_file" 源类型（幂等）
    [self chooseAndPlay];
}

- (void)chooseAndPlay {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择媒体文件（测试 source 注册 + pacing）";
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;

    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *path = panel.URLs.firstObject.path;
        if (path.length == 0) return;

        self->_source = wl_source_create("media_file", path.fileSystemRepresentation);
        if (!self->_source) {
            NSLog(@"[ViewController] wl_source_create 失败: %@", path);
            return;
        }
        if (wl_source_start(self->_source) != 0) {
            NSLog(@"[ViewController] wl_source_start 失败");
            wl_source_destroy(self->_source);
            self->_source = NULL;
            return;
        }
        NSLog(@"[ViewController] 开始播放（看控制台 [src V]/[src A] 日志）: %@", path);
    }];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    if (_source) {
        wl_source_destroy(_source);   // 内部先 stop（join 线程）再 destroy
        _source = NULL;
    }
}

@end
