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

// 💡 关键：强制编译器按照 1 字节对齐，绝不允许在结构体成员之间加入任何 Padding 空隙
#pragma pack(push, 1)

// 14 字节的 BMP 文件头
typedef struct {
    uint16_t bfType;      // 文件类型，固定为 0x4D42 (即字符 'BM')
    uint32_t bfSize;      // 整个文件的大小
    uint16_t bfReserved1; // 保留字，设为 0
    uint16_t bfReserved2; // 保留字，设为 0
    uint32_t bfOffBits;   // 像素数据在文件中的起始偏移量 (54 字节)
} BMPFileHeader;

// 40 字节的 BMP 信息头
typedef struct {
    uint32_t biSize;          // 本结构体的大小 (40 字节)
    int32_t  biWidth;         // 图像宽度
    int32_t  biHeight;        // 图像高度 (负数代表自上而下，避免画面倒立)
    uint16_t biPlanes;        // 通道平面数，固定为 1
    uint16_t biBitCount;      // 每像素位数，24 位真彩色
    uint32_t biCompression;   // 压缩类型，0 代表不压缩
    uint32_t biSizeImage;     // 像素数据总大小
    int32_t  biXPelsPerMeter; // 水平分辨率，设为 0
    int32_t  biYPelsPerMeter; // 垂直分辨率，设为 0
    uint32_t biClrUsed;       // 使用的颜色数，设为 0
    uint32_t biClrImportant;  // 重要颜色数，设为 0
} BMPInfoHeader;

#pragma pack(pop) // 恢复默认的对齐方式


