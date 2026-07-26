//
//  WLDockManager.h
//  OBSLabs
//
//  Dock 管理器 + 事件总线。
//  - 管理 5 个 Dock VC 的注册/增删/显示隐藏
//  - 构造 dockBar（NSStackView）
//  - 统一事件派发：sendEvent:info: + subscribeEvent:handler: / unsubscribeWithTag:
//

#import <Cocoa/Cocoa.h>

@class WLDockViewController;

#pragma mark - 枚举

typedef NS_ENUM(NSInteger, WLDockIdentifier) {
    WLDockIdentifierScenes,
    WLDockIdentifierSources,
    WLDockIdentifierAudioMixer,
    WLDockIdentifierTransitions,
    WLDockIdentifierControls,
};

typedef NS_ENUM(NSInteger, WLEventType) {
    // Dock 生命周期事件（由 WLDockManager 命令式 API 内部派发）
    WLEventTypeDockDidAdd,
    WLEventTypeDockDidRemove,
    WLEventTypeDockDidReplace,
    WLEventTypeDockVisibilityChanged,   // show/hide

    // 源事件（由 WLSourcesDockViewController 或未来组件派发）
    WLEventTypeSourceAdded,
    WLEventTypeSourceRemoved,
    WLEventTypeSourceSelectionChanged,   // info: { @"sourcePtr": NSValue(nullable) }
};

#pragma mark - WLDockManager

@interface WLDockManager : NSObject

/// 摆好的 dock 栏 stackView（horizontal + fillEqually + spacing 6）
@property (nonatomic, readonly) NSStackView *dockBar;

/// 发送事件
- (void)sendEvent:(WLEventType)event info:(id __nullable)info;

/// 订阅事件，返回 tag 用于退订
- (NSUInteger)subscribeEvent:(WLEventType)event
                     handler:(void(^)(WLEventType event, id __nullable info))handler;

/// 移除订阅的事件
- (void)unsubscribeWithTag:(NSUInteger)tag;

/// 创建 5 个默认 dock（Scenes / Sources / Audio / Transitions / Controls）
- (void)setupDefaultDocks;

/// 命令式 API（内部派发事件）
- (void)addDock:(WLDockViewController *)dock forIdentifier:(WLDockIdentifier)identifier;
- (void)removeDockForIdentifier:(WLDockIdentifier)identifier;
- (void)replaceDockForIdentifier:(WLDockIdentifier)identifier
                        withDock:(WLDockViewController *)newDock;
- (void)setVisible:(BOOL)visible forIdentifier:(WLDockIdentifier)identifier;
- (nullable WLDockViewController *)dockForIdentifier:(WLDockIdentifier)identifier;

/// 转发 viewWillDisappear 给所有 dock VC
- (void)viewWillDisappear;

@end
