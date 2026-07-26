//
//  WLCanvasView.m
//  OBSLabs
//

#import "WLCanvasView.h"

@implementation WLCanvasView

- (void)mouseDown:(NSEvent *)event {
    if (self.onBackgroundClick) self.onBackgroundClick();
}

@end
