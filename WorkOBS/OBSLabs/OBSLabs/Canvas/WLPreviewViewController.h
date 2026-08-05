//
//  WLPreviewViewController.h
//  OBSLabs
//
//  预览区 VC：画布（16:9 居中）+ per-source 交互浮层 + 帧路由 + 源事件订阅
//  全部内聚在这里；ViewController 只负责窗口布局骨架与 WLCore 生命周期。
//
//  view = 预览外围深色区（previewArea），父控制器加约束定位即可。
//  帧输出的挂/摘由父控制器显式编排（不依赖 viewDidAppear 传播顺序）：
//    WLCore::Startup 成功后 → startFrameOutput
//    窗口不可见时           → stopFrameOutput（摘输出不拆管线，恢复时重挂）
//  浮层/源数据的生命周期跟管线（= app）走，窗口消失不清理；
//  管线 shutdown 挂在 app 退出（AppDelegate）。
//

#import <Cocoa/Cocoa.h>

@class WLDockManager;

NS_ASSUME_NONNULL_BEGIN

@interface WLPreviewViewController : NSViewController

// 事件总线经构造注入（订阅 SourceAdded/Removed/SelectionChanged，
// 广播选中联动与移除请求）。
- (instancetype)initWithDockManager:(WLDockManager *)manager;

- (void)startFrameOutput;
- (void)stopFrameOutput;

@end

NS_ASSUME_NONNULL_END
