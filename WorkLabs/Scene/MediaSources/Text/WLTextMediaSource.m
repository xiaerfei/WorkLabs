//
//  WLTextMediaSource.m
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//

#import "WLTextMediaSource.h"

@interface WLTextMediaSource ()

/// 渲染后的像素缓冲区
@property (nonatomic, assign, nullable) CVPixelBufferRef pixelBuffer;

/// 标记是否需要重新渲染
@property (nonatomic, assign) BOOL dirty;

@end

@implementation WLTextMediaSource
@synthesize sourceType = _sourceType;
@synthesize sourceName = _sourceName;
@synthesize volume = _volume;
@synthesize isActive = _isActive;

- (instancetype)initWithText:(NSString *)text size:(CGSize)size {
    self = [super init];
    if (self) {
        _sourceType = WLMediaSourceTypeText;
        _sourceName = @"Text";
        _volume = 1.0;
        _isActive = NO;
        _text = [text copy];
        _outputSize = size;
        _font = [NSFont systemFontOfSize:24];
        _textColor = [NSColor whiteColor];
        _backgroundColor = [NSColor clearColor];
        _dirty = YES;
    }
    return self;
}

- (void)dealloc {
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
}

#pragma mark - WLMediaSourceProvider

- (void)start {
    _isActive = YES;
    [self renderIfNeeded];
}

- (void)stop {
    _isActive = NO;
    if (self.pixelBuffer) {
        CVPixelBufferRelease(self.pixelBuffer);
        self.pixelBuffer = NULL;
    }
}

- (nullable WLNodeFrame *)nextVideoFrame {
    if (!self.isActive) return nil;

    [self renderIfNeeded];

    if (!self.pixelBuffer) return nil;

    CVPixelBufferRetain(self.pixelBuffer);

    WLNodeFrame *frame = [[WLNodeFrame alloc] init];
    frame.type = WLFrameTypeVideo;
    frame.pixelBuffer = self.pixelBuffer;
    frame.pts = CMTimeMake([[NSDate date] timeIntervalSinceReferenceDate] * 1000, 1000);
    frame.videoSize = self.outputSize;

    return frame;
}

- (nullable WLNodeFrame *)nextAudioFrame {
    // 文字源无音频
    return nil;
}

- (CGSize)intrinsicSize {
    return self.outputSize;
}

- (void)invalidate {
    self.dirty = YES;
}

#pragma mark - Private

- (void)renderIfNeeded {
    if (!self.dirty) return;
    self.dirty = NO;

    if (self.outputSize.width <= 0 || self.outputSize.height <= 0) return;

    // 释放旧缓冲区
    if (self.pixelBuffer) {
        CVPixelBufferRelease(self.pixelBuffer);
        self.pixelBuffer = NULL;
    }

    NSDictionary *attrs = @{(id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES};

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                           self.outputSize.width,
                                           self.outputSize.height,
                                           kCVPixelFormatType_32ARGB,
                                           (__bridge CFDictionaryRef)attrs,
                                           &pixelBuffer);
    if (status != kCVReturnSuccess) return;

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *data = CVPixelBufferGetBaseAddress(pixelBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(data,
                                                  self.outputSize.width,
                                                  self.outputSize.height,
                                                  8,
                                                  CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                  colorSpace,
                                                  kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(colorSpace);

    if (context) {
        // 填充背景
        if (self.backgroundColor && [self.backgroundColor alphaComponent] > 0) {
            NSColor *bgRGB = [self.backgroundColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
            CGContextSetRGBFillColor(context,
                                     bgRGB.redComponent,
                                     bgRGB.greenComponent,
                                     bgRGB.blueComponent,
                                     bgRGB.alphaComponent);
            CGContextFillRect(context, CGRectMake(0, 0, self.outputSize.width, self.outputSize.height));
        }

        // 绘制文字
        NSDictionary *attrs2 = @{
            NSFontAttributeName: self.font,
            NSForegroundColorAttributeName: self.textColor
        };
        NSAttributedString *attrStr = [[NSAttributedString alloc] initWithString:self.text attributes:attrs2];

        // 使用 NSGraphicsContext + drawInRect
        NSGraphicsContext *nsContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:nsContext];

        // 居中绘制
        NSSize textSize = attrStr.size;
        NSPoint origin = NSMakePoint((self.outputSize.width - textSize.width) / 2,
                                      (self.outputSize.height - textSize.height) / 2);
        [attrStr drawAtPoint:origin];

        [NSGraphicsContext restoreGraphicsState];
        CGContextRelease(context);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    self.pixelBuffer = pixelBuffer;
}

@end
