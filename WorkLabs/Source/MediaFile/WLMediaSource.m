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
#include "libavutil/avutil.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/opt.h"
#include "libavutil/intreadwrite.h"
#include <stdatomic.h>
#include <time.h>
#include <math.h>

// ─── 时间戳安全处理（参照 mpv common.h:38 + av_common.c:169） ───

/// NOPTS 哨兵：与 mpv MP_NOPTS_VALUE 一致，double 可精确表示
#define WL_NOPTS_VALUE (-0x1p+63)

/// 安全 pts 转换：AVFrame pts → 秒，显式处理 NOPTS（参照 mpv av_common.c:169）
static inline double wl_pts_from_av(int64_t av_pts, double time_base) {
    return av_pts == AV_NOPTS_VALUE ? WL_NOPTS_VALUE : av_pts * time_base;
}

/// 安全 pts 加偏移：NOPTS 传播（参照 mpv common.h:66 MP_ADD_PTS）
static inline double wl_add_pts(double pts, double offset) {
    return pts == WL_NOPTS_VALUE ? WL_NOPTS_VALUE : pts + offset;
}

/// 是否为有效 pts：排除 NOPTS 哨兵，并排除 inf/NaN。
/// 坏 time_base（den=0）或异常时间戳会产生 inf/NaN，而 NaN != 任何值恒为真、会穿透 NOPTS 判断；
/// 若放行，(int64_t)(pts*1e9) 是未定义行为，且 deadline 会变成 ±inf 的截断巨值 → render 挂死。
static inline BOOL wl_pts_is_valid(double pts) {
    return pts != WL_NOPTS_VALUE && isfinite(pts);
}

/// 单调时钟纳秒（CLOCK_UPTIME_RAW：单调递增、不受改系统时间/NTP 影响、休眠期间暂停）。
/// 用于 render 线程节流与队列等待，替代会漂移的 CFAbsoluteTimeGetCurrent（墙钟）。
static inline uint64_t wl_mono_now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

/// 分段睡眠：从现在睡到单调时刻 deadlineNs，但单次不超过 capNs。
/// 返回 YES 表示已到/已过 deadline（含微负 pts、过期帧 → 立即输出）；返回 NO 表示只睡了一段，
/// 由调用方在循环里复查停止标志后再睡，从而 abort 最多延迟一段（(c) 配 (a) 方案）。
/// nanosleep 为相对睡眠，时长与 CLOCK_UPTIME_RAW 同步推进，时基与 wl_mono_now_ns 一致。
static inline BOOL wl_sleep_until_segment(int64_t deadlineNs, int64_t capNs) {
    int64_t rel = deadlineNs - (int64_t)wl_mono_now_ns();
    if (rel <= 0) return YES;
    if (rel > capNs) rel = capNs;
    struct timespec ts;
    ts.tv_sec  = (time_t)(rel / 1000000000LL);
    ts.tv_nsec = (long)(rel % 1000000000LL);
    nanosleep(&ts, NULL);
    return NO;
}

/// 单帧最大等待上限：正常帧间隔仅几十 ms，1s 纯属坏时间戳兜底，不影响任何正常播放。
#define WL_MAX_FRAME_WAIT_NS  (1000000000LL)   // 1s

/// deadline 合理性钳制：deadline 距 now 远超上限（有限但离谱的坏 pts、int64 截断巨值）时，
/// 钳到 now + 上限，避免外层 while 空转等一个到不了的 deadline 而挂死 render 线程。
/// 负 / 过期 deadline（倒退帧）原样返回，由 wl_sleep_until_segment 的 rel<=0 立即输出。
/// （inf/NaN 已在 wl_pts_is_valid 处被丢弃，到不了这里——这是兜“有限巨值”的第二道防线）
static inline int64_t wl_clamp_deadline(int64_t deadline) {
    int64_t maxd = (int64_t)wl_mono_now_ns() + WL_MAX_FRAME_WAIT_NS;
    return deadline > maxd ? maxd : deadline;
}

