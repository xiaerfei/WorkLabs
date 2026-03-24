//
//  WLMediaSource.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import "WLMediaSource.h"
#import "WLNodeQueue.h"

#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavcodec/bsf.h"
#include "libavutil/avutil.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/opt.h"
#include "libavutil/intreadwrite.h"


@interface WLMediaSource ()
@property (nonatomic,   copy, readwrite) NSString *path;
@property (nonatomic, assign, readwrite) WLMediaSourceState state;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;

@property (atomic, assign, getter=isVideoDecoding) BOOL videoDecoding;
@property (atomic, assign, getter=isAudioDecoding) BOOL audioDecoding;

@property (nonatomic, assign, readwrite, getter=isVideoRendering) BOOL videoRendering;
@property (nonatomic, assign, readwrite, getter=isAudioRendering) BOOL audioRendering;

@property (nonatomic, unsafe_unretained) AVFormatContext *formatContext;
@property (nonatomic, unsafe_unretained) AVCodecContext  *audioCodecContext;
@property (nonatomic, unsafe_unretained) AVCodecContext  *videoCodecContext;

@property (nonatomic, assign) int videoStreamIndex;
@property (nonatomic, assign) int audioStreamIndex;

@property (nonatomic, strong) WLNodeQueue *videoPacketQueue;
@property (nonatomic, strong) WLNodeQueue *audioPacketQueue;

@property (nonatomic, strong) WLNodeQueue *videoFrameQueue;
@property (nonatomic, strong) WLNodeQueue *audioFrameQueue;

@property (nonatomic, assign) double videoTimeBase;
@property (nonatomic, assign) double audioTimeBase;

@property (nonatomic, assign) AVRational video_time_base;

@end

@implementation WLMediaSource
#pragma mark - Public Methods
- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        self.path = path;
    }
    return self;
}
- (void)start {
    self.running = YES;
    [NSThread detachNewThreadSelector:@selector(parseThread) toTarget:self withObject:nil];
}

- (void)stop {
}

#pragma mark - Parse Thread
- (void)parseThread {
    NSString *errorMsg = [self configureFFmpeg];
    if (errorMsg != nil) {
        return;
    }
    
    [NSThread currentThread].name = @"com.media-source.thread";
    
    [self configureQueue];
    [self configureDecode];
    
    self.video_time_base = self.formatContext->streams[self.videoStreamIndex]->time_base;
    self.videoTimeBase = av_q2d(self.formatContext->streams[self.videoStreamIndex]->time_base);
    self.audioTimeBase = av_q2d(self.formatContext->streams[self.audioStreamIndex]->time_base);
    
    AVPacket *packet = av_packet_alloc();
    
    while (self.isRunning) {
        int size = av_read_frame(self.formatContext, packet);
        if (size < 0 || packet->size < 0) {
            /// 视频播放完成了
            av_packet_free(&packet);
            break;
        }
        if (packet->stream_index == self.videoStreamIndex) {
            [self addPacket:packet type:WLDecodeTypeVideo];
        } else if (packet->stream_index == self.audioStreamIndex) {
            [self addPacket:packet type:WLDecodeTypeAudio];
        }
        av_packet_unref(packet);
    }
    
    [self doExit];
}

- (void)addPacket:(AVPacket *)packet type:(WLDecodeType)type {
    AVPacket *nodeP = av_packet_alloc();
    av_packet_ref(nodeP, packet);
    
    WLDecodeNode *node = [WLDecodeNode new];
    node.type = type;
    node.packet = nodeP;
    if (type == WLDecodeTypeVideo) {
        [self.videoPacketQueue enQueue:node];
    } else if (type == WLDecodeTypeAudio) {
        [self.audioPacketQueue enQueue:node];
    }
}

