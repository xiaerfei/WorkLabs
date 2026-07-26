//
//  WLSourcesDockViewController.h
//  OBSLabs
//
//  源列表 Dock：源列表（NSTableView 单列，无表头）+ 底部 +/− 工具条。
//  添加/删除源时通过 WLDockManager 事件总线派发 WLEventTypeSourceAdded/Removed，
//  同时订阅这些事件以支持外部触发的源变更。
//

#import "WLDockViewController.h"

@interface WLSourcesDockViewController : WLDockViewController
@end
