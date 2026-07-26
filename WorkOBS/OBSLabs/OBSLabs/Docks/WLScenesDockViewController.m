//
//  WLScenesDockViewController.m
//  OBSLabs
//

#import "WLScenesDockViewController.h"
#import "WLDockView.h"

@implementation WLScenesDockViewController

- (instancetype)init {
    return [self initWithTitle:@"场景 Scenes"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self addPlaceholderText:@"场景（≈M3）"];
}

- (void)addPlaceholderText:(NSString *)text {
    NSTextField *l = [NSTextField labelWithString:text];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.textColor = [NSColor colorWithWhite:0.5 alpha:1];
    l.font = [NSFont systemFontOfSize:11];
    [self.dockContent addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:self.dockContent.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:self.dockContent.centerYAnchor],
    ]];
}

@end
