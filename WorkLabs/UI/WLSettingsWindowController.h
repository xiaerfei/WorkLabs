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

@class WLEncoderConfig;
@protocol WLSettingsWindowControllerDelegate;

@interface WLSettingsWindowController : NSWindowController

@property (nonatomic, weak) id<WLSettingsWindowControllerDelegate> settingsDelegate;

// 打开前由宿主同步当前画布尺寸，用于分辨率下拉的初始选中
@property (nonatomic, assign) CGSize currentCanvasSize;

// 源增删后刷新左栏源列表（窗口可见时调用）
- (void)reloadSources;
// 选中并显示某个源的属性页（供右键「属性…」跳转）
- (void)selectSourceID:(NSString *)streamID;

@end

@protocol WLSettingsWindowControllerDelegate <NSObject>

- (void)settingsDidChooseBackgroundColor:(NSColor *)color;
- (void)settingsDidChooseBackgroundImage:(NSImage *)image;
- (void)settingsDidClearBackground;

// 录制进行中禁止改分辨率：返回 NO 时设置窗口会提示并恢复原选中
- (BOOL)settingsCanChangeCanvasSize;
- (void)settingsDidSelectCanvasSize:(CGSize)size;

// 当前所有源列表；每项 @{@"sid":NSString, @"name":NSString, @"fromType":@(WLFromType), @"hasAudio":@(BOOL)}
- (NSArray<NSDictionary *> *)settingsSourceList;
// 按单路源（streamID）设置/读取混音音量（1.0=原始）
- (void)settingsDidSetVolume:(float)volume forStreamID:(NSString *)streamID;
- (float)settingsVolumeForStreamID:(NSString *)streamID;

// 每路源的基本滤镜参数（镜像/颜色校正/裁剪）。参数字典键见 WLBasicVideoFilter。
- (NSDictionary *)settingsFilterParamsForStreamID:(NSString *)streamID;
- (void)settingsDidSetFilterParams:(NSDictionary *)params forStreamID:(NSString *)streamID;

// 推流：服务器地址 + 密钥（推流码）。编辑结束即回调宿主保存；打开设置时回读做回填。
- (void)settingsDidSetPushURL:(NSString *)url streamKey:(NSString *)streamKey;
- (nullable NSString *)settingsPushURL;
- (nullable NSString *)settingsStreamKey;

// 编码配置（码率/关键帧间隔/帧率/音频码率，推流 + 录制共用一套）
- (nullable WLEncoderConfig *)settingsEncoderConfig;
- (void)settingsDidUpdateEncoderConfig:(WLEncoderConfig *)config;

@optional
// 调试（测试页）：请求模拟音频断流 N 秒，用于验证 A/V 同步隐患 B
- (void)settingsDidRequestSimulateAudioGap:(NSTimeInterval)seconds;

@end

NS_ASSUME_NONNULL_END
