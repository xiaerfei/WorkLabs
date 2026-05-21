# AAC 音频编码完全指南

> 一份轻松理解 AAC 编码的完整总结文档

---

## 📋 目录

1. [AAC 概述](#一aac-概述)
2. [AAC 规格分类](#二aac-规格分类)
3. [AAC 文件格式](#三aac-文件格式)
4. [ADTS 帧结构详解](#四adts-帧结构详解)
5. [AAC 解码流程](#五aac-解码流程)
6. [实战代码示例](#六实战代码示例)

---

## 一、AAC 概述

### 什么是 AAC？

**AAC（Advanced Audio Coding）** 即高级音频编码，是一种高压缩比的有损音频压缩算法。

| 特性 | 说明 |
|------|------|
| 诞生时间 | 1997 年 |
| 起源 | 基于 MPEG-2 音频编码技术 |
| 开发公司 | Fraunhofer IIS、Dolby Laboratories、AT&T、Sony 等 |
| 目标 | 取代 MP3 格式 |
| 别名 | 也称为 M4A（MPEG-4 Audio） |

### AAC 的发展历程

```
1997 ─────────────────────────────────────────▶
│
│  MPEG-2 AAC 制定标准
│
│
1999 ─────────────────────────────────────────▶
│
│  MPEG-4 AAC V1
│  +LTP(长时期预测) +PNS(知觉噪声替换)
│
│
2000 ─────────────────────────────────────────▶
│
│  MPEG-4 标准出台
│  AAC 也称为 M4A
│
│
2002 ─────────────────────────────────────────▶
│
│  HE-AAC (高效率AAC)
│  +SBR(频段复制) +错误鲁棒性
│
│
2004 ─────────────────────────────────────────▶
│
│  EAAC+ (Enhanced AAC Plus)
│  +PS(参数立体声)
```

### AAC 的特点

1. **高压缩比**：压缩比远超过 MP3、AC-3 等老一代音频编码
2. **高质量**：音质可以同未压缩的 CD 音质相媲美
3. **宽频响范围**：8KHz - 96KHz，远宽于 MP3 的 16KHz-48KHz
4. **多声道支持**：最多支持 48 个主声道 + 16 个低频声道
5. **高解码效率**：采用优化算法，解码端处理简单

---

## 二、AAC 规格分类

AAC 共有 9 种规格，分为三大类：

### 规格总览

```
┌─────────────────────────────────────────────────────────────┐
│                     AAC 家族                                │
├─────────────┬─────────────┬─────────────────────────────────┤
│   LC-AAC    │   HE-AAC    │          HE-AAC v2             │
│  (传统AAC)  │  (AAC+SBR)  │       (AAC+SBR+PS)            │
├─────────────┼─────────────┼─────────────────────────────────┤
│ 中高码率    │  中低码率   │           低码率               │
│  >=80Kbps   │  <=80Kbps   │          <=48Kbps              │
└─────────────┴─────────────┴─────────────────────────────────┘
```

### 详细规格说明

| 规格 | 名称 | 说明 | 常用场景 |
|------|------|------|----------|
| MPEG-2 AAC LC | 低复杂度规格 | 无增益控制，编码效率高 | 磁盘文件 |
| MPEG-2 AAC Main | 主规格 | 音质最好 | 专业领域 |
| MPEG-2 AAC SSR | 可变采样率 | | |
| MPEG-4 AAC LC | 低复杂度规格 | MP4 文件常用 | 手机、平板 |
| MPEG-4 AAC Main | 主规格 | 除增益控制外全部功能 | |
| MPEG-4 AAC LTP | 长时期预测 | | |
| MPEG-4 AAC LD | 低延迟规格 | 实时通信 | |
| MPEG-4 AAC HE | 高效率规格 | 适合低码率编码 | 网络流媒体 |

### 🔑 关键技术：SBR 和 PS

#### SBR (Spectral Band Replication) - 频段复制

> 音乐的主要频谱集中在低频段，高频段幅度很小，但很重要，决定了音质。

```
传统编码: 整个频段一起编码
          ↓
若保护高频 → 低频编码过细 → 文件巨大
若保存低频 → 失去高频 → 音质损失

SBR 方案:
┌─────────────────┬─────────────────┐
│   低频段         │    高频段        │
│   单独编码       │    放大复制      │
│   保存主要成分    │    保存音质      │
└─────────────────┴─────────────────┘
→ 减少文件大小的同时保持音质
```

#### PS (Parametric Stereo) - 参数立体声

```
立体声文件大小 = 单声道 × 2

问题: 两声道声音存在相似性，直接存储造成浪费

PS 方案:
┌─────────────────┬─────────────────┐
│   声道1         │      声道2      │
│   完整存储      │   用参数描述差异  │
└─────────────────┴─────────────────┘
→ 大幅减少存储空间
```

---

## 三、AAC 文件格式

### 两种格式对比

```
┌──────────────────────┬──────────────────────────────────────┐
│        ADIF          │              ADTS                     │
│ Audio Data           │  Audio Data Transport Stream        │
│ Interchange Format  │                                     │
├──────────────────────┼──────────────────────────────────────┤
│ 音频数据交换格式     │  音频数据传输流                      │
├──────────────────────┼──────────────────────────────────────┤
│ ❌ 只能在文件开头    │ ✅ 可以在任意位置开始解码             │
│    开始解码          │    (每帧都有同步头)                  │
├──────────────────────┼──────────────────────────────────────┤
│ 只有一个统一头部     │ 每一帧都有独立头部                   │
├──────────────────────┼──────────────────────────────────────┤
│ 适用于磁盘文件存储   │ 适用于流媒体传输                    │
├──────────────────────┼──────────────────────────────────────┤
│ [头部][数据][数据]...│ [帧头][数据][帧头][数据][帧头]...   │
└──────────────────────┴──────────────────────────────────────┘
```

### 格式结构图

#### ADIF 格式
```
┌──────────┬──────────┬──────────┬──────────┐
│   头部    │ Raw Data │ Raw Data │ Raw Data │ ...
│ (ADIF头)  │  Block   │  Block   │  Block   │
└──────────┴──────────┴──────────┴──────────┘
  ↑ 文件开头只有这一个头
```

#### ADTS 格式
```
┌────────┬────────┐┌────────┬────────┐┌────────┬────────┐
│ 帧头   │ 数据   ││ 帧头   │ 数据   ││ 帧头   │ 数据   │
│(ADTS)  │        ││(ADTS)  │        ││(ADTS)  │        │
└────────┴────────┘└────────┴────────┘└────────┴────────┘
  ↑ 每一帧都有自己的头
```

> ⚠️ **注意**: 目前编码后和抽取出的 AAC 音频流基本都是 ADTS 格式

---

## 四、ADTS 帧结构详解

### 帧结构总览

```
┌────────────────────────────────────────────────────────────┐
│                     ADTS 帧结构                            │
├──────────────────────────┬─────────────────────────────────┤
│           ADTS Header    │         AAC 原始数据             │
│      (7 或 9 字节)       │        (Raw Data Block)         │
├──────────────────────────┼─────────────────────────────────┤
│ 固定头 │ 可变头 │ CRC   │                                 │
│ 28bit  │ 28bit  │ 16bit │        1024个采样              │
│        │(可选)  │(可选) │                                 │
└──────────────────────────┴─────────────────────────────────┘
```

### ADTS 头部字段

#### 固定头信息 (每帧相同)

| 字段 | 长度 | 说明 | 示例值 |
|------|------|------|--------|
| **syncword** | 12bit | 同步字，始终为 0xFFF | 0xFFF |
| **ID** | 1bit | MPEG 版本 (0=MPEG-4, 1=MPEG-2) | 0 |
| **layer** | 2bit | 总是 00 | 00 |
| **protection_absent** | 1bit | 是否误码校验 (1=无CRC, 0=有CRC) | 1 |
| **profile** | 2bit | AAC 级别 (值 = Audio Object Type - 1) | 2 (LC) |
| **sampling_frequency_index** | 4bit | 采样率下标 | 3 (48000Hz) |
| **private_bit** | 1bit | 私有位 | 0 |
| **channel_configuration** | 3bit | 声道配置 | 2 (立体声) |
| **original/copy** | 1bit | 原始/拷贝 | 0 |
| **home** | 1bit | 主场 | 0 |

#### 可变头信息 (每帧可能不同)

| 字段 | 长度 | 说明 | 示例值 |
|------|------|------|--------|
| **copyright_identification_bit** | 1bit | 版权标识位 | 0 |
| **copyright_identification_start** | 1bit | 版权标识开始 | 0 |
| **frame_length** | 13bit | 帧长度 (包括头部) | 535 |
| **adts_buffer_fullness** | 11bit | 缓冲满度 (0x7FF=可变码率) | 0x7FF |
| **number_of_raw_data_blocks_in_frame** | 2bit | 原始帧数量-1 | 0 |

### 采样率对应表

| 下标 | 采样率 | 应用场景 |
|------|--------|----------|
| 0x0 | 96000 | DVD-Audio |
| 0x1 | 88200 | |
| 0x2 | 64000 | |
| **0x3** | **48000** | **DVD、DAT、电影 (最常用)** |
| **0x4** | **44100** | **音频 CD、MP3** |
| 0x5 | 32000 | |
| 0x6 | 24000 | |
| 0x7 | 22050 | |
| 0x8 | 16000 | |
| 0x9 | 12000 | |
| 0xA | 11025 | |
| 0xB | 8000 | 电话 |

### 声道配置对应表

| 值 | 声道配置 |
|----|----------|
| 0 | 在音频特定配置中定义 |
| 1 | 单声道 (front-center) |
| **2** | **立体声 (front-left, front-right)** |
| 3 | 3声道 (front-center, L, R) |
| 4 | 4声道 (front-center, L, R, back-center) |
| 5 | 5声道 (5.1环绕声) |
| 6 | 6声道 (5.1 + LFE) |
| 7 | 8声道 (7.1 + LFE) |
| 8-15 | 保留 |

### 帧长度计算

```
frame_length = (protection_absent == 1 ? 7 : 9) + AAC原始数据长度

例如:
- 无CRC时，头部 = 7字节
- 有CRC时，头部 = 9字节
```

### 一个 AAC 帧包含多少采样？

> **1024 个采样点**

这意味着：
- 单声道 44.1kHz 的一帧时长 = 1024 / 44100 ≈ 23.2ms
- 立体声 48kHz 的一帧时长 = 1024 / 48000 ≈ 21.3ms

---

## 五、AAC 解码流程

### 解码流程图

```
┌─────────────┐
│ AAC 比特流  │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   主控模块   │ ← 输入缓冲区、调用各模块、输出缓冲区
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ 无噪解码     │ ← 哈夫曼解码，减少尺度因子和频谱冗余
│ (Noiseless) │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   反量化     │ ← 4/3次幂运算
│ (Dequantize)│
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ 联合立体声   │ ← 渲染立体声
│(Joint Stereo)│
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ 知觉噪声替换 │ ← 以参数编码模拟噪声
│    (PNS)    │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ 瞬时噪声整形 │ ← 频域预测修整时域噪声
│    (TNS)    │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│    IMDCT    │ ← 频域 → 时域
│ 反离散余弦   │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   SBR       │ ← 高频重建 (HE-AAC 特有)
│  (频段复制) │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   PCM 输出   │
└─────────────┘
```

### 各模块功能详解

1. **主控模块**: 操作输入输出缓冲区，调度各模块协同工作
2. **无噪解码**: 哈夫曼解码，减少尺度因子和量化频谱的冗余
3. **反量化**: 保持符号并进行 4/3 次幂运算
4. **联合立体声**: 对左右声道进行渲染，使声音更好听
5. **知觉噪声替换 (PNS)**: 用参数编码方式模拟噪声
6. **瞬时噪声整形 (TNS)**: 通过频率域预测修整时域噪声分布
7. **IMDCT**: 将频域数据转换为时域数据
8. **SBR**: 低码率时重建高频部分

---

## 六、实战代码示例

### ADTS 头部结构体

```c
typedef struct _AdtsHeader
{
    unsigned int nSyncWord;           // 12bit - 同步字 0xFFF
    unsigned int nId;                 // 1bit  - MPEG版本
    unsigned int nLayer;              // 2bit  - 总是00
    unsigned int nProtectionAbsent;   // 1bit  - 是否CRC校验
    unsigned int nProfile;            // 2bit  - AAC级别
    unsigned int nSfIndex;            // 4bit  - 采样率下标
    unsigned int nPrivateBit;         // 1bit
    unsigned int nChannelConfiguration; // 3bit - 声道数
    unsigned int nOriginal;           // 1bit
    unsigned int nHome;               // 1bit

    unsigned int nCopyrightIdentificationBit;     // 1bit
    unsigned int nCopyrightIdentificationStart;   // 1bit
    unsigned int nAacFrameLength;    // 13bit - 帧长度
    unsigned int nAdtsBufferFullness; // 11bit - 缓冲满度
    unsigned int nNoRawDataBlocksInFrame; // 2bit - 原始帧数-1
} AdtsHeader;
```

### ADTS 头部生成函数

> **修复 (2026-05-15)**: 完善了声道配置字段的设置

```c
const int sampling_frequencies[] = {
    96000, 88200, 64000, 48000, 44100, 
    32000, 24000, 22050, 16000, 12000, 11025, 8000
};

int adts_header(char * const p_adts_header, const int data_length,
                const int profile, const int samplerate,
                const int channels)
{
    int sampling_frequency_index = 3; // 默认 48000Hz
    int adtsLen = data_length + 7;    // 头部7字节

    // 查找采样率对应的下标
    for(int i = 0; i < 12; i++) {
        if(sampling_frequencies[i] == samplerate) {
            sampling_frequency_index = i;
            break;
        }
    }

    // 固定头 (7 bytes)
    // byte 0: syncword 高8位 (0xFF)
    p_adts_header[0] = 0xff;

    // byte 1: syncword 低4位 (0xF) + ID (1bit) + layer (2bit)
    p_adts_header[1] = 0xf0;

    // byte 1 续: profile (2bit) - 注意: profile = Audio Object Type - 1
    p_adts_header[1] |= ((profile - 1) << 6);

    // byte 2: sampling_frequency_index (4bit) + private_bit (1bit) + channel_configuration (3bit高2位)
    p_adts_header[2] = (sampling_frequency_index << 2) | (channels >> 2);

    // byte 2 续: channel_configuration 低1位 + original/copy (1bit) + home (1bit)
    p_adts_header[2] |= ((channels & 0x03) << 6);

    // 可变头
    // byte 3: copyright_identification_bit (1bit) + copyright_identification_start (1bit) + frame_length 高6位
    p_adts_header[3] = 0x00;

    // byte 3 续: frame_length 中8位
    p_adts_header[4] = (adtsLen >> 5) & 0xff;

    // byte 5: frame_length 低5位 + adts_buffer_fullness 高3位
    p_adts_header[5] = (adtsLen & 0x1f) << 3;

    // byte 5 续: adts_buffer_fullness 低8位 (0x7FF = VBR)
    p_adts_header[5] |= 0x07;

    // byte 6: adts_buffer_fullness 低3位 + number_of_raw_data_blocks_in_frame (2bit) + 填充位
    p_adts_header[6] = 0xf8;

    return 0;
}

// 注意: profile 参数传入实际的 AAC profile 值 (如 2=LC, 5=Main)
// 函数内部会自动转换为 ADTS header 要求的格式 (profile - 1)
```

**调用示例:**
```c
char adts_header[7];
adts_header(adts_header, aac_data_size, 2, 44100, 2);  // LC profile, 44.1kHz, 立体声
```
```

### 解析 ADTS 帧

```c
int getADTSframe(unsigned char* buffer, int buf_size, 
                 unsigned char* data, int* data_size)
{
    int size = 0;
    
    while(1) {
        // 查找同步字 0xFFF
        if(buf_size < 7) return -1;
        if((buffer[0] == 0xff) && ((buffer[1] & 0xf0) == 0xf0)) {
            // 计算帧长度
            size |= ((buffer[3] & 0x03) << 11);     // 高2位
            size |= buffer[4] << 3;                  // 中8位
            size |= ((buffer[5] & 0xe0) >> 5);       // 低3位
            break;
        }
        --buf_size;
        ++buffer;
    }
    
    memcpy(data, buffer, size);
    *data_size = size;
    return 0;
}
```

### 使用 FFmpeg 抽取 AAC

```bash
# 从 MP4 文件中提取 AAC 音频
ffmpeg -i input.mp4 -vn -y -acodec copy output.aac
```

---

## 📊 总结

| 项目 | 说明 |
|------|------|
| **压缩率** | 比 MP3 高 30% |
| **音质** | 接近 CD 质量 |
| **采样率** | 8KHz - 96KHz |
| **码率** | 8kbps - 576kbps |
| **声道** | 最多 48 主声道 + 16 低音 |
| **主流格式** | ADTS (每帧都有头) |
| **常用规格** | LC-AAC、HE-AAC、HE-AACv2 |
| **帧大小** | 1024 采样点/帧 |

---

## 🔗 参考资源

- [AAC 格式分析 - 腾讯云](https://cloud.tencent.com/developer/article/1960483)
- [AAC 音频基础 - 腾讯云](https://cloud.tencent.com/developer/article/1746985)
- [AAC 实战解析 - 腾讯云](https://cloud.tencent.com/developer/article/2021880)
- [AAC 格式详解 - 阿里云](https://developer.aliyun.com/article/229178)
- [AAC 帧解析 - 博客园](https://www.cnblogs.com/embedded-linux/p/6683613.html)

---

*文档生成时间: 2026-04-14*
