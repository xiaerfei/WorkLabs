# RTMP 聚合转发 — 时间戳重算与音视频同步

## 1. 背景与问题描述

在 iOS App 上实现了一个 RTMP Server，其它设备可以向其推送视频流。App 是聚合类应用，可将接收到的流转发至 YouTube、Twitter、Facebook 等平台（经由云服务器中转）。

### 当前时间戳重算公式

App 接收到音频流和视频流后，会重新计算它们的时间戳：

| 变量 | 说明 |
|------|------|
| `system_timestamp` | 系统时间戳，精度毫秒 |
| `first_video_timestamp` | 视频第一帧的时间戳 |
| `first_audio_timestamp` | 音频第一帧的时间戳 |
| `base_timestamp` | 基准时间戳，第一帧到达时获取的系统时间 |
| `video_frame_timestamp` | 从视频帧中获取的帧时间戳，精度毫秒 |
| `audio_frame_timestamp` | 从音频帧中获取的帧时间戳，精度毫秒 |

```c
new_video_timestamp = base_timestamp + (video_frame_timestamp - first_video_timestamp);
new_audio_timestamp = base_timestamp + (audio_frame_timestamp - first_audio_timestamp);
```

---

## 2. 当前方案的核心缺陷

### 2.1 基准漂移与时钟异步（Clock Drift）

推送端的设备时钟（产生 `video_frame_timestamp` 的时钟）与 iOS App 系统时钟（`base_timestamp` 的来源）不一致。

- 如果推送端的时钟比 iOS App 的时钟快，`(video_frame_timestamp - first_video_timestamp)` 的增长速度会超过系统实际流逝的时间。
- **后果：** 随着直播时间增加，重计算后的 `new_timestamp` 会逐渐偏离真实的墙上时间（Wall Clock），导致云端转发时缓冲区溢出或排队延迟，最终体现为音画不同步。

### 2.2 初始帧的时间差（Race Condition）

公式假设视频和音频的"第一帧"是同时到达的，但实际上：

- RTMP 连接建立后，音频第一帧和视频第一帧到达 iOS App 的时间通常有先后差异（几十毫秒到几百毫秒不等）。
- 为音频和视频分别使用 `first_video_timestamp` 和 `first_audio_timestamp`，会**抹平原始流中音视频之间的偏移量**。

> **示例：** 如果原始流中视频比音频晚 100ms 产生，公式会把它们都强制对齐到 `base_timestamp`，导致播放端声音和画面错位。

### 2.3 精度损失与累计误差

`system_timestamp` 精度为毫秒，RTMP 内部时间戳也是毫秒，但在音视频编码底层（如 AAC 或 H.264），采样频率转换时简单的加减法会导致微小的舍入误差。

---

## 3. 优化设计方案

### 方案 A：透传原始相对增量（推荐）

如果 App 只是做转发（Relay），最理想的做法是不通过系统时间重算，而是保留原始流的相对时间戳关系。

```c
// 记录第一次收到的帧的时间（不论音视频）
if (is_first_frame) {
    global_start_timestamp = packet.timestamp; 
    is_first_frame = false;
}

// 所有的帧都减去同一个全局起始值
new_timestamp = packet.timestamp - global_start_timestamp;
```

- **优点：** 完美保留了推流端原始的音画同步关系（DTS/PTS 比例）。

### 方案 B：统一基准时钟

如果必须使用 `base_timestamp`（例如为了对齐多个推流源），需要**统一基准**：

1. **统一 Base：** 只记录第一个到达的帧（无论是音还是视）的系统时间作为 `base_system_time`。
2. **统一 Offset：** 只记录第一个到达帧的原始时间戳作为 `base_source_time`。
3. **计算公式：**

$$new\_timestamp = base\_system\_time + (current\_frame\_timestamp - base\_source\_time)$$

> 注意：音频和视频必须减去同一个 `base_source_time`。

### 方案 C：处理时钟抖动（Jitter Buffer）

由于网络抖动，帧到达的时间是不稳定的。如果 iOS App 接收压力大，`system_timestamp` 可能会受到线程调度的影响。

