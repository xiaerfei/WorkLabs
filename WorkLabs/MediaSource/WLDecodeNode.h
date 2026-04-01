//
//  WLDecodeNode.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import <Foundation/Foundation.h>
#include "libavcodec/packet.h"
#include "libavutil/frame.h"

NS_ASSUME_NONNULL_BEGIN


typedef NS_ENUM(NSInteger, WLDecodeType) {
    WLDecodeTypeNone,
    WLDecodeTypeVideo,
    WLDecodeTypeAudio
};

typedef NS_ENUM(NSInteger, WLFromType) {
    WLFromTypeMedia,
    WLFromTypeCamera,
};

@interface WLDecodeNode : NSObject
@property (nonatomic, assign) WLDecodeType type;
@property (nonatomic, assign) WLFromType fromType;
@property (nonatomic, assign) AVPacket *packet; // 内部管理
@property (nonatomic, assign) AVFrame *frame;   // 内部管理
@property (nonatomic, assign) Float64 pts;
///< 解码后视频数据(CVPixelBufferRef)
@property (nonatomic, strong) id data;
@property (nonatomic, strong, nullable) WLDecodeNode *next;

- (void)flush;
@end

NS_ASSUME_NONNULL_END
