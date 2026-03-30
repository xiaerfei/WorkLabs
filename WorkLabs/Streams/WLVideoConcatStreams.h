//
//  WLVideoConcatStreams.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/27.
//

#import <Foundation/Foundation.h>
#import "WLDecodeNode.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLVideoConcatStreams : NSObject
- (void)addDecodeNode:(WLDecodeNode *)node;
@end

NS_ASSUME_NONNULL_END
