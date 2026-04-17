//
//  WLSourceView.h
//  WorkLabs
//

#import <AppKit/AppKit.h>
#import "WLMediaSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLSourceView : NSView
@property (nonatomic, weak, nullable) id<WLMediaSource> source;
- (instancetype)initWithSource:(id<WLMediaSource>)source frame:(NSRect)frame;
- (void)renderWithSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)clearFrame;
@end

NS_ASSUME_NONNULL_END
