//
//  WLDockView.mm
//  OBSLabs
//
//  Dock 通用容器：深色标题栏（24pt）+ contentView 撑满。
//  从 ViewController.mm 原样搬出，零修改。
//

#import "WLDockView.h"

@implementation WLDockView

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithWhite:0.14 alpha:1].CGColor;
        self.layer.borderColor = [NSColor colorWithWhite:0.25 alpha:1].CGColor;
        self.layer.borderWidth = 1;

        NSView *header = [NSView new];
        header.translatesAutoresizingMaskIntoConstraints = NO;
        header.wantsLayer = YES;
        header.layer.backgroundColor = [NSColor colorWithWhite:0.18 alpha:1].CGColor;
        [self addSubview:header];

        NSTextField *label = [NSTextField labelWithString:title];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.textColor = [NSColor colorWithWhite:0.85 alpha:1];
        label.font = [NSFont boldSystemFontOfSize:11];
        [header addSubview:label];

        _contentView = [NSView new];
        _contentView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_contentView];

        [NSLayoutConstraint activateConstraints:@[
            [header.topAnchor      constraintEqualToAnchor:self.topAnchor],
            [header.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
            [header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [header.heightAnchor   constraintEqualToConstant:24],
            [label.leadingAnchor   constraintEqualToAnchor:header.leadingAnchor constant:8],
            [label.centerYAnchor   constraintEqualToAnchor:header.centerYAnchor],
            [_contentView.topAnchor      constraintEqualToAnchor:header.bottomAnchor],
            [_contentView.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
            [_contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_contentView.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
        ]];
    }
    return self;
}

@end
