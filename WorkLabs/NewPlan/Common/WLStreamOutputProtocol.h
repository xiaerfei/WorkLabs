//
//  WLStreamOutputProtocol.h
//  WorkLabs
//
//  统一输出协议
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLDefines.h"

NS_ASSUME_NONNULL_BEGIN

@protocol WLStreamOutputProtocol <NSObject>
@property (nonatomic, assign, readonly) WLNodeType outputType;
@end

#pragma mark - Video Output

@protocol WLVideoOutputProtocol <WLStreamOutputProtocol>
- (void)receiveVideoFrame:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
@end

#pragma mark - Audio Output

@protocol WLAudioOutputProtocol <WLStreamOutputProtocol>
- (void)receiveAudioBuffer:(CMSampleBufferRef)sampleBuffer pts:(Float64)pts;
@end

NS_ASSUME_NONNULL_END
