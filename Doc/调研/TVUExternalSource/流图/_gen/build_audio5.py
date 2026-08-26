import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AUDIO-5-DJI与Accsoon音频.html")

GW = [540, 550, 550, 550]
GX, TOTW = lanes(GW, gap=68, x0=80)
NH = 52
R1 = [128 + i * 70 for i in range(6)]
R2 = [830 + i * 70 for i in range(6)]
G1T, G1H, A1Y = 108, 620, 550
G2T, G2H, A2Y = 810, 620, 1252

d = Diagram(TOTW, 1480, "audio5",
            "DJI RTMP 与 Accsoon 音频 · 方法级调用图",
            "DJI 音频从内建 RTMP server 收 AAC，解码后经压缩域抖动缓冲吐出，index 200；"
            "Accsoon 从 USB 收 AAC，剥 ADTS 后软解，index 5。两条链最终都走同一套四级改道阶梯，"
            "与本地 mic 逐行同构。")

d.group("① DJI · RTMP 消息分派", GX[0], G1T, GW[0], G1H)
d.group("② DJI · AAC 解码 + PTS 重锚", GX[1], G1T, GW[1], G1H)
d.group("③ DJI · 抖动缓冲（绝不补静音）", GX[2], G1T, GW[2], G1H)
d.group("④ DJI · Ingest 三路改道", GX[3], G1T, GW[3], G1H)
d.group("⑤ Accsoon · USB 回调 + 6 道闸门", GX[0], G2T, GW[0], G2H)
d.group("⑥ Accsoon · 软解 + 重采样", GX[1], G2T, GW[1], G2H)
d.group("⑦ Accsoon · 定长分包 + switch 四路", GX[2], G2T, GW[2], G2H)
d.group("⑧ 两条链共用的下游", GX[3], G2T, GW[3], G2H)

# ---------------- DJI ----------------
N = GX[0] + 30
d.node("a1", N, R1[0], 480, NH, "TVUIRLMediaPipeline::processMessage", "MediaPipeline.m:221〔com.tvu.rtmp-server〕", style="focal")
d.node("a2", N, R1[1], 480, NH, "processAudio", ":688 · codec != 0xA → stopWithReason", style="cond")
d.node("a3", N, R1[2], 480, NH, "processAacSequenceStart", ":705 · aacPacketType == 0")
d.node("a4", N, R1[3], 480, NH, "TVUIRLAudioConfig initWithData:", "AudioConfig.m:35 · 解 AudioSpecificConfig")
d.node("a5", N, R1[4], 480, NH, "alloc TVUIRLBufferedAudio(latency, maxLatency=5.0)", ":720 · 仅 jitter buffer 开且 latency > 0", style="cond")
d.node("a6", N, R1[5], 480, NH, "processAacRaw", ":727 · aacPacketType == 1")
for x, y in (("a1","a2"),("a2","a3"),("a3","a4"),("a4","a5"),("a5","a6")): d.edge(x, y, fs="b", ts="t")
d.annot(N, A1Y, [
    "latency 链：kTVUIRLDJIDefaultLatency = 1000（DJIStreamModel.m:15）→ ControlBS.m:77",
    "→ RTMPIngestController.mm:87 → MediaPipeline.m:351。",
    "本地采集接管由【首个视频帧】触发，不是 publish 握手（:334-343）。",
])

N = GX[1] + 30
d.node("b1", N, R1[0], 490, NH, "decodeAacFrame:presentationTimeStamp:", ":759 → AudioDecoder.m:82")
d.node("b2", N, R1[1], 490, NH, "闸门 AAC 包 > 4096 × channelCount ?", "AudioDecoder.m:85-88", style="cond")
d.node("b3", N, R1[2], 490, NH, "AVAudioConverter convertToBuffer:…", ":102 · 输出 48000 / 2ch 钉死（:44-47）", style="focal")
d.node("b4", N, R1[3], 490, NH, "frameLength = 1024 × 48000 / srcSampleRate", ":75-76 · 48k→1024 帧；44.1k→≈1115；8k→6144", style="focal")
d.node("b5", N, R1[4], 490, NH, "[connection remapAudioDecodedPts:]", ":125 → StreamConnection.m:789 · 重锚到 host time")
d.node("b6", N, R1[5], 490, NH, "单调 clamp：≤ 上一帧则 +1ms", ":849-856 · 专为绕开 encode: 的 last_audio_pts 守卫")
for x, y in (("b1","b2"),("b2","b3"),("b3","b4"),("b4","b5"),("b5","b6")): d.edge(x, y, fs="b", ts="t")
d.edge("a6", "b1", fs="r", ts="l", route="hvh", gut=GX[1] - 34)
d.annot(N, A1Y, [
    "PTS：newPts = anchorBasetime + (pts − audioFirstPts)，audio 首帧一次性锚（:804-808）。",
    "PLL 是关的：kTVUIRLDJIBasetimePLLEnabled = NO（StreamConnection.m:23），clamp 纯防御。",
    "video 对齐：anchorFirstPts 优先取 audioFirstPts → 同源时刻 A/V offset = 0（:753）。",
])

