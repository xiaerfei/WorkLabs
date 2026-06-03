//
//  WLSettingsWindowController.h
//  WorkLabs
//
//  设置窗口 — 仿 macOS 系统设置的左右分栏（左侧分类 sidebar + 右侧面板）。
//  把原先散在工具栏菜单里的「画布分辨率」「背景色/图」迁入；操作经 delegate
//  回调宿主控制器复用既有执行逻辑。
//

#import <Cocoa/Cocoa.h>
#import "WLDefines.h"

NS_ASSUME_NONNULL_BEGIN

@protocol WLSettingsWindowControllerDelegate;

@interface WLSettingsWindowController : NSWindowController

@property (nonatomic, weak) id<WLSettingsWindowControllerDelegate> settingsDelegate;

// 打开前由宿主同步当前画布尺寸，用于分辨率下拉的初始选中
@property (nonatomic, assign) CGSize currentCanvasSize;

@end

@protocol WLSettingsWindowControllerDelegate <NSObject>

- (void)settingsDidChooseBackgroundColor:(NSColor *)color;
- (void)settingsDidChooseBackgroundImage:(NSImage *)image;
- (void)settingsDidClearBackground;

// 录制进行中禁止改分辨率：返回 NO 时设置窗口会提示并恢复原选中
- (BOOL)settingsCanChangeCanvasSize;
- (void)settingsDidSelectCanvasSize:(CGSize)size;

// 按来源类型设置混音音量（1.0=原始）
- (void)settingsDidSetVolume:(float)volume forFromType:(WLFromType)fromType;
- (float)settingsVolumeForFromType:(WLFromType)fromType;

@end

NS_ASSUME_NONNULL_END