- **建议：** 在发送到云端前，检查 `new_timestamp` 是否单调递增。RTMP 严禁时间戳回退，一旦出现回退，YouTube 等平台可能会直接断开连接。

### 核心改进总结

| 改进项 | 说明 |
|--------|------|
| **删掉** | `first_video_timestamp` 和 `first_audio_timestamp` 的区分 |
| **建立** | 一个全局的 `first_frame_timestamp`（谁先到就取谁） |
| **确保** | 音频和视频帧在计算新时间戳时，减去的是同一个原始基准值 |

---

## 4. PLL 锁相环算法

引入 **PLL（Phase-Locked Loop，锁相环）** 算法，使用 `new_video_timestamp` 和 `system_timestamp` 的差值，不断矫正 `base_timestamp`，以解决异构时钟同步问题。

### 4.1 误差信号的输入选择

误差定义为：

$$\Delta = system\_timestamp - (base\_timestamp + video\_relative\_offset)$$

- **注意：** `system_timestamp` 容易受系统调度、网络抖动（Jitter）影响。如果直接将每一帧的差值都丢进 PLL，会导致 `base_timestamp` 频繁抖动。
- **建议：** 在进入 PLL 之前，先对 `system_timestamp` 进行低通滤波（Low-pass Filter）或简单的滑动平均，滤除由于系统抢占 CPU 导致的毫秒级瞬时抖动。

### 4.2 避免"追赶"过快

PLL 的核心是**比例-积分（PI）控制**：

- 如果校准 `base_timestamp` 的步长过大，输出的时间戳序列会出现明显的"跳跃"。
- **后果：** 某些流媒体服务器对时间戳平滑度有严格要求，突然跳变可能触发服务器端缓冲区重置。
- **优化：** 确保 `base_timestamp` 的修正是一个极其微小的增量过程（例如每帧只修正几个微秒）。

### 4.3 修正量的"阈值"控制（Deadband）

系统时间戳本身存在操作系统的调度抖动，通常在 $1 \sim 10$ 毫秒之间。

- **设计建议：** 引入**死区（Deadband）**。如果 $|system\_timestamp - new\_timestamp| < 5ms$，则不触发 PI 调节。
- **目的：** 避免 PLL 追随系统层面的微小噪声，保证输出时间戳序列在微观上保持绝对等间距。

### 4.4 积分饱和与抗饱和（Anti-windup）

在 PLL 的 PI 控制器中，积分项（I）用于消除静态误差。但如果推流端网络突然中断几秒又恢复，积分项会累积一个巨大的误差。

- **风险：** 恢复后 PLL 会尝试疯狂补偿，导致 `base_timestamp` 剧烈跳变。
- **对策：** 必须给积分项设置**上下限（Clamping）**。同时，当检测到时间戳断档（Gap > 500ms）时，直接重置 PLL 而不是尝试平滑修正。

### 4.5 音视频"重心"对齐

不要只根据视频流来修正。如果视频帧率是 30fps，音频采样包是每 20ms 一个，可以计算一个"加权误差"：

$$\Delta_{combined} = W_v \cdot \Delta_{video} + W_a \cdot \Delta_{audio}$$

- 使用音视频共同的误差来修正全局的 `base_timestamp`。
- 即便视频因编码负载高出现瞬间延迟，音频作为更稳定的参考源（音频时钟通常比视频更准）能拉住 `base_timestamp` 不至于跑偏。

### 4.6 音视频同步的致命风险

**是否为音频和视频分别运行了两个 PLL？**

- ❌ **错误做法：** 视频流校准一个 `base_video_timestamp`，音频流校准一个 `base_audio_timestamp`。因为音视频的抖动特征不同，两个 PLL 可能向不同方向收敛。
- ✅ **正确做法：** 以视频为"主时钟"运行 PLL 产生校准后的 `base_timestamp`，音频强制共享该基准。

### 4.7 PLL 控制逻辑伪代码