N = GX[2] + 30
d.node("c1", N, R1[0], 490, NH, "[bufferedAudio appendSampleBuffer:]", "MediaPipeline.m:811 · latency > 0 才入缓冲", style="queue")
d.node("c2", N, R1[1], 490, NH, "TVUIRLBufferedAudio::output", "BufferedAudio.m:114〔com.tvu.dji.buffered.audio〕", style="focal")
d.node("c3", N, R1[2], 490, NH, "出帧节拍 = frameLength / sampleRate ≈ 21.33ms", ":83 · TVUIRLSimpleTimer 驱动")
d.node("c4", N, R1[3], 490, NH, "蓄水期 firstPts + latency > now → return", ":126-132", style="cond")
d.node("c5", N, R1[4], 490, NH, "overflow > maxLatency(5.0s) → 丢最老帧", ":165-177", style="cond")
d.node("c6", N, R1[5], 490, NH, "underrun → 不输出、等真帧（绝不补静音）", ":156-159 · 头文件注释说会补静音，已过期", style="drop")
for x, y in (("c1","c2"),("c2","c3"),("c3","c4"),("c4","c5"),("c5","c6")): d.edge(x, y, fs="b", ts="t")
d.edge("b6", "c1", fs="r", ts="l", route="hvh", gut=GX[2] - 34)
d.annot(N, A1Y, [
    "MediaClock 支线：pipelineDidObserveAudioPts: → MediaClock.update → forwardTarget…Latency:",
    "→ server:didUpdateTargetVideoLatency:audioLatency: 【全仓无实现】—— 决策算完就扔。",
    "DriftTracker 只在 TVUIRLBufferedVideo.m:44 用，音频侧没有。DJIBLE 全目录零音频。",
])

N = GX[3] + 30
d.node("d1", N, R1[0], 490, NH, "-server:didReceiveAudioSampleBuffer:", "RTMPIngestController.mm:366〔缓冲出帧线程〕", style="focal")
d.node("d2", N, R1[1], 490, NH, "① isReceivingFrame → tvuSendAudioToScreenShare", ":387 / :388 · 不预施加增益（队列会加）", style="sink")
d.node("d3", N, R1[2], 490, NH, "applyCaptureGain:toInterleavedInt16PCM:…", ":397 · 与 mic / Accsoon 三份逐行等价")
d.node("d4", N, R1[3], 490, NH, "② shouldOutputAudioStream → Overlay 混音器[0]", ":417 / :419 · SPAR-765，index 取主源=200", style="sink")
d.node("d5", N, R1[4], 490, NH, "③ 直送 -[TVUAudioEncoderManager encode:]", ":422 · param.size = frameLength × 4", style="focal")
for x, y in (("d1","d2"),("d2","d3"),("d3","d4"),("d4","d5")): d.edge(x, y, fs="b", ts="t")
d.edge("c6", "d1", fs="r", ts="l", route="hvh", gut=GX[3] - 34)
d.annot(N, A1Y, [
    "本地采集接管：suspendLocalCapture :172 index→200、:174 streamType→OSMORTMP，",
    "后台时反而 startAudioCapture（:179-183）保「audio」后台模式不被系统杀。",
    "mic 侧由 isSendAuidoToEncoder 的 streamType==OSMORTMP → NO 整体丢弃（TVURecorder.mm:1424）。",
])

