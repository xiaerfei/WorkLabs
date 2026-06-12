# 玩具编码器概念 ↔ WorkLabs 真实管线对照

> 这篇文章的价值不在于造轮子，而在于给 WorkLabs 已经在用的工业级组件（FFmpeg + VideoToolbox）补上"为什么"。
> 下面把玩具编码器的每个概念对到 WorkLabs 管线里已经趟过/正在用的具体位置。

---

## 对照表

| 玩具编码器概念 | WorkLabs 中的对应物 | 说明 |
|---|---|---|
| 第一步 RGB→YUV | `WLVideoMix` 输出 BGRA → `WLRecorder` 用 swscale 转 NV12 | NV12 就是 4:2:0 的 YUV 排布（Y 平面 + UV 交错平面）；编码器只吃 YUV |
| 量化表 / 编码参数 | H.264 的 SPS/PPS | 玩具容器头里写的"量化表、分辨率"，在 H.264 里就是 SPS/PPS。`WLRecorder` 把 `avformat_write_header` 延迟到第一个包，正是因为 VideoToolbox 的 extradata（SPS/PPS）要等第一帧编完才有 |
| 第五步 GOP / I 帧 | seek 实现（commit `8e2d813`，epoch 世代号） | seek 后解码必须从关键帧追起：P 帧是"上一帧 + 补丁"，没有 I 帧打底就是一堆没头的补丁。这也是"只有收到 I 帧才能开始播"的根源 |
| 第五步 误差累积 / 参考链 | FFmpeg 编码参数里的 GOP 长度（关键帧间隔） | 间隔越长压缩率越高、但 seek 粒度越粗且误差链越长——玩具版里"P5 重新锚定"的取舍就是这个参数的来历 |
| 第六步 容器（分辨率/帧率/时间索引） | mp4 的 moov/mdat；`WLRecorder` 的 VFR 时间戳 | 玩具容器的"时间索引"对应 pts；WorkLabs 录制用真实 pts 做 VFR（可变帧率），而不是假设固定帧率 |
| B 帧（参考后一帧） | pts ≠ dts 的来源 | B 帧要先解出"未来帧"才能解自己，所以解码顺序 ≠ 显示顺序——这就是 dts 存在的全部理由（另见 [h264 笔记 1.4 节](../h264/h264.md)） |
| YUV 平面布局 / 位深 | 滤镜渲染 10-bit HEVC 踩坑（commit `5d8ecd2`/`a75447c`） | 当年把 P010 当 BGRA 绑定导致画面分裂——理解"YUV 是几张独立平面图"之后，这类坑能在写代码前就预见 |
| 色彩空间声明 | `WLVideoMix` 显式 sRGB 渲染；`WLRecorder` 声明 BT.709 limited range | 玩具版里 RGB↔YUV 公式选哪套（BT.601/709、full/limited range）两端必须一致，否则就是"录出来偏暗"那类 bug |

---

## 几条值得展开的线

### SPS/PPS 为什么"迟到"

玩具编码器第六步把元数据写进容器头，看起来理所当然——但 H.264 的 SPS/PPS 是**编码器根据实际编码决定的**（profile、level、参数选择），所以 VideoToolbox 在第一帧编码完成之前给不出 extradata。`WLRecorder` 延迟 `avformat_write_header` 到首包就是在等这份"说明书"。自己设计一遍容器，对这件事的因果会非常清楚。

### seek 与 GOP 的共生关系

WorkLabs 的 seek 用 epoch 世代号丢弃旧帧、落点后从最近关键帧追解——玩具编码器第五步直接解释了为什么没有别的选项：P/B 帧的数据本身不完整，参考链断了就什么都不是。将来若做"精确到帧的 seek 预览"，本质就是"找前一个 I 帧 + 静默快速解到目标帧"，成本与 GOP 长度成正比。

### 未来如果做 RTMP 推流

玩具版"只有收到 I 帧才能开播"的约束，在直播场景就是：推流端要**定期重发 I 帧**（关键帧间隔通常 1~2 秒），新观众才能秒开。到时候调 `h264_videotoolbox` 的关键帧间隔参数，背后的取舍（码率 vs 秒开速度）正是第五步讲的东西。

---

## 结论

不需要、也不建议把玩具编码器用进 WorkLabs——但按 [02-实现难度评估](./02-实现难度评估与避坑.md) 的路线做一遍（哪怕只做到 M2），`WLRecorder` 这条链路上的每个"约定俗成"（延迟写头、VFR pts、NV12、BT.709）都会从"照着做"变成"知道为什么"。