```c
// Phase Detector (鉴相器)：计算 diff = system_timestamp - current_calculated_timestamp
// Loop Filter (环路滤波)：PI 控制器计算修正量
// VCO (压控振荡器)：将 Adjustment 应用到 base_timestamp 的更新步长中

// 平滑修正逻辑
double error = system_now - (base_timestamp + (frame_ts - first_ts));

// 1. 低通滤波，过滤系统抖动
filtered_error = low_pass_filter(error);

// 2. PI 控制器计算修正步长
adjustment = Kp * filtered_error + Ki * integral_error;

// 3. 限制单次最大修正量，比如每帧修正不得超过 0.5ms
adjustment = clamp(adjustment, -0.5, 0.5);

// 4. 应用修正
base_timestamp += adjustment;
```

### 4.8 验证方法

- 使用 `ffprobe` 查看云端收到流的 **DTS 增量**：如果 PLL 工作良好，DTS 增量应非常接近原始帧率（如 33.3ms），且没有跳变。
- 运行数小时后，查看 `base_timestamp` 与 `system_timestamp` 的相对偏移，如果趋于稳定常数，说明 PLL 已成功锁定频率。

---

## 5. 音频修正的引入

### 5.1 核心原则

**"一个基准，加权反馈"**。不需要两个 PLL，而是将音频和视频的误差加权合并后，输入到同一个 PLL 环路。

$$Error_{total} = (Error_{video} \times W_{video}) + (Error_{audio} \times W_{audio})$$

- **权重分配：** 建议音频权重略高于视频（例如 $W_a=0.6, W_v=0.4$），因为音频时钟的抖动通常比经过编码器后的视频时钟更小。
- **计算方式：**
  - $Error_{v} = System\_Time - (Base\_Time + Video\_Offset)$
  - $Error_{a} = System\_Time - (Base\_Time + Audio\_Offset)$

### 5.2 音频帧的特殊处理（采样对齐）

视频帧是离散的（如 30fps），但音频是连续的采样。建议使用**采样数**来校验，而不是仅依赖 RTMP 包自带的时间戳。

```c
// 更精确的音频偏移计算
// Audio_Offset = (已接收总采样数 / 采样率) * 1000
double audio_offset_ms = (total_samples_received / 44100.0) * 1000.0;
```

这样可以避免因 RTMP 打包导致的毫秒级取整误差进入 PLL 反馈环路。

### 5.3 改进后的 PLL 控制逻辑

```c
// 每当音频包或视频包到达时调用
void update_pll(long long frame_ts, bool is_audio) {
    long long now = get_system_time_ms();
    
    // 1. 计算当前帧的理论系统时间
    long long first_ts = is_audio ? first_audio_ts : first_video_ts;
    long long expected_system_time = base_timestamp + (frame_ts - first_ts);
    
    // 2. 计算瞬时误差
    double current_error = (double)(now - expected_system_time);
    
    // 3. 修正 base_timestamp (平滑修正)
    // 如果是音频帧，修正步长可以稍微激进一点点，因为它更准
    double step = is_audio ? Kp_audio * current_error : Kp_video * current_error;
    
    // 4. 限制单次修正上限（例如 0.2ms），防止抖动
    step = fmin(fmax(step, -0.2), 0.2);
    
    base_timestamp += step;
}
```

### 5.4 关键注意事项

- **防止"拉锯战"：** 如果音频和视频的原始流本身就存在严重的 Lip-sync 问题，合并修正会试图寻找中间值。建议增加判定：如果 $|Error_v - Error_a| > 100ms$，说明原始流已乱，应立即**停止音频修正**，仅以视频为准。
- **静音包处理：** 推流端发送静音包（Silent Frames）时，音频采样数不再增加，务必暂停音频对 PLL 的贡献，否则会导致 `base_timestamp` 停滞。

---

## 6. 业界成熟做法

### 6.1 OBS：绝对系统时钟对齐

OBS 的核心是一个**中心参考时钟（System Wall Clock）**。

