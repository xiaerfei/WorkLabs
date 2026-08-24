import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "M1-外部源视频解码链路.html")

PITCH = 468
GX = [80 + i * PITCH for i in range(7)]        # 80 508 936 1364 1792 2220 2648
NX = [g + 40 for g in GX]
NW, NH = 340, 52
RY = [128 + i * 68 for i in range(6)]          # 128 196 264 332 400 468
GT, GH = 108, 520                              # 108 .. 628
AY = 486                                       # annotation block top

d = Diagram(3620, 720, "m1",
            "外部源视频解码链路 · 方法级调用图",
            "从 FFmpeg 打开文件到把帧交给合流层的逐方法调用图：解析线程读包入队，"
            "解码线程出队后调用解码器的 initDecoder 与 startDecode 送进 VideoToolbox，"
            "VT 回调线程做旋转封装并按 PTS 加入排序队列，排序线程出队后交给合流层，"
            "首帧改写活跃源索引，索引不符的帧在此丢弃。")

d.group("① TVUExternalSourceParse  -startParseWithPath:andIndex:   〔解析线程 · parseQueue〕", GX[0], GT, 400, GH)
d.group("② TVUExternalSourceQueue   video: queue", GX[1], GT, 400, GH)
d.group("③ TVUExternalSourceQueueManager::videoDecodeThread   〔解码线程〕", GX[2], GT, 400, GH)
d.group("④ TVUExternalSourceVideoDecoder  -decode:", GX[3], GT, 400, GH)
d.group("⑤ didDecompress   〔VideoToolbox 回调线程〕", GX[4], GT, 400, GH)
d.group("⑥ TVUExternalSourceSortQueueManager   sort: queue", GX[5], GT, 400, GH)
d.group("⑦ TVUExternalSourceSortQueueManager::sortThread   〔排序线程〕", GX[6], GT, 640, GH)

