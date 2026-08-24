import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "M5-音频编码器与二次混音.html")

GW = [520, 460, 480, 480, 520]
GX, TOTW = lanes(GW, gap=68, x0=80)
NH = 52
RY = [128 + i * 68 for i in range(6)]
GT, GH, AY = 108, 560, 548

d = Diagram(TOTW, 760, "m5",
            "音频编码器与二次混音 · 方法级调用图",
            "TVUAudioEncoderManager 的 encode: 是所有音频源的唯一汇聚点：先做声道与采样率校验，"
            "单声道转立体声，向 Agora 分叉一份，再用 external_source_index 守门整块丢弃非活跃源，"
            "接着与 VOIP / Partyline / RTIL 远端语音二次混音，最后 AAC 编码并走两条互斥链路，"
            "另有录音旁路。")

d.group("① -encode: 入口校验", GX[0], GT, GW[0], GH)
d.group("② 声道归一 + Agora 分叉", GX[1], GT, GW[1], GH)
d.group("③ index 守门（整块丢弃）", GX[2], GT, GW[2], GH)
d.group("④ 二次混音 + AAC 编码", GX[3], GT, GW[3], GH)
d.group("⑤ 出口：两条互斥链路 + 录音旁路", GX[4], GT, GW[4], GH)

# ① 入口
N = GX[0] + 40
d.node("a1", N, RY[0], 440, NH, "-encode:(TVUAudioEncoderData *)param", "mic / 外部源 / 屏录 / DJI / 混音器 都进这里", style="focal")
d.node("a2", N, RY[1], 440, NH, "param->channel 合法 ?", "非单/双声道 → 打错误日志后 return", style="cond")
d.node("a3", N, RY[2], 440, NH, "param->sampleRate == 48000 ?", "不是 48k 直接拒收", style="cond")
d.node("a4", N, RY[3], 440, NH, "getCurrentAgoraMeetingState()", "== Joined ? 决定要不要给 Agora 一份")
for a, b in (("a1", "a2"), ("a2", "a3"), ("a3", "a4")):
    d.edge(a, b, fs="b", ts="t")
d.annot(N, AY, [
    "param 里五个字段全程透传：data / size / channel / sampleRate / pts / external_source_index",
    "kTVUAudioEncoderSampleRate = 48000 是硬约束 —— 整条音频链没有重采样兜底",
    "入口不加锁；锁从 index 守门之后才开始（mutex_lock）",
])

# ② 声道 + Agora
N = GX[1] + 40
d.node("b1", N, RY[0], 380, NH, "monoConvertToStereoWithMonoAudio:…", "单声道 → 立体声（复用静态 buffer）")
d.node("b2", N, RY[1], 380, NH, "isJoined || enableEncoding ?", "只在需要时才转", style="cond")
d.node("b3", N, RY[2], 380, NH, "pushAudioData:andSampes:andTimestamp:", "给 Agora 一份（不影响主链）", style="sink")
d.node("b4", N, RY[3], 380, NH, "enableEncoding ?", "为假直接 return，不编码", style="cond")
d.edge("b2", "b1", fs="t", ts="b", label="是")
d.edge("b2", "b3", fs="b", ts="t")
d.edge("b3", "b4", fs="b", ts="t")
d.edge("a4", "b2", fs="r", ts="l", route="hvh", gut=GX[1] - 34)
d.annot(N, AY, [
    "送 Agora 的样本数算法：param->size / (2 * param->channel)",
    "曾经为 partyline 做过单声道下采样，现在统一按立体声送（注释里留着旧代码）",
    "Agora 分叉在 index 守门之前，",
    "所以 partyline 听到的源可能与推流的不是同一路",
])

# ③ index 守门
N = GX[2] + 40
d.node("c1", N, RY[0], 400, NH, "pthread_mutex_lock(&mutex_lock)", "从这里开始进临界区")
d.node("c2", N, RY[1], 400, NH, "isReceivingFrame ?", "投屏中放行（IRL）", style="cond")
d.node("c3", N, RY[2], 400, NH, "isLiveWithBulidInAudioStream ?", "Accsoon 例外开关（主 App）", style="cond")
d.node("c4", N, RY[3], 400, NH, "external_source_index 相符 ?", "不符 → unlock 后整块丢弃", style="focal")
d.node("c5", N, RY[4], 400, NH, "resetLastExternalSourceIndex 时机", "updateExternalSourceIndex: 由 M1 的 sort() 调", style="drop")
for a, b in (("c1", "c2"), ("c2", "c3"), ("c3", "c4"), ("c4", "c5")):
    d.edge(a, b, fs="b", ts="t")
d.edge("b4", "c1", fs="r", ts="l", route="hvh", gut=GX[2] - 34, label="否")
d.annot(N, AY, [
    "这是整条音频链最容易踩的地方：丢弃是整块，不是静音",
    "屏录生效期间只收 100，本地 −1 全丢；DJI 接管期间只收 200",
    "所以混音器混出来的帧，external_source_index 必须取主源的，",
    "否则整块被这里丢掉（Overlay 混音器就踩过）",
])

