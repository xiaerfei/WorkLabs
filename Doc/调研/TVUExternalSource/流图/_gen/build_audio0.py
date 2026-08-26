import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AUDIO-0-音频全景.html")

GW = [430, 460, 470, 450, 430]
GX, TOTW = lanes(GW, gap=66, x0=80)
NH = 52
RY = [126 + i * 72 for i in range(8)]
GT, GH, AY = 106, 690, 690

d = Diagram(TOTW, 900, "audio0",
            "音频全景 · 所有音频流与混音",
            "七个活音频源经同一条四级改道优先级分流，进三套前置混音器或直送编码器；"
            "TVUAudioEncoderManager -encode: 是唯一汇聚点，内部再与会议远端声二次混音，"
            "最后 AAC 编码走四路出口。")

d.group("① 主源候选（互斥，同一时刻只有一个）", GX[0], GT, GW[0], GH)
d.group("② 四级改道优先级（三个主源共用同一套）", GX[1], GT, GW[1], GH)
d.group("③ 三套前置混音器 + 辅源两路", GX[2], GT, GW[2], GH)
d.group("④ encode: 汇聚 + 二次混音", GX[3], GT, GW[3], GH)
d.group("⑤ 四路出口", GX[4], GT, GW[4], GH)

# ---------- ① 主源 ----------
N = GX[0] + 30
d.node("s1", N, RY[0], 370, NH, "内置 mic（index −1）",
       "AudioUnit VPIO / AudioQueue 双实现")
d.node("s2", N, RY[1], 370, NH, "外部源 文件 / RTSP（槽位 1..4）",
       "AudioConverter 硬解 → TVUExtAudioEncoder")
d.node("s3", N, RY[2], 370, NH, "外部源 组播（槽位 1..4）",
       "ffmpeg 软解捷径，单声道 2048B")
d.node("s4", N, RY[3], 370, NH, "Accsoon / SeeMo（index 5）",
       "USB → 剥 ADTS → 软解 → TVUExtAudioEncoder")
d.node("s5", N, RY[4], 370, NH, "DJI RTMP（index 200）",
       "AAC → AVAudioConverter → 抖动缓冲")
d.node("s6", N, RY[5], 370, NH, "屏共 App 音频（index 100）",
       "扩展进程 → Peertalk → 分包器", style="ext")
d.node("s7", N, RY[6], 370, NH, "Overlay 网页声（辅源）",
       "WKWebView AudioWorklet 抓 Web Audio", style="ext")
d.node("s8", N, RY[7], 370, NH, "弹幕朗读 TTS（辅源）",
       "AVSpeechSynthesizer 本地合成", style="ext")
d.annot(N, AY, [
    "已核实的死代码，别当活路径：aacEncoder 的 PCM 环形池整套（startEncode 函数体被注释，",
    "tvu_mic_pcm_separator 线程从不启动）；屏共 Mic 走扩展进程那条（收发两侧都注释掉）。",
    "两个辅源自填的 pts 全部被丢弃 —— 混音输出一律用主源的 pts。",
])

# ---------- ② 四级改道 ----------
N = GX[1] + 30
d.node("g0", N, RY[0], 400, NH, "改道决策（if / else if 阶梯）",
       "mic · Accsoon/外部源 · DJI 三家逐行同构", style="focal")
d.node("g1", N, RY[1], 400, NH, "① isReceivingFrame ?",
       "屏共在收帧 → 送屏共 mic 队列", style="cond")
d.node("g2", N, RY[2], 400, NH, "② shouldOutputAudioStream ?",
       "朗读/Overlay 要混 → 当 Overlay 主源", style="cond")
d.node("g3", N, RY[3], 400, NH, "③ streamType ∈ PIP / PBP / 替换背景 ?",
       "→ 外部源混音器", style="cond")
d.node("g4", N, RY[4], 400, NH, "④ 以上皆否 → 直送 encode:",
       "单源直播的常态路径")
