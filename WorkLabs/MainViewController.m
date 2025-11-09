//
//  MainViewController.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/9.
//

#import "MainViewController.h"
#include <libavformat/avformat.h>

@interface MainViewController ()
@property (weak) IBOutlet NSView *bottomBarView;

@end

@implementation MainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.bottomBarView.layer == nil) {
        self.bottomBarView.wantsLayer = YES;
    } else {
        NSLog(@"---------%p", self.bottomBarView.layer);
    }
    self.bottomBarView.layer.backgroundColor = [NSColor lightGrayColor].CGColor;
    
}


- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];

    // Update the view, if already loaded.
}


@end
