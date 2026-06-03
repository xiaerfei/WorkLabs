//
//  WLMicSource.h
//  WorkLabs
//
//  麦克风采集源 — AVCaptureSession + AVCaptureAudioDataOutput，
//  输出 LPCM CMSampleBufferRef（所有权转移给 delegate）。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLStreamSourceProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLMicSource : NSObject <WLStreamSourceProtocol>

- (instancetype)initWithDevice:(AVCaptureDevice *)device;

@property (nonatomic, strong, readonly) AVCaptureDevice *device;

// WLStreamSourceProtocol 的 delegate 需由遵循类显式声明以合成 setter/getter
@property (nonatomic, weak, nullable) id<WLStreamSourceDelegate> delegate;

@end

NS_ASSUME_NONNULL_END
