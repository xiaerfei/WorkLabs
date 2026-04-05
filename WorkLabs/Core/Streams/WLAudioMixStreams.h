//
//  WLAudioMixStreams.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/27.
//

#import <Foundation/Foundation.h>
#import "WLNode.h"
#import "WLCoreUtils.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLAudioMixStreams : NSObject

@property (nonatomic, assign) WLAudioRenderType audioRenderType;

- (void)addNode:(WLNode *)node;

- (void)startMix;
- (void)stopMix;

@end

NS_ASSUME_NONNULL_END
