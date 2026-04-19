//
//  WLNodeFrame.h
//  WorkLabs
//
//  Created by erfeixia on 18/04/2026.
//
//  统一的音视频帧容器
//  参考: OBS架构设计.md §3.1

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AppKit/AppKit.h>
#include "libavutil/frame.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 帧类型枚举

/** 帧类型：区分视频帧和音频帧 */
typedef NS_ENUM(NSInteger, WLFrameType) {
    WLFrameTypeVideo = 0,
    WLFrameTypeAudio
};

#pragma mark - WLNodeFrame (通用帧容器)

/**
 WLNodeFrame —— 统一的音视频帧容器
 
 设计意图：
 - 屏蔽底层差异（FFmpeg AVFrame / AVCapture CMSampleBuffer）
 - 对外统一暴露 CVPixelBufferRef（视频）+ 标准音频参数（音频）
 - 场景渲染器 (WLSceneRenderer) 和混音器 (WLMediaMixer) 只需处理此类型
 
 与现有 WLNode 的关系：
 ┌─────────────┐     转换      ┌─────────────┐
 │  WLNode      │ ──────────→ │  WLNodeFrame  │
 │  (内部用)    │             │  (对外接口)   │
 │ AVPacket     │             │ CVPixelBuffer │
 │ AVFrame      │             │ CMTime pts    │
 └─────────────┘             └─────────────┘
 */
@interface WLNodeFrame : NSObject

/// 帧类型（视频或音频）
@property (nonatomic, assign) WLFrameType type;

/// 视频像素缓冲区（仅 video 类型有效）
@property (nonatomic, assign, nullable) CVPixelBufferRef pixelBuffer;

/// 显示时间戳
@property (nonatomic, assign) CMTime pts;

/// 解码时间戳（可选）
@property (nonatomic, assign) CMTime dts;

/// 帧持续时间
@property (nonatomic, assign) CMTime duration;

// ---- 视频属性 (type == WLFrameTypeVideo 时有效) ----

/// 原始视频尺寸（像素）
@property (nonatomic, assign) CGSize videoSize;

// ---- 音频属性 (type == WLFrameTypeAudio 时有效) ----

/// 采样率 (Hz)
@property (nonatomic, assign) UInt32 sampleRate;

/// 声道数
@property (nonatomic, assign) UInt32 channelCount;

/// 音频原始帧数据（仅 audio 类型有效，内部管理生命周期）
@property (nonatomic, unsafe_unretained, nullable) AVFrame *audioFrame;

/// 链表下一节点（WLNodeFrameQueue 内部使用）
@property (nonatomic, strong, nullable) WLNodeFrame *next;

/// 释放所有持有的资源（pixelBuffer / audioFrame）
- (void)flush;

@end

NS_ASSUME_NONNULL_END