# ---------------- Accsoon ----------------
N = GX[0] + 30
d.node("e1", N, R2[0], 480, NH, "rtmsuListener.audioDataHandler", "TVUAccsoonManager.mm:290〔闭源库线程，名未确认〕", style="focal")
d.node("e2", N, R2[1], 480, NH, "self.audioStreamTime = now", ":292 · 活性戳，喂 isLiveWithBulidInAudioStream")
d.node("e3", N, R2[2], 480, NH, "-acceptAudioData:andTimestamp:", ":629")
d.node("e4", N, R2[3], 480, NH, "6 道闸门 −1..−6", ":642-690 · 等视频就绪 / 格式未到 / pts < 0", style="cond")
d.node("e5", N, R2[4], 480, NH, "剥 7 字节 ADTS 头", ":672 · kTVU_ADTS_HEADER_LEGHT")
d.node("e6", N, R2[5], 480, NH, "param.external_source_index = 5", ":679 · kTVUExternalAccsoonIndex（:164）")
for x, y in (("e1","e2"),("e2","e3"),("e3","e4"),("e4","e5"),("e5","e6")): d.edge(x, y, fs="b", ts="t")
d.annot(N, A2Y, [
    "isLiveWithBulidInAudioStream（:711-733）：插着 + 在工作 + 视频已跑 + 无异常告警 + >1s 没收到音频包。",
    "目的不是「用手机麦替代」而是【保一条静音音轨】—— TVURecorder.mm:598 会 memset 清零。",
    "它能绕过 encode: 的 index 守门，但只在主 App（#else 分支）；IRL 侧没有这条 bypass。",
])

N = GX[1] + 30
d.node("f1", N, R2[0], 490, NH, "[audioDecoder decode:&param]", ":694 → Decoder.mm:118")
d.node("f2", N, R2[1], 490, NH, "-setupDecoder:sampleRate:", ":208 · AudioConverterRef 软解")
d.node("f3", N, R2[2], 490, NH, "TVUExtAudioEncoder::startEncode()", ":210 · 顺带把分包线程拉起来")
d.node("f4", N, R2[3], 490, NH, "AudioConverterFillComplexBuffer", ":118 · 出 1024 帧，源采样率 / 源声道")
d.node("f5", N, R2[4], 490, NH, "[_ffmpegResample convertor_feed_data:…]", ":140 · 仅 ch != 2 || sr != 48000 才走", style="cond")
d.node("f6", N, R2[5], 490, NH, "TVUExtAudioEncoder::pushFrame(…, pts×1000, 5)", ":153 / :156")
for x, y in (("f1","f2"),("f2","f3"),("f3","f4"),("f4","f5"),("f5","f6")): d.edge(x, y, fs="b", ts="t")
d.edge("e6", "f1", fs="r", ts="l", route="hvh", gut=GX[1] - 34)
d.annot(N, A2Y, [
    "PTS：(usbTs − first_audio_frame_timestamp)/scale + videoDecoder.externalSourceBaseTime 〔秒〕",
    "→ pushFrame 传毫秒 → 槽位按已写字节补偿 movtime → encodeParam.pts 回到秒。",
    "⚠️ Accsoon 侧【没有任何单调 clamp】，切源时会撞上 encode: 的 last_audio_pts 高水位。",
])

N = GX[2] + 30
d.node("g1", N, R2[0], 490, NH, "TVUExtPCMFrameList::pushFrame", "ExtAudioEncoder.mm:359 · 切/拼进 4096B 槽位", style="queue")
d.node("g2", N, R2[1], 490, NH, "闸门 m_count ≥ 50 → 丢", ":369-372", style="cond")
d.node("g3", N, R2[2], 490, NH, "TVUExtAudioEncoder::doencode()", ":182〔tvu_ext_pcm_separator〕", style="focal")
d.node("g4", N, R2[3], 490, NH, "闸门 size == capacity(4096) ?", ":206 · 否则只打日志丢弃", style="cond")
d.node("g5", N, R2[4], 490, NH, "tvuApplyExternalSourceCaptureGain（in-place）", ":241-244 · gain != 1.0 才做")
d.node("g6", N, R2[5], 490, NH, "switch (streamType)  四路", ":246 · 与 mic 那套阶梯逐行同构", style="focal")
for x, y in (("g1","g2"),("g2","g3"),("g3","g4"),("g4","g5"),("g5","g6")): d.edge(x, y, fs="b", ts="t")
d.edge("f6", "g1", fs="r", ts="l", route="hvh", gut=GX[2] - 34)
d.annot(N, A2Y, [
    "屏共改道在 switch 之前（:235 / :236，continue），也不预施加增益。",
    "isLocalFile 语义实为「视频源已被外部源接管」，配合 streamType==ExternalSource",
    "让 mic 在 isSendAuidoToEncoder 被丢（TVURecorder.mm:1428-1443）。",
])

