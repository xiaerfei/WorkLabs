import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "M6-DJI-RTMP全栈.html")

# band 1 : 接入 → 分派 → 视频 → 汇入
B1W = [440, 460, 700, 460, 480]
B1X, TOTW = lanes(B1W, gap=68, x0=80)
R1 = [136 + i * 68 for i in range(4)]          # 136 204 272 340
G1T, G1H, A1Y = 108, 420, 428                  # 108..528

# band 2 : 音频 → 汇入 → 控制面
B2W = [700, 460, 480]
B2X = [B1X[2], B1X[3], B1X[4]]
R2 = [616 + i * 68 for i in range(4)]          # 616 684 752 820
G2T, G2H, A2Y = 588, 420, 908                  # 588..1008

d = Diagram(TOTW, 1080, "m6",
            "DJI RTMP 全栈 · 方法级调用图",
            "App 内建 RTMP 服务器：Transport 收字节，StreamConnection 完成 handshake 与 chunk 解析，"
            "MediaPipeline 按 messageTypeId 分派；上带是视频链路（配置 → 压缩域抖动缓冲 → 硬解 → index 200 入队），"
            "下带是音频链路（AAC 解码 → 重锚 PTS → 补施采集增益 → 三个出口）与控制面。")

d.group("① Transport   〔Network.framework 回调线程〕", B1X[0], G1T, B1W[0], G1H)
d.group("② TVUIRLStreamConnection   handshake + chunk 组包", B1X[1], G1T, B1W[1], G1H)
d.group("③ TVUIRLMediaPipeline   switch (messageTypeId)", B1X[2], G1T, B1W[2], G1H)
d.group("④ 视频：配置 → 抖动缓冲 → 硬解", B1X[3], G1T, B1W[3], G1H)
d.group("⑤ 汇入主管线（视频）", B1X[4], G1T, B1W[4], G1H)
d.group("⑥ 音频：配置 → 解码 → 重锚 → 增益", B2X[0], G2T, B2W[0], G2H)
d.group("⑦ 汇入主管线（音频三出口）", B2X[1], G2T, B2W[1], G2H)
d.group("⑧ 控制面与自愈", B2X[2], G2T, B2W[2], G2H)

# ---- ① Transport
N = B1X[0] + 40
d.node("t1", N, R1[0], 360, 52, "-startWithPort:streamKey:", "多次调用安全，先 stop 旧会话")
d.node("t2", N, R1[1], 360, 52, "TVUIRLTransportBackend", "Network.framework / AsyncSocket")
d.node("t3", N, R1[2], 360, 52, "TCP_NODELAY = YES", "关 Nagle · 到达抖动是卡顿主因")
d.node("t4", N, R1[3], 360, 52, "accept → [connection start]", "每连接一个 StreamConnection")
for a, b in (("t1", "t2"), ("t2", "t3"), ("t3", "t4")):
    d.edge(a, b, fs="b", ts="t")
d.annot(N, A1Y, [
    "DJI 设备把 App 当推流目标：码率 / 分辨率 / 帧率全由设备侧决定",
    "BLE 侧另有控制通道（TVUIRLDJIDeviceScanner / TVUIRLDJIStreamManager）",
    "负责扫描、配对与开关推流，与媒体面完全分离",
])