#pragma mark - Configure Queue
- (void)configureQueue {
    self.videoPacketQueue = [[WLNodeQueue alloc] initWithType:WLDecodeTypeVideo size:15];
    self.videoPacketQueue.queueName = @"video packet queue";
    
    self.audioPacketQueue = [[WLNodeQueue alloc] initWithType:WLDecodeTypeAudio size:20];
    self.audioPacketQueue.queueName = @"audio packet queue";
    
    self.videoFrameQueue = [[WLNodeQueue alloc] initWithType:WLDecodeTypeVideo size:5];
    self.videoFrameQueue.queueName = @"video frame queue";
    
    self.audioFrameQueue = [[WLNodeQueue alloc] initWithType:WLDecodeTypeAudio size:20];
    self.audioFrameQueue.queueName = @"audio frame queue";
}

- (void)configureDecode {
    self.videoDecoding = YES;
    self.audioDecoding = YES;
    self.videoRendering = YES;
    self.audioRendering = YES;
    [NSThread detachNewThreadSelector:@selector(videoDecodeThread) toTarget:self withObject:nil];
    [NSThread detachNewThreadSelector:@selector(audioDecodeThread) toTarget:self withObject:nil];
    
    [NSThread detachNewThreadSelector:@selector(videoRenderThread) toTarget:self withObject:nil];
    [NSThread detachNewThreadSelector:@selector(audioRenderThread) toTarget:self withObject:nil];
}
#pragma mark - Decode Thread
- (void)videoDecodeThread {
    [NSThread currentThread].name = @"com.wl-decode-video.thread";
    AVFrame *frame = av_frame_alloc();
    
    while (self.isVideoDecoding) {
        int result = [self decodeFrame:self.videoCodecContext
                                 frame:frame
                                 queue:self.videoPacketQueue];
        if (result == 0) {
            // 封装 Node 并入队 FrameQueue
            WLDecodeNode *node = [[WLDecodeNode alloc] init];
            node.frame = av_frame_clone(frame); // 引用计数+1
            node.type = WLDecodeTypeVideo;
            node.pts = frame->pts * av_q2d(self.formatContext->streams[self.videoStreamIndex]->time_base);
            [self.videoFrameQueue enQueue:node];
        } else if (result == AVERROR_EOF) {
            break;
        }
        av_frame_unref(frame); // 重置 frame 状态
    }
    av_frame_free(&frame);
}

- (void)audioDecodeThread {
    [NSThread currentThread].name = @"com.wl-decode-audio.thread";
    AVFrame *frame = av_frame_alloc();
    while (self.isAudioDecoding) {
        int result = [self decodeFrame:self.audioCodecContext
                                 frame:frame
                                 queue:self.audioPacketQueue];
        if (result == 0) {
            // 封装 Node 并入队 FrameQueue
            WLDecodeNode *node = [[WLDecodeNode alloc] init];
            node.frame = av_frame_clone(frame); // 引用计数+1
            node.type = WLDecodeTypeAudio;
            node.pts = frame->pts * av_q2d(self.formatContext->streams[self.audioStreamIndex]->time_base);
            [self.audioFrameQueue enQueue:node];
        } else if (result == AVERROR_EOF) {
            break;
        }
        av_frame_unref(frame);
    }
    av_frame_free(&frame);
    avcodec_flush_buffers(self.audioCodecContext);
}

- (int)decodeFrame:(AVCodecContext *)avctx
             frame:(AVFrame *)frame
             queue:(WLNodeQueue *)queue {
    int ret = AVERROR(EAGAIN);
    
    while (1) {
        // 1. 尝试从解码器接收帧
        ret = avcodec_receive_frame(avctx, frame);
        if (ret >= 0) return 0; // 成功获得一帧
        
        if (ret == AVERROR_EOF) {
            avcodec_flush_buffers(avctx);
            return AVERROR_EOF;
        }
        
        if (ret == AVERROR(EAGAIN)) {
            // 2. 解码器需要更多数据，从队列取出一个 Packet
            WLDecodeNode *node = [queue deQueueWithBlock:YES];
            if (!node) return AVERROR_EOF; // 队列已中止
            
            // 3. 送入解码器
            ret = avcodec_send_packet(avctx, node.packet);
            
            // 释放 node (内部会自动 free packet)
            node = nil;
            
            if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
                return ret; // 真正的解码错误
            }
            continue; // 继续循环去 receive_frame
        }
        return ret;
    }
}
#pragma mark - Render Thread
- (void)videoRenderThread {
    /// 开始渲染视频
    while (self.isVideoRendering) {
        WLDecodeNode *node = [self.videoFrameQueue deQueueWithBlock:NO];
        if (node) {
            if (node.frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)node.frame->data[3];
                if (pixelBuffer && [self.delegate respondsToSelector:@selector(mediaSource:didOutputVideoPixelBuffer:pts:)]) {
                    [self.delegate mediaSource:self didOutputVideoPixelBuffer:pixelBuffer pts:node.pts];
                }
            }
            [node flush];
        }
        [NSThread sleepForTimeInterval:0.05];
    }
}