N = GX[3] + 30
d.node("h1", N, R2[0], 490, NH, "tvuEncodeOrMixExternalSourceAudio(&param)", ":252 · ExternalSource && !ReplaceBackground")
d.node("h2", N, R2[1], 490, NH, "shouldOutputAudioStream → Overlay 混音器[0]", ":37 · SPAR-769", style="sink")
d.node("h3", N, R2[2], 490, NH, "外部源混音器 addDataToAudioMixer[ExternalSource]", ":254 · PIP / PBP / ReplaceBackground", style="sink")
d.node("h4", N, R2[3], 490, NH, "default → -[TVUAudioEncoderManager encode:]", ":259 · Camera / OSMORTMP 时", style="focal")
d.node("h5", N, R2[4], 490, NH, "encode: 的 10 道闸门", "AudioEncoderManager.mm:92 起 · 详见 M5", style="sink")
for x, y in (("h1","h2"),("h2","h3"),("h3","h4"),("h4","h5")): d.edge(x, y, fs="b", ts="t")
d.edge("g6", "h1", fs="r", ts="l", route="hvh", gut=GX[3] - 34)
d.edge("d5", "h5", fs="r", ts="r", route="hvh", gut=GX[3] + GW[3] + 40, style="dash", label="DJI 也汇到这里")
d.annot(N, A2Y, [
    "三份增益实现（DJI / Accsoon / 本地 mic）逐行等价：同 MAX/MIN、同 f += (1−f)/32 带记忆软限幅，",
    "差别只有 in-place vs out-of-place。原因是前两者不经 TVURecorder，界面 Mute 本来对它们无效。",
    "gain 读自 liveRecorder.gain，stopAudioCapture 不清空它。",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "闸门 / 分支"),
    ("box", "focal", "线程入口 / 关键处理"), ("box", "queue", "入队"),
    ("box", "drop", "不输出 / 丢弃"), ("box", "sink", "改道出口"),
    ("line", "solid", "同线程调用"), ("line", "dash", "跨带汇聚"),
]

cards = [
    card("DJI 是唯一破坏块规格的源", "coral", "frameLength = 1024 × 48000 / 源采样率",
         ["48k 源 → 1024 帧 = 4096B ✅；44.1k → ≈1115 帧 ≈ 4460B；8k → 6144 帧 = 24576B",
          "缓冲不会溢出（<code>encode:</code> 有 realloc），但超出 4096 的余量<strong>无代码路径消费</strong>",
          "下一帧 <code>memcpy</code> 直接覆盖 → 44.1k 源约 8.2% 音频不进流",
          "验证：抓 <code>AudioDecoder.m:59-61</code> 那行日志看实际采样率"]),
    card("两个设计存在但不接线", "ink", "MediaClock 与 DriftTracker",
         ["<code>server:didUpdateTargetVideoLatency:audioLatency:</code> <strong>全仓无实现</strong>，只有声明与调用",
          "MediaClock 对音频当前零作用；DriftTracker 只在 <code>BufferedVideo.m:44</code> 用",
          "PLL 也是关的（<code>kTVUIRLDJIBasetimePLLEnabled = NO</code>）",
          "<code>BufferedAudio.h:7</code> 注释说会补静音，实现是不输出等真帧 —— 注释过期"]),
    card("单调 clamp 只有 DJI 有", "muted", "Accsoon 裸奔",
         ["<code>encode:</code> 的 <code>last_audio_pts</code> 是<strong>全进程静态</strong>，且永不复位",
          "DJI 在 <code>StreamConnection.m:849</code> 主动 clamp（≤ 上一帧则 +1ms）绕开它",
          "Accsoon 侧没有任何 clamp，切源时 PTS 跳变会连锁丢帧",
          "注释原话点明了动机：「绕过 TVUAudioEncoderManager 的 last_audio_pts 守卫」"]),
]

write(OUT, d, "Call graph · 音频 A5", "DJI RTMP 与 Accsoon 音频 — 两条外部音源",
      "上带是 DJI（index 200，走内建 RTMP server + 压缩域抖动缓冲），下带是 Accsoon/SeeMo（index 5，USB 软解）。"
      "两条链最终汇到同一套四级改道阶梯。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ 736863f1f · 2026-08-25 · Diagram Design 2.6.1")
