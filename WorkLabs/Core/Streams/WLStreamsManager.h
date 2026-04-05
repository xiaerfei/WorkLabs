//
//  WLStreamsManager.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/29.
//

#import <Foundation/Foundation.h>
#import "WLNode.h"
#import "WLCoreUtils.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLStreamsManager : NSObject

+ (instancetype)manager;

@property (nonatomic, assign) WLVideoRenderType videoRenderType;
@property (nonatomic, assign) WLAudioRenderType audioRenderType;

- (void)addVideoNode:(WLNode *)node;
- (void)addAudioNode:(WLNode *)node;

- (void)start;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
