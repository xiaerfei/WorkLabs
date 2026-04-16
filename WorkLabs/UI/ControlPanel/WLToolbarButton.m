//
//  WLToolbarButton.m
//  WorkLabs
//

#import "WLToolbarButton.h"

@implementation WLToolbarButton

- (void)mouseEntered:(NSEvent *)event {
    self.alphaValue = 0.6;
}

- (void)mouseExited:(NSEvent *)event {
    self.alphaValue = 1.0;
}

- (void)mouseDown:(NSEvent *)event {
    self.alphaValue = 0.3;
    [super mouseDown:event];
}

- (void)mouseUp:(NSEvent *)event {
    self.alphaValue = 0.6;
    [super mouseUp:event];
}

@end
