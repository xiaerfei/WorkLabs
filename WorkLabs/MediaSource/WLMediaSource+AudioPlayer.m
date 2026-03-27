//
//  WLMediaSource+AudioPlayer.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/26.
//

#import "WLMediaSource+AudioPlayer.h"
#import "WLAudioPlayer.h"
#import <objc/runtime.h>

static const void *kAudioPlayerKey = &kAudioPlayerKey;

@implementation WLMediaSource (AudioPlayer)

#pragma mark - Associated Object

- (WLAudioPlayer *)audioPlayer {
    return objc_getAssociatedObject(self, kAudioPlayerKey);
}

- (void)setAudioPlayer:(WLAudioPlayer *)audioPlayer {
    objc_setAssociatedObject(self, kAudioPlayerKey, audioPlayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - 连接管理

- (BOOL)connectAudioPlayer:(WLAudioPlayer *)player {
    if (!player) return NO;

    if (player.mode != WLAudioPlayerModeDelegate) {
        NSLog(@"WLMediaSource+AudioPlayer: Player must be in Delegate mode for integration");
        return NO;
    }

    // 保存引用
    self.audioPlayer = player;

    // 设置 self 为 delegate，这样 audioRenderThread 的回调会传递给 player
    self.delegate = (id<WLMediaSourceDelegate>)self;

    NSLog(@"WLMediaSource+AudioPlayer: Audio player connected");
    return YES;
}

- (void)disconnectAudioPlayer {
    WLAudioPlayer *player = self.audioPlayer;
    if (player) {
        [player stop];
    }

    self.audioPlayer = nil;
    NSLog(@"WLMediaSource+AudioPlayer: Audio player disconnected");
}

- (WLAudioPlayer *)createAndConnectAudioPlayer {
    // 创建默认配置的播放器（44100Hz, 2ch, Float32, Delegate 模式）
    WLAudioPlayer *player = [[WLAudioPlayer alloc] init];

    if ([self connectAudioPlayer:player]) {
        return player;
    }

    return nil;
}

@end