# ---- ② Connection
N = B1X[1] + 40
d.node("c1", N, R1[0], 380, 52, "handshake C0/C1 → S0/S1/S2 → C2", "RTMP 三次握手")
d.node("c2", N, R1[1], 380, 52, "读 chunk 头 → messageStreamId", "type 0/1/2/3 四种头格式")
d.node("c3", N, R1[2], 380, 52, "nextChunkDataSize()", "min(chunkSizeFromClient, remaining)")
d.node("c4", N, R1[3], 380, 52, "-appendChunkRawBytes:length:", "满一条完整消息才触发 process", style="focal")
for a, b in (("c1", "c2"), ("c2", "c3"), ("c3", "c4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("t4", "c1", fs="r", ts="l", route="hvh", gut=B1X[1] - 34)
d.annot(N, A1Y, [
    "每个 chunk stream id 一条 MediaPipeline，各自维护 messageLength /",
    "remainingMessageBytes / extendedTimestampPresentInType3",
    "WindowAck / FlowControl / SetChunkSize 走同一条分派",
    "TVUIRLBandwidthMeter 在这层统计吞吐（updateStats 返回快照）",
])

# ---- ③ 分派（一行四子）
N = B1X[2] + 40
d.node("p1", N, R1[0], 620, 52, "switch (self.messageTypeId)", "RTMP 消息类型分派", style="focal")
d.node("pa", N, R1[2], 190, 52, "-processAmf0Command", "connect / publish")
d.node("pv", N + 210, R1[2], 190, 52, "-processVideo", "读 control 字节")
d.node("pu", N + 420, R1[2], 200, 52, "-processAudio", "AAC seq header / raw")
d.node("px", N + 210, R1[3] + 8, 190, 52, "-processVideoExtendedHeader:", "HEVC(hvc1) 分支")
d.edge("p1", "pa", fs="b", ts="t", foff=-215)
d.edge("p1", "pv", fs="b", ts="t", foff=-5)
d.edge("p1", "pu", fs="b", ts="t", foff=205)
d.edge("pv", "px", fs="b", ts="t")
d.edge("c4", "p1", fs="r", ts="l", route="hvh", gut=B1X[2] - 34, label="整包")
d.annot(N, A1Y + 44, [
    "control 字节掩码曾写错：HEVC 关键帧首字节 0x90 与 0x0F 相与为 0，",
    "使 (control & X)==X 判断错位、路由不到 HEVC 分支 —— 改回 0x80 修好",
    "前 5 个 tag 打诊断日志（videoTagDiagCount 一次性判定，扩展头复用同一窗口）",
])

# ---- ④ 视频
N = B1X[3] + 40
d.node("v1", N, R1[0], 380, 52, "TVUIRLVideoConfigAvc / Hevc", "VPS / SPS / PPS → 格式描述")
d.node("v2", N, R1[1], 380, 52, "-appendSampleBuffer:", "进压缩域抖动缓冲")
d.node("v3", N, R1[2], 380, 52, "TVUIRLBufferedCompressedVideo", "单帧 FIFO · 严格不跳帧", style="focal")
d.node("v4", N, R1[3], 380, 52, "TVUIRLHardwareDecoder", "VTDecompressionSession")
for a, b in (("v1", "v2"), ("v2", "v3"), ("v3", "v4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("px", "v1", fs="r", ts="l", route="hvh", gut=B1X[3] - 34)
d.annot(N, A1Y, [
    "存压缩帧而非 NV12：内存省约 70×，对突发涌入免疫",
    "见底就等下一轮，不重复上一帧；溢出只在 IDR 边界整段丢最老 GOP",
    "—— 解码前丢中间帧会断参考链花屏，所以不能按帧丢",
    "-startOutput / -setTargetLatency: 把延迟量与容量解耦",
])

# ---- ⑤ 汇入（视频）
N = B1X[4] + 40
d.node("i1", N, R1[1], 400, 52, "-remapVideoDecodedPts:", "stream 轴 → host 时钟")
d.node("i2", N, R1[2], 400, 52, "AddBufferToWorkQueue(…, 200)", "OSMORTMPQueue · 刻意不是 −1", style="sink")
d.edge("i1", "i2", fs="b", ts="t")
d.edge("v4", "i1", fs="r", ts="l", route="hvh", gut=B1X[4] - 34, label="解码帧")
d.annot(N, A1Y, [
    "锚点是 basePresentationTimeStampMs",
    "videoRotation 由用户在 Advance 手选，setter 即时桥接到 TVUAVStreamManager",
    "handleOSMORTMPStream 完全按此角度旋转，与 app 方向无关",
    "流层面（RTMP / BLE / SEI 四路）都没有旋转角度 —— 所以只能手选",
])

# ---- ⑥ 音频
N = B2X[0] + 40
d.node("u1", N, R2[0], 300, 52, "TVUIRLAudioConfig", "从 seq header 取 ASC")
d.node("u2", N, R2[1], 300, 52, "TVUIRLAudioDecoder", "AAC → 48k / stereo / Int16")
d.node("u3", N, R2[2], 300, 52, "-remapAudioDecodedPts:", "不用 CACurrentMediaTime()")
d.node("u4", N, R2[3], 300, 52, "getAudioCaptureGain → 施加增益", "否则界面 Mute 对 DJI 无效", style="focal")
for a, b in (("u1", "u2"), ("u2", "u3"), ("u3", "u4")):
    d.edge(a, b, fs="b", ts="t")
d.node("u5", N + 340, R2[1], 300, 52, "TVUIRLMediaClock", "音视频 PTS 差变化 > 100ms 才调延迟")
d.node("u6", N + 340, R2[2], 300, 52, "TVUIRLDriftTracker", "单独跟踪两路漂移趋势")
d.edge("u3", "u5", fs="r", ts="l", route="hvh", gut=N + 320, style="dash")
d.edge("u5", "u6", fs="b", ts="t", style="dash")
d.edge("pu", "u1", fs="b", ts="t", route="vhv", gut=560, style="cross", label="音频消息")
d.annot(N, A2Y, [
    "audio underrun 绝不补静音：保 PTS 不输出，缺口交服务端重排",
    "MediaClock 用「最新音 PTS − 最新视频 PTS」的变化量做判据，不是绝对差",
])

# ---- ⑦ 音频三出口
N = B2X[1] + 40
d.node("o1", N, R2[0], 380, 52, "tvuSendAudioToScreenShare(…)", "投屏中 · 受 getShareScreenAudioMixType 控制", style="sink")
d.node("o2", N, R2[1], 380, 52, "OverlayAudioMixer::addDataToAudioMixer", "朗读开启时当主源", style="sink")
d.node("o3", N, R2[2], 380, 52, "[TVUAudioEncoderManager encode:&param]", "index 200 → M5", style="sink")
d.edge("u4", "o1", fs="r", ts="l", route="hvh", gut=B2X[1] - 48, label="投屏")
d.edge("u4", "o2", fs="r", ts="l", route="hvh", gut=B2X[1] - 34, foff=-12, label="朗读")
d.edge("u4", "o3", fs="r", ts="l", route="hvh", gut=B2X[1] - 20, foff=12, label="否则")
d.annot(N, A2Y, [
    "三个出口与 aacEncoder 里 mic 的四路分叉是同一套判据",
    "投屏那支送解码原始 PCM，增益由屏幕分享队列的 adjustAudioGain 施加",
])

# ---- ⑧ 控制面
N = B2X[2] + 40
d.node("w1", N, R2[0], 400, 52, "suspendLocalCapture", "收到首帧视频才挂起相机/麦克风", style="focal")
d.node("w2", N, R2[1], 400, 52, "forceResumeLocalCapture", "无视标志位硬拉回采集")
d.node("w3", N, R2[2], 400, 52, "previewPipelineAnomalyDescription", "返回 nil 表示管线健康")
d.node("w4", N, R2[3], 400, 52, "healPreviewPipelineIfStalled", "补回被吞掉的 ActiveAVStreamThread")
d.edge("w1", "w2", fs="b", ts="t", style="dash")
d.edge("w2", "w3", fs="b", ts="t", style="dash")
d.edge("w3", "w4", fs="b", ts="t", style="dash")
d.edge("o3", "w1", fs="r", ts="l", route="hvh", gut=B2X[2] - 34, style="dash", label="首帧副作用")
d.annot(N, A2Y, [
    "石锤特征：avThreadSuspended=1 且 onMainPage=1 持续出现",
    "healPreview 刻意只补 ActiveAVStreamThread + 启编码器，",
    "不补 OnAir / openAudio —— 那些不影响预览，交下一次正常生命周期",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "focal", "设计取舍集中处"),
    ("box", "sink", "出口"),
    ("line", "solid", "同线程调用"), ("line", "cross", "跨带（音频分支）"), ("line", "dash", "控制面 / 辅助"),
]

cards = [
    card("缓冲层的三条取舍", "coral", "为什么缓冲放在解码之前",
         ["存压缩帧而非 NV12：内存省约 70×，对突发涌入免疫",
          "严格不跳帧：解码前丢中间帧会断参考链花屏，只能在 IDR 边界整段丢",
          "见底就等下一轮，不重复上一帧、也不补静音；缺口交服务端重排",
          "<code>latency</code>（延迟量）与 <code>maxLatency</code>（容量）解耦"]),
    card("两个时钟域的换算", "ink", "解码出口才重锚",
         ["stream-pts / dts 原样喂解码器",
          "出口用 <code>-remapVideoDecodedPts:</code> / <code>-remapAudioDecodedPts:</code> 换到 host 时钟",
          "锚点是 <code>basePresentationTimeStampMs</code>",
          "音频 PTS 刻意不用 <code>CACurrentMediaTime()</code>，避开回调线程调度抖动"]),
    card("副作用与兜底", "muted", "本地采集会被接管",
         ["收到<strong>第一帧视频</strong>才 <code>suspendLocalCapture</code>，之前预览照常",
          "DJI 音频要补施 mic 增益/静音，否则界面 Mute 对 DJI 无效",
          "watchdog 两级：硬拉回采集 + 补回被 intercept 吞掉的线程恢复",
          "流层面四路都没有旋转角度，最终开放用户在 Advance 手选 0/90/180/270"]),
]

write(OUT, d, "Call graph · 方法级 M6", "DJI RTMP 全栈 — 一个方法一个盒子",
      "App 自己实现的一整套 RTMP 服务器。上带是接入与视频链路，下带是音频链路与控制面 —— "
      "分派节点（③）同时喂两带。橙色是设计取舍集中处。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ bc4021368 · 2026-08-24 · Diagram Design 2.6.1")
