//
//  WLFFmpegMediaSource.m
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//

#import "WLFFmpegMediaSource.h"
#import "WLSceneManager.h"
#import "WLNodeFrameQueue.h"
#import "WLNodeQueue.h"
#import "WLNode.h"

#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavcodec/bsf.h"
#include "libavutil/avutil.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/opt.h"
#include "libavutil/intreadwrite.h"
#import <stdatomic.h>

@interface WLFFmpegMediaSource ()

@property (nonatomic, copy, readwrite) NSString *path;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;

@property (atomic, assign, getter=isVideoDecoding) BOOL videoDecoding;
@property (atomic, assign, getter=isAudioDecoding) BOOL audioDecoding;

/// FFmpeg 上下文
@property (nonatomic, unsafe_unretained) AVFormatContext *formatContext;
@property (nonatomic, unsafe_unretained) AVCodecContext  *audioCodecContext;
@property (nonatomic, unsafe_unretained) AVCodecContext  *videoCodecContext;

/// 流索引
@property (nonatomic, assign) int videoStreamIndex;
@property (nonatomic, assign) int audioStreamIndex;

/// 内部包队列（解码线程消费，使用原有 WLNodeQueue）
@property (nonatomic, strong) WLNodeQueue *videoPacketQueue;
@property (nonatomic, strong) WLNodeQueue *audioPacketQueue;

/// 帧队列（对外提供，使用新的 WLNodeFrameQueue）
@property (nonatomic, strong) WLNodeFrameQueue *videoFrameQueue;
@property (nonatomic, strong) WLNodeFrameQueue *audioFrameQueue;

/// 时间基
@property (nonatomic, assign) double videoTimeBase;
@property (nonatomic, assign) double audioTimeBase;

@end

@implementation WLFFmpegMediaSource
@synthesize sourceType = _sourceType;
@synthesize volume = _volume;
@synthesize sourceName = _sourceName;
@synthesize identifier = _identifier;

#pragma mark - Lifecycle

- (void)dealloc {
    [self stop];
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
        self.sourceType = WLMediaSourceTypeFFmpeg;
        self.sourceName = path.lastPathComponent;
        self.volume = 1.0f;
        self.identifier = [[WLSceneManager shared] generateIdentifier];
        _videoStreamIndex = -1;
        _audioStreamIndex = -1;
    }
    return self;
}

#pragma mark - WLMediaSourceProvider Protocol

- (void)start {
    if (self.isRunning) return;
    self.running = YES;
    [NSThread detachNewThreadSelector:@selector(parseThread) toTarget:self withObject:nil];
}

- (void)stop {
    if (!self.isRunning) return;
    self.running = NO;
    
    // 中止包队列，让 decode 线程自然退出
    [self.videoPacketQueue abort];
    [self.audioPacketQueue abort];
    
    // 等待一小段时间让线程退出
    usleep(50 * 1000);
    
    // 中止帧队列
    [self.videoFrameQueue abort];
    [self.audioFrameQueue abort];
    
    // 清空残留帧
    [self.videoFrameQueue flush];
    [self.audioFrameQueue flush];
    
    // 释放 FFmpeg 资源
    [self releaseFFmpegResources];
}

- (nullable WLNodeFrame *)nextVideoFrame {
    return [self.videoFrameQueue deQueueWithBlock:NO];
}

- (nullable WLNodeFrame *)nextAudioFrame {
    return [self.audioFrameQueue deQueueWithBlock:NO];
}

- (CGSize)intrinsicSize {
    if (_videoCodecContext && _videoStreamIndex >= 0) {
        return CGSizeMake(_videoCodecContext->width, _videoCodecContext->height);
    }
    return CGSizeZero;
}

- (BOOL)isActive {
    return self.isRunning;
}

#pragma mark - Parse Thread

