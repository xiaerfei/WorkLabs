//
//  WLTransitionEngine.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WLTransitionType) {
    WLTransitionTypeNone = 0, WLTransitionTypeFade,
    WLTransitionSlideLeft, WLTransitionSlideRight, WLTransitionSlideUp, WLTransitionSlideDown,
    WLTransitionTypeCut, WLTransitionTypeZoom, WLTransitionTypeFadeColor
};

@interface WLTransition : NSObject
@property (nonatomic, assign) WLTransitionType type;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, strong, nullable) NSColor *fadeColor;
+ (instancetype)transitionWithType:(WLTransitionType)type duration:(NSTimeInterval)duration;
+ (instancetype)fadeWithDuration:(NSTimeInterval)duration;
+ (instancetype)slideLeftWithDuration:(NSTimeInterval)duration;
+ (instancetype)slideRightWithDuration:(NSTimeInterval)duration;
+ (instancetype)cut;
@end

@interface WLTransitionEngine : NSObject
@property (nonatomic, strong, nullable, readonly) WLTransition *currentTransition;
@property (nonatomic, assign, readonly) float progress;
@property (nonatomic, assign, getter=isRunning) BOOL running;
- (instancetype)init;
- (void)applyTransitionFromView:(nullable NSView *)fromView toView:(NSView *)toView inContainer:(NSView *)container transition:(WLTransition *)transition completion:(nullable void (^)(void))completion;
- (void)cancelCurrentTransition;
@end

NS_ASSUME_NONNULL_END
