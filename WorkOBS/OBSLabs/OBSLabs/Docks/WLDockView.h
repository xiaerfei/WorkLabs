//
//  WLDockView.h
//  OBSLabs
//
//  Dock 通用容器：深色标题栏 + contentView。
//  所有 WLDockViewController 子类共用。
//

#import <Cocoa/Cocoa.h>

@interface WLDockView : NSView
@property (nonatomic, readonly) NSView *contentView;
- (instancetype)initWithTitle:(NSString *)title;
@end
