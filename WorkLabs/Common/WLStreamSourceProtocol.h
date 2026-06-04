//
//  WLStreamSourceProtocol.h
//  WorkLabs
//
//  统一输入源协议
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WLDefines.h"

NS_ASSUME_NONNULL_BEGIN

@protocol WLStreamSourceProtocol;

#pragma mark - Source Delegate

@protocol WLStreamSourceDelegate <NSObject>
@required
- (void)source:(id<WLStreamSourceProtocol>)source
    didOutputVideoFrame:(CVPixelBufferRef)pixelBuffer
                    pts:(Float64)pts;

- (void)source:(id<WLStreamSourceProtocol>)source
    didOutputAudioBuffer:(CMSampleBufferRef)sampleBuffer;

@optional
- (void)source:(id<WLStreamSourceProtocol>)source didEncounterError:(NSError *)error;
- (void)sourceDidStart:(id<WLStreamSourceProtocol>)source;
- (void)sourceDidStop:(id<WLStreamSourceProtocol>)source;
@end

#pragma mark - Source Protocol

@protocol WLStreamSourceProtocol <NSObject>

// 流类型：Video / Audio（复用 WLNodeType）
@property (nonatomic, assign, readonly) WLNodeType streamType;

// 流来源：Camera / Mic / Media / Network（复用 WLFromType）
@property (nonatomic, assign, readonly) WLFromType fromType;

// 用于 UI 显示的名称（设备名 / 文件名等）
@property (nonatomic, copy, readonly) NSString *displayName;

// 生命周期
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
- (BOOL)start:(NSError **)error;
- (void)stop;

// delegate 回调
@property (nonatomic, weak, nullable) id<WLStreamSourceDelegate> delegate;

@end

NS_ASSUME_NONNULL_END
