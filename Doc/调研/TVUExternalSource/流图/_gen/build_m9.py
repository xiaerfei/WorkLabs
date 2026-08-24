import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "M9-屏幕录制链路.html")

B1W = [620, 460, 620, 500]
B1X, TOTW = lanes(B1W, gap=68, x0=80)
R1 = [136 + i * 68 for i in range(4)]
G1T, G1H, A1Y = 108, 420, 428

B2X = [B1X[1], B1X[2], B1X[3]]
R2 = [616 + i * 68 for i in range(4)]
G2T, G2H, A2Y = 588, 420, 908

d = Diagram(TOTW, 1080, "m9",
            "屏幕录制链路 · 方法级调用图",
            "ReplayKit 扩展进程把视频与两路音频经 Peertalk socket 送进主 App，"
            "主 App 侧入三路队列，由两条独立线程分别处理：视频线程直送编码队列并在断帧时补帧，"
            "音频线程把 mic 与 App 音频按 25ms 容差对齐后混音，全部以索引 100 交给编码器。")

d.group("① ReplayKit 扩展进程", B1X[0], G1T, B1W[0], G1H)
d.group("② Peertalk socket   跨进程", B1X[1], G1T, B1W[1], G1H)
d.group("③ 主 App 入队（三路）", B1X[2], G1T, B1W[2], G1H)
d.group("④ 视频线程", B1X[3], G1T, B1W[3], G1H)
d.group("⑤ 音频线程   两路对齐与混音", B2X[0], G2T, B1W[1] + B1W[2] + 68, G2H)
d.group("⑥ 出口（索引 100）", B2X[2], G2T, B1W[3], G2H)

# ① 扩展
N = B1X[0] + 40
d.node("a1", N, R1[0], 560, 52, "-processSampleBuffer:withType:", "RPSampleBufferType 三种")
d.node("a3", N, R1[2], 180, 52, "-sendAudioSampleBuffer:", "frameType: …AudioApp")
d.node("a4", N + 190, R1[2], 180, 52, "-sendAudioSampleBuffer:", "frameType: …AudioMic")
d.node("a2", N + 380, R1[2], 180, 52, "-sendVideoSampleBuffer:", "屏幕画面")
d.edge("a1", "a3", fs="b", ts="t", foff=-190)
d.edge("a1", "a4", fs="b", ts="t", foff=0)
d.edge("a1", "a2", fs="b", ts="t", foff=190)
d.annot(N, A1Y, [
    "扩展进程内存上限很紧，所以只做封包不做编码",
    "TVUScreenRecordingFrameTypeAudioApp / AudioMic 两个 frameType 区分两路音频",
    "扩展侧采不到主 App 的 mic —— 主 App 那路走 tvuSendAudioToScreenShare 单独送进来",
])

# ② socket
N = B1X[1] + 40
d.node("b1", N, R1[1], 380, 52, "TVUScreenRecordingIPv4PortNumber", "= 2345")
d.node("b2", N, R1[2], 380, 52, "TVUScreenRecordingServerSocketManager", "isReceivingFrame 是全局闸门", style="focal")
d.edge("b1", "b2", fs="b", ts="t")
d.edge("a2", "b1", fs="r", ts="l", route="hvh", gut=B1X[1] - 34, style="cross", label="三路同 socket")
d.annot(N, A1Y, [
    "isReceivingFrame 一旦为真，整个 App 的音频路由都改道：",
    "本地 mic、外部源、DJI 全部转送屏幕分享队列（见 M2 / M6 的投屏分叉）",
    "TVUScreenRecordingSourceIndex = 100 从这里开始贯穿到编码器",
])

# ③ 入队
N = B1X[2] + 40
d.node("c1", N, R1[0], 560, 52, "addDataToScreenRecordingQueue(&param, q)", "三路共用同一个入队方法")
d.node("c3", N, R1[2], 180, 52, "…AudioApp", "App 音频队列", style="queue")
d.node("c4", N + 190, R1[2], 180, 52, "…AudioMic", "mic 队列", style="queue")
d.node("c2", N + 380, R1[2], 180, 52, "…Video", "视频队列", style="queue")
d.edge("c1", "c3", fs="b", ts="t", foff=-190)
d.edge("c1", "c4", fs="b", ts="t", foff=0)
d.edge("c1", "c2", fs="b", ts="t", foff=190)
d.edge("b2", "c1", fs="r", ts="l", route="hvh", gut=B1X[2] - 34)
d.annot(N, A1Y, [
    "kTUScreenRecordingMediaSize = 3（video / audioApp / audioMic）",
    "param 里 mediaType 决定进哪一路；每路都是 Free / Work 双队列",
    "adjustAudioGain 在入队侧施加 Mute / 增益 —— 所以上游送的是原始 PCM",
])

