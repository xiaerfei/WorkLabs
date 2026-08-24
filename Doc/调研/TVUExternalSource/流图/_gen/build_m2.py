import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "M2-外部源音频解码链路.html")

GW = [660, 400, 420, 420, 400, 460, 420]
GX, TOTW = lanes(GW, gap=68, x0=80)
NW, NH = 340, 52
RY = [128 + i * 68 for i in range(6)]
GT, GH = 108, 520
AY = 486

d = Diagram(TOTW, 720, "m2",
            "外部源音频解码链路 · 方法级调用图",
            "解析线程按流索引把音频包分流，组播源在解析线程内用 FFmpeg 软解直发，"
            "其余源投进音频解码队列；音频解码线程先等视频建立基准时间再按墙上时钟节流出队，"
            "调用解码器把 AAC 解成 PCM 并攒成定长块推入环形队列；"
            "独立的编码线程出队后依次判投屏、施加采集增益，最后按 streamType 分流到三个出口。")

d.group("① TVUExternalSourceParse  读包循环内的音频分支   〔解析线程 · parseQueue〕", GX[0], GT, GW[0], GH)
d.group("② TVUExternalSourceQueue   audio: queue", GX[1], GT, GW[1], GH)
d.group("③ TVUExternalSourceQueueManager::audioDecodeThread   〔音频解码线程〕", GX[2], GT, GW[2], GH)
d.group("④ TVUExternalSourceAudioDecoder  -decode:", GX[3], GT, GW[3], GH)
d.group("⑤ TVUExtPCMFrameList   定长环形队列", GX[4], GT, GW[4], GH)
d.group("⑥ TVUExtAudioEncoder::doencode()   〔外部源音频编码线程〕", GX[5], GT, GW[5], GH)
d.group("⑦ 三个出口", GX[6], GT, GW[6], GH)

# ---- ① 解析线程（两列：主路 / 组播捷径）
A1, A2 = GX[0] + 40, GX[0] + 400
d.node("a1", A1, RY[0], 300, NH, "packet.stream_index == _audioStream", "读包循环里的音频分支", style="cond")
d.node("a2", A1, RY[1], 300, NH, "sourceType == …MuticastUrl ?", "组播走软解捷径", style="cond")
d.node("a3", A1, RY[2], 300, NH, "packet.pts > 0 ?", "负 pts 直接丢，防 mux 队列积压", style="cond")
d.node("a4", A1, RY[3], 300, NH, "addDataToDecoder(&param, sourceQueue[…Audio])", "RTSP 换 rtpQueueManager")
d.edge("a1", "a2", fs="b", ts="t")
d.edge("a2", "a3", fs="b", ts="t", label="否")
d.edge("a3", "a4", fs="b", ts="t", label="是")

d.node("m1", A2, RY[0], 220, NH, "-decodeAudioWithCodetext:…", "等 isVideoFirstF == YES")
d.node("m2", A2, RY[1], 220, NH, "avcodec_send_packet", "+ avcodec_receive_frame · 软解")
d.node("m3", A2, RY[2], 220, NH, "subcontractWithInBuffer:…", "重采样 + 分包 → 出口", style="sink")
d.edge("a2", "m1", fs="r", ts="l", route="hvh", gut=GX[0] + 370, label="是")
d.edge("m1", "m2", fs="b", ts="t")
d.edge("m2", "m3", fs="b", ts="t")
d.annot(A1, AY, [
    "组播那一支完全不经 audio 队列与编码线程：block 里直接判 PIP，",
    "进 TVUExternalSourceAudioMixerQueueManager 或 [TVUAudioEncoderManager encode:]",
    "param 带 channel / sampleRate / pts / current_frame_index",
])

# ---- ② audio 队列
d.node("q1", GX[1] + 30, RY[2], NW, 110, "Free / Work 双队列", style="queue", tag="QUEUE")
d.queue_cells(GX[1] + 54, RY[2] + 48, 5)
d.edge("a4", "q1", fs="r", ts="l", route="hvh", gut=GX[1] - 34, label="入队")
d.annot(GX[1] + 30, AY, [
    "与 video 队列共用",
    "kTUExternalSourceDecoderMediaSize = 2",
    "getFrontNodePts() 只窥探队头，不出队",
])

