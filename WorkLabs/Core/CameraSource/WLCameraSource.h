//
//  WLCameraSource.h
//  WorkLabs
//
//  Created by erfeixia on 13/04/2026.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@class WLCameraSourceConfig;

NS_ASSUME_NONNULL_BEGIN

@interface WLCameraSource : NSObject

@property (nonatomic, strong, readonly) WLCameraSourceConfig *config;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

- (instancetype)initWithConfig:(WLCameraSourceConfig *)config;
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
