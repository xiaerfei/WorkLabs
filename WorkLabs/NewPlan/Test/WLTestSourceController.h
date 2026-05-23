//
//  WLTestSourceController.h
//  WorkLabs
//
//  通用 Source 测试控制器
//  用于独立测试各个 Source 模块（MediaSource / CameraSource / MicSource 等）
//

#import <Cocoa/Cocoa.h>
#import "WLStreamSourceProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLTestSourceController : NSViewController <WLStreamSourceDelegate>

/// 当前测试的 Source
@property (nonatomic, strong, nullable) id<WLStreamSourceProtocol> source;

/// 使用一个 Source 启动测试
- (void)testWithSource:(id<WLStreamSourceProtocol>)source;

/// 停止测试
- (void)stopTest;

@end

NS_ASSUME_NONNULL_END