- (void)parseThread {
    NSString *errorMsg = [self configureFFmpeg];
    if (errorMsg != nil) {
        NSLog(@"[WLFFmpegMediaSource] FFmpeg 初始化失败: %@", errorMsg);
        self.running = NO;
        return;
    }
    
    [NSThread currentThread].name = @"com.wlffmpeg-parse.thread";
    
    [self configureQueues];
    [self startDecodeThreads];
    
    AVPacket *packet = av_packet_alloc();
    
    while (self.isRunning) {
        int size = av_read_frame(self.formatContext, packet);
        if (size < 0 || packet->size < 0) {
            // 文件读取完成或出错
            break;
        }
        
        if (packet->stream_index == self.videoStreamIndex) {
            [self addPacket:packet type:WLNodeTypeVideo];
        } else if (packet->stream_index == self.audioStreamIndex) {
            [self addPacket:packet type:WLNodeTypeAudio];
        }
        
        av_packet_unref(packet);
    }
    
    av_packet_free(&packet);
    
    // 通知解码线程退出
    self.videoDecoding = NO;
    self.audioDecoding = NO;
    [self.videoPacketQueue abort];
    [self.audioPacketQueue abort];
}

- (void)addPacket:(AVPacket *)packet type:(WLNodeType)type {
    AVPacket *nodeP = av_packet_alloc();
    av_packet_ref(nodeP, packet);
    
    WLNode *node = [WLNode new];
    node.type = type;
    node.packet = nodeP;
    
    if (type == WLNodeTypeVideo) {
        [self.videoPacketQueue enQueue:node];
    } else if (type == WLNodeTypeAudio) {
        [self.audioPacketQueue enQueue:node];
    }
}

#pragma mark - Queue & Decode Setup

- (void)configureQueues {
    // 包队列（内部用，复用 WLNodeQueue）
    self.videoPacketQueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:15];
    self.videoPacketQueue.queueName = @"wlffmpeg-video-packet";
    
    self.audioPacketQueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeAudio size:20];
    self.audioPacketQueue.queueName = @"wlffmpeg-audio-packet";
    
    // 帧队列（对外暴露，使用 WLNodeFrameQueue）
    self.videoFrameQueue = [[WLNodeFrameQueue alloc] initWithSize:4];
    self.videoFrameQueue.queueName = @"wlffmpeg-video-frame";
    
    self.audioFrameQueue = [[WLNodeFrameQueue alloc] initWithSize:20];
    self.audioFrameQueue.queueName = @"wlffmpeg-audio-frame";
}

- (void)startDecodeThreads {
    self.videoDecoding = YES;
    self.audioDecoding = YES;
    
    [NSThread detachNewThreadSelector:@selector(videoDecodeThread) toTarget:self withObject:nil];
    [NSThread detachNewThreadSelector:@selector(audioDecodeThread) toTarget:self withObject:nil];
}

#pragma mark - Video Decode Thread

- (void)videoDecodeThread {
    [NSThread currentThread].name = @"wlffmpeg-decode-video";
    AVFrame *frame = av_frame_alloc();
    
    while (self.isVideoDecoding) {
        int result = [self decodeFrame:self.videoCodecContext
                                  frame:frame
                                  queue:self.videoPacketQueue];
        if (result == 0) {
            WLNodeFrame *nodeFrame = [self createVideoNodeFrame:frame];
            if (nodeFrame) {
                [self.videoFrameQueue enQueue:nodeFrame];
            }
        } else if (result == AVERROR_EOF) {
            break;
        }
        av_frame_unref(frame);
    }
    
    av_frame_free(&frame);
    [self.videoPacketQueue flush];
    [self.videoFrameQueue abort];
}

#pragma mark - Audio Decode Thread

- (void)audioDecodeThread {
    [NSThread currentThread].name = @"wlffmpeg-decode-audio";
    AVFrame *frame = av_frame_alloc();
    
    while (self.isAudioDecoding) {
        int result = [self decodeFrame:self.audioCodecContext
                                  frame:frame
                                  queue:self.audioPacketQueue];
        if (result == 0) {
            WLNodeFrame *nodeFrame = [self createAudioNodeFrame:frame];
            if (nodeFrame) {
                [self.audioFrameQueue enQueue:nodeFrame];
            }
        } else if (result == AVERROR_EOF) {
            break;
        }
        av_frame_unref(frame);
    }
    
    av_frame_free(&frame);
    [self.audioPacketQueue flush];
    [self.audioFrameQueue abort];
}

#pragma mark - Frame Creation

/**
 将 AVFrame 转换为 WLNodeFrame（视频帧）
 处理 VideoToolbox 硬解：从 AVFrame 提取 CVPixelBufferRef
 */
