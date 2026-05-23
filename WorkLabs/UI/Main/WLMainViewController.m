//
//  WLMainViewController.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/9.
//

#import "WLMainViewController.h"
#import <Masonry/Masonry.h>
#import "WLStreamViewController.h"

@interface WLMainViewController ()
@property (nonatomic, strong) WLStreamViewController *streamVC;
@end

@implementation WLMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [NSColor blackColor].CGColor;

    self.streamVC = [[WLStreamViewController alloc] init];
    [self addChildViewController:self.streamVC];
    [self.view addSubview:self.streamVC.view];

    [self.streamVC.view mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];
}

@end