- **硬件时间戳：** OBS 优先使用音视频采集卡/摄像头驱动提供的硬件时间戳。如果驱动不准，回退到采样瞬间的系统时间。
- **同步偏移（Sync Offset）：** OBS 允许用户手动设置每个源的毫秒偏移量。
- **输出对齐：** 在转发或推流时，将所有源的时间戳重映射到一个连续的、基于起始运行时间的线性序列。
- **核心逻辑：** OBS 认为"视频是每一帧的快照，音频是连续的流"，通常**以音频为基准**（因为音频采样率由声卡晶振决定，极其稳定）。如果视频慢了，重复上一帧；如果视频快了，丢弃多出来的帧。

### 6.2 WebRTC：RTCP SR + NetEQ

WebRTC 处理同步的逻辑是工业界最高标准，非常适合 RTMP 转发场景：

- **NTP 对齐：** 发送端发送 **RTCP SR 包**，包含两对数据：
  1. RTP 时间戳（由编码器生成，相对的）
  2. NTP 时间戳（绝对系统时间戳）
- **接收端同步（Lip-syncing）：** 接收端通过这组对应关系，计算出音频 RTP 和视频 RTP 对应到同一时刻的"绝对时间"。
- **NetEQ（Jitter Buffer）：** WebRTC 有极其复杂的算法，不仅修正时间戳，还会动态调整音频的播放速度：
  - **加速/减速播放：** 如果发现音频比视频慢了（由于时钟漂移），利用 **WSOLA（波形相似叠加）算法** 在不改变音调的前提下，悄悄把音频缩短（加速播放），从而追上视频。

### 6.3 针对当前 App 的"业界级"改进建议

#### A. "音频驱动视频"模式（Audio-Driven）

- **做法：** PLL 应该完全**锁定音频流**。
- **原理：** 假设音频每秒产生 44100 个采样点，无论系统时间如何抖动，44100 个点就是 1000ms。可以根据 `(已处理采样数 / 采样率)` 得到一个极其完美的 `Audio_Base_Time`。
- **同步视频：** 视频帧到达后，根据它与音频帧在接收端的时间差，计算其 `new_video_timestamp`。

#### B. 引入 NTP 外部参考

- 不要在 iOS 本地做过多的"猜测"。
- 在 RTMP 协议中，尽可能透传原始流的 DTS/PTS 差值。如果必须重写，请确保 `new_video_timestamp - new_audio_timestamp` 的差值与原始流保持一致。

#### C. 处理网络抖动（Jitter Buffer）

- 建立约 200ms-500ms 的**缓冲区**。
- 不要一收到包就跑 PLL。先让包在缓冲区里排队，取缓冲区中间的包来计算 `system_timestamp` 的差值，能过滤掉 90% 的瞬时网络延迟波动。

### 6.4 对比总结

| 维度 | 基础做法 | 业界成熟做法（OBS/WebRTC） |
|:---|:---|:---|
| **时钟源** | 系统 `gettimeofday` | **音频采样时钟**（Audio Master） |
| **漂移处理** | PLL 平滑修正 `base` | **重采样/WSOLA**（动态伸缩音频包） |
| **音画对齐** | 分别计算 Offset | **RTCP-like 映射表**（统一映射到 NTP） |
| **容错性** | 持续修正 | **跳变检测**（Gap > 500ms 时立即重置） |

> 如果希望实现像 OBS 那么稳的效果，建议把 PLL 逻辑调整为：**"以音频采样进度为绝对参考系，通过 PLL 微调视频帧的呈现时间戳"**。

