# 视音频数据处理：RGB、YUV像素数据处理

本文记录 RGB/YUV 视频像素数据的处理方法。视频像素数据在视频播放器的解码流程中的位置如下图所示。

![解码流程](https://user-images.githubusercontent.com/87458342/127621050-4f585dde-fea8-4524-a964-c4a7da92c942.png)

## 目录

- [一、YUV 像素数据处理](#一yuv-像素数据处理)
  - [1.1 分离 YUV420P 的 Y、U、V 分量](#11-分离-yuv420p-像素数据中的-yuv-分量)
  - [1.2 分离 YUV444P 的 Y、U、V 分量](#12-分离-yuv444p-像素数据中的-yuv-分量)
  - [1.3 YUV420P 转灰度图](#13-将-yuv420p-像素数据去掉颜色变成灰度图)
  - [1.4 YUV420P 亮度减半](#14-将-yuv420p-像素数据的亮度减半)
  - [1.5 YUV420P 添加边框](#15-将-yuv420p-像素数据的周围加上边框)
  - [1.6 生成 YUV420P 灰阶测试图](#16-生成-yuv420p-格式的灰阶测试图)
  - [1.7 计算两个 YUV420P 的 PSNR](#17-计算两个-yuv420p-像素数据的-psnr)
- [二、RGB 像素数据处理](#二rgb-像素数据处理)
  - [2.1 分离 RGB24 的 R、G、B 分量](#21-分离-rgb24-像素数据中的-rgb-分量)
  - [2.2 RGB24 封装为 BMP 图像](#22-将-rgb24-格式像素数据封装为-bmp-图像)
- [附录：YUV 格式基础](#附录yuv-格式基础)
  - [A.1 I420、NV12、NV21 的区别](#a1-i420nv12nv21-的区别)
  - [A.2 其他常见 YUV 格式](#a2-其他常见-yuv-格式)
  - [A.3 色度抽样详解](#a3-色度抽样chroma-subsampling详解)
  - [A.4 Stride（跨距/行对齐）](#a4-stride跨距行对齐)
  - [A.5 颜色空间与转换矩阵](#a5-颜色空间与转换矩阵bt601--bt709--bt2020)
  - [A.6 数值范围（Full Range vs Limited Range）](#a6-数值范围full-range-vs-limited-range)
  - [A.7 采样中心对齐（Chroma Siting）](#a7-采样中心对齐chroma-siting)

---

## 一、YUV 像素数据处理

### 1.1 分离 YUV420P 像素数据中的 Y、U、V 分量

将 YUV420P 数据中的 Y、U、V 三个分量分离并保存为三个独立文件。

```c
/**
 * Split Y, U, V planes in YUV420P file.
 * @param url  Location of Input YUV file.
 * @param w    Width of Input YUV file.
 * @param h    Height of Input YUV file.
 * @param num  Number of frames to process.
 */
int simplest_yuv420_split(char *url, int w, int h, int num) {
    FILE *fp  = fopen(url, "rb+");
    FILE *fp1 = fopen("output_420_y.y", "wb+");
    FILE *fp2 = fopen("output_420_u.y", "wb+");
    FILE *fp3 = fopen("output_420_v.y", "wb+");

    unsigned char *pic = (unsigned char *)malloc(w * h * 3 / 2);

    for (int i = 0; i < num; i++) {
        fread(pic, 1, w * h * 3 / 2, fp);
        // Y
        fwrite(pic, 1, w * h, fp1);
        // U
        fwrite(pic + w * h, 1, w * h / 4, fp2);
        // V
        fwrite(pic + w * h * 5 / 4, 1, w * h / 4, fp3);
    }

    free(pic);
    fclose(fp);
    fclose(fp1);
    fclose(fp2);
    fclose(fp3);

    return 0;
}
```

调用方式：

```c
simplest_yuv420_split("lena_256x256_yuv420p.yuv", 256, 256, 1);
```

**内存布局**：若视频帧宽高为 `w` 和 `h`，一帧 YUV420P 共占用 `w * h * 3 / 2` 字节。其中前 `w * h` 字节存储 Y，接着 `w * h / 4` 字节存储 U，最后 `w * h / 4` 字节存储 V。

> 注：本文像素采样位数均为 8 bit（1 字节）。

运行后将 `lena_256x256_yuv420p.yuv`（256×256）分离为三个文件：

| 文件 | 内容 | 分辨率 |
|------|------|--------|
| `output_420_y.y` | 纯 Y 数据 | 256×256 |
| `output_420_u.y` | 纯 U 数据 | 128×128 |
| `output_420_v.y` | 纯 V 数据 | 128×128 |

**输入原图：**

![lena_256x256_yuv420p.yuv](https://user-images.githubusercontent.com/87458342/127621291-777790a8-39c9-4b15-9c99-0352dd6d4262.png)

**输出结果**（U、V 分量在 YUV 播放器中按 Y 分量方式播放）：

![output_420_y.y](https://user-images.githubusercontent.com/87458342/127621328-1249e21d-bf32-4aba-a450-5e4c4bca70ec.png)

![output_420_u.y / output_420_v.y](https://user-images.githubusercontent.com/87458342/127621359-f290504c-56c8-4bc9-8be9-09abd63665fa.png)

---

### 1.2 分离 YUV444P 像素数据中的 Y、U、V 分量

将 YUV444P 数据中的 Y、U、V 三个分量分离并保存为三个独立文件。

```c
/**
 * Split Y, U, V planes in YUV444P file.
 * @param url  Location of YUV file.
 * @param w    Width of Input YUV file.
 * @param h    Height of Input YUV file.
 * @param num  Number of frames to process.
 */
int simplest_yuv444_split(char *url, int w, int h, int num) {
    FILE *fp  = fopen(url, "rb+");
    FILE *fp1 = fopen("output_444_y.y", "wb+");
    FILE *fp2 = fopen("output_444_u.y", "wb+");
    FILE *fp3 = fopen("output_444_v.y", "wb+");
    unsigned char *pic = (unsigned char *)malloc(w * h * 3);

    for (int i = 0; i < num; i++) {
        fread(pic, 1, w * h * 3, fp);
        // Y
        fwrite(pic, 1, w * h, fp1);
        // U
        fwrite(pic + w * h, 1, w * h, fp2);
        // V
        fwrite(pic + w * h * 2, 1, w * h, fp3);
    }

    free(pic);
    fclose(fp);
    fclose(fp1);
    fclose(fp2);
    fclose(fp3);

    return 0;
}
```

调用方式：

```c
simplest_yuv444_split("lena_256x256_yuv444p.yuv", 256, 256, 1);
```

**内存布局**：一帧 YUV444P 共占用 `w * h * 3` 字节。Y、U、V 各占 `w * h` 字节，依次排列。

运行后输出三个文件，分辨率均为 256×256。

**输入原图：**

![lena_256x256_yuv444p.yuv](https://user-images.githubusercontent.com/87458342/127621621-55a4cdf2-96c0-40dc-8489-1753bb60630f.png)

**输出结果：**

![output_444_y.y](https://user-images.githubusercontent.com/87458342/127621903-97a52af8-98fa-4019-85e1-5bf8501d60d7.png)

![output_444_u.y](https://user-images.githubusercontent.com/87458342/127621932-b5ab3d43-9b17-4de3-82ba-bd877e87f7c4.png)

![output_444_v.y](https://user-images.githubusercontent.com/87458342/127621959-a5f51091-a3dc-4a67-ad40-a127774c56b9.png)

---

### 1.3 将 YUV420P 像素数据去掉颜色（变成灰度图）

将 YUV420P 格式的彩色图像转为灰度图。

```c
/**
 * Convert YUV420P file to gray picture
 * @param url  Location of Input YUV file.
 * @param w    Width of Input YUV file.
 * @param h    Height of Input YUV file.
 * @param num  Number of frames to process.
 */
int simplest_yuv420_gray(char *url, int w, int h, int num) {
    FILE *fp  = fopen(url, "rb+");
    FILE *fp1 = fopen("output_gray.yuv", "wb+");
    unsigned char *pic = (unsigned char *)malloc(w * h * 3 / 2);

    for (int i = 0; i < num; i++) {
        fread(pic, 1, w * h * 3 / 2, fp);
        // Gray
        memset(pic + w * h, 128, w * h / 2);
        fwrite(pic, 1, w * h * 3 / 2, fp1);
    }

    free(pic);
    fclose(fp);
    fclose(fp1);
    return 0;
}
```

调用方式：

```c
simplest_yuv420_gray("lena_256x256_yuv420p.yuv", 256, 256, 1);
```

**原理**：将 U、V 分量全部置为 128 即可得到灰度图。U、V 是经过偏置处理的色度分量——偏置前取值范围为 -128~127（无色对应 0），偏置后变为 0~255（无色对应 128）。

**输入原图：**

![lena_256x256_yuv420p.yuv](https://user-images.githubusercontent.com/87458342/127622102-279186b3-7fdb-4b8f-b2ec-cee3e7f2cead.png)

**处理结果：**

![output_gray.yuv](https://user-images.githubusercontent.com/87458342/127622125-a7885fa4-d55c-4c2d-900b-a09a0f3243ce.png)

---

### 1.4 将 YUV420P 像素数据的亮度减半

将 Y 分量数值减半，降低图像亮度。

```c
/**
 * Halve Y value of YUV420P file
 * @param url  Location of Input YUV file.
 * @param w    Width of Input YUV file.
 * @param h    Height of Input YUV file.
 * @param num  Number of frames to process.
 */
int simplest_yuv420_halfy(char *url, int w, int h, int num) {
    FILE *fp  = fopen(url, "rb+");
    FILE *fp1 = fopen("output_half.yuv", "wb+");

    unsigned char *pic = (unsigned char *)malloc(w * h * 3 / 2);

    for (int i = 0; i < num; i++) {
        fread(pic, 1, w * h * 3 / 2, fp);
        // Half
        for (int j = 0; j < w * h; j++) {
            unsigned char temp = pic[j] / 2;
            pic[j] = temp;
        }
        fwrite(pic, 1, w * h * 3 / 2, fp1);
    }

    free(pic);
    fclose(fp);
    fclose(fp1);

    return 0;
}
```

调用方式：

```c
simplest_yuv420_halfy("lena_256x256_yuv420p.yuv", 256, 256, 1);
```

**原理**：遍历每个像素的 Y 分量（`unsigned char`，取值范围 0~255），除以 2 即可。

**输入原图：**

![lena_256x256_yuv420p.yuv](https://user-images.githubusercontent.com/87458342/127622252-28e70181-facf-4e78-a68f-fa2ee50b52af.png)

**处理结果：**

![output_half.yuv](https://user-images.githubusercontent.com/87458342/127622274-e2c8fed6-2d08-4465-8d93-d0b156a30cc4.png)

---

### 1.5 将 YUV420P 像素数据的周围加上边框

修改图像边缘区域的 Y 分量，添加边框效果。

```c
/**
 * Add border for YUV420P file
 * @param url     Location of Input YUV file.
 * @param w       Width of Input YUV file.
 * @param h       Height of Input YUV file.
 * @param border  Width of Border.
 * @param num     Number of frames to process.
 */
int simplest_yuv420_border(char *url, int w, int h, int border, int num) {
    FILE *fp  = fopen(url, "rb+");
    FILE *fp1 = fopen("output_border.yuv", "wb+");

    unsigned char *pic = (unsigned char *)malloc(w * h * 3 / 2);

    for (int i = 0; i < num; i++) {
        fread(pic, 1, w * h * 3 / 2, fp);
        // Y
        for (int j = 0; j < h; j++) {
            for (int k = 0; k < w; k++) {
                if (k < border || k > (w - border) || j < border || j > (h - border)) {
                    pic[j * w + k] = 255;
                    // pic[j*w+k] = 0;  // 黑色边框
                }
            }
        }
        fwrite(pic, 1, w * h * 3 / 2, fp1);
    }

    free(pic);
    fclose(fp);
    fclose(fp1);

    return 0;
}
```

调用方式：

```c
simplest_yuv420_border("lena_256x256_yuv420p.yuv", 256, 256, 20, 1);
```

**原理**：将距离图像边缘 `border` 像素范围内的 Y 分量设为亮度最大值 255（白色边框），也可设为 0（黑色边框）。

**输入原图：**

![lena_256x256_yuv420p.yuv](https://user-images.githubusercontent.com/87458342/127622416-47a62f52-3000-4e60-bf77-b15a2920b1c4.png)

**处理结果：**

![output_border.yuv](https://user-images.githubusercontent.com/87458342/127622443-48b4a985-22b4-40f9-88a4-dfd7bf976b33.png)

---

### 1.6 生成 YUV420P 格式的灰阶测试图

生成一张 YUV420P 格式的灰阶测试图。

```c
/**
 * Generate YUV420P gray scale bar.
 * @param width    Width of Output YUV file.
 * @param height   Height of Output YUV file.
 * @param ymin     Min value of Y
 * @param ymax     Max value of Y
 * @param barnum   Number of bars
 * @param url_out  Location of Output YUV file.
 */
int simplest_yuv420_graybar(int width, int height, int ymin, int ymax, int barnum, char *url_out) {
    int barwidth;
    float lum_inc;
    unsigned char lum_temp;
    int uv_width, uv_height;
    FILE *fp = NULL;
    unsigned char *data_y = NULL;
    unsigned char *data_u = NULL;
    unsigned char *data_v = NULL;
    int t = 0, i = 0, j = 0;

    barwidth = width / barnum;
    lum_inc = ((float)(ymax - ymin)) / ((float)(barnum - 1));
    uv_width = width / 2;
    uv_height = height / 2;

    data_y = (unsigned char *)malloc(width * height);
    data_u = (unsigned char *)malloc(uv_width * uv_height);
    data_v = (unsigned char *)malloc(uv_width * uv_height);

    if ((fp = fopen(url_out, "wb+")) == NULL) {
        printf("Error: Cannot create file!");
        return -1;
    }

    // Output Info
    printf("Y, U, V value from picture's left to right:\n");
    for (t = 0; t < (width / barwidth); t++) {
        lum_temp = ymin + (char)(t * lum_inc);
        printf("%3d, 128, 128\n", lum_temp);
    }
    // Gen Data
    for (j = 0; j < height; j++) {
        for (i = 0; i < width; i++) {
            t = i / barwidth;
            lum_temp = ymin + (char)(t * lum_inc);
            data_y[j * width + i] = lum_temp;
        }
    }
    for (j = 0; j < uv_height; j++) {
        for (i = 0; i < uv_width; i++) {
            data_u[j * uv_width + i] = 128;
        }
    }
    for (j = 0; j < uv_height; j++) {
        for (i = 0; i < uv_width; i++) {
            data_v[j * uv_width + i] = 128;
        }
    }
    fwrite(data_y, width * height, 1, fp);
    fwrite(data_u, uv_width * uv_height, 1, fp);
    fwrite(data_v, uv_width * uv_height, 1, fp);
    fclose(fp);
    free(data_y);
    free(data_u);
    free(data_v);
    return 0;
}
```

调用方式：

```c
simplest_yuv420_graybar(640, 360, 0, 255, 10, "graybar_640x360.yuv");
```

**原理**：通过 `ymin`、`ymax`、`barnum` 确定每个灰度条的 Y 值，结合图像宽高计算每个灰度条的宽度。U、V 固定为 128（无色）。

运行后生成 640×360、10 个灰度条（Y 从 0 到 255 均匀分布）的测试图：

![graybar_640x360.yuv](https://user-images.githubusercontent.com/87458342/127622590-5eb17424-6d52-4b12-86ca-6ed11f804b31.png)

从左到右各灰度条的 Y、U、V 取值：

![灰度条数值](https://user-images.githubusercontent.com/87458342/127622624-41c06324-800c-48f1-97f7-c323fd119d21.png)

---

### 1.7 计算两个 YUV420P 像素数据的 PSNR

PSNR（Peak Signal-to-Noise Ratio）是最基本的视频质量评价指标。本函数对比两张 YUV 图像亮度分量 Y 的 PSNR。

```c
/**
 * Calculate PSNR between 2 YUV420P file
 * @param url1  Location of first Input YUV file.
 * @param url2  Location of another Input YUV file.
 * @param w     Width of Input YUV file.
 * @param h     Height of Input YUV file.
 * @param num   Number of frames to process.
 */
int simplest_yuv420_psnr(char *url1, char *url2, int w, int h, int num) {
    FILE *fp1 = fopen(url1, "rb+");
    FILE *fp2 = fopen(url2, "rb+");
    unsigned char *pic1 = (unsigned char *)malloc(w * h);
    unsigned char *pic2 = (unsigned char *)malloc(w * h);

    for (int i = 0; i < num; i++) {
        fread(pic1, 1, w * h, fp1);
        fread(pic2, 1, w * h, fp2);

        double mse_sum = 0, mse = 0, psnr = 0;
        for (int j = 0; j < w * h; j++) {
            mse_sum += pow((double)(pic1[j] - pic2[j]), 2);
        }
        mse = mse_sum / (w * h);
        psnr = 10 * log10(255.0 * 255.0 / mse);
        printf("%5.3f\n", psnr);

        fseek(fp1, w * h / 2, SEEK_CUR);
        fseek(fp2, w * h / 2, SEEK_CUR);
    }

    free(pic1);
    free(pic2);
    fclose(fp1);
    fclose(fp2);
    return 0;
}
```

调用方式：

```c
simplest_yuv420_psnr("lena_256x256_yuv420p.yuv", "lena_distort_256x256_yuv420p.yuv", 256, 256, 1);
```

**计算公式**（8 bit 量化）：

```
PSNR = 10 × log₁₀(255² / MSE)

MSE = (1 / (M × N)) × ΣᵢΣⱼ (xᵢⱼ - yᵢⱼ)²
```

其中 M、N 为图像宽高，xᵢⱼ、yᵢⱼ 分别为两张图像对应像素值。

PSNR 通常用于评价受损图像质量，取值一般在 20~50 之间，越高表示两图越接近、受损图像质量越好。

**对比图**（左：原始图像，右：受损图像）：

![原始 vs 受损](https://user-images.githubusercontent.com/87458342/127622860-c25f73ad-a95b-4e77-b4aa-5d8389d58524.png)

计算结果：PSNR = **26.693**。

---

## 二、RGB 像素数据处理

### 2.1 分离 RGB24 像素数据中的 R、G、B 分量

将 RGB24 数据中的 R、G、B 三个分量分离并保存为三个独立文件。

```c
/**
 * Split R, G, B planes in RGB24 file.
 * @param url  Location of Input RGB file.
 * @param w    Width of Input RGB file.
 * @param h    Height of Input RGB file.
 * @param num  Number of frames to process.
 */
int simplest_rgb24_split(char *url, int w, int h, int num) {
    FILE *fp  = fopen(url, "rb+");
    FILE *fp1 = fopen("output_r.y", "wb+");
    FILE *fp2 = fopen("output_g.y", "wb+");
    FILE *fp3 = fopen("output_b.y", "wb+");

    unsigned char *pic = (unsigned char *)malloc(w * h * 3);

    for (int i = 0; i < num; i++) {
        fread(pic, 1, w * h * 3, fp);

        for (int j = 0; j < w * h * 3; j = j + 3) {
            // R
            fwrite(pic + j, 1, 1, fp1);
            // G
            fwrite(pic + j + 1, 1, 1, fp2);
            // B
            fwrite(pic + j + 2, 1, 1, fp3);
        }
    }

    free(pic);
    fclose(fp);
    fclose(fp1);
    fclose(fp2);
    fclose(fp3);

    return 0;
}
```

调用方式：

```c
simplest_rgb24_split("cie1931_500x500.rgb", 500, 500, 1);
```

**存储方式对比**：

| 格式 | 存储方式 | 说明 |
|------|----------|------|
| YUV420P / YUV444P | Planar（平面） | 各分量分开连续存储 |
| RGB24 | Packed（打包） | 各分量交错存储：R₁G₁B₁ R₂G₂B₂ ... |

一帧 `w × h` 的 RGB24 图像共占用 `w * h * 3` 字节，按像素顺序依次存储每个像素的 R、G、B。

运行后输出三个文件，分辨率均为 500×500。

**输入原图**（CIE 1931 色度图：右下红、上方绿、左下蓝）：

![cie1931_500x500.rgb](https://user-images.githubusercontent.com/87458342/127623095-009a68ec-8379-40bc-916e-94dd6c734390.png)

**输出结果：**

![output_r.y](https://user-images.githubusercontent.com/87458342/127623123-cd9af91a-4e59-4ef5-bf1a-8b2faa0afc72.png)

![output_g.y](https://user-images.githubusercontent.com/87458342/127623145-0eb999d2-08cb-4489-a542-1b91fdcebaac.png)

![output_b.y](https://user-images.githubusercontent.com/87458342/127623175-8b4d140b-a758-4ad0-b998-7040d22e2f19.png)

---

### 2.2 将 RGB24 格式像素数据封装为 BMP 图像

BMP 图像内部存储的即为 RGB 数据。本函数将 RGB 像素数据封装为 BMP 文件。

```c
/**
 * Convert RGB24 file to BMP file
 * @param rgb24path  Location of input RGB file.
 * @param width      Width of input RGB file.
 * @param height     Height of input RGB file.
 * @param bmppath    Location of Output BMP file.
 */
int simplest_rgb24_to_bmp(const char *rgb24path, int width, int height, const char *bmppath) {
    typedef struct {
        long imageSize;
        long blank;
        long startPosition;
    } BmpHead;

    typedef struct {
        long Length;
        long width;
        long height;
        unsigned short colorPlane;
        unsigned short bitColor;
        long zipFormat;
        long realSize;
        long xPels;
        long yPels;
        long colorUse;
        long colorImportant;
    } InfoHead;

    int i = 0, j = 0;
    BmpHead m_BMPHeader = {0};
    InfoHead m_BMPInfoHeader = {0};
    char bfType[2] = {'B', 'M'};
    int header_size = sizeof(bfType) + sizeof(BmpHead) + sizeof(InfoHead);
    unsigned char *rgb24_buffer = NULL;
    FILE *fp_rgb24 = NULL, *fp_bmp = NULL;

    if ((fp_rgb24 = fopen(rgb24path, "rb")) == NULL) {
        printf("Error: Cannot open input RGB24 file.\n");
        return -1;
    }
    if ((fp_bmp = fopen(bmppath, "wb")) == NULL) {
        printf("Error: Cannot open output BMP file.\n");
        return -1;
    }

    rgb24_buffer = (unsigned char *)malloc(width * height * 3);
    fread(rgb24_buffer, 1, width * height * 3, fp_rgb24);

    m_BMPHeader.imageSize = 3 * width * height + header_size;
    m_BMPHeader.startPosition = header_size;

    m_BMPInfoHeader.Length = sizeof(InfoHead);
    m_BMPInfoHeader.width = width;
    // BMP stores pixel data from bottom to top (opposite Y-axis direction).
    m_BMPInfoHeader.height = -height;
    m_BMPInfoHeader.colorPlane = 1;
    m_BMPInfoHeader.bitColor = 24;
    m_BMPInfoHeader.realSize = 3 * width * height;

    fwrite(bfType, 1, sizeof(bfType), fp_bmp);
```

> ⚠️ 此节内容不完整，原文后续代码缺失。

---

## 附录：YUV 格式基础

### A.1 I420、NV12、NV21 的区别

三者都属于 **YUV 4:2:0** 采样，区别在于内存排列方式。

**I420（即 YUV420p）— Planar（平面格式）**

三个独立平面，依次存储全部 Y、全部 U、全部 V：

```
YYYYYYYY... UUUU... VVVV...
```

FFmpeg 内部默认使用此格式，适合纯软件处理。

**NV12 — Semi-Planar（半平面格式）**

两个平面：Y 平面 + UV 交错平面：

```
YYYYYYYY... UVUVUV...
```

这是 **iOS/macOS 原生采集（AVCapture）和硬解码（VideoToolbox）** 最常用的格式。GPU 渲染时只需两个纹理（Y 单通道 + UV 双通道），比 I420 的三个纹理更高效。

**NV21 — Semi-Planar**

与 NV12 的唯一区别是 UV 平面中 **V 在前、U 在后**：

```
YYYYYYYY... VUVUVU...
```

这是 **Android 平台默认格式**。跨平台开发时注意区分。

| 特性 | I420 | NV12 | NV21 |
|------|------|------|------|
| 类型 | Planar | Semi-Planar | Semi-Planar |
| 平面数 | 3 | 2 | 2 |
| 排列 | Y... U... V... | Y... UVUV... | Y... VUVU... |
| 主要场景 | FFmpeg 软解 | iOS/macOS 硬解 | Android |

> **避坑**：画面颜色发绿/发紫/发青，通常是 UV 顺序搞反了（I420 vs YV12，或 NV12 vs NV21）。

---

### A.2 其他常见 YUV 格式

| 格式 | 采样 | 存储方式 | 平面数 | 典型场景 |
|------|------|----------|--------|----------|
| **I420** | 4:2:0 | Planar | 3 | FFmpeg、软解 |
| **NV12** | 4:2:0 | Semi-Planar | 2 | iOS/macOS 硬解与渲染 |
| **NV21** | 4:2:0 | Semi-Planar | 2 | Android |
| **YV12** | 4:2:0 | Planar | 3 | 老旧编解码器（U/V 顺序与 I420 相反） |
| **YUY2** | 4:2:2 | Packed | 1 | USB 摄像头（`Y0 U0 Y1 V0 ...`） |
| **P010** | 4:2:0 | Semi-Planar | 2 | HDR 视频（10-bit，布局同 NV12） |

---

### A.3 色度抽样（Chroma Subsampling）详解

**J:a:b 表示法**：以 `4:2:0` 为例：

- **J=4**：参考块宽度为 4 像素
- **a=2**：第一行 4 个像素中保留 2 组色度
- **b=0**：第二行不复用新色度，直接复用第一行

**核心思想**：利用人眼对亮度敏感、对颜色迟钝的特性，在水平和垂直两个维度同时压缩色度。

**直观理解**：在一个 2×2 像素方块中，4 个像素各自保留亮度（Y），但共享 1 组色度（U、V）。

```
Y1  Y2    ← 共用 U1, V1
Y3  Y4    ← 共用 U1, V1
```

**各采样比例对比**：

| 格式 | 颜色保留 | 数据量（相对 4:4:4） | 场景 |
|------|----------|---------------------|------|
| 4:4:4 | 每像素独立颜色 | 100% | 高端后期、无损 |
| 4:2:2 | 横向每 2 像素共用 | 66.7% | 专业摄像机 |
| 4:2:0 | 横向纵向均减半 | 50% | 互联网视频、移动端 |

**数据量对比**（以 2×2 像素为例）：

- RGB24：4 像素 × 3 字节 = **12 字节**
- YUV 4:2:0：4 个 Y + 1 个 U + 1 个 V = **6 字节**（节省 50%）

---

### A.4 Stride（跨距/行对齐）

这是工程中最容易出错的细节。

视频帧在内存中每行的实际字节数可能**大于** `宽度 × 每像素字节数`，因为系统会为内存对齐进行补齐。

例如宽度为 7 的视频帧，系统可能将每行补齐到 8 像素：

```
逻辑宽度: 7 → 实际 Stride: 8
```

**如果按逻辑宽度读取下一行数据，会导致画面斜切或出现绿边。**
在 iOS 开发中，处理 `CVPixelBuffer` 时**永远使用 `CVPixelBufferGetBytesPerRow`** 获取实际行宽，而不是用 `width` 直接计算。使用 FFmpeg 时同理，用 `frame->linesize[0]` 而非 `width`。

---

### A.5 颜色空间与转换矩阵（BT.601 / BT.709 / BT.2020）

YUV 转 RGB 的公式并非唯一。选错转换矩阵会导致颜色偏淡或偏红。

| 标准 | 适用场景 | 色域 |
|------|----------|------|
| **BT.601** | 标清视频（SD） | 较小 |
| **BT.709** | 高清视频（1080p） | 标准 |
| **BT.2020** | 4K/8K、HDR 视频 | 最广 |

**BT.709 转换矩阵示例**（YUV → RGB，Limited Range）：

```
R = Y                          + 1.5748 × (V - 128)
G = Y - 0.1873 × (U - 128) - 0.4681 × (V - 128)
B = Y + 1.8556 × (U - 128)
```

> **避坑**：渲染时需根据视频源的实际标准选择对应矩阵，否则颜色整体偏移。

---

### A.6 数值范围（Full Range vs Limited Range）

YUV 数据存在两种数值范围，这是"颜色看起来不对劲"的另一常见原因。

| 类型 | Y 范围 | UV 范围 | 典型场景 |
|------|--------|---------|----------|
| **Limited Range**（MPEG） | 16 ~ 235 | 16 ~ 240 | 广播、在线视频（主流） |
| **Full Range**（JPEG） | 0 ~ 255 | 0 ~ 255 | 相机拍照、桌面采集 |

> **避坑**：把 Limited Range 视频当 Full Range 渲染 → 黑色发灰、白色发污。反之则暗部死黑、亮部过曝。

---

### A.7 采样中心对齐（Chroma Siting）

色度采样点（U/V）对应哪个亮度像素（Y）的中心位置，不同标准有差异：

| 标准 | 水平对齐 | 垂直对齐 |
|------|----------|----------|
| **MPEG-2 / H.264** | 与左 Y 像素中心对齐 | 位于上下两行 Y 之间 |
| **JPEG** | 位于 4 个 Y 像素正中心 | 位于 4 个 Y 像素正中心 |

> **避坑**：对齐方式不匹配时，文字边缘或高对比度边缘会出现细微的**彩色重影（Chroma Ghosting）**。

---

原文作者： 雷霄骅