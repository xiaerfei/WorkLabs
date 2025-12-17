//
//  WLSettingViewController.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/16.
//

#import "WLSettingViewController.h"
#import "WLDevicesManager.h"
#import "NSArray+Function.h"
#import "WLVideoSelectView.h"
#import "Masonry.h"
#import "WLEvent.h"

@interface WLSettingViewController ()
@property (nonatomic, strong) NSStackView *stackView;

@property (nonatomic, strong) WLVideoSelectView *videoSelectView;
@end

@implementation WLSettingViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 创建 stackView
    self.stackView = [[NSStackView alloc] init];
    self.stackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stackView.alignment = NSLayoutAttributeCenterX;
    self.stackView.distribution = NSStackViewDistributionFill;
    self.stackView.spacing = 10;

    [self.view addSubview:self.stackView];

    // Masonry 约束 stackView 填满控制器的根视图
    [self.stackView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.top.right.equalTo(self.view);
    }];

    // 添加子视图
    self.videoSelectView = [[WLVideoSelectView alloc] init];
    [self.stackView addArrangedSubview:self.videoSelectView];
    [self.videoSelectView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(50);
    }];
    
    [self.videoSelectView updateWithDeviceItems:[[WLDevicesManager manager] currentVideoDevices]];
    
    WLEventObserve()
        .type(WLEventTypeVideoDeviceChange)
        .payload(@[])
        .send();
    
    WLEventObserve()
        .subscribe(@[])
        .owner(self)
        .mainQueue()
        .block(^(WLEventType type, id payload) {
            
        });
    
}

- (void)dealloc {
    NSLog(@"sharexia: WLSettingViewController release ...");
}

@end
