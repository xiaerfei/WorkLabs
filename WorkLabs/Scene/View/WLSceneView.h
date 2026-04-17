//
//  WLSceneView.h
//  WorkLabs
//

#import <AppKit/AppKit.h>
#import "WLMediaSource.h"

NS_ASSUME_NONNULL_BEGIN

@class WLScene;
@class WLSourceView;

@interface WLSceneView : NSView
@property (nonatomic, weak, nullable) WLScene *scene;
@property (nonatomic, strong, readonly) NSMutableArray<WLSourceView *> *sourceViews;
- (instancetype)initWithScene:(WLScene *)scene frame:(NSRect)frame;
- (void)addSourceView:(WLSourceView *)sourceView;
- (void)removeSourceView:(WLSourceView *)sourceView;
- (void)removeSourceViewForSource:(id<WLMediaSource>)source;
- (nullable WLSourceView *)sourceViewForSource:(id<WLMediaSource>)source;
- (void)updateSourceViewFrame:(NSRect)frame forSource:(id<WLMediaSource>)source;
- (void)updateLayouts;
@end

NS_ASSUME_NONNULL_END
