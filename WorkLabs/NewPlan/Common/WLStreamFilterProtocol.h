//
//  WLStreamFilterProtocol.h
//  WorkLabs
//
//  Filter 协议 — 链路中间处理节点
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLDefines.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Filter Base

@protocol WLStreamFilterProtocol <NSObject>
@property (nonatomic, assign, readonly) WLNodeType filterType;
@end

#pragma mark - Video Filter

// 输入 pixelBuffer 由调用方持有所有权，Filter 内部仅读取，不修改其 retain count。
// 返回值遵循 Create Rule：所有权转移给调用方，调用方负责 CVPixelBufferRelease。
// 同步执行；返回 NULL 表示丢帧。
@protocol WLVideoFilterProtocol <WLStreamFilterProtocol>
- (nullable CVPixelBufferRef)processVideoFrame:(CVPixelBufferRef)pixelBuffer
                                            pts:(Float64)pts CF_RETURNS_RETAINED;
@end

#pragma mark - Audio Filter

// 与 Video Filter 一致的所有权约定：返回值所有权转移给调用方。
@protocol WLAudioFilterProtocol <WLStreamFilterProtocol>
- (nullable CMSampleBufferRef)processAudioBuffer:(CMSampleBufferRef)sampleBuffer
                                              pts:(Float64)pts CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
