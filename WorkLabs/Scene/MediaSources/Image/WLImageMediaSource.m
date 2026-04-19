//
//  WLImageMediaSource.m
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//

#import "WLImageMediaSource.h"

@interface WLImageMediaSource ()

/// 解码后的像素缓冲区
@property (nonatomic, assign, nullable) CVPixelBufferRef pixelBuffer;

/// 图片尺寸
@property (nonatomic, assign) CGSize imageSize;

/// 是否已被读取过（图片源只产生一帧，重复返回同一帧）
@property (nonatomic, assign) BOOL frameConsumed;

@end

@implementation WLImageMediaSource
@synthesize sourceType = _sourceType;
@synthesize sourceName = _sourceName;
@synthesize volume = _volume;
@synthesize isActive = _isActive;

- (nullable instancetype)initWithFilePath:(NSString *)filePath {
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:filePath];
    if (!image) return nil;
    return [self initWithImage:image];
}

- (instancetype)initWithImage:(NSImage *)image {
    self = [super init];
    if (self) {
        _sourceType = WLMediaSourceTypeImage;
        _sourceName = @"Image";
        _volume = 1.0;
        _isActive = NO;
        _frameConsumed = NO;
        _pixelBuffer = [self pixelBufferFromImage:image];
        _imageSize = image.size;
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
    self.frameConsumed = NO;
}

- (void)stop {
    _isActive = NO;
    self.frameConsumed = YES;
}

- (nullable WLNodeFrame *)nextVideoFrame {
    if (!self.isActive || !self.pixelBuffer) return nil;

    // 图片源：每次都返回同一帧（持续显示）
    CVPixelBufferRetain(self.pixelBuffer);

    WLNodeFrame *frame = [[WLNodeFrame alloc] init];
    frame.type = WLFrameTypeVideo;
    frame.pixelBuffer = self.pixelBuffer;
    frame.pts = CMTimeMake([[NSDate date] timeIntervalSinceReferenceDate] * 1000, 1000);
    frame.videoSize = self.imageSize;

    return frame;
}

- (nullable WLNodeFrame *)nextAudioFrame {
    // 图片源无音频
    return nil;
}

- (CGSize)intrinsicSize {
    return self.imageSize;
}

#pragma mark - Private

- (nullable CVPixelBufferRef)pixelBufferFromImage:(NSImage *)image {
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) return NULL;

    CGSize size = CGSizeMake(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage));
    if (size.width <= 0 || size.height <= 0) return NULL;

    NSDictionary *attrs = @{(id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES};

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                           size.width, size.height,
                                           kCVPixelFormatType_32ARGB,
                                           (__bridge CFDictionaryRef)attrs,
                                           &pixelBuffer);
    if (status != kCVReturnSuccess) return NULL;

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *data = CVPixelBufferGetBaseAddress(pixelBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(data,
                                                  size.width, size.height,
                                                  8,
                                                  CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                  colorSpace,
                                                  kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(colorSpace);

    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), cgImage);
        CGContextRelease(context);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

@end