- (WLNodeFrame *)createVideoNodeFrame:(AVFrame *)frame {
    WLNodeFrame *nodeFrame = [[WLNodeFrame alloc] init];
    nodeFrame.type = WLFrameTypeVideo;
    
    // 时间戳转换
    double ptsSeconds = frame->pts * self.videoTimeBase;
    nodeFrame.pts = CMTimeMakeWithSeconds(ptsSeconds, NSEC_PER_SEC);
    nodeFrame.duration = CMTimeMakeWithSeconds(frame->pkt_duration * self.videoTimeBase, NSEC_PER_SEC);
    // 视频尺寸
    nodeFrame.videoSize = CGSizeMake(self.videoCodecContext->width,
                                      self.videoCodecContext->height);
    
    // 提取 pixelBuffer
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX && frame->data[0]) {
        CVPixelBufferRef pb = (CVPixelBufferRef)frame->data[0];
        nodeFrame.pixelBuffer = CVPixelBufferRetain(pb);
    } else {
        // 软解情况：暂不转换，pixelBuffer 保持 NULL
        // 后续可通过 swscale 转换
    }
    
    return nodeFrame;
}

/**
 将 AVFrame 转换为 WLNodeFrame（音频帧）
 通过 av_frame_clone 持有音频数据
 */
- (WLNodeFrame *)createAudioNodeFrame:(AVFrame *)frame {
    WLNodeFrame *nodeFrame = [[WLNodeFrame alloc] init];
    nodeFrame.type = WLFrameTypeAudio;
    
    // 时间戳转换
    double ptsSeconds = frame->pts * self.audioTimeBase;
    nodeFrame.pts = CMTimeMakeWithSeconds(ptsSeconds, NSEC_PER_SEC);
    nodeFrame.duration = CMTimeMakeWithSeconds(frame->nb_samples / (double)frame->sample_rate, NSEC_PER_SEC);
    
    // 音频参数
    nodeFrame.sampleRate = (UInt32)frame->sample_rate;
    nodeFrame.channelCount = (UInt32)frame->channels;
    
    // clone 一份音频帧数据
    nodeFrame.audioFrame = av_frame_clone(frame);
    
    return nodeFrame;
}

#pragma mark - Decode Helper

- (int)decodeFrame:(AVCodecContext *)avctx
              frame:(AVFrame *)frame
              queue:(WLNodeQueue *)queue {
    int ret = AVERROR(EAGAIN);
    
    while (1) {
        ret = avcodec_receive_frame(avctx, frame);
        if (ret >= 0) return 0;
        
        if (ret == AVERROR_EOF) {
            avcodec_flush_buffers(avctx);
            return AVERROR_EOF;
        }
        
        if (ret == AVERROR(EAGAIN)) {
            WLNode *node = [queue deQueueWithBlock:YES];
            if (!node) return AVERROR_EOF;
            
            ret = avcodec_send_packet(avctx, node.packet);
            
            [node flush]; // 无论成功失败都释放包
            node = nil;
            
            if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
                return ret;
            }
            continue;
        }
        return ret;
    }
}

#pragma mark - FFmpeg Configuration

- (NSString *)configureFFmpeg {
    NSString *errorMsg = nil;
    int err = 0;
    
    // 1. 打开文件
    err = [self openFileWithErrorMessage:&errorMsg];
    if (err != 0) return errorMsg;
    
    // 2. 打开视频流
    err = [self openVideoStreamWithError:&errorMsg];
    if (err != 0) {
        [self releaseFFmpegResources];
        return errorMsg;
    }
    
    // 3. 打开音频流
    err = [self openAudioStreamWithError:&errorMsg];
    if (err != 0) {
        [self releaseFFmpegResources];
        return errorMsg;
    }
    
    return nil;
}

- (int)openFileWithErrorMessage:(NSString **)errorMsg {
    if (_formatContext) avformat_close_input(&_formatContext);
    
    AVFormatContext *tempCtx = NULL;
    AVDictionary *opts = NULL;
    
    int ret = avformat_open_input(&tempCtx, self.path.UTF8String, NULL, &opts);
    if (opts) av_dict_free(&opts);
    
    if (ret < 0) {
        if (errorMsg) *errorMsg = [self getFFmpegError:ret];
        return ret;
    }
    
    ret = avformat_find_stream_info(tempCtx, NULL);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [self getFFmpegError:ret];
        avformat_close_input(&tempCtx);
        return ret;
    }
    
    self.formatContext = tempCtx;
    return 0;
}

