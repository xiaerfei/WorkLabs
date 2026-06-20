# YUV 格式深入：采样、布局与工程实践

> 来源：Gemini 对话整理，补充 `YUV.md` 附录中的实操细节。

---

## 1. I420 / NV12 / NV21 对比

三者都属于 YUV 4:2:0 采样，区别在于内存排列方式。

### I420（即 YUV420P）— Planar（平面格式）

三个独立平面，依次存储全部 Y、全部 U、全部 V：

```
YYYYYYYY... UUUU... VVVV...
```

FFmpeg 内部默认使用此格式，适合纯软件处理。

### NV12 — Semi-Planar（半平面格式）

两个平面：Y 平面 + UV 交错平面：

```
YYYYYYYY... UVUVUV...
```

iOS/macOS 原生采集（AVCapture）和硬解码（VideoToolbox）最常用的格式。GPU 渲染时只需两个纹理（Y 单通道 + UV 双通道），比 I420 的三个纹理更高效。

### NV21 — Semi-Planar

与 NV12 的唯一区别是 UV 平面中 **V 在前、U 在后**：

```
YYYYYYYY... VUVUVU...
```

Android 平台默认格式。

| 特性 | I420 | NV12 | NV21 |
|------|------|------|------|
| 类型 | Planar | Semi-Planar | Semi-Planar |
| 平面数 | 3 | 2 | 2 |
| 排列 | `Y... U... V...` | `Y... UVUV...` | `Y... VUVU...` |
| 主要场景 | FFmpeg 软解 | iOS/macOS 硬解 | Android |

> **避坑**：画面颜色发绿/发紫/发青，通常是 UV 顺序搞反了（I420 vs YV12，或 NV12 vs NV21）。

---

## 2. 其他常见 YUV 格式

| 格式 | 采样 | 存储方式 | 平面数 | 典型场景 |
|------|------|----------|--------|----------|
| **I420** | 4:2:0 | Planar | 3 | FFmpeg、软解 |
| **NV12** | 4:2:0 | Semi-Planar | 2 | iOS/macOS 硬解与渲染 |
| **NV21** | 4:2:0 | Semi-Planar | 2 | Android |
| **YV12** | 4:2:0 | Planar | 3 | 老旧编解码器（U/V 顺序与 I420 相反） |
| **YUY2** | 4:2:2 | Packed | 1 | USB 摄像头（`Y0 U0 Y1 V0 ...`） |
| **P010** | 4:2:0 | Semi-Planar | 2 | HDR 视频（10-bit，布局同 NV12） |

---

## 3. 色度抽样（Chroma Subsampling）详解

### J:a:b 表示法

以 `4:2:0` 为例：

- **J=4**：参考块宽度为 4 像素
- **a=2**：第一行 4 个像素中保留 2 组色度
- **b=0**：第二行不复用新色度，直接复用第一行

### 核心思想

利用人眼对亮度敏感、对颜色迟钝的特性，在水平和垂直两个维度同时压缩色度。

### 直观理解

在一个 2×2 像素方块中，4 个像素各自保留亮度（Y），但共享 1 组色度（U、V）：

```
Y1  Y2    ← 共用 U1, V1
Y3  Y4    ← 共用 U1, V1
```

### 各采样比例对比

| 格式 | 颜色保留 | 数据量（相对 4:4:4） | 场景 |
|------|----------|---------------------|------|
| 4:4:4 | 每像素独立颜色 | 100% | 高端后期、无损 |
| 4:2:2 | 横向每 2 像素共用 | 66.7% | 专业摄像机 |
| 4:2:0 | 横向纵向均减半 | 50% | 互联网视频、移动端 |

### 数据量对比（以 2×2 像素为例）

- RGB24：4 像素 × 3 字节 = **12 字节**
- YUV 4:2:0：4 个 Y + 1 个 U + 1 个 V = **6 字节**（节省 50%）

### 为什么是 2×2 方阵而不是 1×4 长条？

