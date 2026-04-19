//
//  WLScreenMediaSource.m
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//

#import "WLScreenMediaSource.h"
#import <CoreGraphics/CoreGraphics.h>

@interface WLScreenMediaSource ()

@property (nonatomic, assign) uint32_t displayID;

/// 缓存的最新视频帧
@property (nonatomic, strong, nullable) WLNodeFrame *latestFrame;

/// 定时器，驱动屏幕截取
@property (nonatomic, strong) NSTimer *captureTimer;

@end

@implementation WLScreenMediaSource
@synthesize sourceType = _sourceType;
@synthesize sourceName = _sourceName;
@synthesize volume = _volume;
@synthesize isActive = _isActive;
@synthesize frameRate = _frameRate;

- (instancetype)initWithDisplayID:(uint32_t)displayID {
    self = [super init];
    if (self) {
        _displayID = displayID;
        _sourceType = WLMediaSourceTypeScreen;
        _sourceName = [NSString stringWithFormat:@"Screen %u", displayID];
        _volume = 1.0;
        _isActive = NO;
        _frameRate = 30.0;
        _showCursor = YES;
    }
    return self;
}

#pragma mark - WLMediaSourceProvider

- (void)start {
    _isActive = YES;
    // TODO: 使用 SCStream 替代定时器截取方式
    self.captureTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / self.frameRate
                                                        target:self
                                                      selector:@selector(captureFrame)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)stop {
    [self.captureTimer invalidate];
    self.captureTimer = nil;
    _isActive = NO;
    self.latestFrame = nil;
}

- (nullable WLNodeFrame *)nextVideoFrame {
    WLNodeFrame *frame = self.latestFrame;
    self.latestFrame = nil;
    return frame;
}

- (nullable WLNodeFrame *)nextAudioFrame {
    // 屏幕捕获不提供音频
    return nil;
}

- (CGSize)intrinsicSize {
    CGRect mainRect = CGDisplayBounds(self.displayID);
    return mainRect.size;
}

#pragma mark - Private

- (void)captureFrame {
    CGRect rect = CGDisplayBounds(self.displayID);
    CGImageRef image = nil;
    if (!image) return;

    // CGImage → CVPixelBuffer
    CVPixelBufferRef pixelBuffer = [self pixelBufferFromCGImage:image];
    CGImageRelease(image);

    if (!pixelBuffer) return;

    WLNodeFrame *frame = [[WLNodeFrame alloc] init];
    frame.type = WLFrameTypeVideo;
    frame.pixelBuffer = pixelBuffer;
    frame.pts = CMTimeMake([[NSDate date] timeIntervalSinceReferenceDate] * 1000, 1000);
    frame.videoSize = CGSizeMake(CVPixelBufferGetWidth(pixelBuffer),
                                  CVPixelBufferGetHeight(pixelBuffer));

    self.latestFrame = frame;
}

- (nullable CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image {
    CGSize size = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
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
        CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), image);
        CGContextRelease(context);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

@end
