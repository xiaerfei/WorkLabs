import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AUDIO-4-朗读与Overlay音频.html")

GW = [660, 660, 660]
GX, TOTW = lanes(GW, gap=68, x0=80)
NH = 52
R1 = [128 + i * 70 for i in range(6)]
R2 = [760 + i * 70 for i in range(6)]
G1T, G1H, A1Y = 108, 560, 570
G2T, G2H, A2Y = 740, 560, 1202

d = Diagram(TOTW, 1330, "audio4",
            "朗读与 Overlay 音频 · 方法级调用图",
            "Overlay 混音器有三路：主源（mic / Accsoon / DJI 之一）当节拍源，辅源是 Overlay 网页声与弹幕朗读。"
            "两个辅源都不产生有效 PTS，混音输出一律用主源的 pts 与 index；辅源块长与主源不一致时直接跳过不混。")

d.group("① Overlay 网页声 · WKWebView JS 侧", GX[0], G1T, GW[0], G1H)
d.group("② Overlay 网页声 · 原生侧", GX[1], G1T, GW[1], G1H)
d.group("③ 混音器主循环 + 出口", GX[2], G1T, GW[2], G1H)
d.group("④ 弹幕朗读 · 触发", GX[0], G2T, GW[0], G2H)
d.group("⑤ 弹幕朗读 · 本地合成", GX[1], G2T, GW[1], G2H)
d.group("⑥ 弹幕朗读 · 喂流（三道闸门）", GX[2], G2T, GW[2], G2H)

# ---------------- 带 1 ----------------
N = GX[0] + 30
d.node("j1", N, R1[0], 600, NH, "AudioContextProxy → setupIntercept(context)", "TVUWebviewAudioOutputManager.mm:307〔注入的 JS〕", style="focal")
d.node("j2", N, R1[1], 600, NH, "patch AudioNode.prototype.connect", ":318-329 · 任何 connect(destination) 额外连 captureNode")
d.node("j3", N, R1[2], 600, NH, "AudioCaptureProcessor.process(inputs, outputs)", ":232 · 只取 inputs[0][0]；最近邻重采样到 48k")
d.node("j4", N, R1[3], 600, NH, "flush() → port.postMessage({pcm})", ":254 · 攒满 4096 个 Float32 才发")
d.node("j5", N, R1[4], 600, NH, "sendToOC(base64) → audioHandler.postMessage", ":285-288 · WKScriptMessage 过桥", style="sink")
for x, y in (("j1","j2"),("j2","j3"),("j3","j4"),("j4","j5")): d.edge(x, y, fs="b", ts="t")
d.annot(N, A1Y, [
    "重采样在 JS 的 AudioWorklet 里做，而且是【最近邻】不是线性插值。",
    "采样率 48000 在原生侧是硬编码信任 JS 的（.mm:13 / :75），没有校验。",
])

N = GX[1] + 30
d.node("k1", N, R1[0], 600, NH, "-userContentController:didReceiveScriptMessage:", "TVUWebSnapshotView.mm:618〔主线程〕")
d.node("k2", N, R1[1], 600, NH, "dispatch_async(audioWriteQueue)", ":52〔com.tvu.webAudioWriteQueue〕")
d.node("k3", N, R1[2], 600, NH, "-initWithBase64EncodedString: → resampleFloat32ToInt16:", ":55 / :161 · ⚠️ 无 vDSP_vclip，会回绕爆音", style="cond")
d.node("k4", N, R1[3], 600, NH, "-getCurrentTimeStamp（CMClockGetHostTimeClock）× 1000", ":62 / :80 · 算出来的 pts 最终被丢弃", style="drop")
d.node("k5", N, R1[4], 600, NH, "convertToStereo → addDataToAudioMixer(queue[1])", ":143 / :154 · 4096B / 2ch / 48000", style="queue")
for x, y in (("k1","k2"),("k2","k3"),("k3","k4"),("k4","k5")): d.edge(x, y, fs="b", ts="t")
d.edge("j5", "k1", fs="r", ts="l", route="hvh", gut=GX[1] - 34, label="JS→OC")
d.annot(N, A1Y, [
    "一次 JS 消息（4096 个 Float32）正好产出 4 个 4096 字节的 overlay 块。",
    "start/stop：TVUWebSnapshotManager.mm:116 checkAudioOutputState —— 任一 TVUWebSnapshotView 的",
    "shouldOutputAudioStream（= enableAudioStreamOutput && viewMode == Live）为真则 start，全假则 stop。",
])

