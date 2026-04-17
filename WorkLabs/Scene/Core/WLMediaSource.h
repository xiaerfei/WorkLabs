//
//  WLMediaSource.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, WLMediaSourceState) {
    WLMediaSourceStateCfgFFmpeg,
    WLMediaSourceStateCfgFFmpegFailed,
    WLMediaSourceStateReadVideo,
    WLMediaSourceStateExit
};

@protocol WLMediaSource <NSObject>
@required
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign, readonly) CGSize intrinsicSize;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign, getter=isActive) BOOL active;
@property (nonatomic, assign, getter=isRunning) BOOL running;
- (void)start;
- (void)stop;
- (nullable CMSampleBufferRef)nextVideoFrame;
- (nullable CMSampleBufferRef)nextAudioFrame;
@optional
- (void)setFrameAvailableCallback:(void (^)(CMSampleBufferRef _Nullable, CMSampleBufferRef _Nullable))callback;
@end

@interface WLBaseMediaSource : NSObject <WLMediaSource>
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign, readonly) CGSize intrinsicSize;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign, getter=isActive) BOOL active;
@property (nonatomic, assign, getter=isRunning) BOOL running;
- (instancetype)initWithName:(NSString *)name;
@end

NS_ASSUME_NONNULL_END