- (int)openVideoStreamWithError:(NSString **)errorMsg {
    [self closeVideoStream];
    
    const AVCodec *codec = NULL;
    int ret = 0;
    
    ret = av_find_best_stream(self.formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"未找到有效的视频流: %@", [self getFFmpegError:ret]];
        return ret;
    }
    self.videoStreamIndex = ret;
    AVStream *stream = self.formatContext->streams[self.videoStreamIndex];
    
    self.videoCodecContext = avcodec_alloc_context3(codec);
    if (!self.videoCodecContext) {
        if (errorMsg) *errorMsg = @"无法分配解码器上下文 (内存不足)";
        return AVERROR(ENOMEM);
    }
    
    ret = avcodec_parameters_to_context(self.videoCodecContext, stream->codecpar);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"参数同步失败: %@", [self getFFmpegError:ret]];
        goto fail;
    }
    
    ret = [self setupHardwareDecoder:self.videoCodecContext];
    if (ret < 0) {
        NSLog(@"[WLFFmpegMediaSource] 硬件加速初始化失败，将尝试软件解码: %@", [self getFFmpegError:ret]);
    }
    
    ret = avcodec_open2(self.videoCodecContext, codec, NULL);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"无法打开解码器: %@", [self getFFmpegError:ret]];
        goto fail;
    }
    
    // 记录时间基
    self.videoTimeBase = av_q2d(stream->time_base);
    
    return 0;
    
fail:
    [self closeVideoStream];
    return ret;
}

- (int)setupHardwareDecoder:(AVCodecContext *)ctx {
    AVBufferRef *hw_device_ctx = NULL;
    int err = av_hwdevice_ctx_create(&hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
    if (err < 0) return err;
    
    ctx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
    av_buffer_unref(&hw_device_ctx);
    return 0;
}

- (void)closeVideoStream {
    if (_videoCodecContext) {
        avcodec_free_context(&_videoCodecContext);
        _videoCodecContext = NULL;
    }
    self.videoStreamIndex = -1;
}

- (int)openAudioStreamWithError:(NSString **)errorMsg {
    if (_audioCodecContext) {
        avcodec_free_context(&_audioCodecContext);
        _audioCodecContext = NULL;
    }
    self.audioStreamIndex = -1;
    
    const AVCodec *codec = NULL;
    int ret = 0;
    
    ret = av_find_best_stream(self.formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"未找到音频流: %@", [self getFFmpegError:ret]];
        return ret;
    }
    self.audioStreamIndex = ret;
    
    AVCodecContext *codecContext = avcodec_alloc_context3(codec);
    if (!codecContext) {
        if (errorMsg) *errorMsg = @"无法分配音频解码上下文";
        return AVERROR(ENOMEM);
    }
    
    ret = avcodec_parameters_to_context(codecContext, self.formatContext->streams[self.audioStreamIndex]->codecpar);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"音频参数拷贝失败: %@", [self getFFmpegError:ret]];
        avcodec_free_context(&codecContext);
        return ret;
    }
    
    ret = avcodec_open2(codecContext, codec, NULL);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"无法打开音频解码器: %@", [self getFFmpegError:ret]];
        avcodec_free_context(&codecContext);
        return ret;
    }
    
    self.audioCodecContext = codecContext;
    
    // 记录时间基
    self.audioTimeBase = av_q2d(self.formatContext->streams[self.audioStreamIndex]->time_base);
    
    return 0;
}

#pragma mark - Resource Cleanup

- (void)releaseFFmpegResources {
    if (_videoCodecContext) {
        avcodec_free_context(&_videoCodecContext);
        _videoCodecContext = NULL;
    }
    
    if (_audioCodecContext) {
        avcodec_free_context(&_audioCodecContext);
        _audioCodecContext = NULL;
    }
    
    if (_formatContext) {
        avformat_close_input(&_formatContext);
        _formatContext = NULL;
    }
    
    self.videoStreamIndex = -1;
    self.audioStreamIndex = -1;
    
    NSLog(@"[WLFFmpegMediaSource] FFmpeg resources cleaned up.");
}

#pragma mark - Tools

- (NSString *)getFFmpegError:(int)errNum {
    char errbuf[AV_ERROR_MAX_STRING_SIZE];
    if (av_strerror(errNum, errbuf, sizeof(errbuf)) == 0) {
        return [NSString stringWithFormat:@"FFmpeg Error(%d): %s", errNum, errbuf];
    }
    return [NSString stringWithFormat:@"Unknown Error: %d", errNum];
}
@end