# ---- ③ 音频解码线程
N3 = GX[2] + 40
d.node("b1", N3, RY[0], NW, NH, "audioDecodeThread()", "while (!threadToEnd)")
d.node("b2", N3, RY[1], NW, NH, "externalSourceBaseTime == 0 ?", "视频没落地就 usleep(10ms) 返回", style="focal")
d.node("b3", N3, RY[2], NW, NH, "getFrontNodePts() + baseTime", "只看队头 pts，不动队列")
d.node("b4", N3, RY[3], NW, NH, "pts*1000 + 30 < now*1000 ?", "pts_offset = 30 · 墙上时钟节流", style="focal")
d.node("b5", N3, RY[4], NW, NH, "deQueue(workQueue)", "到点了才真出队")
d.edge("b1", "b2", fs="b", ts="t")
d.edge("b2", "b3", fs="b", ts="t", label="否")
d.edge("b3", "b4", fs="b", ts="t")
d.edge("b4", "b5", fs="b", ts="t", label="是")
d.edge("q1", "b3", fs="r", ts="l", route="hvh", gut=GX[2] - 34, style="cross", label="窥探")
d.annot(N3, AY, [
    "这两个菱形是整条音频链的节拍来源：",
    "视频的 sortQueueManager 建立 externalSourceBaseTime 之前，",
    "一帧音频都不会解 —— 视频卡住音频就跟着停",
])

# ---- ④ -decode:
N4 = GX[3] + 40
d.node("e1", N4, RY[0], NW, NH, "-setupDecoder:sampleRate:", "建 AudioConverter（AAC → PCM）")
d.node("e2", N4, RY[1], NW, NH, "TVUFFmpegResample -initWithResampleDic:", "andSrcNBSample:1024 · 非 48k 才建")
d.node("e3", N4, RY[2], NW, NH, "AudioConverterFillComplexBuffer(…)", "AudioDecoderConverterComplexInputDataProc")
d.node("e4", N4, RY[3], NW, NH, "TVUExtAudioEncoder::pushFrame(…)", "data, size, pts*1000, external_source_index")
d.edge("e1", "e2", fs="b", ts="t")
d.edge("e2", "e3", fs="b", ts="t")
d.edge("e3", "e4", fs="b", ts="t")
d.edge("b5", "e1", fs="r", ts="l", route="hvh", gut=GX[3] - 34, label="decode:")
d.annot(N4, AY, [
    "kTVUExternalSourceAudioDecoderFramesPerPacket = 1024",
    "重采样只在源采样率不是 48k 时才建，建一次复用",
    "解出来是 48k / stereo / Int16 交织",
])

# ---- ⑤ 环形队列
d.node("q2", GX[4] + 30, RY[2], NW, 110, "50 槽 × 4096B 定长", style="queue", tag="RING")
d.queue_cells(GX[4] + 54, RY[2] + 48, 5, labels=["0", "1", "2", "3", "…"])
d.edge("e4", "q2", fs="r", ts="l", route="hvh", gut=GX[4] - 34, label="攒块")
d.annot(GX[4] + 30, AY, [
    "PCMFRAMELIST_SIZE = 50",
    "PCMBUFF_SIZE = 4096（1024 帧 × 双声道 × int16）",
    "每格自带 mutex + timestamp + external_source_index",
])

