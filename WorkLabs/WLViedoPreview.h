//
//  WLViedoPreview.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/11/10.
//

#import <Cocoa/Cocoa.h>
#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLViedoPreview : NSView
@property (nonatomic, strong, readonly) AVSampleBufferDisplayLayer *displayLayer;
@end

NS_ASSUME_NONNULL_END