参考：[How to Sync Audio and Video (OBS Studio Tutorial)](https://www.youtube.com/watch?v=inKl1YPeAAs)

---

## 7. 保证 A/V Delta 一致性

### 7.1 核心原则

**放弃为音频和视频分别建立基准，转而使用"单一全局偏移量（Global Offset）"。**

在业界（如 FFmpeg 的转录逻辑或 WebRTC 的对齐逻辑），这种做法被称为 **Relative Re-timestamping**。

不再需要 `first_video_timestamp` 和 `first_audio_timestamp`，只需要一个**全局起始锚点**。

### 7.2 处理逻辑

```c
// 全局状态
double base_timestamp;      // PLL 矫正后的系统基准时间
long long first_source_ts;  // 原始流中收到的第一个包的时间戳（不分音视频）
bool is_initialized = false;
```

当任何一个包（无论是音频还是视频）到达时：

```c
void process_packet(Packet packet) {
    if (!is_initialized) {
        // 1. 记录原始流的绝对起点
        first_source_ts = packet.timestamp;
        // 2. 记录此时的系统基准（初次采样）
        base_timestamp = get_system_time_ms();
        is_initialized = true;
    }

    // 3. 计算当前包相对于原始流起点的偏移
    // 关键点：无论音视频，都减去同一个 first_source_ts
    long long relative_offset = packet.timestamp - first_source_ts;

    // 4. 应用 PLL 矫正后的基准
    packet.new_timestamp = base_timestamp + relative_offset;

    // 5. 将 error 送入 PLL 环路（仅用于平滑修正 base_timestamp）
    double error = get_system_time_ms() - packet.new_timestamp;
    update_pll(error); 
    
    send_to_cloud(packet);
}
```

### 7.3 数学证明

假设原始流中：
- 视频某帧时间戳为 $V_{orig}$
- 音频某帧时间戳为 $A_{orig}$
- 原始差值 $\Delta_{orig} = V_{orig} - A_{orig}$

使用统一公式计算后：
- $new\_V = base\_timestamp + (V_{orig} - first\_source\_ts)$
- $new\_A = base\_timestamp + (A_{orig} - first\_source\_ts)$

两者相减：

$$new\_V - new\_A = (base\_timestamp - base\_timestamp) + (V_{orig} - A_{orig}) + (first\_source\_ts - first\_source\_ts) = \Delta_{orig}$$

**结论：** 只要 `base_timestamp` 在处理音视频帧的极短时间内没有剧烈跳变，它们的相对距离就完全由原始时间戳决定。

### 7.4 处理"原始流时间戳回绕或重置"

在 RTMP 长时间推流中，推流端断开重连可能导致原始 `packet.timestamp` 突然跳变。

**健壮做法：**

1. **检测跳变：** 如果 `abs(packet.timestamp - last_packet_timestamp) > 5000ms`（阈值可调），认为原始流发生了断档或重置。
2. **更新锚点：**

```c
if (detect_gap) {
    // 补偿旧的偏移量，使 new_timestamp 连续
    long long current_output_max = max(last_video_out, last_audio_out);
    base_timestamp = current_output_max + 20; // 留出 20ms 间隔
    first_source_ts = packet.timestamp;       // 重新对齐原始流起点
}
```

### 7.5 方案总结

| 原则 | 说明 |
|------|------|
| **统一基准** | 严禁分音视频计算 `first_timestamp` |
| **单点反馈** | PLL 只负责缓慢移动 `base_timestamp` |
| **透传增量** | 所有的音视频帧共享同一个 `first_source_ts` 减法器 |

这样无论 PLL 如何修正系统性漂移，音频和视频都会像被一根"刚性杆"连接在一起，同步移动。

---

## 8. Python 模拟验证

### 8.1 模拟代码

```python
import numpy as np
import matplotlib.pyplot as plt

class TimestampPLL:
    def __init__(self, kp=0.01, ki=0.001, max_step=0.5):
        self.kp = kp
        self.ki = ki
        self.max_step = max_step
        self.integral_error = 0
        
        self.base_timestamp = None
        self.first_source_ts = None
        self.is_initialized = False

    def process_packet(self, orig_ts, system_now):
        if not self.is_initialized:
            self.first_source_ts = orig_ts
            self.base_timestamp = system_now
            self.is_initialized = True
            return self.base_timestamp

        # 1. 计算原始相对偏移 (A/V Delta 在此锁定)
        relative_offset = orig_ts - self.first_source_ts

        # 2. 计算当前预测的时间戳
        predicted_ts = self.base_timestamp + relative_offset

        # 3. 计算与系统时钟的误差
        error = system_now - predicted_ts

        # 4. PI 控制器计算修正量
        self.integral_error += error
        # 限制积分饱和
        self.integral_error = np.clip(self.integral_error, -100, 100)
        
        adjustment = self.kp * error + self.ki * self.integral_error
        
        # 5. 限制单次修正步长，保证平滑
        adjustment = np.clip(adjustment, -self.max_step, self.max_step)

        # 6. 修正全局基准
        self.base_timestamp += adjustment

        # 返回最终映射后的时间戳
        return self.base_timestamp + relative_offset

# --- 模拟实验 ---

def simulate_streaming(drift_rate=0.005, jitter_amp=10, reset_at=500):
    """
    drift_rate: 时钟偏移率 (0.005 代表推流端时钟每秒快 5ms)
    jitter_amp: 网络抖动幅度 (ms)
    reset_at: 在第几帧发生时间戳重置
    """
    pll = TimestampPLL(kp=0.05, ki=0.005)
    
    results = []
    source_clock = 0
    system_clock = 0
    
    for i in range(1000):
        # 模拟推流端生成音视频包 (交替产生)
        is_video = i % 2 == 0
        interval = 33 if is_video else 20 # 视频~30fps, 音频~50fps
        
        source_clock += interval
        system_clock += interval * (1 + drift_rate) # 系统时钟与源时钟存在漂移
        
        # 模拟时间戳异常：在指定位置发生重置
        orig_ts = source_clock
        if i > reset_at:
            orig_ts -= 5000  # 模拟推流端突然重置了时间戳
        
        # 模拟网络传输抖动 (到达系统的时间是不稳定的)
        arrival_time = system_clock + np.random.uniform(-jitter_amp, jitter_amp)
        
        # 处理时间戳
        new_ts = pll.process_packet(orig_ts, arrival_time)
        
        results.append({
            'frame': i,
            'type': 'V' if is_video else 'A',
            'orig_ts': orig_ts,
            'new_ts': new_ts,
            'error': arrival_time - new_ts
        })
        
    return results

# 运行模拟
data = simulate_streaming()

# --- 验证 A/V Delta ---
v_frames = [d for d in data if d['type'] == 'V']
a_frames = [d for d in data if d['type'] == 'A']

idx = 100
orig_delta = v_frames[idx]['orig_ts'] - a_frames[idx]['orig_ts']
new_delta = v_frames[idx]['new_ts'] - a_frames[idx]['new_ts']
print(f"原始音画差值: {orig_delta}ms")
print(f"修正后音画差值: {new_delta}ms")
print(f"同步保真度: {'成功' if abs(orig_delta - new_delta) < 1e-6 else '失败'}")
```

### 8.2 模拟的异常场景

| 异常场景 | 模拟方式 | 预期表现 |
|----------|----------|----------|
| **时钟漂移** | `system_clock += interval * (1 + drift_rate)` | PLL 通过不断微调 `base_timestamp` 追赶斜率 |
| **网络抖动** | `np.random.uniform(-jitter_amp, jitter_amp)` | 由于 `max_step` 限制，输出 `new_ts` 依然平滑 |
| **时间戳重置** | `orig_ts -= 5000` | 需检测误差超阈值后重置 `first_source_ts` |

> 实际代码中，如果 `error` 超过巨大阈值（如 > 1000ms），应重置 `first_source_ts`。

### 8.3 核心公式

$$Adjustment = K_p \cdot (SystemNow - PredictedTS) + K_i \cdot \sum (SystemNow - PredictedTS)$$

### 8.4 在 iOS 上这样写的优势

1. **低耦合：** 音频线程和视频线程不需要频繁通信，只需要共享一个 PLL 对象。
2. **抗干扰：** 即使 iOS 因系统通知弹出导致 UI 线程卡顿（导致某几帧 `system_now` 异常大），PLL 的 `max_step` 限制了它不会立刻产生剧烈跳变。
3. **云端友好：** 转发给 YouTube/Facebook 的流，时间戳序列极其平滑，极大地降低了云端转码失败的概率。