- (void)audioRenderThread {
    /// 开始渲染音频
    while (self.isAudioRendering) {
        WLDecodeNode *node = [self.audioFrameQueue deQueueWithBlock:YES];
        if (node) {
            if ([self.delegate respondsToSelector:@selector(mediaSource:didOutputAudioFrame:pts:)]) {
                [self.delegate mediaSource:self didOutputAudioFrame:node.frame pts:node.pts];
            }
            [node flush];
        }
    }
}
#pragma mark - initial FFmpeg
- (NSString *)configureFFmpeg {
    NSString *errorMsg = nil;
    int err = 0;
    
    // 1. 打开文件
    err = [self openFileWithErrorMessage:&errorMsg];
    if (err != 0) {
        // openFile 内部失败会自动清理 partial 资源，此处直接返回
        return errorMsg;
    }
    
    // 2. 打开视频流
    err = [self openVideoStreamWithError:&errorMsg];
    if (err != 0) {
        [self doExit]; // 一步失败，全盘清理
        return errorMsg;
    }
    
    // 3. 打开音频流
    err = [self openAudioStreamWithError:&errorMsg];
    if (err != 0) {
        [self doExit]; // 确保视频流等资源也被释放
        return errorMsg;
    }
    
    return nil;
}

- (int)openFileWithErrorMessage:(NSString **)errorMsg {
    // 重新进入前确保干净
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
#pragma mark Video stream
- (int)openVideoStreamWithError:(NSString **)errorMsg {
    // 1. 重置并清理旧资源
    [self closeVideoStream];
    
    const AVCodec *codec = NULL;
    int ret = 0;

    // 2. 使用 av_find_best_stream 自动筛选最佳视频流
    // 它会自动过滤 AV_DISPOSITION_ATTACHED_PIC (封面图)
    ret = av_find_best_stream(self.formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"未找到有效的视频流: %@", [self getFFmpegError:ret]];
        return ret;
    }
    self.videoStreamIndex = ret;
    AVStream *stream = self.formatContext->streams[self.videoStreamIndex];

    // 3. 分配解码器上下文
    self.videoCodecContext = avcodec_alloc_context3(codec);
    if (!self.videoCodecContext) {
        if (errorMsg) *errorMsg = @"无法分配解码器上下文 (内存不足)";
        return AVERROR(ENOMEM);
    }

    // 4. 填充流参数
    ret = avcodec_parameters_to_context(self.videoCodecContext, stream->codecpar);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"参数同步失败: %@", [self getFFmpegError:ret]];
        goto fail;
    }

    // 5. 尝试配置 VideoToolbox 硬件加速
    ret = [self setupHardwareDecoder:self.videoCodecContext];
    if (ret < 0) {
        // 提示：此处如果硬件初始化失败，严谨的做法是记录警告，但可以继续尝试打开解码器（走软解）
        NSLog(@"硬件加速初始化失败，将尝试软件解码: %@", [self getFFmpegError:ret]);
    }

    // 6. 正式打开解码器
    ret = avcodec_open2(self.videoCodecContext, codec, NULL);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"无法打开解码器: %@", [self getFFmpegError:ret]];
        goto fail;
    }

    return 0; // 成功

