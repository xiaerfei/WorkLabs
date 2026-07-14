# `obs_source_info` 结构体详解

> 文件位置: [`libobs/obs-source.h`](libobs/obs-source.h#L218-L563)
> 行范围: L218 – L563

## 一、概述

`obs_source_info` 是 OBS libobs 中**最核心的源类型注册结构**。它本质上是一个"虚函数表"(vtable)，定义了一种源类型（输入源 / 滤镜 / 场景过渡）的全部行为。

插件通过 [`obs_register_source()`](libobs/obs-source.h#L574-L575) 宏把此结构注册给 libobs，OBS 在运行时根据这些回调来管理源的生命周期、渲染、音频、交互等。

```c
#define obs_register_source(info) \
    obs_register_source_s(info, sizeof(struct obs_source_info))
```

宏自动传入结构体大小，便于 libobs 做向前兼容（新增字段时老插件仍可工作）。

---

## 二、设计理念

1. **面向对象的 C 风格**：所有回调的第一个参数 `void *data` 相当于 C++ 的 `this`，由 [`create`](libobs/obs-source.h#L252) 分配、[`destroy`](libobs/obs-source.h#L260) 释放。
2. **能力即标志位**：[`output_flags`](libobs/obs-source.h#L235) 决定 OBS 如何调度源（是否异步、是否自带绘制、是否可音频等），与回调函数配合表达源的完整能力。
3. **v2 系列回调**：[`get_defaults2`](libobs/obs-source.h#L515) / [`get_properties2`](libobs/obs-source.h#L524) 允许获取 [`type_data`](libobs/obs-source.h#L476)，是新版推荐用法；老版会被先调用再调用 v2。
4. **必填与可选分离**：结构体注释明确划分为 "Required implementation" 与 "Optional implementation"。

---

## 三、必填字段（Required Implementation）

位于 [L218-L268](libobs/obs-source.h#L218-L268)。

| 字段 | 类型 | 说明 |
|---|---|---|
| [`id`](libobs/obs-source.h#L223) | `const char *` | 源类型的唯一字符串 ID（如 `"dshow_input"`、`"color_source"`）。 |
| [`type`](libobs/obs-source.h#L232) | `enum obs_source_type` | 源类型枚举：<br>• `OBS_SOURCE_TYPE_INPUT` 输入源<br>• `OBS_SOURCE_TYPE_FILTER` 滤镜<br>• `OBS_SOURCE_TYPE_TRANSITION` 场景过渡 |
| [`output_flags`](libobs/obs-source.h#L235) | `uint32_t` | 输出能力位掩码（视频/音频/异步/自定义绘制等）。常用标志见 `OBS_SOURCE_*` 宏，如 `OBS_SOURCE_VIDEO`、`OBS_SOURCE_AUDIO`、`OBS_SOURCE_ASYNC`、`OBS_SOURCE_CUSTOM_DRAW` 等。 |
| [`get_name`](libobs/obs-source.h#L243) | `const char *(*)(void *type_data)` | 返回该源类型的（已翻译）显示名。 |
| [`create`](libobs/obs-source.h#L252) | `void *(*)(obs_data_t *settings, obs_source_t *source)` | 实例化源时分配私有数据 `data`，返回值会作为后续所有回调的首参。 |
| [`destroy`](libobs/obs-source.h#L260) | `void (*)(void *data)` | 销毁源时释放 `data`。异步源在返回后不得再调用 `obs_source_output_video`。 |
| [`get_width`](libobs/obs-source.h#L264) | `uint32_t (*)(void *data)` | 返回源输出宽度。非异步视频输入源必填。 |
| [`get_height`](libobs/obs-source.h#L268) | `uint32_t (*)(void *data)` | 返回源输出高度。非异步视频输入源必填。 |

---

## 四、可选回调（Optional Implementation）

位于 [L270-L562](libobs/obs-source.h#L270-L562)，按功能分组说明。

### 4.1 设置与属性

| 字段 | 行号 | 说明 |
|---|---|---|
| [`get_defaults`](libobs/obs-source.h#L279) | L279 | 获取默认设置。**已废弃**，建议用 `get_defaults2`。 |
| [`get_defaults2`](libobs/obs-source.h#L515) | L515 | 获取默认设置（可拿到 `type_data`）。若同时定义两者，先调 `get_defaults` 再调 `get_defaults2`。 |
| [`get_properties`](libobs/obs-source.h#L287) | L287 | 返回属性 UI 描述（`obs_properties_t`）。**已废弃**，建议用 `get_properties2`。 |
| [`get_properties2`](libobs/obs-source.h#L524) | L524 | 返回属性 UI 描述（可拿到 `type_data`）。 |
| [`update`](libobs/obs-source.h#L295) | L295 | 设置变更时调用，用于把新 `settings` 应用到 `data`。 |
| [`save`](libobs/obs-source.h#L401) | L401 | 序列化保存时的钩子，允许源在保存时刻再更新一次设置。 |
| [`load`](libobs/obs-source.h#L411) | L411 | 从保存数据反序列化时的钩子。应在所有源加载完成后再调用，因为可能有相互依赖。 |

### 4.2 生命周期

| 字段 | 行号 | 说明 |
|---|---|---|
| [`activate`](libobs/obs-source.h#L298) | L298 | 源在主视图中被激活时调用。 |
| [`deactivate`](libobs/obs-source.h#L304) | L304 | 源从主视图中取消激活（不再播放/显示）时调用。 |
| [`show`](libobs/obs-source.h#L307) | L307 | 源变为可见时调用。 |
| [`hide`](libobs/obs-source.h#L310) | L310 | 源不再可见时调用。 |

### 4.3 视频渲染

| 字段 | 行号 | 说明 |
|---|---|---|
| [`video_tick`](libobs/obs-source.h#L318) | L318 | 每个视频帧调用，传入距上一帧的秒数 `seconds`。 |
| [`video_render`](libobs/obs-source.h#L347) | L347 | 渲染调用。输入/过渡源用于绘制自身纹理；滤镜源用于包装目标源的绘制（推荐用 `obs_source_process_filter`）。<br>若 `output_flags` 不含 `SOURCE_CUSTOM_DRAW`，只需设置 effect 的 `image` 参数即可；若含 `SOURCE_COLOR_MATRIX`，可设置 `color_matrix` 参数（默认 YUV→RGB）。 |
| [`video_get_color_space`](libobs/obs-source.h#L552) | L552 | 协商源的颜色空间，传入候选 `preferred_spaces` 列表。 |
| [`filter_video`](libobs/obs-source.h#L359) | L359 | **滤镜专用**。过滤原始异步视频帧，可返回新帧或延迟处理。 |

### 4.4 音频

| 字段 | 行号 | 说明 |
|---|---|---|
| [`filter_audio`](libobs/obs-source.h#L376) | L376 | **滤镜专用**。过滤音频数据，可直接修改并返回，或延迟处理。返回的新数据须存活到下次调用或滤镜销毁。 |
| [`audio_render`](libobs/obs-source.h#L483) | L483 | 同步音频源输出。 |
| [`audio_mix`](libobs/obs-source.h#L526) | L526 | 音频混音。 |

### 4.5 子源枚举

| 字段 | 行号 | 说明 |
|---|---|---|
| [`enum_active_sources`](libobs/obs-source.h#L388) | L388 | 枚举当前活跃的子源。若源有渲染音视频的子源，**必填**。 |
| [`enum_all_sources`](libobs/obs-source.h#L499) | L499 | 枚举所有子源（含非活跃）。未实现时回退到 `enum_active_sources`。 |

### 4.6 交互（鼠标 / 键盘）

| 字段 | 行号 | 说明 |
|---|---|---|
| [`mouse_click`](libobs/obs-source.h#L423) | L423 | 鼠标按下/抬起。参数：事件、按键类型、是否抬起、点击次数。 |
| [`mouse_move`](libobs/obs-source.h#L432) | L432 | 鼠标移动。含 `mouse_leave` 离开状态。 |
| [`mouse_wheel`](libobs/obs-source.h#L443) | L443 | 鼠标滚轮。含 `x_delta` / `y_delta`。 |
| [`focus`](libobs/obs-source.h#L452) | L452 | 获取/失去焦点。 |
| [`key_click`](libobs/obs-source.h#L462) | L462 | 键盘按下/抬起。 |

### 4.7 滤镜钩子

| 字段 | 行号 | 说明 |
|---|---|---|
| [`filter_add`](libobs/obs-source.h#L562) | L562 | 滤镜被添加到某源时调用。 |
| [`filter_remove`](libobs/obs-source.h#L471) | L471 | 滤镜从某源移除时调用。 |

### 4.8 场景过渡

| 字段 | 行号 | 说明 |
|---|---|---|
| [`transition_start`](libobs/obs-source.h#L503) | L503 | 过渡开始。 |
| [`transition_stop`](libobs/obs-source.h#L504) | L504 | 过渡结束。 |

### 4.9 媒体控制

位于 [L533-L542](libobs/obs-source.h#L533-L542)，用于媒体源（如视频文件播放）。

| 字段 | 说明 |
|---|---|
| [`media_play_pause`](libobs/obs-source.h#L534) | 播放/暂停切换。 |
| [`media_restart`](libobs/obs-source.h#L535) | 重新开始。 |
| [`media_stop`](libobs/obs-source.h#L536) | 停止。 |
| [`media_next`](libobs/obs-source.h#L537) | 下一首。 |
| [`media_previous`](libobs/obs-source.h#L538) | 上一首。 |
| [`media_get_duration`](libobs/obs-source.h#L539) | 获取总时长（毫秒）。 |
| [`media_get_time`](libobs/obs-source.h#L540) | 获取当前时间（毫秒）。 |
| [`media_set_time`](libobs/obs-source.h#L541) | 跳转到指定时间（毫秒）。 |
| [`media_get_state`](libobs/obs-source.h#L542) | 获取媒体状态（`enum obs_media_state`）。 |

### 4.10 元数据与杂项

| 字段 | 行号 | 说明 |
|---|---|---|
| [`type_data`](libobs/obs-source.h#L476) | L476 | 注册者私有数据，会回传给 `get_name` / `get_defaults2` / `get_properties2` / `free_type_data`。 |
| [`free_type_data`](libobs/obs-source.h#L481) | L481 | 关闭时释放 `type_data`。 |
| [`icon_type`](libobs/obs-source.h#L531) | L531 | UI 图标类型（`enum obs_icon_type`）。 |
| [`version`](libobs/obs-source.h#L545) | L545 | 版本号，新增功能时递增。 |
| [`unversioned_id`](libobs/obs-source.h#L546) | L546 | **内部使用**，不要手动设置。用于在 `version` 变化时保持同一逻辑 ID。 |
| [`missing_files`](libobs/obs-source.h#L549) | L549 | 返回缺失文件列表（`obs_missing_files_t`）。 |

---

## 五、典型注册示例（伪代码）

```c
/* 1. 声明 obs_source_info 并填充字段 */
struct obs_source_info my_input_info = {
    .id             = "my_custom_input",
    .type           = OBS_SOURCE_TYPE_INPUT,
    .output_flags   = OBS_SOURCE_VIDEO | OBS_SOURCE_CUSTOM_DRAW,
    .get_name       = my_input_get_name,
    .create         = my_input_create,
    .destroy        = my_input_destroy,
    .get_width      = my_input_get_width,
    .get_height     = my_input_get_height,
    .get_defaults2  = my_input_get_defaults2,
    .get_properties2= my_input_get_properties2,
    .update         = my_input_update,
    .video_tick     = my_input_video_tick,
    .video_render   = my_input_video_render,
    .icon_type      = OBS_ICON_TYPE_CAMERA,
};

/* 2. 在 obs_module_load 中注册 */
bool obs_module_load(void)
{
    obs_register_source(&my_input_info);
    return true;
}

/* 3. create / destroy 配对管理私有数据 */
struct my_input_data {
    int width;
    int height;
    /* ... */
};

static void *my_input_create(obs_data_t *settings, obs_source_t *source)
{
    struct my_input_data *data = bzalloc(sizeof(*data));
    /* 初始化 data ... */
    return data;
}

static void my_input_destroy(void *data)
{
    struct my_input_data *d = data;
    /* 释放内部资源 ... */
    bfree(d);
}
```

---

## 六、能力标志位速查（`output_flags`）

常见 `OBS_SOURCE_*` 标志（详见 `obs-source.h` 中相关宏定义）：

| 标志 | 含义 |
|---|---|
| `OBS_SOURCE_VIDEO` | 输出视频 |
| `OBS_SOURCE_AUDIO` | 输出音频 |
| `OBS_SOURCE_ASYNC` | 异步视频源（通过 `obs_source_output_video` 推帧） |
| `OBS_SOURCE_CUSTOM_DRAW` | 自定义绘制，`video_render` 的 `effect` 参数将为 `NULL` |
| `OBS_SOURCE_COLOR_MATRIX` | 允许在 effect 中设置自定义 `color_matrix` |
| `OBS_SOURCE_DO_NOT_DUPLICATE` | 不允许被复制 |
| `OBS_SOURCE_DO_NOT_SELF_MONITOR` | 不在监听设备中回放自身 |
| `OBS_SOURCE_INTERACTION` | 支持交互（鼠标/键盘） |

---

## 七、字段索引（按行号）

| 行号 | 字段 |
|---|---|
| L223 | `id` |
| L232 | `type` |
| L235 | `output_flags` |
| L243 | `get_name` |
| L252 | `create` |
| L260 | `destroy` |
| L264 | `get_width` |
| L268 | `get_height` |
| L279 | `get_defaults` (deprecated) |
| L287 | `get_properties` (deprecated) |
| L295 | `update` |
| L298 | `activate` |
| L304 | `deactivate` |
| L307 | `show` |
| L310 | `hide` |
| L318 | `video_tick` |
| L347 | `video_render` |
| L359 | `filter_video` |
| L376 | `filter_audio` |
| L388 | `enum_active_sources` |
| L401 | `save` |
| L411 | `load` |
| L423 | `mouse_click` |
| L432 | `mouse_move` |
| L443 | `mouse_wheel` |
| L452 | `focus` |
| L462 | `key_click` |
| L471 | `filter_remove` |
| L476 | `type_data` |
| L481 | `free_type_data` |
| L483 | `audio_render` |
| L499 | `enum_all_sources` |
| L503 | `transition_start` |
| L504 | `transition_stop` |
| L515 | `get_defaults2` |
| L524 | `get_properties2` |
| L526 | `audio_mix` |
| L531 | `icon_type` |
| L534-L542 | 媒体控制系列 |
| L545 | `version` |
| L546 | `unversioned_id` |
| L549 | `missing_files` |
| L552 | `video_get_color_space` |
| L562 | `filter_add` |

---

## 八、总结

写一个 OBS 源插件，本质上就是：

1. 实现一组 C 函数（生命周期 / 渲染 / 音频 / 交互等）；
2. 填充一个 `struct obs_source_info`，把函数指针指向上述实现；
3. 在 `obs_module_load` 中调用 `obs_register_source(&info)` 注册。

libobs 会在合适的时机回调这些函数，完成源的创建、渲染、销毁等全流程管理。
