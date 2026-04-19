//
//  WLColorMediaSource.m
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//

#import "WLColorMediaSource.h"

@interface WLColorMediaSource ()

/// 预生成的像素缓冲区
@property (nonatomic, assign, nullable) CVPixelBufferRef pixelBuffer;

@end

@implementation WLColorMediaSource
@synthesize sourceType = _sourceType;
@synthesize sourceName = _sourceName;
@synthesize volume = _volume;
@synthesize isActive = _isActive;

- (instancetype)initWithColor:(NSColor *)color size:(CGSize)size {
    self = [super init];
    if (self) {
        _sourceType = WLMediaSourceTypeColor;
        _sourceName = @"Color";
        _volume = 1.0;
        _isActive = NO;
        _color = [color copy];
        _outputSize = size;
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
    [self generatePixelBuffer];
}

- (void)stop {
    _isActive = NO;
    if (self.pixelBuffer) {
        CVPixelBufferRelease(self.pixelBuffer);
        self.pixelBuffer = NULL;
    }
}

- (nullable WLNodeFrame *)nextVideoFrame {
    if (!self.isActive || !self.pixelBuffer) return nil;

    CVPixelBufferRetain(self.pixelBuffer);

    WLNodeFrame *frame = [[WLNodeFrame alloc] init];
    frame.type = WLFrameTypeVideo;
    frame.pixelBuffer = self.pixelBuffer;
    frame.pts = CMTimeMake([[NSDate date] timeIntervalSinceReferenceDate] * 1000, 1000);
    frame.videoSize = self.outputSize;

    return frame;
}

- (nullable WLNodeFrame *)nextAudioFrame {
    // 纯色源无音频
    return nil;
}

- (CGSize)intrinsicSize {
    return self.outputSize;
}

#pragma mark - Private

- (void)generatePixelBuffer {
    if (self.outputSize.width <= 0 || self.outputSize.height <= 0) return;

    // 如果颜色变化需要重新生成，先释放旧的
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
        NSColor *rgbColor = [self.color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
        CGContextSetRGBFillColor(context,
                                 rgbColor.redComponent,
                                 rgbColor.greenComponent,
                                 rgbColor.blueComponent,
                                 rgbColor.alphaComponent);
        CGContextFillRect(context, CGRectMake(0, 0, self.outputSize.width, self.outputSize.height));
        CGContextRelease(context);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    self.pixelBuffer = pixelBuffer;
}

@end
