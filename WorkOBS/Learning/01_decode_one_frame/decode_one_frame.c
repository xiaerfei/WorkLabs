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

static int write2file(const char *out_path, void *buffer, int size, int width, int height) 
{
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
        free(buffer);
        return -1;
    }

    // 写入文件头
    fwrite(&fileHeader, sizeof(BMPFileHeader), 1, fp);
    // 写入信息头
    fwrite(&infoHeader, sizeof(BMPInfoHeader), 1, fp);
    // 写入像素数据
    fwrite(buffer, pixelDataSize, 1, fp);
    fclose(fp);
    printf("BMP 文件已写入: %s\n", out_path);
    return 0;
}

static void handle_yuv420p(AVFrame *frame, const char *out_path) 
{
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

    write2file(out_path, rgbBuf, rgbSize, width, height);
    free(rgbBuf);
}

static void handle_yuv420p_10le(AVFrame *frame, const char *out_path) 
{
    // 💡 1. 关键：将指针强转为 uint16_t*，因为 10-bit 格式每个分量占 2 字节
    uint16_t *dataY_10 = (uint16_t*)frame->data[0];
    uint16_t *dataU_10 = (uint16_t*)frame->data[1];
    uint16_t *dataV_10 = (uint16_t*)frame->data[2];

    // 💡 2. 关键：linesize 是字节数。转成 uint16_t 后，每行的“元素个数”要除以 2！
    int linesizeY = frame->linesize[0] / 2;
    int linesizeU = frame->linesize[1] / 2;
    int linesizeV = frame->linesize[2] / 2;

    printf("当前帧的 linesizeY 是: %d, linesizeU 是: %d, linesizeV 是: %d\n", linesizeY, linesizeU, linesizeV);
    int width = frame->width;
    int height = frame->height;
    printf("当前帧的宽度是: %d, 高度是: %d\n", width, height);
    int rgbSize = frame->width * frame->height * 3;
    uint8_t* rgbBuf = (uint8_t*)malloc(rgbSize);

    for (int y = 0; y < height; y++)
    {
        for (int x = 0; x < width; x++)
        {
            // 使用修正后的 uint16_t 元素步长寻址
            int y_index = y * linesizeY + x;
            int uvIdx   = (y / 2) * linesizeU + (x / 2);
            // 此时读出来的是 0 ~ 1023 之间的数字
            uint16_t Y = dataY_10[y_index];
            uint16_t U = dataU_10[uvIdx];
            uint16_t V = dataV_10[uvIdx];
            // 💡 3. BT.709 10-bit Limited Range 标准转换公式
            // 10-bit 的 Y 减去 64 (即 16<<2)，U/V 减去 512 (即 128<<2)
            // 算出来的结果会很大，最后要整体右移 2 位（除以 4）拉高到 8 位 RGB 空间
            int r_val = (int)(1.1644 * (Y - 64) + 1.7927 * (V - 512)) >> 2;
            int g_val = (int)(1.1644 * (Y - 64) - 0.2132 * (U - 512) - 0.5329 * (V - 512)) >> 2;
            int b_val = (int)(1.1644 * (Y - 64) + 2.1124 * (U - 512)) >> 2;
            // 💡 4. 严格 Clamp 到 8-bit BMP 要求的 0 ~ 255
            r_val = r_val < 0 ? 0 : (r_val > 255 ? 255 : r_val);
            g_val = g_val < 0 ? 0 : (g_val > 255 ? 255 : g_val);
            b_val = b_val < 0 ? 0 : (b_val > 255 ? 255 : b_val);

            // 写入你的 24 位 BMP 缓冲区
            int rgbIdx = (y * width + x) * 3;
            rgbBuf[rgbIdx + 0] = (uint8_t)b_val; // B
            rgbBuf[rgbIdx + 1] = (uint8_t)g_val; // G
            rgbBuf[rgbIdx + 2] = (uint8_t)r_val; // R
        }
    }
    write2file(out_path, rgbBuf, rgbSize, width, height);
    free(rgbBuf);
}

int main(int argc, char *argv[])
{
    printf ("v = %s\n", argv[1]);
    const char *in_path = "./small10b.mp4";
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
    if (frame->format == AV_PIX_FMT_YUV420P) {
        handle_yuv420p(frame, out_path);
    } else if (frame->format == AV_PIX_FMT_YUV420P10LE) {
        handle_yuv420p_10le(frame, out_path);
    } else {
        return 0;
    }
    /* 步骤 8 · 释放资源（别漏！）
     *   av_frame_free / av_packet_free / avcodec_free_context / avformat_close_input
     * */
    av_frame_free(&frame);
    avcodec_free_context(&codec_ctx);
    avformat_close_input(&fmt_ctx);
    return 0;
}