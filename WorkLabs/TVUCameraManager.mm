//
//  TVUCameraManager.m
//  TVUPartyline
//
//  Created by Qi Zhang on 2024/1/30.
//  Copyright © 2024 tvunetworks. All rights reserved.
//

#import "TVUCameraManager.h"
#include <syslog.h>

#define log4cplus_error(category, logFmt, ...) \
do { \
        syslog(LOG_ERR, "<Error:> %s:" logFmt, #category,##__VA_ARGS__); \
}while(0)


@interface TVUCameraManager ()<AVCaptureVideoDataOutputSampleBufferDelegate>
{
    AVCaptureSession         * m_session;
    AVCaptureDeviceInput     * m_video_input;
    AVCaptureVideoDataOutput *m_video_output;
    dispatch_queue_t _cameraQueue;

}

@end
static NSString * const resolution_default = @"1280x720";
static NSString * const frameRate_default  = @"30P";


@implementation TVUCameraManager
#pragma mark - public methods
+ (TVUCameraManager *)manager
{
    static TVUCameraManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TVUCameraManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _cameraQueue = dispatch_queue_create("com.tvuPartyline.camera.Queue", DISPATCH_QUEUE_SERIAL);
        m_session = [[AVCaptureSession alloc] init];

    }
    return self;
}

- (void)startCaptureSessionWithDevice:(NSDictionary *)deviceDict {
    
    NSString * uniqueID = [deviceDict objectForKey:@"uniqueID"];
    if (!uniqueID) {
        log4cplus_error("CameraManagerPL", "no device uniqueID");
        return;
    }
    
    AVCaptureDevice * device = [AVCaptureDevice deviceWithUniqueID:uniqueID];
    if (!device) {
        log4cplus_error("CameraManagerPL", "no Capture Device");
        return;
    }
    
    if(![device hasMediaType:AVMediaTypeVideo])
    {
        log4cplus_error("CameraManagerPL", "no AVMediaTypeVideo");
        return;
    }
    
    NSString * resolution = [self findFitResolution:deviceDict];
    if (!resolution) {
        log4cplus_error("CameraManagerPL", "no resolution");
        return;
    }
    
    NSString * frameRate = [self findFitFrameRate:deviceDict[resolution]];
    if (!frameRate) {
        log4cplus_error("CameraManagerPL", "no frameRate");
        return;
    }
    
    dispatch_async(_cameraQueue, ^{
        [self stopSession];
        AVFrameRateRange * range_select = nil;
        AVCaptureDeviceFormat *deviceFormat = [self getDeviceFormatWithDevice:device
                                                                 andReslution:resolution
                                                                  andFramRate:frameRate
                                                                  rangeSelect:&range_select];
        if (!deviceFormat) {
            log4cplus_error("CameraManagerPL", "no deviceFormat");
            return;
        }

        
        self->m_session.sessionPreset = AVCaptureSessionPreset640x480;
        if ([device lockForConfiguration:nil]) {
            device.activeFormat = deviceFormat;
            CMTime minFrameDuration = [range_select minFrameDuration];
            device.activeVideoMinFrameDuration =minFrameDuration;
            [device unlockForConfiguration];
        }

        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device
                                                                            error:&error];
        
        if (error) {
            log4cplus_error("CameraManagerPL", "deviceInputWithDevice error");
            return;
        }
        self->m_video_input= input;
        if ([self->m_session canAddInput:input]) {
            [self->m_session addInput:input];
        }
        
        [self initVideoOutput];
        if ([self->m_session canAddOutput:self-> m_video_output]) {
            [self->m_session addOutput:self->m_video_output];
        }
        
        [self->m_session startRunning];
        log4cplus_error("CameraManagerPL","m_session startRunning");
    });
}

-(void)initVideoOutput {
    
    if (!self->m_video_output) {
        self->m_video_output = [[AVCaptureVideoDataOutput alloc] init];
        NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                       [NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],kCVPixelBufferPixelFormatTypeKey,
                                       nil];
        self->m_video_output .videoSettings = videoSettings;
        self->m_video_output .alwaysDiscardsLateVideoFrames = YES;
        dispatch_queue_t queue = dispatch_queue_create("cameraVideoQueue", NULL);
        [self->m_video_output setSampleBufferDelegate:self queue:queue];
    }
}

- (void)stopCapture{
    dispatch_async(_cameraQueue, ^{
        [self stopSession];
    });
}

- (void)stopSession {
    if (!self->m_session.isRunning) {
        return;
    }
    [self->m_session stopRunning];
    [self->m_session removeInput:self->m_video_input];
    [self->m_session removeOutput:self->m_video_output];
    self->m_video_input= nil;
    log4cplus_error("CameraManagerPL", "m_session stopRunning");

}

- (BOOL)isRunning {
    return self->m_session.isRunning;
}

