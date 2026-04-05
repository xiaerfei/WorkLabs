//
//  WLVideoConcatStreams.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/27.
//

#import <Foundation/Foundation.h>
#import "WLNode.h"
#import "WLCoreUtils.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLVideoConcatStreams : NSObject

@property (nonatomic, assign) WLVideoRenderType videoRenderType;

- (void)addNode:(WLNode *)node;

- (void)startConcat;
- (void)stopConcat;

@end

NS_ASSUME_NONNULL_END
