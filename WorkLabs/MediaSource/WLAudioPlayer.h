//
//  WLAudioPlayer.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/24.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libswresample/swresample.h>

NS_ASSUME_NONNULL_BEGIN

@class WLAudioPlayer;

@protocol MXAudioPlayerDelegate <NSObject>

@end

@interface WLAudioPlayer : NSObject

@end

NS_ASSUME_NONNULL_END
