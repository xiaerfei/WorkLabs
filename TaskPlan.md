## 迁移代码
1. 将 WLMediaSource 中的内容迁移到 WLFFmpegMediaSource 中
2. 实现 WLNodeFrameQueue，可以参照 WLNodeQueue 的实现，放在和 WLNodeFrame 同一目录下
## WLFFmpegMediaSource 实现大概逻辑
从 videoDecodeThread 和 audioDecodeThread 中解码之后，放在 WLNodeFrameQueue 中。我们之前不是有协议 WLMediaSourceProvider 吗，实现 WLMediaSourceProvider 协议，里面不是有 nextVideoFrame 和 nextAudioFrame，外面的调用者可以自由获取。
## 音频数据
现在 WLNodeFrame 中没有音频数据，需要在 WLNodeFrame 中添加音频数据，暂时可以增加一个 AVFrame 属性。

## WLNodeFrame
释放，实现 - (void)flush; 方法，可以释放数据，比如释放 AVFrame 中的数据，和 pixelBuffer 中的数据。
## 逻辑验证
1. 你需要自己检查一下整个数据流，看看是否有问题。
2. 注意实现 WLMediaSourceProvider

## 工具
你可以使用 xcode mcp;