@interface WLMediaSource ()
@property (nonatomic,   copy, readwrite) NSString *path;
@property (nonatomic, assign, readwrite) WLMediaSourceState state;

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

// A/V 输出微调偏移（秒，默认 0 = 精确到点；正值延后、负值提前，供未来 a/v 微调用）
@property (nonatomic, assign) Float64 videoPtsOffset;
@property (nonatomic, assign) Float64 audioPtsOffset;

// 时间戳归一化（参照 mpv demux_lavf.c:1498 + video.c:383）
@property (nonatomic, assign) double startTime;       // 容器 start_time（秒）
@property (nonatomic, assign) Float64 lastVideoPts;   // 上一帧视频 pts（归一化后）
@property (nonatomic, assign) Float64 lastAudioPts;   // 上一帧音频 pts（归一化后）

// WLStreamSourceProtocol 协议属性
@property (nonatomic, assign, readwrite) WLFromType fromType;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@end

@implementation WLMediaSource {
    _Atomic int _activeRenderThreads;

    // A/V 共享时基锚点（单调纳秒，有符号）：baseTime = 首帧输出时刻 - 首帧 pts。
    // 用 int64 是因 pts 不从 0 起（如 seek 后段）时该锚点逻辑上可能为负，uint64 会下溢。
    // 0 = 未锚定；由首个出帧的 render 线程用 CAS 设定，video/audio 共享同一值即 A/V 同步。
    _Atomic(int64_t) _baseTimeNs;

    // 软解视频帧转换: AVFrame → BGRA CVPixelBufferRef
    struct SwsContext *_swsCtx;
    int _swsSrcW, _swsSrcH;
    enum AVPixelFormat _swsSrcFmt;

    // 音频帧转换: AVFrame → interleaved CMSampleBufferRef
    struct SwrContext *_swrCtx;
    int _swrSrcRate, _swrSrcChannels;
    enum AVSampleFormat _swrSrcFmt;
}

@synthesize fromType = _fromType;
@synthesize running = _running;
@synthesize delegate = _delegate;

- (NSString *)displayName { return self.path.lastPathComponent ?: @"媒体文件"; }

- (void)dealloc {
    [self stop];
}

#pragma mark - Public Methods
- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        atomic_init(&_activeRenderThreads, 0);

        _fromType = WLFromTypeMedia;
        self.path = path;
        self.videoPtsOffset = 0.0;
        self.audioPtsOffset = 0.0;
        atomic_init(&_baseTimeNs, 0);
    }
    return self;
}
- (BOOL)start:(NSError **)error {
    if (self.isRunning) return YES;
    self.running = YES;
    [NSThread detachNewThreadSelector:@selector(parseThread) toTarget:self withObject:nil];
    return YES;
}

- (void)stop {
    if (!self.isRunning) return;
    self.running = NO;
    if ([self.delegate respondsToSelector:@selector(sourceDidStop:)]) {
        [self.delegate sourceDidStop:self];
    }
}

