## WLMediaSource
- 从 `videoRenderThread` 出来的 Video Node;
- 从 `audioRenderThread` 出来的 Audio Node;

### 关于时间戳
取第一帧的系统时间，重新构造时间戳：

```c
Float64 base_time = CFAbsoluteTimeGetCurrent() * 1000;
Float64 newpts = node.pts * 1000 + base_time;
```
稍后我们讨论时间戳构造的细节；

### 流的去向



## WLCameraSource

## WLAudioSource