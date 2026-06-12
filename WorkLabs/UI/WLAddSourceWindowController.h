//
//  WLAddSourceWindowController.h
//  WorkLabs
//
//  「添加源」窗口 — 左右双栏：左栏列出已添加的源（可移除），右栏列出可添加项
//  （视频文件按钮 + 摄像头/麦克风设备列表，已添加的设备标记 ✓ 不可重复加）。
//  设备热插拔经 WLDevicesManager 信号实时刷新；支持把视频文件拖入窗口添加。
//  取代原工具栏「+」的三级弹出菜单。
//

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol WLAddSourceWindowControllerDelegate <NSObject>

// 当前所有源；每项 @{@"sid":NSString, @"name":NSString, @"fromType":@(WLFromType),
//                  @"deviceUID":NSString(仅摄像头/麦克风，设备唯一标识，用于「已添加」判定)}
- (NSArray<NSDictionary *> *)addSourceCurrentSources;

// 用户选择了要添加的项（授权请求与同设备去重由宿主处理）
- (void)addSourceDidPickMediaPath:(NSString *)path;
- (void)addSourceDidPickCameraDevice:(AVCaptureDevice *)device;
- (void)addSourceDidPickMicDevice:(AVCaptureDevice *)device;

// 请求移除某路源（窗口内已弹确认）
- (void)addSourceDidRequestRemove:(NSString *)streamID;

@end

@interface WLAddSourceWindowController : NSWindowController

@property (nonatomic, weak) id<WLAddSourceWindowControllerDelegate> addSourceDelegate;

// 源增删后由宿主调用：刷新左栏列表 + 右栏设备「已添加」状态（窗口不可见时无操作）
- (void)reloadSources;

@end

NS_ASSUME_NONNULL_END
