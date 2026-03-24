//
//  TVUCameraManager.h
//  TVUPartyline
//
//  Created by Qi Zhang on 2024/1/30.
//  Copyright © 2024 tvunetworks. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>


NS_ASSUME_NONNULL_BEGIN

@protocol TVUCameraManagerDelegate <NSObject>
- (void)tvuCaptureOutput:(AVCaptureOutput *)output
   didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
          fromConnection:(AVCaptureConnection *)connection;

@end

@interface TVUVideoManager : NSObject

@property (nonatomic, weak) id<TVUCameraManagerDelegate> delegate;

+ (TVUVideoManager *)manager;

- (void)startCaptureSessionWithDevice:(NSDictionary *)deviceDict;

- (void)stopCapture;

@property(nonatomic, readonly, getter=isRunning) BOOL running;

- (NSString *)findFitResolution:(NSDictionary *)deviceDict;

@end

NS_ASSUME_NONNULL_END
