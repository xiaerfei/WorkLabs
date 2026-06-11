//
//  AppDelegate.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/9.
//

#import "AppDelegate.h"
#import "WLLog.h"
#import "WLPerfMonitor.h"

@interface AppDelegate ()


@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [WLLog restorePersistedGlobalLevel]; // 恢复设置界面选过的日志等级
    [WLPerfMonitor start]; // CPU/内存日志统计，200ms 一次
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [WLPerfMonitor stop];
}


- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return NO;
}


@end
