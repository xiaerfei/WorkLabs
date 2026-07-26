//
//  WLAudioMixerDockViewController.m
//  OBSLabs
//

#import "WLAudioMixerDockViewController.h"
#import "WLDockView.h"

@implementation WLAudioMixerDockViewController

- (instancetype)init {
    return [self initWithTitle:@"混音器 Audio Mixer"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self addPlaceholderText:@"音频混音（M4）"];
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
