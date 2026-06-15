# libwl — 纯 C 音视频内核

每个模块**先在 `../Learning/` 里独立验证**，跑通后再提炼到这里（`include/` 放头、`src/` 放实现、`tests/` 放单测）。
零 OC 依赖，可用 gcc/clang 命令行独立编译测试。

## 计划模块（对应学习里程碑 / WorkLabs 参照类）

| 模块 | 里程碑 | 职责 | WorkLabs 对照 |
|------|--------|------|---------------|
| `decoder` | M1 | 解封装 + 解码 → YUV/PCM | `WLMediaSource` |
| `encoder` + `muxer` | M2 | 编码 + 封装 MP4 | `WLEncoder` · `WLRecorder` |
| `mixer` | M3 | 多源视频合成（alpha blend + 缩放 + z-order） | `WLVideoMix` |
| `audio` | M3/M4 | PCM 重采样 + 多路混音 + gain | `WLAudioMixer` |
| `queue` | M4 | 线程安全队列（生产者-消费者） | `WLNodeQueue` |
| `rtmp` | M5 | RTMP 握手 + AMF + 推流 | —（新功能） |
| `utils` | 贯穿 | 色彩空间转换 · 时间戳工具 · BMP 读写 | — |
