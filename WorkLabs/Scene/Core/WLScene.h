//
//  WLScene.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import "WLMediaSource.h"
#import "WLMediaMixer.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLSourceLayout : NSObject
@property (nonatomic, weak, nullable) id<WLMediaSource> source;
@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) CGFloat cropTop;
@property (nonatomic, assign) CGFloat cropBottom;
@property (nonatomic, assign) CGFloat cropLeft;
@property (nonatomic, assign) CGFloat cropRight;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) NSInteger zIndex;
+ (instancetype)layoutWithSource:(id<WLMediaSource>)source frame:(CGRect)frame;
@end

@interface WLScene : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, assign) CGSize canvasSize;
@property (nonatomic, strong, readonly) NSMutableArray<id<WLMediaSource>> *sources;
@property (nonatomic, strong, readonly) NSMutableArray<WLSourceLayout *> *sourceLayouts;
@property (nonatomic, strong, readonly) WLMediaMixer *audioMixer;
@property (nonatomic, strong, readonly) NSView *sceneView;
- (instancetype)initWithName:(NSString *)name canvasSize:(CGSize)size;
- (void)addSource:(id<WLMediaSource>)source atRect:(CGRect)rect;
- (void)removeSource:(id<WLMediaSource>)source;
- (void)updateLayoutForSource:(id<WLMediaSource>)source layout:(WLSourceLayout *)layout;
- (nullable WLSourceLayout *)layoutForSource:(id<WLMediaSource>)source;
- (CMSampleBufferRef _Nullable)renderFrame;
- (void)start;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