# ④ 视频线程
N = B1X[3] + 40
d.node("d1", N, R1[0], 420, 52, "videoEncodeThread() → encodeVideo()", "独立线程")
d.node("d2", N, R1[1], 420, 52, "deQueue(workQueue)", "取一个 node")
d.node("d3", N, R1[2], 420, 52, "AddBufferToWorkQueue(…EncoderQueue, 100)", "直送编码队列，绕过合成", style="sink")
d.node("d4", N, R1[3], 420, 52, "addTransitionFrame()", "断帧超 99ms 复用上一帧", style="focal")
for a, b in (("d1", "d2"), ("d2", "d3"), ("d3", "d4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("c2", "d1", fs="r", ts="l", route="hvh", gut=B1X[3] - 34, style="cross", label="出队")
d.annot(N, A1Y, [
    "屏录是唯一一条完全绕过合流层合成的视频源 —— 整帧不需要 PIP / PBP",
    "addTransitionFrame：offset >= 33*3（99ms）就把 lastSampleBuffer 的 pts 加 99ms 重发",
    "这是全链路里唯一还在生效的补帧机制（合流层那套已被硬禁用）",
])

# ⑤ 音频线程
N = B2X[0] + 40
d.node("e1", N, R2[0], 400, 52, "audioEncodeThread() → encodeAudio()", "独立线程")
d.node("e2", N, R2[1], 400, 52, "两路都无数据 → usleep(10ms)", "直接返回", style="cond")
d.node("e3", N, R2[2], 400, 52, "单路断流超 1 秒 ?", "不混音，直接送在的那一路", style="cond")
d.node("e4", N, R2[3], 400, 52, "getCurrentNodePts() 比对", "只窥探队头，不出队")
for a, b in (("e1", "e2"), ("e2", "e3"), ("e3", "e4")):
    d.edge(a, b, fs="b", ts="t")
d.node("e5", N + 480, R2[0], 400, 52, "|mic_pts − app_pts| > 25ms ?", "tvu_filter_pts_offset = 25", style="focal")
d.node("e6", N + 480, R2[1], 400, 52, "丢掉 pts 靠前的那一路", "只丢一帧然后 return", style="drop")
d.node("e7", N + 480, R2[2], 400, 52, "两路 deQueue", "都拿到才继续")
d.node("e8", N + 480, R2[3], 400, 52, "mix(source_data, data_mix, size, coef)", "归一化叠加 · mic 为基准")
d.edge("e4", "e5", fs="r", ts="l", route="hvh", gut=N + 440)
d.edge("e5", "e6", fs="b", ts="t", label="是")
d.edge("e6", "e7", fs="b", ts="t", style="dash", label="否则")
d.edge("e7", "e8", fs="b", ts="t")
d.edge("c3", "e1", fs="b", ts="t", route="vhv", gut=548, style="cross", label="App 音频")
d.edge("c4", "e1", fs="b", ts="t", route="vhv", gut=560, style="cross", label="mic")
d.annot(N, A2Y, [
    "coefficient 由 tvuGetVolumeScale(getPcmDB(mic)) 算出 —— 按 mic 的响度动态压辅源",
    "data_mix 是 static malloc(mic_size * 2)，块长变大会溢出（与 Overlay 混音器同类隐患）",
    "单路断流超 1 秒就退化成单路直送，不会一直等",
])

# ⑥ 出口
N = B2X[2] + 40
d.node("f1", N, R2[1], 420, 52, "param.external_source_index = 100", "两路都用 TVUScreenRecordingSourceIndex", style="focal")
d.node("f2", N, R2[2], 420, 52, "[TVUAudioEncoderManager encode:&param]", "→ M5", style="sink")
d.edge("f1", "f2", fs="b", ts="t")
d.edge("e8", "f1", fs="r", ts="l", route="hvh", gut=B2X[2] - 34)
d.annot(N, A2Y, [
    "pts 取 mic 那一路的 —— mic 是节拍源",
    "编码器侧此时只收 100，本地 −1 的帧全被 index 守门丢掉（见 M5）",
    "视频侧同样带 100，在 checkSampleBufferPTSForEncode 处参与切源判断",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "条件判断"), ("box", "queue", "队列"),
    ("box", "focal", "关键取舍"), ("box", "drop", "丢弃"), ("box", "sink", "出口"),
    ("line", "solid", "同线程调用"), ("line", "cross", "跨进程 / 跨线程"), ("line", "dash", "分支"),
]

cards = [
    card("两路音频的对齐策略", "coral", "25ms 容差，超了就丢",
         ["<code>tvu_filter_pts_offset = 25</code>（毫秒）",
          "<code>d_offset >= 25</code> → 丢 App 那一路一帧；<code>d_offset <= −25</code> → 丢 mic 一帧",
          "每次只丢一帧然后 <code>return</code>，下一轮重新比对 —— 靠反复丢逐步收敛",
          "单路断流超 1 秒就退化成单路直送，不会一直等"]),
    card("屏录是唯一绕过合成的视频源", "ink", "整帧不需要 PIP / PBP",
         ["<code>encodeVideo()</code> 直接 <code>AddBufferToWorkQueue(…EncoderQueue, 100)</code>",
          "跳过 <code>handleWithSamplebuffer</code> 的整个分发矩阵",
          "<code>addTransitionFrame()</code> 是全链路唯一还生效的补帧：断帧 &gt;99ms 复用上一帧并推进 pts",
          "合流层那套过渡帧机制已被硬禁用"]),
    card("isReceivingFrame 的全局影响", "muted", "一个标志改掉整个音频路由",
         ["为真时本地 mic、外部源、DJI 音频全部改道屏幕分享队列",
          "见 M2 的 <code>doencode()</code> 投屏分叉、M6 的音频三出口",
          "上游一律送<strong>原始 PCM</strong>，增益由入队侧的 <code>adjustAudioGain</code> 施加",
          "<code>getShareScreenAudioMixType</code> 决定要不要混、混哪几路"]),
]

write(OUT, d, "Call graph · 方法级 M9", "屏幕录制链路 — 一个方法一个盒子",
      "扩展进程只封包，编码全在主 App。上带是视频（直送编码队列 + 补帧），"
      "下带是两路音频的 25ms 对齐与混音。橙色是三处关键取舍。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ bc4021368 · 2026-08-24 · Diagram Design 2.6.1")
