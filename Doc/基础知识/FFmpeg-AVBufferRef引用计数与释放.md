# FFmpeg AVBufferRef 引用计数与释放

## 核心结论

FFmpeg 中所有 `AVBufferRef *` 类型的字段（`hw_device_ctx`、`hw_frames_ctx`、`AVFrame.buf[]` 等），**必须用 `av_buffer_unref()` 释放，不能用 `free()`**。

## 内存模型

```
av_hwdevice_ctx_create(&hw_device_ctx, ...)
    │
    ▼
┌─────────────────────────────────┐
│  AVBufferRef (引用句柄)           │  ← hw_device_ctx 指向这里
│  ├─ refcount = 1                │
│  └─ *data ──────────────────────┼──┐
└─────────────────────────────────┘  │
                                     ▼
                              ┌──────────────────────┐
                              │  AVBuffer (底层对象)    │
                              │  ├─ 真正的硬件设备资源   │
                              │  ├─ refcount 管理       │
                              │  └─ free 回调           │
                              └──────────────────────┘
```

- `av_hwdevice_ctx_create` → 内部调用 `av_buffer_create` 分配底层 `AVBuffer`
- 返回的 `AVBufferRef` 是**引用句柄**，不是裸内存
- `av_buffer_ref()` → 引用计数 +1（如 codec ctx 绑定硬解时用）
- `av_buffer_unref()` → 引用计数 -1，归零时触发底层 `free` 回调，真正释放资源

## 正确的释放方式

```c
// ✅ 正确
av_buffer_unref(&decoder->hw_device_ctx);

// ❌ 错误：只释放了 AVBufferRef 外壳，底层硬件资源泄漏
free(decoder->hw_device_ctx);
```

## 多引用场景

```c
// 分配硬件设备上下文，refcount = 1
av_hwdevice_ctx_create(&decoder->hw_device_ctx, ...);

// 绑定到 codec ctx，refcount = 2（共享同一底层对象）
decoder->video_codec_ctx->hw_device_ctx = av_buffer_ref(decoder->hw_device_ctx);

// 释放顺序（先释放 codec ctx，再释放我们持有的引用）：
avcodec_free_context(&decoder->video_codec_ctx);  // refcount 2→1
av_buffer_unref(&decoder->hw_device_ctx);          // refcount 1→0，真正释放
```

**顺序不能反**：如果先 `av_buffer_unref` 再 `avcodec_free_context`，codec ctx 内部访问的 `hw_device_ctx` 可能已经是悬垂引用（虽然 refcount 机制通常能兜底，但不保证安全）。

## 适用范围

FFmpeg 中所有通过 `av_buffer_create` 分配的引用计数对象都遵循此规则：

| 字段 | 分配函数 | 释放函数 |
|------|---------|---------|
| `AVCodecContext->hw_device_ctx` | `av_hwdevice_ctx_create` | `av_buffer_unref` |
| `AVCodecContext->hw_frames_ctx` | `av_hwframe_ctx_alloc` | `av_buffer_unref` |
| `AVFrame->buf[]` | `av_frame_get_buffer` | `av_buffer_unref`（或 `av_frame_free`） |
| `AVBufferRef *` 返回值 | `av_buffer_ref` / `av_hwdevice_ctx_create` | `av_buffer_unref` |

## 一句话总结

> `malloc` 配 `free`，`av_buffer_*` 配 `av_buffer_unref`。看到 `AVBufferRef *`，一律 `av_buffer_unref`。
