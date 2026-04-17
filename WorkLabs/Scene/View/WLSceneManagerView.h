//
//  WLSceneManager.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "WLScene.h"
#import "WLTransitionEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLSceneManagerView : NSView
@property (nonatomic, strong, readonly) NSView *backgroundView;
@property (nonatomic, strong, readonly) NSView *contentView;
@property (nonatomic, strong, readonly) NSView *transitionView;
- (instancetype)initWithFrame:(NSRect)frame;
- (void)setContentView:(nullable NSView *)view;
- (void)clearContentView;
- (void)transitionFromView:(nullable NSView *)fromView toView:(nullable NSView *)toView transition:(WLTransition *)transition;
- (void)setBackgroundColor:(NSColor *)color;
@end

NS_ASSUME_NONNULL_END
