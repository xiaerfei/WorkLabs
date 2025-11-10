//
//  NSView+BackgroundColor.m
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/11/10.
//

#import "NSView+BackgroundColor.h"

@implementation NSView (BackgroundColor)

- (void)setBackgroundColor:(NSColor *)backgroundColor {
    if (!self.wantsLayer) {
        self.wantsLayer = YES;
    }
    self.layer.backgroundColor = backgroundColor.CGColor;
}

- (NSColor *)backgroundColor {
    if (self.layer.backgroundColor) {
        return [NSColor colorWithCGColor:self.layer.backgroundColor];
    }
    return nil;
}

- (void)backgroundColorWithHexString:(NSString *)hexString {
    if ([hexString hasPrefix:@"#"]) {
        hexString = [hexString substringFromIndex:1];
    }
    unsigned int rgbaValue = 0;
    [[NSScanner scannerWithString:hexString] scanHexInt:&rgbaValue];
    [self backgroundColorWithHex:rgbaValue];
}

- (void)backgroundColorWithHex:(NSUInteger)hexValue {
    CGFloat red   = ((hexValue >> 24) & 0xFF) / 255.0;
    CGFloat green = ((hexValue >> 16) & 0xFF) / 255.0;
    CGFloat blue  = ((hexValue >> 8) & 0xFF) / 255.0;
    CGFloat alpha = (hexValue & 0xFF) / 255.0;

    // 如果只传了 RRGGBB（没有 alpha），默认 alpha = 1.0
    if (hexValue <= 0xFFFFFF) {
        red   = ((hexValue >> 16) & 0xFF) / 255.0;
        green = ((hexValue >> 8) & 0xFF) / 255.0;
        blue  = (hexValue & 0xFF) / 255.0;
        alpha = 1.0;
    }

    NSColor *color = [NSColor colorWithRed:red green:green blue:blue alpha:alpha];
    self.backgroundColor = color;
}
@end
