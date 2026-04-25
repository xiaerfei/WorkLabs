//
//  WLMediaSource.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import "WLMediaSource.h"
#import "WLNodeQueue.h"
#import "WLVideoConcatStreams.h"
#import "WLAudioMixStreams.h"
#import "WLStreamsManager.h"

#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavcodec/bsf.h"
#include "libavutil/avutil.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/opt.h"
#include "libavutil/intreadwrite.h"
#include <stdatomic.h>

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

@property (nonatomic, assign) Float64 baseTime;
@property (nonatomic, assign) Float64 videoPtsOffset;
@property (nonatomic, assign) Float64 audioPtsOffset;

@property (nonatomic, strong) WLVideoConcatStreams *streams;
@property (nonatomic, strong) WLAudioMixStreams *audioMixStreams;

@end

@implementation WLMediaSource {
    // 声明一个原子类型的整数
    _Atomic int _activeRenderThreads;
    _Atomic int32_t _seekGeneration;
    volatile BOOL _seekRequested;
    Float64 _seekTarget;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Public Methods
- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        // 初始化原子变量
        atomic_init(&_activeRenderThreads, 0);
        
        self.path = path;
        self.videoPtsOffset = 30.0;
        self.audioPtsOffset = 30.0;
        self.baseTime = 0.0;
        self.streams = [[WLVideoConcatStreams alloc] init];
        self.audioMixStreams = [[WLAudioMixStreams alloc] init];
    }
    return self;
}
- (void)start {
    self.running = YES;
    [NSThread detachNewThreadSelector:@selector(parseThread) toTarget:self withObject:nil];
}

- (void)stop {
    if (!self.running) return;
    self.running = NO;
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
    
    atomic_store_explicit(&_activeRenderThreads, 2, memory_order_relaxed);
    
    AVPacket *packet = av_packet_alloc();
    
    while (self.isRunning) {
        // 检查是否有 seek 请求
        if (_seekRequested) {
            [self performSeek];
        }
        
        int size = av_read_frame(self.formatContext, packet);
        if (size < 0 || packet->size < 0) {
            /// 视频播放完成了
            av_packet_free(&packet);
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

#pragma mark - Configure Queue
- (void)configureQueue {
    self.videoPacketQueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:15];
    self.videoPacketQueue.queueName = @"video packet queue";
    
    self.audioPacketQueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeAudio size:20];
    self.audioPacketQueue.queueName = @"audio packet queue";
    
    self.videoFrameQueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:4];
    self.videoFrameQueue.queueName = @"video frame queue";
    
    self.audioFrameQueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeAudio size:20];
    self.audioFrameQueue.queueName = @"audio frame queue";
}

- (void)configureDecode {
    self.videoDecoding  = YES;
    self.audioDecoding  = YES;
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
    int32_t lastSeekGen = 0;
    
    while (self.isVideoDecoding) {
        // 检测 seek 生成计数器是否变化
        int32_t currentGen = atomic_load(&_seekGeneration);
        if (currentGen != lastSeekGen) {
            lastSeekGen = currentGen;
            continue;
        }
        
        int result = [self decodeFrame:self.videoCodecContext
                                 frame:frame
                                 queue:self.videoPacketQueue];
        if (result == 0) {
            // 封装 Node 并入队 FrameQueue
            WLNode *node = [[WLNode alloc] init];
            node.frame = av_frame_clone(frame); // 引用计数+1
            node.fromType = WLFromTypeMedia;
            node.type = WLNodeTypeVideo;
            node.pts = frame->pts * self.videoTimeBase;
            [self.videoFrameQueue enQueue:node];
        } else if (result == AVERROR_EOF) {
            // 再次检查：seek 可能在 decodeFrame 期间发生
            currentGen = atomic_load(&_seekGeneration);
            if (currentGen != lastSeekGen) {
                lastSeekGen = currentGen;
                continue;
            }
            break;
        }
        av_frame_unref(frame); // 重置 frame 状态
    }
    av_frame_free(&frame);
    
    [self.videoPacketQueue flush];
    self.videoRendering = NO;
    [self.videoFrameQueue abort];
}