- (WLNodeType)streamType {
    return WLNodeTypeVideo;
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

    atomic_store_explicit(&_activeRenderThreads, 2, memory_order_relaxed);

    AVPacket *packet = av_packet_alloc();

    while (self.isRunning) {

        int ret = av_read_frame(self.formatContext, packet);
        if (ret == AVERROR_EOF) {
            break;  // 正常结束
        }
        if (ret < 0) {
            NSLog(@"[WLMediaSource] 读取错误: %s", av_err2str(ret));
            break;  // 错误退出
        }
        if (packet->size <= 0) {
            av_packet_unref(packet);
            continue;  // 跳过空包
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

    while (self.isVideoDecoding) {

        int result = [self decodeFrame:self.videoCodecContext
                                 frame:frame
                                 queue:self.videoPacketQueue];
        if (result == 0) {
            // 封装 Node 并入队 FrameQueue
            WLNode *node = [[WLNode alloc] init];
            node.frame = av_frame_clone(frame); // 引用计数+1
            node.fromType = WLFromTypeMedia;
            node.type = WLNodeTypeVideo;
            node.pts = wl_pts_from_av(frame->pts, self.videoTimeBase);
            [self.videoFrameQueue enQueue:node];
        } else if (result == AVERROR_EOF) {
            break;
        }
        av_frame_unref(frame);
    }
    av_frame_free(&frame);

    [self.videoPacketQueue flush];
    self.videoRendering = NO;
    [self.videoFrameQueue abort];
}

- (void)audioDecodeThread {
    [NSThread currentThread].name = @"com.wl-decode-audio.thread";
    AVFrame *frame = av_frame_alloc();
    while (self.isAudioDecoding) {

        int result = [self decodeFrame:self.audioCodecContext
                                 frame:frame
                                 queue:self.audioPacketQueue];
        if (result == 0) {
            WLNode *node = [[WLNode alloc] init];
            node.frame = av_frame_clone(frame);
            node.fromType = WLFromTypeMedia;
            node.type = WLNodeTypeAudio;
            node.pts = wl_pts_from_av(frame->pts, self.audioTimeBase);
            [self.audioFrameQueue enQueue:node];
        } else if (result == AVERROR_EOF) {
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
            // 使用带超时的阻塞出队，替代忙轮询
            // 队列有数据时立即返回，无数据时阻塞等待（零 CPU）
            // flush() 会 broadcast 唤醒，超时则继续等待
            WLNode *node = [queue deQueueWithTimeout:30]; // 30ms 超时

            if (!node) {
                // 超时，继续等待
                continue;
            }

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
    while (self.isVideoRendering) {
        // 阻塞取走队头帧（空队列零 CPU，不再 peek/usleep 轮询）。取走后该帧归本线程私有，
        // 节流期间不再持有队列内部指针 → 无悬垂、无 peek-then-pop 的 TOCTOU。
        // 阻塞出队返回 nil ⟺ 队列已 abort（停止信号），直接退出。
        WLNode *node = [self.videoFrameQueue deQueueWithBlock:YES];
        if (!node) break;

        // start_time 归一化（参照 mpv demux.c:2858 ts_offset = -start_time）
        Float64 normalized_pts = wl_add_pts(node.pts, -self.startTime);
        if (!wl_pts_is_valid(normalized_pts)) {
            [node flush];   // NOPTS 帧：丢弃（参照 mpv video.c:383-392 异常处理）
            continue;
        }
        int64_t pts_ns = (int64_t)(normalized_pts * 1e9);   // 有符号：归一化后边界帧 pts 可能微负

        // 首帧用 CAS 锚定 baseTime = 现在(单调) - 首帧 pts，使首帧立即出。
        // video/audio 谁先到谁设、另一路读同一值 → 共享时基即 A/V 同步（无需轮询等待）。
        int64_t expected = 0;
        atomic_compare_exchange_strong(&_baseTimeNs, &expected,
                                       (int64_t)wl_mono_now_ns() - pts_ns);
        int64_t baseTime = atomic_load_explicit(&_baseTimeNs, memory_order_relaxed);
        int64_t deadline = baseTime + pts_ns + (int64_t)(self.videoPtsOffset * 1e9);
        deadline = wl_clamp_deadline(deadline);   // 坏 pts 兜底：离谱远的 deadline 钳到 now+1s，防挂死

        // 节流：分段睡到 deadline（单调钟），单段 ≤20ms，每段复查停止标志 → abort 最多延迟一段。
        // deadline 已过（微负 pts / 过期帧）则首次即返回 YES，不睡，立即输出。
        while (self.isVideoRendering && !wl_sleep_until_segment(deadline, 20000000LL /* 20ms */)) { }
        if (!self.isVideoRendering) { [node flush]; break; }   // 睡眠期间被叫停：丢帧退出

        CVPixelBufferRef pixelBuffer = [self convertVideoFrame:node.frame];
        if (pixelBuffer && _delegate) {
            [_delegate source:self didOutputVideoFrame:pixelBuffer pts:normalized_pts];
        } else if (pixelBuffer) {
            CVPixelBufferRelease(pixelBuffer);
        }
        [node flush];
    }
    [self.videoFrameQueue flush];
    [self cleanupVideoConverter];
    [self releaseFFmpegResources];
}

- (void)audioRenderThread {
    [NSThread currentThread].name = @"com.wl-render-audio.thread";

    while (self.isAudioRendering) {
        // 阻塞取走队头帧（空队列零 CPU）。取走后归本线程私有 → 无悬垂、无 TOCTOU。
        // 阻塞出队返回 nil ⟺ 队列已 abort（停止信号），直接退出。
        WLNode *node = [self.audioFrameQueue deQueueWithBlock:YES];
        if (!node) break;

        // start_time 归一化（参照 mpv demux.c:2858 ts_offset = -start_time）
        Float64 normalized_pts = wl_add_pts(node.pts, -self.startTime);
        if (!wl_pts_is_valid(normalized_pts)) {
            [node flush];   // NOPTS 帧：丢弃
            continue;
        }
        int64_t pts_ns = (int64_t)(normalized_pts * 1e9);   // 有符号：归一化后边界帧 pts 可能微负

        // 与视频共享同一 baseTime（CAS 锚定，谁先到谁设）→ 相同 pts 同时刻输出，即 A/V 同步
        int64_t expected = 0;
        atomic_compare_exchange_strong(&_baseTimeNs, &expected,
                                       (int64_t)wl_mono_now_ns() - pts_ns);
        int64_t baseTime = atomic_load_explicit(&_baseTimeNs, memory_order_relaxed);
        int64_t deadline = baseTime + pts_ns + (int64_t)(self.audioPtsOffset * 1e9);
        deadline = wl_clamp_deadline(deadline);   // 坏 pts 兜底：离谱远的 deadline 钳到 now+1s，防挂死

        // 节流：分段睡到 deadline（单调钟），单段 ≤20ms，每段复查停止标志 → abort 最多延迟一段。
        while (self.isAudioRendering && !wl_sleep_until_segment(deadline, 20000000LL /* 20ms */)) { }
        if (!self.isAudioRendering) { [node flush]; break; }   // 睡眠期间被叫停：丢帧退出

        CMSampleBufferRef sampleBuffer = [self convertAudioFrame:node.frame];
        if (sampleBuffer && _delegate) {
            [_delegate source:self didOutputAudioBuffer:sampleBuffer];
        } else if (sampleBuffer) {
            CFRelease(sampleBuffer);
        }
        [node flush];
    }

    [self.audioFrameQueue flush];
    [self cleanupAudioConverter];
    [self releaseFFmpegResources];
}
#pragma mark - Video Frame Conversion (AVFrame → CVPixelBufferRef)
- (CVPixelBufferRef)convertVideoFrame:(AVFrame *)frame {
    if (!frame) return NULL;

    // VideoToolbox 硬解: data[3] 直接持有 CVPixelBufferRef
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        CVPixelBufferRef vtBuf = (CVPixelBufferRef)frame->data[3];
        if (vtBuf) {
            CVPixelBufferRetain(vtBuf);
            return vtBuf;
        }
    }

    // 软解: swscale 转换到 BGRA → CVPixelBufferRef
    int w = frame->width;
    int h = frame->height;
    enum AVPixelFormat fmt = (enum AVPixelFormat)frame->format;

    if (!_swsCtx || _swsSrcW != w || _swsSrcH != h || _swsSrcFmt != fmt) {
        if (_swsCtx) sws_freeContext(_swsCtx);
        _swsCtx = sws_getContext(w, h, fmt,
                                 w, h, AV_PIX_FMT_BGRA,
                                 SWS_BILINEAR, NULL, NULL, NULL);
        _swsSrcW = w;
        _swsSrcH = h;
        _swsSrcFmt = fmt;
    }
    if (!_swsCtx) return NULL;

    // IOSurface + Metal 兼容：使软解帧也能零拷贝绑 Metal 纹理（滤镜/合成/预览）。
    NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cvRet = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)pbAttrs, &pixelBuffer);
    if (cvRet != kCVReturnSuccess) return NULL;

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *dst = CVPixelBufferGetBaseAddress(pixelBuffer);
    int dstStride = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
    uint8_t *dstSlice[1] = { dst };
    int dstStrideArr[1] = { dstStride };

    sws_scale(_swsCtx, (const uint8_t *const *)frame->data, frame->linesize,
              0, h, dstSlice, dstStrideArr);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

#pragma mark - Audio Frame Conversion (AVFrame → CMSampleBufferRef)
- (CMSampleBufferRef)convertAudioFrame:(AVFrame *)frame {
    if (!frame) return NULL;

    int srcRate = frame->sample_rate;
    int srcChannels = frame->ch_layout.nb_channels;
    enum AVSampleFormat srcFmt = (enum AVSampleFormat)frame->format;
    int nbSamples = frame->nb_samples;

    // 配置或复用 SwrContext
    if (!_swrCtx || _swrSrcRate != srcRate || _swrSrcChannels != srcChannels || _swrSrcFmt != srcFmt) {
        if (_swrCtx) swr_free(&_swrCtx);

        AVChannelLayout outLayout = (srcChannels == 1)
            ? (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO
            : (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;

        swr_alloc_set_opts2(&_swrCtx,
                            &outLayout, AV_SAMPLE_FMT_FLT, srcRate,
                            &frame->ch_layout, srcFmt, srcRate,
                            0, NULL);
        if (!_swrCtx) return NULL;
        if (swr_init(_swrCtx) < 0) {
            swr_free(&_swrCtx);
            return NULL;
        }
        _swrSrcRate = srcRate;
        _swrSrcChannels = srcChannels;
        _swrSrcFmt = srcFmt;
    }

    int outChannels = (srcChannels == 1) ? 1 : 2;
    int outBytesPerSample = sizeof(float);
    int dstNbSamples = (int)av_rescale_rnd(swr_get_out_samples(_swrCtx, nbSamples),
                                            srcRate, srcRate, AV_ROUND_UP);

    // 分配转换缓冲区
    int dstDataSize = dstNbSamples * outChannels * outBytesPerSample;
    uint8_t *dstData = (uint8_t *)av_malloc(dstDataSize);
    if (!dstData) return NULL;

    uint8_t *dstSlice[1] = { dstData };
    int converted = swr_convert(_swrCtx, dstSlice, dstNbSamples,
                                (const uint8_t **)frame->extended_data, nbSamples);
    if (converted <= 0) {
        av_free(dstData);
        return NULL;
    }

    int actualDataSize = converted * outChannels * outBytesPerSample;

    // 创建 CMSampleBufferRef
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = srcRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mChannelsPerFrame = outChannels;
    asbd.mBitsPerChannel = 32;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = outChannels * outBytesPerSample;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;

    CMFormatDescriptionRef fmtDesc = NULL;
    OSStatus osRet = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &fmtDesc);
    if (osRet != noErr) {
        av_free(dstData);
        return NULL;
    }

    CMBlockBufferRef blockBuffer = NULL;
    osRet = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, dstData, actualDataSize,
                                                kCFAllocatorMalloc, NULL, 0, actualDataSize, 0, &blockBuffer);
    if (osRet != kCMBlockBufferNoErr) {
        CFRelease(fmtDesc);
        return NULL;
    }

    CMSampleBufferRef sampleBuffer = NULL;
    CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid };
    osRet = CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, YES, NULL, NULL,
                                  fmtDesc, converted, 1, &timing, 0, NULL, &sampleBuffer);

    CFRelease(fmtDesc);
    CFRelease(blockBuffer);

    return (osRet == noErr) ? sampleBuffer : NULL;
}

