//
//  WLCameraManager.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/11/10.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class WLCameraManager;

@protocol WLCameraCaptureSubscriber <NSObject>
@required
- (void)cameraCaptureManager:(WLCameraManager *)manager
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@interface WLCameraManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>


@property (nonatomic, strong, readonly) AVCaptureSession *session;
@property (nonatomic, strong, readonly) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong, readonly) AVCaptureDevice *currentDevice;

+ (instancetype)manager;

- (void)startCapture;
- (void)stopCapture;
- (BOOL)isRunning;

- (void)switchWithDevice:(AVCaptureDevice *)device;

- (void)subscriber:(id<WLCameraCaptureSubscriber>)subscriber;
- (void)unsubscriber:(id<WLCameraCaptureSubscriber>)subscriber;

@end


NS_ASSUME_NONNULL_END
