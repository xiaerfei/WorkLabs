//
//  ViewController.m
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//

#import "ViewController.h"
#import "WLMediaThread.h"

@interface ViewController ()
@property (nonatomic, strong) WLMediaThread *media;
@property (nonatomic, assign) BOOL didPrompt;
@end

@implementation ViewController

- (void)viewDidAppear {
    [super viewDidAppear];
    // 只弹一次：view 每次出现都会触发 viewDidAppear
    if (self.didPrompt) return;
    self.didPrompt = YES;
    [self chooseAndPlay];
}

- (void)chooseAndPlay {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择要播放的媒体文件（测试 pacing）";
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;

    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *path = panel.URLs.firstObject.path;
        if (path.length == 0) return;

        self.media = [[WLMediaThread alloc] initWithPath:path hwType:@"videotoolbox"];
        if (![self.media start]) {
            NSLog(@"[ViewController] media thread 启动失败: %@", path);
            self.media = nil;
            return;
        }
        NSLog(@"[ViewController] 开始播放（看控制台 [V]/[A] pacing 日志）: %@", path);
    }];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self.media close];
    self.media = nil;
}

@end
