//
//  WLNodeFrame.m
//  WorkLabs
//
//  Created by erfeixia on 18/04/2026.
//

#import "WLNodeFrame.h"

@implementation WLNodeFrame

- (instancetype)init {
    self = [super init];
    if (self) {
        _type = WLFrameTypeVideo;
        _pixelBuffer = NULL;
        _pts = kCMTimeZero;
        _dts = kCMTimeZero;
        _duration = kCMTimeZero;
        _videoSize = CGSizeZero;
        _sampleRate = 0;
        _channelCount = 0;
        _audioFrame = NULL;
    }
    return self;
}

- (void)dealloc {
    [self flush];
}

- (void)flush {
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
    if (_audioFrame) {
        av_frame_free(&_audioFrame);
        _audioFrame = NULL;
    }
}

@end
