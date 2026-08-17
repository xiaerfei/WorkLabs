//
//  UIControl+TVURSignal.m
//  TestPrj
//
//  Created by sharexia on 2/21/24.
//

#if TARGET_OS_IOS
#import "UIControl+TVURSignal.h"
#import <objc/runtime.h>

@implementation UIControl (TVURSignal)

- (TVURSignal *)rs_signalForControlEvents:(UIControlEvents)controlEvents {
    TVURSignal *signal = [TVURSignal signal];
    [self addTarget:signal action:@selector(sendNext:) forControlEvents:controlEvents];
    return signal;
}

@end

#endif