- (void)cleanupVideoConverter {
    if (_swsCtx) {
        sws_freeContext(_swsCtx);
        _swsCtx = NULL;
    }
}

- (void)cleanupAudioConverter {
    if (_swrCtx) {
        swr_free(&_swrCtx);
        _swrCtx = NULL;
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
    err = [self openStreamWithType:AVMEDIA_TYPE_VIDEO error:&errorMsg];
    if (err != 0) {
        [self releaseFFmpegResources];
        return errorMsg;
    }

    // 3. 打开音频流
    err = [self openStreamWithType:AVMEDIA_TYPE_AUDIO error:&errorMsg];
    if (err != 0) {
        [self releaseFFmpegResources];
        return errorMsg;
    }

    // 4. 提取 time_base（初始化内聚，不再分散到 parseThread）
    _video_time_base = self.formatContext->streams[_videoStreamIndex]->time_base;
    _videoTimeBase = av_q2d(self.formatContext->streams[_videoStreamIndex]->time_base);
    _audioTimeBase = av_q2d(self.formatContext->streams[_audioStreamIndex]->time_base);

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

    // 记录容器 start_time（参照 mpv demux_lavf.c:1498-1499）
    if (tempCtx->start_time != AV_NOPTS_VALUE) {
        _startTime = (double)tempCtx->start_time / AV_TIME_BASE;
    } else {
        _startTime = 0.0;
    }

    return 0;
}
#pragma mark - Stream open (统一视频/音频)
- (int)openStreamWithType:(enum AVMediaType)type error:(NSString **)errorMsg {
    const char *typeLabel = (type == AVMEDIA_TYPE_VIDEO) ? "视频" : "音频";

    // 1. 清理旧资源
    if (type == AVMEDIA_TYPE_VIDEO) {
        [self closeVideoStream];
    } else {
        if (_audioCodecContext) { avcodec_free_context(&_audioCodecContext); _audioCodecContext = NULL; }
        self.audioStreamIndex = -1;
    }

    // 2. 查找最佳流
    const AVCodec *codec = NULL;
    int ret = av_find_best_stream(self.formatContext, type, -1, -1, &codec, 0);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"未找到%s流: %@",
                                    typeLabel, [self getFFmpegError:ret]];
        return ret;
    }
    int streamIndex = ret;
    AVStream *stream = self.formatContext->streams[streamIndex];

    // 3. 分配解码器上下文
    AVCodecContext *codecCtx = avcodec_alloc_context3(codec);
    if (!codecCtx) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"无法分配%s解码上下文", typeLabel];
        return AVERROR(ENOMEM);
    }

    // 4. 填充流参数
    ret = avcodec_parameters_to_context(codecCtx, stream->codecpar);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"%s参数同步失败: %@",
                                    typeLabel, [self getFFmpegError:ret]];
        avcodec_free_context(&codecCtx);
        return ret;
    }

    // 5. 视频：尝试 VideoToolbox 硬件加速
    if (type == AVMEDIA_TYPE_VIDEO) {
        int hwRet = [self setupHardwareDecoder:codecCtx];
        if (hwRet < 0) {
            NSLog(@"硬件加速初始化失败，将尝试软件解码: %@", [self getFFmpegError:hwRet]);
        }
    }

    // 6. 打开解码器
    ret = avcodec_open2(codecCtx, codec, NULL);
    if (ret < 0) {
        if (errorMsg) *errorMsg = [NSString stringWithFormat:@"无法打开%s解码器: %@",
                                    typeLabel, [self getFFmpegError:ret]];
        avcodec_free_context(&codecCtx);
        return ret;
    }

    // 7. 赋值
    if (type == AVMEDIA_TYPE_VIDEO) {
        self.videoStreamIndex = streamIndex;
        self.videoCodecContext = codecCtx;
    } else {
        self.audioStreamIndex = streamIndex;
        self.audioCodecContext = codecCtx;
    }
    return 0;
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
#pragma mark - 资源释放
- (void)releaseFFmpegResources {
    NSInteger remaining = atomic_fetch_sub_explicit(&_activeRenderThreads, 1, memory_order_acq_rel) - 1;
    if (remaining > 0) return;

    [self cleanupVideoConverter];
    [self cleanupAudioConverter];

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

@end
