//
//  WLMediaSourcePreview.h
//  WorkLabs
//

#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLMediaSourcePreview : NSView

@property (nonatomic, assign, getter=isSelected) BOOL selected;

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer;

@end

NS_ASSUME_NONNULL_END
