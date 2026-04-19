//
//  WLMediaSourceProvider.h
//  WorkLabs
//
//  Created by erfeixia on 18/04/2026.
//
//  媒体源协议定义 —— 抽象所有视频/音频输入源
//  参考: OBS架构设计.md §3.1

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AppKit/AppKit.h>
#import "WLNodeFrame.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 媒体源类型枚举

/**
 媒体源类型：标识数据来源
 
 | 类型          | 说明                     | 对应实现类            |
 |---------------|--------------------------|----------------------|
 | FFmpeg        | 本地文件 / 网络流媒体     | WLFFmpegMediaSource   |
 | Camera        | 系统摄像头捕获           | WLCameraMediaSource   |
 | Screen        | 屏幕录制捕获             | WLScreenMediaSource   |
 | Image         | 静态图片                 | WLImageMediaSource    |
 | Color         | 纯色背景 / 色块          | WLColorMediaSource    |
 | Text          | 文字 / 字幕叠加          | WLTextMediaSource     |
 */
typedef NS_ENUM(NSInteger, WLMediaSourceType) {
    WLMediaSourceTypeFFmpeg = 0,
    WLMediaSourceTypeCamera,
    WLMediaSourceTypeScreen,
    WLMediaSourceTypeImage,
    WLMediaSourceTypeColor,
    WLMediaSourceTypeText
};

#pragma mark - WLMediaSourceProvider 协议

/**
 WLMediaSourceProvider —— 媒体源抽象协议
 
 所有媒体源（摄像头、文件、屏幕、图片等）都实现此协议，
 使场景管理器能够统一调度不同类型的输入源。
 
 使用方式：
 1. 创建具体实现类实例（如 WLFFmpegMediaSource、WLCameraMediaSource）
 2. 调用 start() 启动数据流
 3. 循环调用 nextVideoFrame / nextAudioFrame 获取帧数据
 4. 调用 stop() 停止并释放资源
 
 线程安全说明：
 - nextVideoFrame / nextAudioFrame 可能被场景渲染线程调用
 - start / stop 应在主线程调用
 - 内部实现需保证线程安全
 */
@protocol WLMediaSourceProvider <NSObject>

@required

/// ======== 基本信息 ========

/** 全局唯一标识符（由 WLSceneManager.generateIdentifier 产生，实现类应在 init 中自动赋值） */
@property (nonatomic, copy, readwrite) NSString *identifier;

/** 媒体源类型标识 */
@property (nonatomic, assign) WLMediaSourceType sourceType;

/** 媒体源名称（用于 UI 展示和日志） */
@property (nonatomic, copy) NSString *sourceName;

/// ======== 生命周期 ========

/**
 启动媒体源，开始产生帧数据
 
 内部行为示例：
 - FFmpeg: 打开文件 → 启动 parse/decode 线程
 - Camera: 启动 AVCaptureSession
 - Image: 将图片解码为 CVPixelBuffer
 */
- (void)start;

/**
 停止媒体源，释放资源
 
 调用后 nextVideoFrame / nextAudioFrame 应返回 nil
 */
- (void)stop;

/// ======== 帧获取（核心接口） ========

/**
 获取下一帧视频
 
 @return 解码后的视频帧；无数据或已停止时返回 nil。
         返回的 frame 由调用者负责使用完毕后释放（如果需要）。
 
 典型实现：
 - 从内部帧队列中取出最新帧并包装为 WLNodeFrame
 - 如果队列为空但仍在运行，可阻塞等待或返回 nil
 */
- (nullable WLNodeFrame *)nextVideoFrame;

/**
 获取下一帧音频
 
 @return 解码后的音频帧；无数据或已停止时返回 nil。
 
 注意：对于纯视频源（如 Image、Color），应始终返回 nil。
 */
- (nullable WLNodeFrame *)nextAudioFrame;

/// ======== 属性查询 ========

/**
 原始尺寸（视频源的固有分辨率）
 
 @return 视频尺寸（像素）。对于非视频源返回 CGSizeZero。
 */
- (CGSize)intrinsicSize;

/// ======== 音量控制 ========

/** 当前音量 (0.0 ~ 1.0)，默认 1.0 */
@property (nonatomic, assign) float volume;

/** 是否处于激活状态（正在运行且可提供数据） */
@property (nonatomic, readonly) BOOL isActive;

@optional

/// ======== 可选属性 ========

/** 输出帧率（fps），用于同步控制 */
@property (nonatomic, assign) float frameRate;

@end

NS_ASSUME_NONNULL_END