# ---------------------------------------------------------------- ① 解析线程
d.node("p1", NX[0], RY[0], NW, NH, "-openFile:", "avformat_open_input")
d.node("p2", NX[0], RY[1], NW, NH, "-openVideoStream / -opneVideoStreamHW", "avcodec_alloc_context3")
d.node("p3", NX[0], RY[2], NW, NH, "av_read_frame(_formatContext, &packet)", "只拆包，不解码")
d.node("p4", NX[0], RY[3], NW, NH, "packet.stream_index == _videoStream", "非视频包走音频分支（M2）", style="cond")
d.node("p5", NX[0], RY[4], NW, NH, "addDataToDecoder(&param, sourceQueue[…Video])", "param 带 pts / fps / rotate / index")
for a, b in (("p1", "p2"), ("p2", "p3"), ("p3", "p4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("p4", "p5", fs="b", ts="t", label="是")
d.edge("p5", "p3", fs="l", ts="l", route="hvh", gut=GX[0] + 18, style="dash")
d.annot(NX[0], AY, [
    "循环：p5 → p3 读下一包（左侧虚线）",
    "读到 EOF → avcodec_flush_buffers 从头再来",
    "RTSP 源换成 rtpQueueManager->addDataToDecoder(…)",
    "整段跑在 dispatch_async(parseQueue) 的一个串行块里",
])

# ---------------------------------------------------------------- ② 队列
d.node("q1", NX[1], RY[2], NW, 110, "Free / Work 双队列", style="queue", tag="QUEUE")
d.queue_cells(NX[1] + 24, RY[2] + 48, 5)
d.edge("p5", "q1", fs="r", ts="l", route="hvh", gut=GX[1] - 44, label="入队")
d.annot(NX[1], AY, [
    "kTUExternalSourceDecoderMediaSize = 2",
    "（video / audio 各一条）",
    "free 队列取不到节点 = 唯一的入队丢帧点",
])

# ---------------------------------------------------------------- ③ 解码线程
d.node("d1", NX[2], RY[0], NW, NH, "videoDecodeThread()", "while (!threadToEnd) 死循环")
d.node("d2", NX[2], RY[1], NW, NH, "while (length() >= 上限) usleep()", "背压：排序队列满就等")
d.node("d3", NX[2], RY[2], NW, NH, "decodeVideo()", "一轮只处理一个 node")
d.node("d4", NX[2], RY[3], NW, NH, "deQueue(workQueue)", "取出一个 node")
d.node("d5", NX[2], RY[4], NW, NH, "resetWorkQueueNode(node)", "归还 free 队列")
for a, b in (("d1", "d2"), ("d2", "d3"), ("d3", "d4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("d4", "d5", fs="b", ts="t", foff=-92, toff=-92, style="dash")
d.edge("d5", "d3", fs="l", ts="l", route="hvh", gut=GX[2] + 18, style="dash")
d.edge("q1", "d4", fs="r", ts="l", route="hvh", gut=GX[2] - 44, style="cross", label="出队")
d.annot(NX[2], AY, [
    "kTVUExternalSourceSortQueueNodeSize 是背压水位",
    "decode: 是同步调用，返回后才 resetWorkQueueNode",
    "循环：d5 → d3 取下一个 node（左侧虚线）",
    "队列空时只打 debug 日志然后 return，不 sleep",
])

# ---------------------------------------------------------------- ④ -decode:
d.node("v1", NX[3], RY[0], NW, NH, "-getNaluInformation:", "extraData 非空才走", style="cond")
d.node("v2", NX[3], RY[1], NW, NH, "-initDecoder:", "VTDecompressionSessionCreate")
d.node("v3", NX[3], RY[2], NW, NH, "-startDecode:", "malloc sourceRef + memcpy 帧数据")
d.node("v4", NX[3], RY[3], NW, NH, "VTDecompressionSessionDecodeFrame", "sourceRef 当 sourceFrameRefCon 透传", style="focal")
for a, b in (("v1", "v2"), ("v2", "v3"), ("v3", "v4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("d4", "v1", fs="r", ts="l", route="hvh", gut=GX[3] - 44, label="decode:")
d.annot(NX[3], AY, [
    "-getNaluInformation: 拆出 vps / sps / 前后两个 pps",
    "参数集与上一帧不同才 -releaseHwDecoder 重建会话",
    "HDR 源先过 -canOpenHDRDecoder: 决定能不能硬解",
    "sourceRef 里装 pts / fps / rotate / index / frameIdx",
])

# ---------------------------------------------------------------- ⑤ VT 回调
d.node("c1", NX[4], RY[0], NW, NH, "didDecompress(…)", "static 回调 · 线程由 VT 决定")
d.node("c2", NX[4], RY[1], NW, NH, "processPixelbuffer(…)", "按 sourceRef->rotate 旋转")
d.node("c3", NX[4], RY[2], NW, NH, "sortQueueManager->addData(…)", "sb, pts, fps, index, frameIdx")
d.node("c4", NX[4], RY[3], NW, NH, "free(sourceRef)", "漏了就是每帧泄漏")
for a, b in (("c1", "c2"), ("c2", "c3"), ("c3", "c4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("v4", "c1", fs="r", ts="l", route="hvh", gut=GX[4] - 44, style="cross", label="异步回调")
d.annot(NX[4], AY, [
    "pixelBuffer == NULL：free(sourceRef) 后直接 return",
    "processPixelbuffer 里 CMSampleBufferCreateForImageBuffer",
    "decodeTimeStamp 直接等于 presentationTimeStamp",
    "addData 之后 CFRelease(samplebuffer)，队列已自己持有",
])

# ---------------------------------------------------------------- ⑥ 排序队列
d.node("q2", NX[5], RY[2], NW, 110, "按 pts 有序插入", style="queue", tag="QUEUE")
d.queue_cells(NX[5] + 24, RY[2] + 48, 5, labels=["p0", "p1", "p2", "p3", "…"])
d.edge("c3", "q2", fs="r", ts="l", route="hvh", gut=GX[5] - 44, label="加入")
d.annot(NX[5], AY, [
    "enQueue 时按 pts 找位置插入，不是尾插",
    "B 帧的解码序 / 显示序错位在这里被抹平",
    "externalSourceBaseTime 在这里建立 —— M2 的音频等的就是它",
])

# ---------------------------------------------------------------- ⑦ 排序线程
SX1, SX2, SW = GX[6] + 40, GX[6] + 380, 240
d.node("s1", SX1, RY[0], SW, NH, "sortThread()", "while (!threadToEnd)")
d.node("s2", SX1, RY[1], SW, NH, "sort()")
d.node("s3", SX1, RY[2], SW, NH, "deQueue(work_queue)", "获取一个 node")
d.node("s4", SX1, RY[3], SW, NH, "处理 node", "三个去向", style="focal")
for a, b in (("s1", "s2"), ("s2", "s3"), ("s3", "s4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("q2", "s3", fs="r", ts="l", route="hvh", gut=GX[6] - 44, style="cross", label="出队")

d.node("s5", SX2, RY[0], SW, NH, "首帧：改写活跃源索引", "+ 发 2 个通知")
d.node("s6", SX2, RY[2] - 4, SW, NH, "resetNode(node) 丢弃", "index 不符", style="drop")
d.node("s7", SX2, RY[4], SW, NH, "AddBufferToWorkQueue(…)", "→ M3 合流层", style="sink")
d.edge("s4", "s5", fs="r", ts="l", route="hvh", gut=GX[6] + 312, label="首帧")
d.edge("s4", "s6", fs="r", ts="l", route="hvh", gut=GX[6] + 332, style="dash", label="不符")
d.edge("s4", "s7", fs="r", ts="l", route="hvh", gut=GX[6] + 352, label="正常")
d.annot(SX1, AY, [
    "首帧那支做三件事：TVUAVStreamManager::external_source_index = node->external_source_index、",
    "[[TVUAudioEncoderManager manager] updateExternalSourceIndex:]、",
    "发 kTVUExternalSourceStopLastSource + kTVUExternalSourceParseStart 两个通知",
    "正常那支：AddBufferToWorkQueue(new_samplebuffer, m_total_queue[TVUExternalQueue], index, fps)",
    "「过滤前三帧」那段目前是注释状态（原本为躲编码器码率过低）",
])

d.legend = [
    ("box", "call",  "方法调用"),
    ("box", "cond",  "条件判断"),
    ("box", "queue", "队列"),
    ("box", "focal", "关键两步"),
    ("box", "drop",  "丢弃"),
    ("box", "sink",  "出口"),
    ("line", "solid", "同线程调用"),
    ("line", "cross", "跨线程交接"),
    ("line", "dash",  "循环 / 返回 / 丢弃"),
]

cards = [
    card("为什么这条链要四个驱动方", "coral", "每条边界都换了谁在推",
         ["解析线程被 <code>av_read_frame</code> 推 —— 有包就往下走",
          "解码线程自己拉 —— <code>decodeVideo()</code> 主动 <code>deQueue</code>，并带背压水位",
          "VT 回调线程被 VideoToolbox 推 —— 线程和时机都不在我们手里",
          "排序线程按 pts 与墙上时钟放行 —— 这里才决定一帧什么时候出去"]),
    card("三对必须成对的动作", "ink", "漏一个就出事",
         ["<code>malloc sourceRef</code>（-startDecode:）↔ <code>free(sourceRef)</code>（didDecompress 的每一条返回路径）",
          "<code>deQueue(workQueue)</code> ↔ <code>resetWorkQueueNode(node)</code>",
          "<code>-initDecoder:</code> ↔ <code>-releaseHwDecoder</code>（只在参数集变化时）"]),
    card("和语雀那张的差异", "muted", "右半段整段已失效",
         ["<code>pushSample:andPtsOffset:sourceType:</code>、<code>pushRenderSampleBuffer:</code>、"
          "<code>addSampleData</code> 在当前代码里 <strong>0 处引用</strong>",
          "那条「编码器扇出 → Record Video + 传输」已被合流层 + "
          "<code>encode:isNeedKeyFrame:externalSourceIndex:</code> 取代，见 M3 / M4",
          "<code>addData</code> 从 4 参变 5 参，多了 <code>current_frame_index</code>",
          "<code>sort()</code> 首帧那支现在还会发两个通知"]),
]

write(OUT, d, "Call graph · 方法级 M1", "外部源视频解码链路 — 一个方法一个盒子",
      "从 <code>av_read_frame</code> 到 <code>AddBufferToWorkQueue</code> 的逐方法调用图。"
      "外框是拥有这段调用的 <code>Class::method</code> 或线程；框内每个盒子是一次真实调用；"
      "框底的小字是这段里其余的调用表达式与约束；虚线是循环 / 返回 / 丢弃，蓝线是跨线程交接。",
      cards,
      "TVUAnywhere iOS · share/SPAR-705 @ bc4021368 · 2026-08-24 · Diagram Design 2.6.1")