如果让 `Y1 Y2 Y3 Y4`（一行 4 个）共用一组 UV，水平颜色分辨率砍掉 75%，但纵向没砍。这会导致画面出现明显的**色边**（水平方向模糊，纵向尖锐）。

4:2:0 的方案：水平砍 50%，纵向也砍 50%。这种**对称的模糊**更符合人眼视觉特征，看起来更自然。

---

## 4. Buffer 大小计算

### 理论值（不含对齐）

以 1080p YUV 4:2:0 为例：

- **Y**：1920 × 1080 = 2,073,600 字节
- **U**：960 × 540 = 518,400 字节
- **V**：960 × 540 = 518,400 字节
- **总计**：3,110,400 字节（约 2.97 MB）

### 工程实际值（含 Stride）

```
Buffer_Size = (Stride_Y × Height) + (Stride_UV × Height / 2)
```

其中 Stride 由系统对齐要求决定（通常 16 或 32 字节对齐）：

```
Stride = ((Width + Alignment - 1) / Alignment) × Alignment
```

例如宽度 1270、32 字节对齐：`Stride = ((1270 + 31) / 32) × 32 = 1280`，每行多 10 字节 padding。

> **避坑**：1920 恰好是 64 的倍数，Stride 等于 Width，容易产生"Stride 没用"的错觉。建议用奇数宽度视频（如 1081×1920）测试。

---

## 5. FFmpeg 中的 Stride 获取

```c
// frame->linesize[i] 就是 Stride
// i=0 是 Y，i=1,2 是 U, V
for (int i = 0; i < 3; i++) {
    total_size += frame->linesize[i] * (i == 0 ? frame->height : frame->height / 2);
}
```

### iOS 中的 Stride 获取

```objectivec
size_t strideY  = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
size_t strideUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
size_t height   = CVPixelBufferGetHeight(pixelBuffer);
size_t totalSize = strideY * height + strideUV * (height / 2);
```

> **铁律**：计算内存偏移时永远用 Stride（`linesize` / `BytesPerRow`），遍历像素边界用逻辑宽高（`width` / `height`）。混用会导致画面斜切或崩溃。

---

## 6. 颜色空间选择（BT.601 vs BT.709 vs BT.2020）

| 标准 | 适用场景 | 色域 |
|------|----------|------|
| **BT.601** | 标清视频（SD，宽 < 1280） | 较小 |
| **BT.709** | 高清视频（HD，1080p） | 标准 |
| **BT.2020** | 4K/8K、HDR 视频 | 最广 |

### BT.709 转换矩阵（YUV → RGB，Full Range）

```
R = Y                          + 1.5748 × (V - 128)
G = Y - 0.1873 × (U - 128) - 0.4681 × (V - 128)
B = Y + 1.8556 × (U - 128)
```

> **避坑**：选错转换矩阵会导致颜色偏淡或偏红。视频流未标记色彩空间时，按分辨率盲猜：宽 < 1280 用 BT.601，否则用 BT.709。

---

## 7. 数值范围（Full Range vs Limited Range）

| 类型 | Y 范围 | UV 范围 | 典型场景 |
|------|--------|---------|----------|
| **Limited Range** | 16 ~ 235 | 16 ~ 240 | 广播、在线视频（主流） |
| **Full Range** | 0 ~ 255 | 0 ~ 255 | 相机拍照、桌面采集 |

> **避坑**：Limited Range 当 Full Range 渲染 → 黑色发灰、白色发污。反之则暗部死黑、亮部过曝。

---

## 8. 采样中心对齐（Chroma Siting）

色度采样点（U/V）对应哪个亮度像素（Y）的中心位置，不同标准有差异：

| 标准 | 水平对齐 | 垂直对齐 |
|------|----------|----------|
| **MPEG-2 / H.264** | 与左 Y 像素中心对齐 | 位于上下两行 Y 之间 |
| **JPEG** | 位于 4 个 Y 像素正中心 | 位于 4 个 Y 像素正中心 |

> **避坑**：对齐方式不匹配时，文字边缘或高对比度边缘会出现细微的**彩色重影（Chroma Ghosting）**。
