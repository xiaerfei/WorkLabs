/*
 * M0 · 解码 mp4 首帧 → BMP
 * ------------------------------------------------------------
 * 目标：打开 mp4 → 解码第一帧视频 → YUV420P 转 RGB → 写成 BMP。
 * 规则：核心逻辑你自己写。卡住先查 FFmpeg 文档 / 找我要提示，
 *       实在不行才翻 WorkLabs 的 WLMediaSource 对照，看懂后合上、自己默写。
 * 验收：输出 BMP 与 `ffmpeg -i input.mp4 -frames:v 1 ref.png` 肉眼一致（颜色不偏、不分裂）。
 *
 * 编译: make
 * 运行: ./decode_one_frame input.mp4 out.bmp
 *
 * 下面只给「分步路标」（每步用到哪些 API），实现留给你填。
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

/* TODO: 引入 FFmpeg 头文件
 *   #include "libavformat/avformat.h"
 *   #include "libavcodec/avcodec.h"
 *   #include "libavutil/imgutils.h"
 */

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "用法: %s <input.mp4> <out.bmp>\n", argv[0]);
        return 1;
    }
    const char *in_path  = argv[1];
    const char *out_path = argv[2];
    (void)in_path; (void)out_path; /* 实现后删掉这行 */

    /* 步骤 1 · 打开文件 + 读流信息
     *   avformat_open_input() / avformat_find_stream_info()
     *   自查：返回值怎么判错？fmt_ctx 用完谁释放？
     * TODO */

    /* 步骤 2 · 找到视频流，拿它的 codecpar
     *   遍历 fmt_ctx->streams[i]，找 codecpar->codec_type == AVMEDIA_TYPE_VIDEO
     *   记下 video_stream_index
     * TODO */

    /* 步骤 3 · 建解码器上下文并打开
     *   avcodec_find_decoder(codecpar->codec_id)
     *   avcodec_alloc_context3() / avcodec_parameters_to_context() / avcodec_open2()
     * TODO */

    /* 步骤 4 · 读包 + 送解码，拿到「第一帧视频」就停
     *   av_read_frame() → 是视频流？ → avcodec_send_packet() → avcodec_receive_frame()
     *   注意 receive 可能返回 EAGAIN（要继续喂包）
     *   自查：AVPacket / AVFrame 谁是压缩的？
     * TODO */

    /* 步骤 5 · YUV420P → RGB（BT.601）——先自己按公式手写，别用 sws_scale（那是后面的事）
     *   frame->data[0]=Y, data[1]=U, data[2]=V；frame->linesize[] 是每行字节数（可能 > 宽度，有 padding！）
     *   R = Y + 1.402*(V-128)
     *   G = Y - 0.344136*(U-128) - 0.714136*(V-128)
     *   B = Y + 1.772*(U-128)        // 记得 clamp 到 [0,255]
     *   注意：U/V 是 2x2 共享，取样索引要 (row/2)*linesize + (col/2)
     * TODO */

    /* 步骤 6 · 写 BMP（54 字节头 + BGR 像素，每行字节数对齐到 4 的倍数）
     *   BMP 文件格式是 M0 的学习点之一，自己写 write_bmp()。
     *   写完 `open out.bmp` 看效果。
     * TODO */

    /* 步骤 7 · 释放资源（别漏！）
     *   av_frame_free / av_packet_free / avcodec_free_context / avformat_close_input
     * TODO */

    return 0;
}
