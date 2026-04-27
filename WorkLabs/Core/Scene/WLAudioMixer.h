//
//  WLAudioMixer.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#include "libavutil/frame.h"

@class WLMediaSourceItem;

NS_ASSUME_NONNULL_BEGIN

@interface WLAudioMixer : NSObject

/// 添加音频源
- (void)addSource:(WLMediaSourceItem *)item;

/// 移除音频源
- (void)removeSource:(WLMediaSourceItem *)item;

/// 推送解码后的音频帧
- (void)pushAudioFrame:(AVFrame *)frame fromSource:(WLMediaSourceItem *)item;

/// 清空所有缓冲区
- (void)reset;

@end

NS_ASSUME_NONNULL_END
