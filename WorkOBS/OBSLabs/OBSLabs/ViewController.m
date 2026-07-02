//
//  ViewController.m
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//

#import "ViewController.h"
#import "wl_source.h"
#import "wl_media_source.h"
#import <time.h>

// 消费端时钟：与生产端 pace 同一把单调尺（CLOCK_MONOTONIC）
static int64_t vc_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

@interface ViewController ()
@property (nonatomic, strong) NSTimer *tickTimer;   // 临时消费 tick（M3 由 wl_graphics 替代）
@end

@implementation ViewController {
    wl_source_t *_source;
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
    panel.title = @"选择媒体文件（测试 async_frames 追赶挑帧）";
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
        NSLog(@"[ViewController] 开始播放（看控制台 [src V] 生产 / [get] 消费挑帧）: %@", path);
        [self startTick];
    }];
}

// 临时 30fps 消费 tick：模拟 wl_graphics，按系统时钟从 source 挑帧
- (void)startTick {
    __weak typeof(self) weakSelf = self;
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
        typeof(self) self_ = weakSelf;
        if (!self_ || !self_->_source) return;
        int64_t pts = 0;
        // borrow 一帧（不 release）；这里只验证挑帧节奏，不渲染
        wl_source_get_frame(self_->_source, vc_now_ns(), &pts);
    }];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self.tickTimer invalidate];
    self.tickTimer = nil;
    if (_source) {
        wl_source_destroy(_source);   // 内部先 stop（join 解码线程）再释放缓冲
        _source = NULL;
    }
}

@end