- (AVCaptureDeviceFormat *)getDeviceFormatWithDevice:(AVCaptureDevice *)device
                                        andReslution:(NSString *)resolution
                                         andFramRate:(NSString * )frameRate
                                         rangeSelect:(AVFrameRateRange **)rangeSelect

{
    
    NSCharacterSet *nonDigitSet = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    NSString *numberString = [[frameRate componentsSeparatedByCharactersInSet:nonDigitSet] componentsJoinedByString:@""];
    int fps = [numberString intValue];
    
    CGSize res = [self covertSessionPresetToSize:resolution];
    int res_w  = res.width;
    int res_h  = res.height;

    AVFrameRateRange * range_select = nil;
    NSArray * formats = [device formats];

    for(AVCaptureDeviceFormat * format in formats)
    {
        CMFormatDescriptionRef description = [format formatDescription];
        CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(description);
        if (dimension.width != res_w || dimension.height != res_h) {
            continue;
        }
        NSArray * ranges = [format videoSupportedFrameRateRanges];
        
        AVFrameRateRange * maxrange = nil;

        for (AVFrameRateRange *range in ranges) {
            double maxFrameRate = [range maxFrameRate];
            
            // Check if the max frame rate is within the desired range
            if ((fps == 30 && maxFrameRate > 29.0 && maxFrameRate < 31.0) ||
                (fps == 25 && maxFrameRate > 24.0 && maxFrameRate < 26.0) ||
                (fps == 50 && maxFrameRate > 49.0 && maxFrameRate < 51.0) ||
                (fps == 60 && maxFrameRate > 59.0 && maxFrameRate < 61.0)) {
                
                range_select = range;
                break; // Found the desired frame rate range, no need to continue the loop
            }

            log4cplus_error(camera_log_cateory, "rate %f   %f", maxFrameRate, [range minFrameRate]);

            if (maxFrameRate > maxFrameRate) {
                maxFrameRate = maxFrameRate;
                maxrange = range;
                if (!range_select) {
                    range_select = range;
                }
            }
        }
        if(!range_select){
            continue;
        }
        *rangeSelect = range_select;
        return format;
    }
    return nil;
}


- (CGSize)covertSessionPresetToSize:(NSString *)resolution{
    
    if ([resolution isEqualToString:@"640x640"]) {
        return CGSizeMake(640, 640);
    } else if ([resolution isEqualToString:@"1280x720"]) {
        return CGSizeMake(1280, 720);
    } else if ([resolution isEqualToString:@"1920x1080"]) {
        return CGSizeMake(1920, 1080);
    } else if ([resolution isEqualToString:@"3840x2160"]) {
        if (@available(macOS 10.15, *)) {
            return CGSizeMake(3840, 2160);
        }
        
        // Handle macOS 10.14 and older versions
        m_session.sessionPreset = AVCaptureSessionPresetHigh;
        return CGSizeMake(1920, 1080);
    }

    return CGSizeMake(1280, 720);

}


- (AVCaptureSessionPreset)covertToSessionPreset:(NSString *)resolution{
    
    if ([resolution isEqualToString:@"640x480"]) {
        return AVCaptureSessionPreset640x480;
    } else if ([resolution isEqualToString:@"1280x720"]) {
        return AVCaptureSessionPreset1280x720;
    } else if ([resolution isEqualToString:@"1920x1080"]) {
        return AVCaptureSessionPresetHigh;
    } else if ([resolution isEqualToString:@"3840x2160"]) {
        if (@available(macOS 10.15, *)) {
            return AVCaptureSessionPreset3840x2160;
        }
        
        // Handle macOS 10.14 and older versions
        m_session.sessionPreset = AVCaptureSessionPresetHigh;
        return AVCaptureSessionPresetHigh;
    }

    return AVCaptureSessionPreset1280x720;
    
}

- (NSString *)findFitResolution:(NSDictionary *)deviceDict {
    NSArray *resolutions = @[resolution_default, @"1920x1080", @"640x480", @"3840x2160"];
    
    for (NSString *resolution in resolutions) {
        if (deviceDict[resolution]) {
            return resolution;
        }
    }

    return nil;
}


- (NSString *)findFitFrameRate:(NSArray *)frameRateArray {
    for (NSDictionary * frameRateDict  in frameRateArray) {
        BOOL isSupport = [frameRateDict[@"isSupport"] boolValue];
        NSString * frameRateName = frameRateDict[@"name"];
        
        if ([frameRateName isEqualToString:frameRate_default] && isSupport) {
            return frameRate_default;
        }
    }
    
    for (NSDictionary * frameRateDict  in frameRateArray) {
        BOOL isSupport = [frameRateDict[@"isSupport"] boolValue];
        NSString * frameRateName = frameRateDict[@"name"];
        
        if  (isSupport) {
            return frameRateName;
        }
    }
    return nil;
}
#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    if (self.delegate && [self.delegate respondsToSelector:@selector(tvuCaptureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.delegate tvuCaptureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}
@end
