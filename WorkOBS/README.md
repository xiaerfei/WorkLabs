# WorkOBS — 音视频边学边写

学习区：用 **C 写内核（libwl）+ OC 写 UI**，从零独立实现简化版 OBS（macOS）。
与根目录的 WorkLabs 工程**隔离**——WorkLabs 只当「参考答案 / 自测基准」，**不抄**。

> 完整学习计划（里程碑 M0–M6 / 方法论 / 协作协议 / 验收基准 / 自测题）见：
> [`../Doc/规划/音视频学习路线_边写边学.md`](../Doc/规划/音视频学习路线_边写边学.md) 文首「🎯 执行计划与进度」。

## 目录

- `Learning/` — 每个知识点的独立小实验（命令行可跑）；验证通过后再提炼进 `libwl/`。
- `libwl/` — 纯 C 内核库（decoder / encoder / mixer / audio / queue / rtmp），M1 起逐步填充。
  - `include/` 公共头 · `src/` 实现 · `tests/` 单元测试。

## 当前：M0 · 解码一帧存 BMP 🚧

```bash
brew install ffmpeg            # 装 FFmpeg（命令行 + 开发库）
cd Learning/01_decode_one_frame
make                           # 编译
./decode_one_frame input.mp4 out.bmp
open out.bmp                   # 对照 ffmpeg -i input.mp4 -frames:v 1 ref.png 肉眼一致即过
```

核心逻辑（解码 / YUV→RGB / BMP）自己写；`decode_one_frame.c` 里已给分步 TODO 路标。
卡住先查资料 / 找我要提示，实在不行再翻 WorkLabs 的 `WLMediaSource` 对照，看懂后合上、自己默写。