# ④ 混音 + 编码
N = GX[3] + 40
d.node("d1", N, RY[0], 400, NH, "enableMixPartyLine && Joined ?", style="cond")
d.node("d2", N, RY[1], 400, NH, "partyLineMixWith(data, size, &out, &n)", "Partyline / RTIL 走同一个队列")
d.node("d3", N, RY[2], 400, NH, "voipMixWith(data, size, &out, &n)", "WebRTC VOIP 通话中")
d.node("d4", N, RY[3], 400, NH, "-writeAudioAssetWithParam:", "isEnableRecordCBR 才写")
d.node("d5", N, RY[4], 400, NH, "AudioConverterFillComplexBuffer(…)", "PCM → AAC · 128kbps · 1024 帧/包", style="focal")
d.edge("d1", "d2", fs="b", ts="t", label="是")
d.edge("d2", "d3", fs="b", ts="t", style="dash", label="互斥")
d.edge("d3", "d4", fs="b", ts="t")
d.edge("d4", "d5", fs="b", ts="t")
d.edge("c4", "d1", fs="r", ts="l", route="hvh", gut=GX[3] - 34, label="相符")
d.annot(N, AY, [
    "混音是就地覆盖：memcpy(param->data, data_mix, size) 后 free(data_mix)",
    "三者互斥：Partyline 优先，否则 VOIP，否则 RTIL（RTIL 复用 partyLineMixWith）",
    "混完才检查 param->size <= 0，为 0 则 unlock 后 return",
    "_audioConverter 为空时会先 unlock 再 setupEncoder，然后重新 lock",
])

# ⑤ 出口
N = GX[4] + 40
d.node("e1", N, RY[0], 440, NH, "handleVoiceRecordWithOutBufferList:…", "录音文件旁路", style="sink")
d.node("e2", N, RY[1], 440, NH, "isEnableFrameTransfer ?", style="cond")
d.node("e3", N, RY[2], 440, NH, "muxFrameWithStremId:TVU_LIVE_STREAM_ID_A", "链路② libtvulive2", style="sink")
d.node("e4", N, RY[3], 440, NH, "AVFormatControl::addAACData(…)", "链路① ASF mux", style="sink")
d.node("e5", N, RY[4], 440, NH, "pthread_mutex_unlock(&mutex_lock)", "临界区结束")
d.edge("e1", "e2", fs="b", ts="t")
d.edge("e2", "e3", fs="b", ts="t", label="是")
d.edge("e3", "e4", fs="b", ts="t", style="dash", label="互斥")
d.edge("e4", "e5", fs="b", ts="t")
d.edge("d5", "e1", fs="r", ts="l", route="hvh", gut=GX[4] - 34, label="出包")
d.annot(N, AY, [
    "newPts 是编码器自己维护的音频时间轴，与视频的 dts 同源于 g_vstarttime",
    "链路① 的 addAACData 进 m_AudioListPack，由 Dispatch_Data() 与视频按时间戳交错",
    "任一路断流，另一路会被交错逻辑卡住 —— 这是刻意的设计",
    "_TVUSDKPartyline 编译时链路② 整段被 #if 排除",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "条件判断"),
    ("box", "focal", "汇聚点 / 守门 / 编码"), ("box", "drop", "丢弃"), ("box", "sink", "出口"),
    ("line", "solid", "同线程调用"), ("line", "dash", "互斥分支"),
]

cards = [
    card("index 守门是整块丢弃", "coral", "不是静音，是整块不要",
         ["条件：<code>param->external_source_index != self.external_source_index</code>",
          "屏录生效期间只收 <code>100</code>；DJI 接管期间只收 <code>200</code>",
          "混音器混出来的帧，index 必须取<strong>主源</strong>的 —— 取辅源就整块被丢",
          "Accsoon 有例外开关 <code>isLiveWithBulidInAudioStream</code> 绕过判断"]),
    card("Agora 分叉的位置很关键", "ink", "在守门之前",
         ["<code>pushAudioData:andSampes:andTimestamp:</code> 在 index 守门<strong>之前</strong>调",
          "所以 partyline 里听到的音源，可能与推到云端的不是同一路",
          "样本数：<code>param->size / (2 * param->channel)</code>",
          "<code>enableEncoding</code> 为假时只走 Agora 不走编码"]),
    card("锁的范围", "muted", "从守门到出包",
         ["<code>mutex_lock</code> 在 index 守门前拿，出包后 <code>unlock</code>",
          "<code>_audioConverter</code> 为空时会先 unlock → <code>setupEncoder</code> → 重新 lock",
          "混音是就地覆盖 <code>param->data</code>，所以调用方的 buffer 会被改写",
          "M2 里 <code>TVUExtAudioEncoder</code> 曾因为在锁里嵌套 cond_wait 死锁过（ITA-824）"]),
]

write(OUT, d, "Call graph · 方法级 M5", "音频编码器与二次混音 — 一个方法一个盒子",
      "<code>TVUAudioEncoderManager -encode:</code> 是所有音频源的唯一汇聚点。"
      "橙色是汇聚点、index 守门与 AAC 编码三处；虚线是互斥分支。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ bc4021368 · 2026-08-24 · Diagram Design 2.6.1")