- (void)audioDecodeThread {
    [NSThread currentThread].name = @"com.wl-decode-audio.thread";
    AVFrame *frame = av_frame_alloc();
    int32_t lastSeekGen = 0;
    while (self.isAudioDecoding) {
        // 检测 seek 生成计数器是否变化
        int32_t currentGen = atomic_load(&_seekGeneration);
        if (currentGen != lastSeekGen) {
            lastSeekGen = currentGen;
            continue;
        }
        
        int result = [self decodeFrame:self.audioCodecContext
                                 frame:frame
                                 queue:self.audioPacketQueue];
        if (result == 0) {
            WLNode *node = [[WLNode alloc] init];
            node.frame = av_frame_clone(frame);
            node.fromType = WLFromTypeMedia;
            node.type = WLNodeTypeAudio;
            node.pts = frame->pts * self.audioTimeBase;
            [self.audioFrameQueue enQueue:node];
        } else if (result == AVERROR_EOF) {
            // 再次检查：seek 可能在 decodeFrame 期间发生
            currentGen = atomic_load(&_seekGeneration);
            if (currentGen != lastSeekGen) {
                lastSeekGen = currentGen;
                continue;
            }
            break;
        }
        av_frame_unref(frame);
    }
    av_frame_free(&frame);
    
    [self.audioPacketQueue flush];
    self.audioRendering = NO;
    [self.audioFrameQueue abort];
}

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
            // 轮询模式，可被 seek 打断
            WLNode *node = nil;
            int pollCount = 0;
            while (!node && !_seekRequested) {
                node = [queue deQueueWithBlock:NO];
                if (!node && !_seekRequested) {
                    usleep(1000); // 1ms 轮询间隔
                    pollCount++;
                    if (pollCount > 5000) break; // ~5 秒超时保护
                }
            }
            
            if (_seekRequested) {
                return AVERROR_EOF;
            }
            
            if (!node) return AVERROR_EOF;
            
            ret = avcodec_send_packet(avctx, node.packet);
            
            [node flush]; // 无论成功失败都释放
            node = nil;
            
            if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
                return ret;
            }
            continue;
        }
        return ret;
    }
}
#pragma mark - Render Thread
- (void)videoRenderThread {
    [NSThread currentThread].name = @"com.wl-render-video.thread";
    WLStreamsManager *streams = [WLStreamsManager manager];
    while (self.isVideoRendering) {
        Float64 current_time = CFAbsoluteTimeGetCurrent() * 1000;
        
        if (self.baseTime == 0) {
            self.baseTime = current_time;
            NSLog(@"[Video] BaseTime set: %.3f", self.baseTime);
        }
        
        WLNode *node = [self.videoFrameQueue peek];
        if (!node) {
            usleep(5 * 1000);
            continue;
        }
        
        Float64 abs_pts = node.pts * 1000 + self.baseTime;
        
        if ((abs_pts + self.videoPtsOffset < current_time) &&
            [self.videoFrameQueue count] >= 4) {
            node = [self.videoFrameQueue deQueueWithBlock:NO];
            if (node && node.frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                [streams addVideoNode:node];
            } else {
                [node flush];                
            }
        } else {
            usleep(5 * 1000);
        }
    }
    [self.videoFrameQueue flush];
    [self releaseFFmpegResources];
}

- (void)audioRenderThread {
    [NSThread currentThread].name = @"com.wl-render-audio.thread";

    while (self.isAudioRendering) {
        Float64 current_time = CFAbsoluteTimeGetCurrent() * 1000;
        
        if (self.baseTime == 0) {
            usleep(10 * 1000);
            continue;
        }
        
        WLNode *node = [self.audioFrameQueue peek];
        if (!node) {
            usleep(10 * 1000);
            continue;
        }
        
        Float64 abs_pts = node.pts * 1000 + self.baseTime;
        
        if (abs_pts + self.audioPtsOffset < current_time) {
            node = [self.audioFrameQueue deQueueWithBlock:NO];
            [[WLStreamsManager manager] addAudioNode:node];
        } else {
            usleep(10 * 1000);
        }
    }

    [self.audioFrameQueue flush];
    [self releaseFFmpegResources];
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
- (void)releaseFFmpegResources {
    NSInteger remaining = atomic_fetch_sub_explicit(&_activeRenderThreads, 1, memory_order_acq_rel) - 1;
    if (remaining > 0) return;
    
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

- (Float64)totalDuration {
    AVFormatContext *fmtCtx = self.formatContext;
    if (fmtCtx && fmtCtx->duration != AV_NOPTS_VALUE) {
        return (Float64)fmtCtx->duration / AV_TIME_BASE;
    }
    return 0.0;
}

#pragma mark - Seek
- (void)seekToTime:(Float64)seconds {
    if (!self.running || !self.formatContext) return;
    if (self.videoStreamIndex < 0 && self.audioStreamIndex < 0) return;
    
    _seekTarget = MAX(0, seconds);
    _seekRequested = YES;
    atomic_fetch_add_explicit(&_seekGeneration, 1, memory_order_release);
}

- (void)performSeek {
    Float64 targetSeconds = _seekTarget;
    int64_t seek_target;
    
    if (self.videoStreamIndex >= 0) {
        seek_target = (int64_t)(targetSeconds / self.videoTimeBase);
    } else if (self.audioStreamIndex >= 0) {
        seek_target = (int64_t)(targetSeconds / self.audioTimeBase);
    } else {
        _seekRequested = NO;
        return;
    }
    
    int ret = av_seek_frame(self.formatContext, -1, seek_target, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) {
        NSLog(@"Seek failed: %@", [self getFFmpegError:ret]);
        _seekRequested = NO;
        return;
    }
    
    // 刷新编解码器内部缓冲区
    if (self.videoCodecContext) {
        avcodec_flush_buffers(self.videoCodecContext);
    }
    if (self.audioCodecContext) {
        avcodec_flush_buffers(self.audioCodecContext);
    }
    
    // 清空所有队列中的旧数据
    [self.videoPacketQueue flush];
    [self.audioPacketQueue flush];
    [self.videoFrameQueue flush];
    [self.audioFrameQueue flush];
    
    // 重置时间基准，渲染线程会重新计算 baseTime
    self.baseTime = 0;
    
    _seekRequested = NO;
}

@end
