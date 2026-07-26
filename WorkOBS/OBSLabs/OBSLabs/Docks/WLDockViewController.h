//
//  WLDockViewController.h
//  OBSLabs
//
//  Dock VC 基类：统一 title + WLDockView 作为 self.view + helper。
//  子类 override viewDidLoad 调 [super viewDidLoad] 后塞自己的内容。
//

#import <Cocoa/Cocoa.h>

@class WLDockManager;
@class WLDockView;

@interface WLDockViewController : NSViewController

/// 反向引用，由 Manager 在 addDock:forIdentifier: 时设置；
/// 子类通过 [self.manager sendEvent:...] 主动广播事件
@property (nonatomic, weak, nullable) WLDockManager *manager;

- (instancetype)initWithTitle:(NSString *)title;

/// 返回 self.view 强转为 WLDockView
- (WLDockView *)dockView;

/// 返回 dockView.contentView（子类往这里加自己的 UI）
- (NSView *)dockContent;

@end
