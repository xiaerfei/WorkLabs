//
//  WLStreamsManager.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/29.
//

#import <Foundation/Foundation.h>
#import "WLDecodeNode.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLStreamsManager : NSObject

+ (instancetype)manager;

- (void)addVideoNode:(WLDecodeNode *)node;
- (void)addAudioNode:(WLDecodeNode *)node;
@end

NS_ASSUME_NONNULL_END