# ---- ⑥ 编码线程
N6 = GX[5] + 40
d.node("f1", N6, RY[0], 380, NH, "__list.popFrame()", "NULL → usleep(10ms) continue")
d.node("f2", N6, RY[1], 380, NH, "size == capacity ?", "不满 4096B 就丢这一格", style="cond")
d.node("f3", N6, RY[2], 380, NH, "isReceivingFrame ?", "投屏中 → 送屏幕分享后 continue", style="cond")
d.node("f4", N6, RY[3], 380, NH, "tvuApplyExternalSourceCaptureGain(…)", "getAudioCaptureGain != 1.0 才施加")
d.node("f5", N6, RY[4], 380, NH, "switch (streamType)", "三个去向", style="focal")
d.edge("f1", "f2", fs="b", ts="t")
d.edge("f2", "f3", fs="b", ts="t", label="是")
d.edge("f3", "f4", fs="b", ts="t", label="否")
d.edge("f4", "f5", fs="b", ts="t")
d.edge("q2", "f1", fs="r", ts="l", route="hvh", gut=GX[5] - 34, style="cross", label="出队")
d.annot(N6, AY, [
    "投屏支：tvuSendAudioToScreenShare(buff, size, pts, stereo)",
    "刻意送解码原始 PCM —— 增益由屏幕分享队列的 adjustAudioGain 施加",
    "锁的范围被刻意缩短过（ITA-824 死锁）：",
    "pthread_mutex_unlock(&pframe->mutex) 在分流之前就调了",
])

# ---- ⑦ 出口
N7 = GX[6] + 40
d.node("o1", N7, RY[0], NW, NH, "Overlay 混音器 · 主源", "sourceQueue[…LocalCamera]", style="sink")
d.node("o2", N7, RY[2], NW, NH, "外部源混音器 · 路 1", "sourceQueue[…ExternalSource]", style="sink")
d.node("o3", N7, RY[4], NW, NH, "[TVUAudioEncoderManager encode:]", "→ M5", style="sink")
d.edge("f5", "o1", fs="r", ts="l", route="hvh", gut=GX[6] - 48, label="朗读开")
d.edge("f5", "o2", fs="r", ts="l", route="hvh", gut=GX[6] - 34, label="PIP/PBP")
d.edge("f5", "o3", fs="r", ts="l", route="hvh", gut=GX[6] - 20, label="default")
d.annot(N7, AY, [
    "出口 ① 走 tvuEncodeOrMixExternalSourceAudio()：",
    "shouldOutputAudioStream 为真才改道 Overlay 混音器（SPAR-769）",
    "出口 ② 含「换背景」场景（tvuIsReplaceBackgroundStart）",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "条件判断"), ("box", "queue", "队列"),
    ("box", "focal", "节拍决策点"), ("box", "sink", "出口"),
    ("line", "solid", "同线程调用"), ("line", "cross", "跨线程交接"),
]

cards = [
    card("音视频同步的实际实现", "coral", "音频被墙上时钟拉着走",
         ["<code>externalSourceBaseTime</code> 由<strong>视频</strong>的排序队列建立，音频只是等它",
          "<code>getFrontNodePts()</code> 只窥探队头，不出队 —— 没到点就原样留在队列里",
          "<code>pts_offset = 30</code>：允许比当前时间早 30ms 就放行",
          "视频链路卡住 → baseTime 不推进 → 音频跟着停，不会各跑各的"]),
    card("组播那条捷径", "ink", "完全不经队列和编码线程",
         ["<code>-decodeAudioWithCodetext:andPkt:andCurrentTimestamp:index:</code> 在解析线程里直接软解",
          "重采样分包用 <code>subcontractWithInBuffer:…SubcontractHandleBlock:</code>",
          "block 里就地判 PIP 决定进混音器还是 <code>encode:</code>",
          "同样要等 <code>isVideoFirstF == YES</code>"]),
    card("和语雀那张的差异", "muted", "这半张整条换掉了",
         ["<code>TVUAudioSampleHandle</code>、<code>caculateVolumn(…)</code> 当前代码里不存在",
          "<code>aacEncoder</code>（本地 mic）与 <code>TVUExtAudioEncoder</code>（外部源）是两个独立类，结构相似但别混",
          "出口从 2 个变 3 个：新增 Overlay 混音器主源",
          "<code>pushFrame</code> 多了 <code>external_source_index</code> 参数"]),
]

write(OUT, d, "Call graph · 方法级 M2", "外部源音频解码链路 — 一个方法一个盒子",
      "从读包循环的音频分支到三个出口的逐方法调用图。橙色菱形是整条链的节拍决策点；"
      "组播源有一条完全绕过队列与编码线程的软解捷径。",
      cards,
      "TVUAnywhere iOS · share/SPAR-705 @ bc4021368 · 2026-08-24 · Diagram Design 2.6.1")
