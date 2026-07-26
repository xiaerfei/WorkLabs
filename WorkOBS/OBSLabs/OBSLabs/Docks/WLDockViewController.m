//
//  WLDockViewController.m
//  OBSLabs
//
//  Dock VC 基类实现。
//

#import "WLDockViewController.h"
#import "WLDockView.h"

@interface WLDockViewController ()
@property (nonatomic, copy) NSString *dockTitle;
@end

@implementation WLDockViewController

- (instancetype)initWithTitle:(NSString *)title {
    self = [super init];
    if (self) {
        _dockTitle = [title copy];
    }
    return self;
}

- (void)loadView {
    WLDockView *dockView = [[WLDockView alloc] initWithTitle:self.dockTitle];
    self.view = dockView;
}

- (WLDockView *)dockView {
    return (WLDockView *)self.view;
}

- (NSView *)dockContent {
    return self.dockView.contentView;
}

@end