static void print_av_error(const char *prefix, int errnum)
{
    char errbuf[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(errnum, errbuf, sizeof(errbuf));
    fprintf(stderr, "%s: %s\n", prefix, errbuf);
}


int main(int argc, char *argv[])
{
    const char *in_path = "/Users/erfeixia/Downloads/small.mp4";
    const char *out_path = "./decoded.bmp";

    AVFormatContext *fmt_ctx = NULL;
    /* 步骤 1 · 打开文件 + 读流信息
     *   avformat_open_input() / avformat_find_stream_info()
     *   自查：返回值怎么判错？fmt_ctx 用完谁释放？
     **/
    int ret = avformat_open_input(&fmt_ctx, in_path, NULL, NULL);
    if (ret < 0)
    {
        print_av_error("avformat_open_input", ret);
        return 1;
    }
    ret = avformat_find_stream_info(fmt_ctx, NULL);
    if (ret < 0)
    {
        print_av_error("avformat_find_stream_info", ret);
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
        print_av_error("video stream not found", AVERROR(EINVAL));
        return 1;
    }
    /* 步骤 3 · 建解码器上下文并打开
     *   avcodec_find_decoder(codecpar->codec_id)
     *   avcodec_alloc_context3() / avcodec_parameters_to_context() / avcodec_open2()
     * */
    const AVCodec *codec = avcodec_find_decoder(fmt_ctx->streams[video_stream_index]->codecpar->codec_id);
    if (codec == NULL)
    {
        print_av_error("avcodec_find_decoder", AVERROR(EINVAL));
        return 1;
    }
    AVCodecContext *codec_ctx = avcodec_alloc_context3(codec);
    if (codec_ctx == NULL)
    {
        print_av_error("avcodec_alloc_context3", AVERROR(ENOMEM));
        return 1;
    }
    ret = avcodec_parameters_to_context(codec_ctx, fmt_ctx->streams[video_stream_index]->codecpar);
    if (ret < 0)
    {
        print_av_error("avcodec_parameters_to_context", ret);
        return 1;
    }

    ret = avcodec_open2(codec_ctx, codec, NULL);
    if (ret < 0)
    {
        print_av_error("avcodec_open2", ret);
        return 1;
    }
    AVFrame *frame = av_frame_alloc();
    if (frame == NULL)
    {
        print_av_error("av_frame_alloc", AVERROR(ENOMEM));
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
            print_av_error("av_packet_alloc", AVERROR(ENOMEM));
            return 1;
        }
        ret = av_read_frame(fmt_ctx, pkt);
        if (ret < 0)
        {
            print_av_error("av_read_frame", ret);
            return 1;
        }
        if (pkt->stream_index != video_stream_index)
        {
            av_packet_free(&pkt);
            continue;
        }

        ret = avcodec_send_packet(codec_ctx, pkt);
        if (ret < 0)
        {
            print_av_error("avcodec_send_packet", ret);
            av_packet_free(&pkt);
            av_frame_free(&frame);
            return 1;
        }
        ret = avcodec_receive_frame(codec_ctx, frame);
        if (ret == AVERROR(EAGAIN))
        {
            // 需要继续喂包
            av_packet_free(&pkt);
            continue;
        }

        if (ret < 0)
        {
            print_av_error("avcodec_receive_frame", ret);
            av_packet_free(&pkt);
            av_frame_free(&frame);
            return 1;
        }
        av_packet_free(&pkt);
        break;
    }
    // 获取像素格式的名称
    const char *fmt_name = av_get_pix_fmt_name(frame->format);
    printf("当前帧的像素格式是: %s\n", fmt_name);
    if ((frame->format != AV_PIX_FMT_YUV420P) && (frame->format != AV_PIX_FMT_YUV420P10LE)) return 0;

    uint8_t *dataY = frame->data[0];
    uint8_t *dataU = frame->data[1];
    uint8_t *dataV = frame->data[2];

    int linesizeY = frame->linesize[0];
    int linesizeU = frame->linesize[1];
    int linesizeV = frame->linesize[2];
    printf("当前帧的 linesizeY 是: %d, linesizeU 是: %d, linesizeV 是: %d\n", linesizeY, linesizeU, linesizeV);
    int width = frame->width;
    int height = frame->height;
    printf("当前帧的宽度是: %d, 高度是: %d\n", width, height);
    int color_type = 0;
    if (frame->colorspace == AVCOL_SPC_BT709) {
        // 明确使用 BT.709 公式
        color_type = 1;
        printf("当前帧的颜色空间是: BT.709\n");
    } else if (frame->colorspace == AVCOL_SPC_BT470BG || frame->colorspace == AVCOL_SPC_SMPTE170M) {
        // 这两个枚举值对应的就是 BT.601 公式（分别对应 PAL 制和 NTSC 制）
        color_type = 0;
        printf("当前帧的颜色空间是: BT.601\n");
    } else if (frame->colorspace == AVCOL_SPC_UNSPECIFIED) {
        // ⚠️ 未指定：说明视频流里没写元数据，需要启用后面介绍的“盲猜法则”
        color_type = 0;
        printf("当前帧的颜色空间是: 未指定\n");
    }

    /* 步骤 5 · YUV420P → RGB（BT.601）——先自己按公式手写，别用 sws_scale（那是后面的事）
     *   frame->data[0]=Y, data[1]=U, data[2]=V；frame->linesize[] 是每行字节数（可能 > 宽度，有 padding！）
     *   R = Y + 1.402*(V-128)
     *   G = Y - 0.344136*(U-128) - 0.714136*(V-128)
     *   B = Y + 1.772*(U-128)        // 记得 clamp 到 [0,255]
     *   注意：U/V 是 2x2 共享，取样索引要 (row/2)*linesize + (col/2)
     * */
    int rgbSize = frame->width * frame->height * 3;
    uint8_t* rgbBuf = (uint8_t*)malloc(rgbSize);

    for (int y = 0; y < height; y++)
    {
        for (int x = 0; x < width; x++)
        {
            int y_index = y * linesizeY + x;
            int u_index = (y / 2) * linesizeU + (x / 2);
            int v_index = (y / 2) * linesizeV + (x / 2);
            uint8_t Y = dataY[y_index];
            uint8_t U = dataU[u_index];
            uint8_t V = dataV[v_index];
            int r = 0, g = 0, b = 0;
            if (color_type == 1)
            {
                // 更换为 BT.709 矩阵系数
                r = (int)(Y + 1.5748 * (V - 128));
                g = (int)(Y - 0.1873 * (U - 128) - 0.4681 * (V - 128));
                b = (int)(Y + 1.8556 * (U - 128));
            } else {
                r = (int)(Y + 1.402 * (V - 128));
                g = (int)(Y - 0.344136 * (U - 128) - 0.714136 * (V - 128));
                b = (int)(Y + 1.772 * (U - 128));
            }
            // 溢出截断 (Clamp) 确保在 0~255 范围内
            r = r < 0 ? 0 : (r > 255 ? 255 : r);
            g = g < 0 ? 0 : (g > 255 ? 255 : g);
            b = b < 0 ? 0 : (b > 255 ? 255 : b);

            int rgbIdx = (y * width + x) * 3;
            rgbBuf[rgbIdx] = b;
            rgbBuf[rgbIdx + 1] = g;
            rgbBuf[rgbIdx + 2] = r;
        }
    }

    /* 步骤 6 · 写 BMP（54 字节头 + BGR 像素，每行字节数对齐到 4 的倍数）
     *   BMP 文件格式是 M0 的学习点之一，自己写 write_bmp()。
     *   写完 `open out.bmp` 看效果。
     * TODO */

    // 1. 计算像素数据大小 (此处暂假定 width * 3 是 4 的倍数)
    int pixelDataSize = width * height * 3;
    // 填充 BMP 头部信息
    BMPFileHeader fileHeader;
    fileHeader.bfType = 0x4D42; // "BM"
    fileHeader.bfSize = sizeof(BMPFileHeader) + sizeof(BMPInfoHeader) + pixelDataSize;
    fileHeader.bfReserved1 = 0;
    fileHeader.bfReserved2 = 0;
    fileHeader.bfOffBits = sizeof(BMPFileHeader) + sizeof(BMPInfoHeader); // 54
    
    BMPInfoHeader infoHeader;
    infoHeader.biSize = sizeof(BMPInfoHeader);
    infoHeader.biWidth = width;
    infoHeader.biHeight = -height; // 💡 负数代表自上而下，匹配我们顺向循环写入的数据
    infoHeader.biPlanes = 1;
    infoHeader.biBitCount = 24;    // 24位真彩色
    infoHeader.biCompression = 0;   // 不压缩
    infoHeader.biSizeImage = pixelDataSize;
    infoHeader.biXPelsPerMeter = 0;
    infoHeader.biYPelsPerMeter = 0;
    infoHeader.biClrUsed = 0;
    infoHeader.biClrImportant = 0;

// 5. 纯 C 文件写入操作
    FILE* fp = fopen(out_path, "wb"); // "wb" 代表以二进制只写模式打开
    if (fp == NULL) {
        printf("无法打开文件: %s\n", out_path);
        free(rgbBuf);
        return -1;
    }
    // 写入文件头
    fwrite(&fileHeader, sizeof(BMPFileHeader), 1, fp);
    // 写入信息头
    fwrite(&infoHeader, sizeof(BMPInfoHeader), 1, fp);
    // 写入像素数据
    fwrite(rgbBuf, pixelDataSize, 1, fp);
    fclose(fp);
    free(rgbBuf);
    printf("BMP 文件已写入: %s\n", out_path);
    /* 步骤 8 · 释放资源（别漏！）
     *   av_frame_free / av_packet_free / avcodec_free_context / avformat_close_input
     * */
    av_frame_free(&frame);
    avcodec_free_context(&codec_ctx);
    avformat_close_input(&fmt_ctx);
    return 0;
}
