//
//  WLMediaSource+AudioPlayer.h
//  WorkLabs
//
//  Created by erfeixia on 2026/3/26.
//

#import "WLMediaSource.h"

NS_ASSUME_NONNULL_BEGIN

@class WLAudioPlayer;

/// WLMediaSource 的音频播放器集成分类
/// 提供便捷方法将 WLAudioPlayer 连接到 WLMediaSource 的音频输出
@interface WLMediaSource (AudioPlayer)

/// 关联的音频播放器（通过 associated object 存储）
@property (nonatomic, strong, nullable) WLAudioPlayer *audioPlayer;

/// 连接音频播放器
/// 自动配置 delegate 关系，并根据音频流信息配置播放器的输入格式
/// @param player 要连接的播放器（需为 Delegate 模式）
/// @return 是否连接成功
- (BOOL)connectAudioPlayer:(WLAudioPlayer *)player;

/// 断开音频播放器
- (void)disconnectAudioPlayer;

/// 创建并连接一个默认配置的音频播放器
/// @return 创建的播放器，如果失败返回 nil
- (nullable WLAudioPlayer *)createAndConnectAudioPlayer;

@end

NS_ASSUME_NONNULL_END