N = GX[2] + 30
d.node("x1", N, R1[0], 600, NH, "audioMixer()", "TVUOverlayAudioMixerManager.mm:269〔TVUOverlayAudioMixerManagerThread〕", style="focal")
d.node("x2", N, R1[1], 600, NH, "取主源节点；连续 1s 无 mic 才丢辅源", ":281 · kTVUOverlayMixerLocalSilenceDropMs = 1000", style="cond")
d.node("x3", N, R1[2], 600, NH, "data_mix 按需扩容（capacity + malloc 失败保护）", ":318-330 · 全仓唯一改对了的那份")
d.node("x4", N, R1[3], 600, NH, "辅源块长 == 主源块长 ?", ":338 / :344 · 不一致则跳过该辅源，只打日志", style="cond")
d.node("x5", N, R1[4], 600, NH, "mix(mic, others, n, …) → index 取【主源】", ":353 / :366 · mic 系数恒 1.0，辅源乘 coefficient")
d.node("x6", N, R1[5], 600, NH, "-[TVUAudioEncoderManager encode:]", ":367 · pts 也取主源（:362）", style="sink")
for x, y in (("x1","x2"),("x2","x3"),("x3","x4"),("x4","x5"),("x5","x6")): d.edge(x, y, fs="b", ts="t")
d.edge("k5", "x1", fs="r", ts="l", route="hvh", gut=GX[2] - 34)
d.annot(N, A1Y, [
    "三路：queue[0] 主源（mic / Accsoon / DJI，节拍源，不在 TVUOverlayMixerSource 枚举里）",
    "· queue[1] Overlay 网页声 · queue[2] 弹幕朗读。activeSources 是按位标记而非引用计数。",
    "⚠️ DJI 源非 48kHz 时块长对不上，朗读和 overlay 两路会被静默跳过、只透传主源。",
])

# ---------------- 带 2 ----------------
N = GX[0] + 30
d.node("t1", N, R2[0], 600, NH, "TVUChatAggregator.messageAdmitted", "TVUWebChatManager.m:105〔平台 client 线程〕", style="focal")
d.node("t2", N, R2[1], 600, NH, "-[TVUChatTTSManager say:]", "TVUChatTTSManager.mm:536")
d.node("t3", N, R2[2], 600, NH, "-trySpeakNextLocked", ":852〔com.tvu.chat.tts〕")
d.node("t4", N, R2[3], 600, NH, "mixesIntoStream = enabled && mode==Both && streamMixReady", ":305 · 展开是六个条件", style="cond")
d.node("t5", N, R2[4], 600, NH, "-applyMixerState → mixer->start(TTS)", ":329 · 四个入口，幂等（按位而非计数）")
for x, y in (("t1","t2"),("t2","t3"),("t3","t4"),("t4","t5")): d.edge(x, y, fs="b", ts="t")
d.annot(N, A2Y, [
    "六个条件：朗读开 / mix 开 / 推到弹幕平台 / html 显示 / mode 是 Live / 输出非内建扬声器。",
    "后四个由 TVUWebChatManager.syncStreamMixReady（.m:195，6 个调用点）合成。",
    "没有服务端 TTS —— TtsMonster 枚举存在但未实现，setEngine: 直接回落 System（:377）。",
])

N = GX[1] + 30
d.node("y1", N, R2[0], 600, NH, "-[TVUChatTTSStreamSpeaker speakText:…]", "TVUChatTTSStreamSpeaker.mm:103〔主线程〕")
d.node("y2", N, R2[1], 600, NH, "-scheduleSilence:seq:", ":145 · preDelay：本地排静音 + 推流推等量零字节")
d.node("y3", N, R2[2], 600, NH, "[synthesizer writeUtterance:toBufferCallback:]", ":182 · AVSpeechSynthesizer 本地合成")
d.node("y4", N, R2[3], 600, NH, "-convertBuffer:seq:（AVAudioConverter，按句重建）", ":354 · → 48k / Float32 / mono")
d.node("y5", N, R2[4], 600, NH, "-appendToBatch: 攒 300ms → -emitBatchBuffer:", ":220 / :275")
d.node("y6", N, R2[5], 600, NH, "-stereoInt16FromMonoBuffer:（vDSP，含 vDSP_vclip）", ":399 · stride=2 一步转交错双声道")
for x, y in (("y1","y2"),("y2","y3"),("y3","y4"),("y4","y5"),("y5","y6")): d.edge(x, y, fs="b", ts="t")
d.edge("t5", "y1", fs="r", ts="l", route="hvh", gut=GX[1] - 34)
d.annot(N, A2Y, [
    "TTS 没有采集时钟，靠【借主源时钟】解决：pts 显式写 0（TVUChatTTSManager.mm:479）。",
    "代价是必须按实时速率喂 —— 所以有 500ms 重试 + 消息间隙推等量零字节。",
    "注释原话：只在本地插静音会让「观众听到的两条消息比主播那边贴得更近，时间轴越读越漂」。",
])

