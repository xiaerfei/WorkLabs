//
//  WLSceneRenderer.h
//  WorkLabs
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@class WLSceneManager;
@protocol MTLTexture;

NS_ASSUME_NONNULL_BEGIN

@interface WLSceneRenderer : NSObject

@property (nonatomic, weak, nullable) WLSceneManager *sceneManager;
@property (nonatomic, assign) CGSize outputSize;

/// 合成当前帧 -> CVPixelBufferRef
- (CVPixelBufferRef _Nullable)compositeFrame;

/// 以 Metal 纹理形式获取合成结果
- (id<MTLTexture> _Nullable)compositeTexture;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
