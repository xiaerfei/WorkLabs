//
//  WLPreviewOutput.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@class WLViedoPreview;

NS_ASSUME_NONNULL_BEGIN

@interface WLPreviewOutput : NSObject
@property (nonatomic, strong, readonly) WLViedoPreview *preview;
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(Float64)pts;
@end

NS_ASSUME_NONNULL_END
