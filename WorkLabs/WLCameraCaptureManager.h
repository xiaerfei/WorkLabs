//
//  WLCameraCaptureManager.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/11/10.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class WLCameraCaptureManager;

@protocol WLCameraCaptureSubscriber <NSObject>
@required
- (void)cameraCaptureManager:(WLCameraCaptureManager *)manager
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@interface WLCameraCaptureManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong, readonly) AVCaptureSession *session;
@property (nonatomic, strong, readonly) AVCaptureVideoPreviewLayer *previewLayer;

/// 单例
+ (instancetype)manager;

/// 启动采集（自动检查权限）
- (void)startCapture;

/// 停止采集
- (void)stopCapture;

/// 添加订阅者
- (void)addSubscriber:(id<WLCameraCaptureSubscriber>)subscriber;

/// 移除订阅者
- (void)removeSubscriber:(id<WLCameraCaptureSubscriber>)subscriber;

@end

NS_ASSUME_NONNULL_END
