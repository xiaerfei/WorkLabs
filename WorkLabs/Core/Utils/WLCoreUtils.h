//
//  WLCoreUtils.h
//  WorkLabs
//
//  Created by erfeixia on 2026/4/5.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WLVideoRenderType) {
    WLVideoRenderTypeCamera,
    WLVideoRenderTypeMedia,
    WLVideoRenderTypePBP,
    WLVideoRenderTypePIP,
};


typedef NS_ENUM(NSInteger, WLAudioRenderType) {
    WLAudioRenderTypeMic,
    WLAudioRenderTypeMeida,
    WLAudioRenderTypeMix,
};

@interface WLCoreUtils : NSObject

@end

NS_ASSUME_NONNULL_END
