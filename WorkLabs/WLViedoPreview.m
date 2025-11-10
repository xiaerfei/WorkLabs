//
//  WLViedoPreview.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/11/10.
//

#import "WLViedoPreview.h"

@interface WLViedoPreview ()
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@end

@implementation WLViedoPreview
- (instancetype)init {
    self = [super init];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor blackColor].CGColor;
    }
    return self;
}

- (void)awakeFromNib {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;
}

- (CALayer *)makeBackingLayer {
    self.displayLayer = [AVSampleBufferDisplayLayer layer];
    return self.displayLayer;
}

@end