for a, b in (("g0", "g1"), ("g1", "g2"), ("g2", "g3"), ("g3", "g4")):
    d.edge(a, b, fs="b", ts="t", label="否" if a != "g0" else None)
for s in ("s1", "s2", "s4", "s5"):
    d.edge(s, "g0", fs="r", ts="l", route="hvh", gut=GX[1] - 33)
d.annot(N, AY, [
    "三处实现：aacEncoder.mm:287-321（mic）· TVUExtAudioEncoder.mm:231-261（Accsoon/外部源）",
    "· RTMPIngestController.mm:387-422（DJI）。优先级完全一致，是同一套逻辑抄三遍。",
    "增益/静音在改道之前施加，三份实现（mic/Accsoon/DJI）也逐行等价。",
])

# ---------- ③ 混音器 ----------
N = GX[2] + 30
d.node("m1", N, RY[1], 410, NH, "TVUScreenRecordingQueueManager",
       "mic + App 双路 · 25ms 对齐 · index 100", style="queue")
d.node("m2", N, RY[2], 410, NH, "TVUOverlayAudioMixerManager",
       "3 路 · index 取主源 · 块长不符则跳过辅源", style="queue")
d.node("m3", N, RY[3], 410, NH, "TVUExternalSourceAudioMixerQueueManager",
       "2 路 · index 取辅源优先", style="queue")
d.edge("g1", "m1", fs="r", ts="l", route="hvh", gut=GX[2] - 33, label="是")
d.edge("g2", "m2", fs="r", ts="l", route="hvh", gut=GX[2] - 33, label="是")
d.edge("g3", "m3", fs="r", ts="l", route="hvh", gut=GX[2] - 33, label="是")
d.edge("s6", "m1", fs="r", ts="l", route="hvh", gut=GX[2] - 54)
d.edge("s7", "m2", fs="r", ts="l", route="hvh", gut=GX[2] - 44, label="→ queue[1]")
d.edge("s8", "m2", fs="r", ts="l", route="hvh", gut=GX[2] - 34, label="→ queue[2]")
d.annot(N, AY, [
    "三套互相独立，数组尺寸各自定义（2 / 3 / 3），线程各一条。",
    "Overlay 那套的 data_mix 已改成按需扩容；另两套仍按首帧 malloc 一次，可变块长会越界写。",
    "辅源两路直接入 Overlay 混音器的 queue[1] / queue[2]，不经改道阶梯。",
])

# ---------- ④ encode: ----------
N = GX[3] + 30
d.node("e1", N, RY[1], 390, NH, "-encode:(TVUAudioEncoderData *)",
       "唯一汇聚点 · 7 个活生产者", style="focal")
d.node("e2", N, RY[2], 390, NH, "10 道闸门",
       "屏共独占 / pts 单调 / 声道 / 48k / index 守门…", style="cond")
d.node("e3", N, RY[3], 390, NH, "二次混音（会议远端声）",
       "partyLineMixWith / voipMixWith 三选一")
d.node("e4", N, RY[4], 390, NH, "AudioConverterFillComplexBuffer",
       "PCM → AAC-LC · 128kbps · 1024 帧/包", style="focal")
d.node("e5", N, RY[0], 390, NH, "Agora Partyline 上行分叉",
       "pushAudioData: 在 index 守门之前", style="sink")
d.edge("e1", "e2", fs="b", ts="t")
d.edge("e2", "e3", fs="b", ts="t")
d.edge("e3", "e4", fs="b", ts="t")
d.edge("e1", "e5", fs="t", ts="b", style="dash")
for m in ("m1", "m2", "m3"):
    d.edge(m, "e1", fs="r", ts="l", route="hvh", gut=GX[3] - 33)
d.edge("g4", "e1", fs="r", ts="l", route="hvh", gut=GX[3] - 47, label="直送")
d.annot(N, AY, [
    "index 守门是整块丢弃不补静音；混音输出的 index 必须取主源，取辅源会被整块丢。",
    "二次混音的两个队列由会议下行侧（AudioPlayer）填，encode: 拉取；三选一：",
    "Partyline 优先 → VOIP → RTIL VoIP（RTIL 那支是 else if，实测轮不到）。",
])

