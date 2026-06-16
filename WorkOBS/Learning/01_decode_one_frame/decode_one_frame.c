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

#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/imgutils.h"

int main(int argc, char *argv[])
{
    const char *in_path = "/Users/erfeixia/Downloads/small.mp4";
    const char *out_path = "decoded.bmp";

    AVFormatContext *fmt_ctx = NULL;
    /* 步骤 1 · 打开文件 + 读流信息
     *   avformat_open_input() / avformat_find_stream_info()
     *   自查：返回值怎么判错？fmt_ctx 用完谁释放？
     **/
    avformat_open_input(&fmt_ctx, in_path, NULL, NULL);
    if (fmt_ctx == NULL)
    {
        fprintf(stderr, "avformat_open_input() failed\n");
        return 1;
    }
    int ret = avformat_find_stream_info(fmt_ctx, NULL);
    if (ret < 0)
    {
        fprintf(stderr, "avformat_find_stream_info() failed\n");
        return 1;
    }
    /* 步骤 2 · 找到视频流，拿它的 codecpar
     *   遍历 fmt_ctx->streams[i]，找 codecpar->codec_type == AVMEDIA_TYPE_VIDEO
     *   记下 video_stream_index
     * */
    int video_stream_index = -1;
    for (int i = 0; i < fmt_ctx->nb_streams; i++)
    {
        if (fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO)
        {
            video_stream_index = i;
            break;
        }
    }
    if (video_stream_index < 0)
    {
        fprintf(stderr, "video stream not found\n");
        return 1;
    }
    /* 步骤 3 · 建解码器上下文并打开
     *   avcodec_find_decoder(codecpar->codec_id)
     *   avcodec_alloc_context3() / avcodec_parameters_to_context() / avcodec_open2()
     * */
    AVCodec *codec = avcodec_find_decoder(fmt_ctx->streams[video_stream_index]->codecpar->codec_id);
    if (codec == NULL)
    {
        fprintf(stderr, "avcodec_find_decoder() failed\n");
        return 1;
    }
    AVCodecContext *codec_ctx = avcodec_alloc_context3(codec);
    if (codec_ctx == NULL)
    {
        fprintf(stderr, "avcodec_alloc_context3() failed\n");
        return 1;
    }
    ret = avcodec_parameters_to_context(codec_ctx, fmt_ctx->streams[video_stream_index]->codecpar);
    if (ret < 0)
    {
        fprintf(stderr, "avcodec_parameters_to_context() failed\n");
        return 1;
    }

    ret = avcodec_open2(codec_ctx, codec, NULL);
    if (ret < 0)
    {
        fprintf(stderr, "avcodec_open2() failed\n");
        return 1;
    }
    AVFrame *frame = av_frame_alloc();
    if (frame == NULL)
    {
        fprintf(stderr, "av_frame_alloc() failed\n");
        return 1;
    }
    /* 步骤 4 · 读包 + 送解码，拿到「第一帧视频」就停
     *   av_read_frame() → 是视频流？ → avcodec_send_packet() → avcodec_receive_frame()
     *   注意 receive 可能返回 EAGAIN（要继续喂包）
     *   自查：AVPacket / AVFrame 谁是压缩的？
     * */
    while (1)
    {
        AVPacket *pkt = av_packet_alloc();
        if (pkt == NULL)
        {
            fprintf(stderr, "av_packet_alloc() failed\n");
            return 1;
        }
        ret = av_read_frame(fmt_ctx, pkt);
        if (ret < 0)
        {
            fprintf(stderr, "av_read_frame() failed\n");
            return 1;
        }
        if (pkt->stream_index != video_stream_index)
        {
            fprintf(stderr, "pkt stream index not video stream index\n");
            av_packet_free(&pkt);
            return 1;
        }

        ret = avcodec_send_packet(codec_ctx, pkt);
        if (ret < 0)
        {
            fprintf(stderr, "avcodec_send_packet() failed\n");
            av_packet_free(&pkt);
            av_frame_free(&frame);
            return 1;
        }
        ret = avcodec_receive_frame(codec_ctx, frame);
        if (ret < 0)
        {
            char errbuf[1024];
            av_strerror(ret, errbuf, sizeof(errbuf));
            fprintf(stderr, "avcodec_receive_frame() failed: %s\n", errbuf);
            av_packet_free(&pkt);
            av_frame_free(&frame);
            return 1;
        }
        break;
        av_packet_free(&pkt);
    }

    uint8_t *data = frame->data[0];
    int linesize = frame->linesize[0];
    int width = frame->width;
    int height = frame->height;
    int size = width * height * 3 / 2;

    printf("size = %d, width = %d, height = %d\n", size, width, height);


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