fail:
    [self closeVideoStream];
    return ret;
}

- (int)setupHardwareDecoder:(AVCodecContext *)ctx {
    AVBufferRef *hw_device_ctx = NULL;
    // 直接指定 VideoToolbox，这是 Apple 平台的标准硬解方式
    int err = av_hwdevice_ctx_create(&hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
    if (err < 0) return err;
    
    ctx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
    av_buffer_unref(&hw_device_ctx);
    return 0;
}

// 统一的资源清理方法
- (void)closeVideoStream {
    if (_videoCodecContext) {
        avcodec_free_context(&_videoCodecContext);
        _videoCodecContext = NULL;
    }
    self.videoStreamIndex = -1;
}
#pragma mark Audio stream
- (int)openAudioStreamWithError:(NSString **)errorMsg {
    // 1. 资源重置，防止重复调用导致内存泄漏
    if (_audioCodecContext) {
        avcodec_free_context(&_audioCodecContext);
        _audioCodecContext = NULL;
    }
    self.audioStreamIndex = -1;

    const AVCodec *codec = NULL;
    int ret = 0;

    // 2. 自动寻找最佳音频流
    // av_find_best_stream 会根据流的配置（如声道数、采样率）自动选择质量最好的流
    ret = av_find_best_stream(self.formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"未找到音频流: %@", [self getFFmpegError:ret]];
        return ret;
    }
    self.audioStreamIndex = ret;

    // 3. 分配解码器上下文
    AVCodecContext *codecContext = avcodec_alloc_context3(codec);
    if (!codecContext) {
        if (errorMsg) *errorMsg = @"无法分配音频解码上下文";
        return AVERROR(ENOMEM);
    }

    // 4. 将流参数填充到解码器上下文
    ret = avcodec_parameters_to_context(codecContext, self.formatContext->streams[self.audioStreamIndex]->codecpar);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"音频参数拷贝失败: %@", [self getFFmpegError:ret]];
        avcodec_free_context(&codecContext); // 必须手动释放，因为还没赋值给 self
        return ret;
    }

    // 5. 打开解码器
    ret = avcodec_open2(codecContext, codec, NULL);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"无法打开音频解码器: %@", [self getFFmpegError:ret]];
        avcodec_free_context(&codecContext);
        return ret;
    }

    // 6. 赋值成功
    self.audioCodecContext = codecContext;
    return 0;
}
#pragma mark - 资源释放
- (void)doExit {
    // 按照从内到外的顺序释放，虽然 FFmpeg 内部有处理，但外层逻辑要清晰
    
    // 1. 释放视频解码器
    if (_videoCodecContext) {
        // 注意：avcodec_free_context 会自动处理内部的 hw_device_ctx unref
        // 不需要手动去 unref videoCodecContext->hw_device_ctx
        avcodec_free_context(&_videoCodecContext);
        _videoCodecContext = NULL;
    }
    
    // 2. 释放音频解码器
    if (_audioCodecContext) {
        avcodec_free_context(&_audioCodecContext);
        _audioCodecContext = NULL;
    }
    
    // 3. 关闭输入上下文
    if (_formatContext) {
        // avformat_close_input 会释放 formatContext 本身并置为 NULL
        avformat_close_input(&_formatContext);
        _formatContext = NULL;
    }
    
    // 4. 重置索引
    self.videoStreamIndex = -1;
    self.audioStreamIndex = -1;
    
    NSLog(@"FFmpeg resources cleaned up safely.");
}
#pragma mark - tools
// 辅助方法：将 FFmpeg 错误码转为可读字符串
- (NSString *)getFFmpegError:(int)errNum {
    char errbuf[AV_ERROR_MAX_STRING_SIZE];
    if (av_strerror(errNum, errbuf, sizeof(errbuf)) == 0) {
        return [NSString stringWithFormat:@"FFmpeg Error(%d): %s", errNum, errbuf];
    }
    return [NSString stringWithFormat:@"Unknown Error: %d", errNum];
}

@end