# ---------- ⑤ 出口 ----------
N = GX[4] + 30
d.node("o1", N, RY[1], 370, NH, "TVUAudioRecorderManager", "m4a 录音 + H265 录制 mux", style="sink")
d.node("o2", N, RY[2], 370, NH, "TVUAssetWriterManager", "CBR 录制，写的是编码前 PCM", style="sink")
d.node("o3", N, RY[3], 370, NH, "TVULiveMediaCenter", "libtvulive2 · stream_id=1 · 补 ADTS", style="sink")
d.node("o4", N, RY[4], 370, NH, "AVFormatControl::addAACData", "ASF mux 链路", style="sink")
d.edge("e4", "o1", fs="r", ts="l", route="hvh", gut=GX[4] - 33)
d.edge("e4", "o3", fs="r", ts="l", route="hvh", gut=GX[4] - 33)
d.edge("e3", "o2", fs="r", ts="l", route="hvh", gut=GX[4] - 47, style="dash")
d.edge("o3", "o4", fs="b", ts="t", style="dash", label="互斥")
d.annot(N, AY, [
    "出口 3/4 由 isEnableFrameTransfer 二选一。",
    "帧传输链路要求音视频互等：v_ready / a_ready",
    "任一为假就不出包。",
    "出口 2 是唯一写编码前 PCM 的一路。",
    "_TVUSDKPartyline 编译时出口 3 整段排除。",
])

d.legend = [
    ("box", "call", "处理步骤"), ("box", "cond", "条件判断"),
    ("box", "focal", "汇聚点 / 编码"), ("box", "queue", "混音器"),
    ("box", "ext", "跨进程 / 辅源"), ("box", "drop", "辅源入队"), ("box", "sink", "出口"),
    ("line", "solid", "主链"), ("line", "dash", "旁路 / 互斥"),
]

cards = [
    card("最值得记住的一条", "coral", "三个主源共用一套改道阶梯",
         ["mic、Accsoon/外部源、DJI 三家的分流逻辑<strong>逐行同构</strong>，只是抄了三遍",
          "优先级：屏共 &gt; 朗读/Overlay 混音 &gt; PIP/PBP 混音 &gt; 直送编码器",
          "新增一个音频源时，照抄这套阶梯即可，别自创顺序",
          "增益/静音也是三份等价实现（<code>f += (1-f)/32</code> 带记忆软限幅）"]),
    card("混音输出的 index", "ink", "两套规则相反，别抄错",
         ["<code>TVUOverlayAudioMixerManager</code> 取<strong>主源</strong> index",
          "<code>TVUExternalSourceAudioMixerQueueManager</code> 取<strong>辅源优先</strong>",
          "编码器按 index 整块丢弃，取错就整条流没声",
          "DJI 接管期间只收 200，Overlay 混音若取辅源 −1 就全丢"]),
    card("块规格是隐含契约", "muted", "4096 字节 = 1024 帧 × 2ch × int16",
         ["三个 PCM 分包器各自 <code>#define PCMBUFF_SIZE 4096</code>，与 <code>FramesPerPacket=1024</code> 绑定",
          "DJI 是唯一破坏这个契约的源：<code>1024 × 48000 / 源采样率</code> 帧",
          "44.1k 源 → 4460B，超出 4096 的余量<strong>无代码路径消费</strong>",
          "混音器块长不符时会跳过辅源，只透传主源"]),
]

write(OUT, d, "Call graph · 音频全景 A0", "音频全景 — 所有音频流与混音",
      "七个活音频源、三套前置混音器、两套二次混音队列、一个汇聚点、四路出口。"
      "橙色是改道决策与编码两处；虚线是旁路与互斥分支。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ 736863f1f · 2026-08-25 · Diagram Design 2.6.1")