N = GX[2] + 30
d.node("z1", N, R2[0], 600, NH, "pcmOutput block → dispatch_async(streamFeedQueue)", "TVUChatTTSManager.mm:236〔com.tvu.chat.tts.stream〕")
d.node("z2", N, R2[1], 600, NH, "-feedStreamPCM: → -drainStreamAccumFromTimer:", ":435 / :453〔com.tvu.chat.tts.mixfeed〕", style="focal")
d.node("z3", N, R2[2], 600, NH, "闸① !mixesIntoStream → return", ":438", style="cond")
d.node("z4", N, R2[3], 600, NH, "闸② workQueueSize() ≥ 节点数−1 → break", ":466 · 水位闸，刻意留一格余量", style="cond")
d.node("z5", N, R2[4], 600, NH, "闸③ !mixer->isSourceActive(TTS) → break", ":472 · 活性闸，紧贴入队（stop 先改标记再清队列）", style="cond")
d.node("z6", N, R2[5], 600, NH, "addDataToAudioMixer(queue[2])  ·  4096B / 2ch / pts=0", ":482 · 失败则 dispatch_after(0.5s) 重试", style="queue")
for x, y in (("z1","z2"),("z2","z3"),("z3","z4"),("z4","z5"),("z5","z6")): d.edge(x, y, fs="b", ts="t")
d.edge("y6", "z1", fs="r", ts="l", route="hvh", gut=GX[2] - 34)
d.edge("z6", "x1", fs="r", ts="r", route="hvh", gut=GX[2] + GW[2] + 40, style="dash", label="进 queue[2]")
d.annot(N, A2Y, [
    "streamDrainScheduled 保证重试链单条，不会并发排两条。",
    "闸③ 必须紧贴入队：stop() 是「先改 activeSources、再清队列」，",
    "overlay 还开着时混音器不挂起，addDataToAudioMixer 自己不会丢，得在这里挡。",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "闸门 / 判断"),
    ("box", "focal", "线程入口 / 混音"), ("box", "queue", "入队混音器"),
    ("box", "drop", "算了但被丢弃"), ("box", "sink", "过桥 / 出口"),
    ("line", "solid", "同线程调用"), ("line", "dash", "跨带 / 旁路"),
]

cards = [
    card("两个辅源都不产生有效 PTS", "coral", "全部借主源时钟",
         ["Overlay：host 时钟 − cache 残留，逐块 +21ms（<code>.mm:131/:150/:157</code>）→ <strong>丢弃</strong>",
          "TTS：显式写 <code>0</code>（<code>TVUChatTTSManager.mm:479</code>）→ <strong>丢弃</strong>",
          "混音输出的 pts 与 index 一律取主源（<code>:362</code> / <code>:366</code>）",
          "代价：辅源必须按实时速率喂，否则时间轴会漂"]),
    card("data_mix 这份改对了", "ink", "另两套还没改",
         ["<code>:318-330</code> 按需扩容 + <code>data_mix_capacity</code> + malloc 失败保护",
          "注释原话：「原来是 malloc(size*2) 一次就不管了，块大小变大就会溢出」",
          "<code>TVUScreenRecordingQueueManager.mm:532</code> 与 <code>…ExternalSourceAudioMixer…mm:228</code> 仍是旧写法",
          "修法现成，照搬即可"]),
    card("辅源块长不符就跳过", "muted", "宁可不混，不读野内存",
         ["<code>mix()</code> 是按主源长度逐样本读的，辅源短了就越界读",
          "三路现在都是 4096 字节（1024 帧 × 双声道 × int16）",
          "不一致时只打日志、跳过该辅源，主源原样透传",
          "⚠️ DJI 非 48k 源会命中这条，朗读和 overlay 静默失效"]),
]

write(OUT, d, "Call graph · 音频 A4", "朗读与 Overlay 音频 — 三路混音",
      "上带是 Overlay 网页声（JS 抓 Web Audio）与混音器主循环，下带是弹幕朗读的合成与喂流。"
      "橙色是线程入口与混音；灰虚框是算了但被丢弃的值。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ 736863f1f · 2026-08-25 · Diagram Design 2.6.1")
