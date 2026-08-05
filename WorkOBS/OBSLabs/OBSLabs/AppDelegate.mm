//
//  AppDelegate.mm
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//
//  管线生命周期挂在 app 上（对齐 OBS：libobs 随进程起落，窗口只是观察窗）：
//  startup 在主窗口首次出现时（ViewController.viewDidAppear，幂等），
//  shutdown 只在 app 退出时——关窗/最小化都不拆管线，只摘帧输出。
//

#import "AppDelegate.h"
#import "WLCore.hpp"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    WLCore::Shutdown();   // join 节拍/解码线程 + 销毁所有源
}

// 单窗口工具 app：关最后一个窗口即退出（没有托盘/菜单栏入口，
// 后台保活用户无从控制；OBS 桌面版关主窗也是退出）
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

@end
