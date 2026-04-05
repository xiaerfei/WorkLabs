//
//  WLNode.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include "libavcodec/packet.h"
#include "libavutil/frame.h"
#import "WLCoreUtils.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLNode : NSObject
@property (nonatomic, assign) WLNodeType type;
@property (nonatomic, assign) WLFromType fromType;
@property (nonatomic, assign) AVPacket *packet; // 内部管理
@property (nonatomic, assign) AVFrame *frame;   // 内部管理
@property (nonatomic, assign) Float64 pts;
///< 解码后视频数据(CVPixelBufferRef)
@property (nonatomic, assign) CVPixelBufferRef data;
@property (nonatomic, strong, nullable) WLNode *next;

- (void)flush;
@end

NS_ASSUME_NONNULL_END
