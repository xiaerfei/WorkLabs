//
//  WLAudioOutput.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLAudioOutput : NSObject
@property (nonatomic, assign) float volume;
- (BOOL)start;
- (void)stop;
- (void)playSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

NS_ASSUME_NONNULL_END
