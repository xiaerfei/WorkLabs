//
//  WLNode.h
//  WorkLabs
//
//  NewPlan 数据帧节点（从 Core/Queue/WLNode 扩展）
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include "libavcodec/packet.h"
#include "libavutil/frame.h"
#import "WLDefines.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLNode : NSObject

@property (nonatomic, assign) WLNodeType type;
@property (nonatomic, assign) WLFromType fromType;

/// FFmpeg 编码包（内部管理生命周期）
@property (nonatomic, assign) AVPacket *packet;

/// FFmpeg 解码帧（内部管理生命周期）
@property (nonatomic, assign) AVFrame *frame;

/// 解码后视频数据（CVPixelBufferRef，内部管理引用计数）
@property (nonatomic, assign) CVPixelBufferRef data;

/// 音频采样数据（CMSampleBufferRef，内部管理引用计数）
@property (nonatomic, assign) CMSampleBufferRef sampleBuffer;

/// 显示时间戳（秒）
@property (nonatomic, assign) Float64 pts;

/// 队列链表指针
@property (nonatomic, strong, nullable) WLNode *next;

/// 释放所有内部持有的数据
- (void)flush;

@end

NS_ASSUME_NONNULL_END
