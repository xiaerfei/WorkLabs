//
//  WLEncodedPacket.h
//  WorkLabs
//
//  共享编码器（WLEncoder）的输出单元：一个编码后数据包 + 一份流格式快照。
//  设计为可被多个 muxer（mp4 / flv）跨 queue 各自持有的不可变 OC 对象 —— 编一次、分发多路。
//
//  · WLEncodedPacket：持有 av_packet_clone 出来的 AVPacket，pts/dts 已统一为微秒
//    （AV_TIME_BASE_Q）。ARC 引用计数 + AVBufferRef 原子引用计数 → 跨 queue 共享安全；
//    最后一个 release 时 dealloc 释放底层 AVPacket。
//  · WLStreamFormat：编码器首帧后对 video(+可选 audio) codecpar 的深拷贝（含 extradata /
//    SPS·PPS·AudioSpecificConfig）。随每个包传给 muxer 建流，使 muxer 永不跨线程读编码器上下文。
//

#import <Foundation/Foundation.h>

struct AVPacket;
struct AVCodecContext;
struct AVCodecParameters;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 流格式快照（不可变）

@interface WLStreamFormat : NSObject

// 由编码器在其 queue 上、首个视频包产生后调用（此时 videotoolbox extradata 已就绪）。
// 深拷贝 vctx 的 codecpar；actx 为 NULL 时表示纯视频。vctx 为空则返回 nil。
- (nullable instancetype)initWithVideoCodecContext:(const struct AVCodecContext *)vctx
                                 audioCodecContext:(nullable const struct AVCodecContext *)actx;

@property (nonatomic, readonly) BOOL hasAudio;

// 把快照拷入目标流的 codecpar（muxer 建流时调用）。成功返回 YES；无音频时 copyAudio… 返回 NO。
- (BOOL)copyVideoParametersTo:(struct AVCodecParameters *)dst;
- (BOOL)copyAudioParametersTo:(struct AVCodecParameters *)dst;

@end

#pragma mark - 编码后数据包

@interface WLEncodedPacket : NSObject

// 内部 av_packet_clone(src)（引用计数共享底层压缩数据，不深拷贝）。
// 约定 src 的 pts/dts 已 rescale 到微秒（AV_TIME_BASE_Q）。format 为同一编码会话共享的格式快照。
- (nullable instancetype)initWithPacket:(struct AVPacket *)src
                                isVideo:(BOOL)isVideo
                                 format:(WLStreamFormat *)format;

@property (nonatomic, readonly) BOOL isVideo;
@property (nonatomic, readonly) BOOL isKeyframe;
@property (nonatomic, readonly) int64_t ptsUs;          // 微秒时间戳（= packet.pts，时间基 AV_TIME_BASE_Q）
@property (nonatomic, readonly) WLStreamFormat *format;

// 内部 AVPacket（只读引用，时间基 AV_TIME_BASE_Q）。muxer 写入前必须自行 av_packet_clone：
// av_interleaved_write_frame 无论成功失败都会 unref 传入包，直接用会让其它 muxer 拿到空 buffer。
- (struct AVPacket *)packet;

@end

NS_ASSUME_NONNULL_END
