//
//  WLSourceLayout.m
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//

#import "WLSourceLayout.h"

@implementation WLSourceLayout

+ (instancetype)layoutWithFrame:(CGRect)frame {
    WLSourceLayout *layout = [[WLSourceLayout alloc] init];
    layout.frame = frame;
    layout.cropTop = 0;
    layout.cropBottom = 0;
    layout.cropLeft = 0;
    layout.cropRight = 0;
    layout.volume = 1.0;
    layout.visible = YES;
    layout.zIndex = 0;
    return layout;
}

@end
