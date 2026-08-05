//
//  WLDecoder.hpp
//  OBSLabs
//
//  FFmpeg 解封装 + 解码（Orthodox C++：class 只做代码组织，
//  内存管理、错误处理全部保持 C 写法，不用 STL）。
//
//  与 C 版 wl_decoder.c 的关系：字段与函数一一对应迁移；
//  create 半途失败 → ctor 提前 return（ok_ 留 false），调用方查 Valid()
//  后 delete，清理统一走 dtor（按 NULL 跳过未分配的资源）。
//

#ifndef WLDecoder_hpp
#define WLDecoder_hpp

#include <stdint.h>

extern "C" {                    // FFmpeg 头没有 extern "C" 守卫，C++ 侧必须自己包
#include <libavformat/avformat.h>   // AVFormatContext
#include <libavcodec/avcodec.h>     // AVCodecContext / AVPacket / AVFrame
}

// ---- 公共类型（原 wl_decoder.h，随 C 版删除搬入）----

#define MAX_HW_ACCELS 16

// 专门对接 UI 层的硬件加速列表结构体
typedef struct HWAccelList {
    const char *names[MAX_HW_ACCELS]; // 硬件加速名称字符串，如 "cuda", "videotoolbox"
    int count;                        // 当前系统实际支持的个数
} HWAccelList;

typedef enum {
    WL_READ_VIDEO = 0, ///< 读到视频包，已送入 video_codec_ctx_
    WL_READ_AUDIO,     ///< 读到音频包，已送入 audio_codec_ctx_
    WL_READ_SKIP,      ///< 字幕 / 数据流等，已跳过
    WL_READ_EOF,       ///< 文件读完（已 flush 两个解码器）
    WL_READ_ERROR,     ///< 致命错误
} wl_read_result_t;

typedef enum {
    WL_FRAME_OK = 0,   ///< 成功解出一帧
    WL_FRAME_AGAIN,    ///< 暂无输出，需要继续喂 packet（EAGAIN）—— codec 未结束
    WL_FRAME_EOF,      ///< codec 已排空，不会再有输出（AVERROR_EOF）—— 真正结束
    WL_FRAME_ERROR,    ///< 致命错误
} wl_frame_result_t;

class WLDecoder {
    // 所有成员在构造函数里逐个初始化：new 不像 calloc 会清零，漏一个就是垃圾值
    char *path_;      // strdup 拥有（C 版存裸指针、靠调用方保证生命周期，这里改为拥有）
    char *hw_type_;   // strdup 拥有；NULL = 纯软解

    AVFormatContext *fmt_ctx_;
    int video_index_;  ///< 视频流索引；-1 = 尚未找到
    int audio_index_;  ///< 音频流索引；-1 = 尚未找到

    AVCodecContext *video_codec_ctx_; ///< Video 解码器
    AVCodecContext *audio_codec_ctx_; ///< Audio 解码器
    AVBufferRef    *hw_device_ctx_;   ///< 硬解码设备上下文

    AVPacket *pkt_;         ///< 复用的读包缓冲（避免每次 av_packet_alloc/free）
    AVFrame  *video_frame_; ///< 复用的 receive 帧缓冲（video）
    AVFrame  *audio_frame_; ///< 复用的 receive 帧缓冲（audio）

    bool eof_reached_;   ///< av_read_frame 已返回 EOF
    bool video_drained_; ///< video codec 已 flush 且无更多输出
    bool audio_drained_; ///< audio codec 已 flush 且无更多输出

    bool ok_;            ///< ctor 全链路是否成功（构造函数没有返回值，靠它表达失败）

    // PTS 外推状态（对标 OBS mp_decode_next：best_effort_timestamp 仍是
    // AV_NOPTS_VALUE 时，用上一帧位置 + 估算时长顶上，不把 NOPTS 传给下游）。
    int64_t video_next_pts_ns_;      ///< 下一帧的预测位置
    int64_t video_last_pts_ns_;      ///< 上一帧实际采用的 pts（AV_NOPTS_VALUE=尚无）
    int64_t video_last_duration_ns_; ///< 上次估算出的时长（duration 缺失时的二级兜底，0=尚无）
    int64_t audio_next_pts_ns_;      ///< 下一帧的预测位置（音频时长由 nb_samples 直接算，无需二级兜底）

    // 分步初始化 / 释放（原 wl_decoder.c 的内部辅助函数）
    int  FfmpegInit();        // avformat_open_input
    int  FindStream();        // avformat_find_stream_info
    int  FindVideoStream();   // av_find_best_stream(VIDEO)
    int  CfgdVideo();         // 配置 video decoder（含硬解，失败降级软解）
    int  FindAudioStream();   // av_find_best_stream(AUDIO)
    int  CfgdAudio();         // 配置 audio decoder
    void VideoCodecFree();    // codec ctx + hw device ctx
    void AudioCodecFree();

public:
    /**
     * @param path     媒体文件路径
     * @param hw_type  硬件加速类型名称（如 "videotoolbox"），传 NULL 则纯软解
     */
    WLDecoder(const char *path, const char *hw_type);
    ~WLDecoder();

    bool Valid() const { return ok_; }   // 创建是否成功；false 时唯一合法操作是 delete

    // ---- 细粒度 API（语义与 C 版 wl_decoder_* 一一对应）----

    /**
     * 从文件读一个 AVPacket，按 stream_index 送入对应解码器。
     * EOF 时自动 flush 两个解码器（send NULL）。
     */
    wl_read_result_t Read();

    /**
     * 尝试从 video_codec_ctx_ 接收一帧（非阻塞）。
     * *out_frame 成功时由调用方 av_frame_free。
     */
    wl_frame_result_t ReceiveVideo(AVFrame **out_frame, int64_t *out_pts_ns);

    /**
     * 尝试从 audio_codec_ctx_ 接收一帧（非阻塞）。
     * *out_frame 成功时由调用方 av_frame_free。
     */
    wl_frame_result_t ReceiveAudio(AVFrame **out_frame, int64_t *out_pts_ns);

    /**
     * 查询解码器是否已经排空（两个 codec 都到真 EOF）。
     */
    bool Drained() const;

    /**
     * Seek 前调用：重置解码器内部缓存（avcodec_flush_buffers），丢弃旧帧并使其
     * 重新接收新 packet。同时清掉 eof / drained 标志（seek 可能从 EOF 往回跳）。
     * ⚠️ 这不是 EOF drain —— 绝不能用 send(NULL)，原因见 .cpp 实现里的坑注释。
     */
    void Flush();

    /**
     * 获取当前 FFmpeg 构建版本及当前主机系统真正支持的硬件加速列表
     * @return HWAccelList 结构体（值传递，无需外部手动 free）
     */
    static HWAccelList GetSupportedHwaccels();
};

#endif /* WLDecoder_hpp */
