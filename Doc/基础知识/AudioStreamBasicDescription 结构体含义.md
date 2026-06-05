## AudioStreamBasicDescription 结构体含义

```c
struct AudioStreamBasicDescription
{
    Float64             mSampleRate;
    AudioFormatID       mFormatID;
    AudioFormatFlags    mFormatFlags;
    UInt32              mBytesPerPacket;
    UInt32              mFramesPerPacket;
    UInt32              mBytesPerFrame;
    UInt32              mChannelsPerFrame;
    UInt32              mBitsPerChannel;
    UInt32              mReserved;
};
typedef struct AudioStreamBasicDescription  AudioStreamBasicDescription;
```

### AudioStreamBasicDescription (ASBD) 详解

| **字段**                | **含义**       | **我们的设置值 (PCM)**   | **作用**                                                     |
| ----------------------- | -------------- | ------------------------ | ------------------------------------------------------------ |
| **`mSampleRate`**       | 采样率         | `44100.0`                | 每秒钟有多少个 Frame。                                       |
| **`mFormatID`**         | 格式 ID        | `kAudioFormatLinearPCM`  | 告诉系统这是原始数据，不是压缩包。                           |
| **`mFormatFlags`**      | 格式标记       | `SignedInteger | Packed` | 细节定义：是整数还是浮点数？是大端还是小端？数据是否紧凑排列？ |
| **`mBytesPerPacket`**   | 每包字节数     | `4`                      | 每个逻辑包的大小。                                           |
| **`mFramesPerPacket`**  | 每包帧数       | `1`                      | 每个逻辑包里装几个采样集合。                                 |
| **`mBytesPerFrame`**    | 每帧字节数     | `4`                      | **(重要)** 跨越一个时间点需要的字节。                        |
| **`mChannelsPerFrame`** | 每帧声道数     | `2`                      | 这一帧里包含了多少个独立声道。                               |
| **`mBitsPerChannel`**   | 每个声道的位深 | `16`                     | 决定了声音的动态范围（分辨率）。                             |
| **`mReserved`**         | 保留字段       | `0`                      | 填充字段，目前没用，必须设为 0。                             |

------

### 为什么要区分这么多层级？

你可能会问：既然 `mBytesPerPacket` 和 `mBytesPerFrame` 在 PCM 里是一样的，为什么要搞两个变量？

这就是 Apple 设计的精妙之处——**统一抽象**：

1. **对于 PCM**：`Packet = Frame`，所以两者相等。
2. **对于 VBR（变比特率压缩音频）**：比如 MP3。一个 Packet 包含 1152 个 Frame，但由于压缩比例不同，每个 Packet 的字节数是不固定的。这时候 `mBytesPerPacket` 会被设为 `0`，而由专门的 `AudioStreamPacketDescription` 结构体来单独描述每一个包的大小。

## 常用的配置

```c
// 配置 ASBD (macOS 硬件友好的 PCM 格式)
AudioStreamBasicDescription _asbd;
_asbd.mSampleRate = rate;
_asbd.mFormatID = kAudioFormatLinearPCM;
_asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
_asbd.mChannelsPerFrame = channels;
_asbd.mFramesPerPacket = 1;
_asbd.mBitsPerChannel = 16;
_asbd.mBytesPerFrame = channels * (16 / 8);
_asbd.mBytesPerPacket = _asbd.mBytesPerFrame;
```

### 核心概念：什么是 Frame（帧）？

在 **线性 PCM（Linear PCM）** 数据中：

- **Sample（采样点）**：单个声道在某一瞬间的数值。因为我们用的是 `S16` 格式，所以一个采样点占用 **16 bit（2 字节）**。
- **Frame（帧）**：同一时间点下，**所有声道**采样点的集合。

### `mBytesPerFrame`

```c
_asbd.mBytesPerFrame = channels * (16 / 8);
```

这一行计算的是 **“一个时间点的完整数据占多少字节”**。

- `16 / 8`：将 bit 转换为 Byte（字节）。16-bit 音频每个采样点占 2 字节。
- `channels`：如果是立体声（Stereo），`channels = 2`。
- **计算结果**：`2 x 2 = 4` 字节。

**为什么要这个值？**

因为硬件在播放时，必须同时输出左声道和右声道的数值。它需要知道每次从内存里跳跃 **4 字节** 才能拿到下一个时间点的数据。

### `mBytesPerPacket`

```c
_asbd.mBytesPerPacket = _asbd.mBytesPerFrame;
```

这一行定义了 **“一个数据包（Packet）占多少字节”**。

- 在 **非压缩格式（如 PCM）** 中：概念上 `1 Packet = 1 Frame`。所以它们的大小是相等的。
- 在 **压缩格式（如 MP3/AAC）** 中：一个 Packet 通常包含很多个 Frame（比如 AAC 一个 Packet 包含 1024 个帧），那时候这两个值就会大不相同。

### 形象化的例子：积木条

想象你的音频数据是一根很长的积木条，存储在内存里：

| **字节偏移** | **0** | **1**       | **2** | **3**  | **4** | **5**       | **6** | **7**  |
| ------------ | ----- | ----------- | ----- | ------ | ----- | ----------- | ----- | ------ |
| **数据**     | L-Low | L-High      | R-Low | R-High | L-Low | L-High      | R-Low | R-High |
| **归属**     | ---   | **Frame 1** | ---   | ---    | ---   | **Frame 2** | ---   | ---    |

**`mBytesPerFrame = 4`**：告诉系统，每往后走 4 个字节，就是一个完整的播放单位（左+右）。

**`mBitsPerChannel = 16`**：告诉系统一个采样点 16 bit (2 字节)，在这一帧里，前 2 字节是左耳的，后 2 字节是右耳的。



所以 **1 Frame 包含: L R**，同一时间点的左声道采样（L）和右声道采样（R）紧挨着放在一起

### 验证你的理解

假设我们现在的配置是 **5.1 环绕声 (6 channels)**，采样率 **48000Hz**，位深 **16bit**：

- 一个 **Frame** 的大小就是：6 x (16 / 8) = 12 字节。
- 一秒钟的数据量就是：48000 x 12 = 576,000 字节。

### 举一反三

如果现在是 **5.1 声道**（6 个 channels）：

- **1 个 Frame** 里面就包含了：`L` `R` `C` `LFE` `Ls` `Rs`（左、右、中置、低音炮、左环绕、右环绕）。
- 此时 `mBytesPerFrame` 就会变成 6 x 2 = 12 字节。
- 但无论几个声道，它们依然代表**同一个瞬间**的声音。

### 总结

- **1 Frame** = 所有声道在**同一时间点**的采样集合。
- **1 Packet** = 逻辑上的传输单位（在 PCM 里等于 1 Frame）。
- **Sample Rate** = 每秒钟跑过多少个这样的 Frame。