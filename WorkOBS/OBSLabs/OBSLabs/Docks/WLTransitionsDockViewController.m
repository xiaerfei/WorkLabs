//
//  WLTransitionsDockViewController.m
//  OBSLabs
//

#import "WLTransitionsDockViewController.h"
#import "WLDockView.h"

@implementation WLTransitionsDockViewController

- (instancetype)init {
    return [self initWithTitle:@"转场 Transitions"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self addPlaceholderText:@"转场（后续）"];
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
