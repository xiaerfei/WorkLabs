import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "M4-视频编码与推流.html")

GW = [460, 460, 460, 420, 440, 500]
GX, TOTW = lanes(GW, gap=68, x0=80)
NH = 52
RY = [128 + i * 68 for i in range(6)]
GT, GH, AY = 108, 560, 548

d = Diagram(TOTW, 760, "m4",
            "视频编码与推流 · 方法级调用图",
            "sendToEncoderWithSamplebuffer 里依次做 PTS 守门、缩略图、Overlay 合成、I 帧决策与后台喂点，"
            "然后调 TVUVideoEncoderManager 的 encode:isNeedKeyFrame:externalSourceIndex:；"
            "H.264 / H.265 各自送进 VTCompressionSessionEncodeFrame，回调里算 dts、拼 SPS/PPS，"
            "最后按 isEnableFrameTransfer 走 ASF mux 或 libtvulive2 两条互斥链路，另有录制旁路。")

d.group("① sendToEncoderWithSamplebuffer 前段   〔encoder 线程〕", GX[0], GT, GW[0], GH)
d.group("② Overlay 合成（IRL / TVUOnlyAnyWhere）", GX[1], GT, GW[1], GH)
d.group("③ I 帧决策 + 后台喂点", GX[2], GT, GW[2], GH)
d.group("④ TVUVideoEncoderManager -encode:isNeedKeyFrame:externalSourceIndex:", GX[3], GT, GW[3], GH)
d.group("⑤ VideoToolbox 压缩 + 回调", GX[4], GT, GW[4], GH)
d.group("⑥ 出口：两条互斥推流链路 + 录制旁路", GX[5], GT, GW[5], GH)

# ① 前段
N = GX[0] + 40
d.node("a1", N, RY[0], 380, NH, "checkSampleBufferPTSForEncode(sb, subType)", "PTS 守门 · 不合格直接 return", style="cond")
d.node("a2", N, RY[1], 380, NH, "productThumbnail:andSendSignal:", "每 kTVUThumbnailInterval 秒一张")
d.node("a3", N, RY[2], 380, NH, "isMuteVideoInPartyline ?", "partyline 里 mute video", style="cond")
d.node("a4", N, RY[3], 380, NH, "createBlackPiexelBufferWithWidth:andHeight:", "分辨率变了才重建黑帧")
d.node("a5", N, RY[4], 380, NH, "tvuConsumePixelBuffer:andPresentTime:", "partyline 另一路消费同一帧", style="sink")
for a, b in (("a1", "a2"), ("a2", "a3"), ("a3", "a4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("a4", "a5", fs="b", ts="t", label="是")
d.annot(N, AY, [
    "setEncVideoPTS: 在这里记编码前 pts 与 UTC 的误差",
    "enableEncoding 为假时：resetLastExternalSourceIndex + 释放水印 buffer 后 return",
    "（预览照常，只是不编码）",
])

# ② Overlay
N = GX[1] + 40
d.node("b1", N, RY[0], 380, NH, "[TVUSnapshotManager manager] running ?", "且 enableEncoding || isJoinPartline", style="cond")
d.node("b2", N, RY[1], 380, NH, "snapNodes", "取全部 overlay node")
d.node("b3", N, RY[2], 380, NH, "lastObject.isBuiltInOverlay ?", "内置全屏模板恒在末尾", style="cond")
d.node("b4", N, RY[3], 180, NH, "fullScreenPixelBuffer…", "整帧替换", style="focal")
d.node("b5", N + 200, RY[3], 180, NH, "addImageWatermarks…GPU:", "逐层叠加", style="focal")
for a, b in (("b1", "b2"), ("b2", "b3")):
    d.edge(a, b, fs="b", ts="t")
d.edge("b3", "b4", fs="b", ts="t", foff=-100, label="内置模板")
d.edge("b3", "b5", fs="b", ts="t", foff=100, label="常规 overlay")
d.edge("a3", "b1", fs="r", ts="l", route="hvh", gut=GX[1] - 34, label="否")
d.annot(N, AY, [
    "后台推流时 skipOverlayInBackground = inBackground：常规 overlay 刻意不合成，",
    "保持编码帧干净（喂给 PiP 的是同一帧）；内置全屏遮罩例外，遮住画面就是它的目的",
    "SPAR-30：streamType(1) + streamSubType(-1) = 0 曾把自定义流误判成相机原生流，",
    "绕过了从 GPU 取 buffer 的防死锁分支 —— 所以这里用 abs() 相加",
])

# ③ I 帧决策
N = GX[2] + 40
d.node("c1", N, RY[0], 380, NH, "streamType / subType 变了 ?", "切源 → isNeedKeyFrame = YES", style="cond")
d.node("c2", N, RY[1], 380, NH, "exif LensModel 含 \"front\" ?", "切摄像头 → isNeedKeyFrame = YES", style="cond")
d.node("c3", N, RY[2], 380, NH, "isFirst ?", "开播首帧 → isNeedKeyFrame = YES", style="cond")
d.node("c4", N, RY[3], 380, NH, "convertCVImageBufferRefToCMSampleBufferRef:", "把合成好的 pixelbuffer 重新封装")
d.node("c5", N, RY[4], 380, NH, "enqueueCameraSampleBuffer:", "后台推流统一喂点 → M8", style="sink")
for a, b in (("c1", "c2"), ("c2", "c3"), ("c3", "c4"), ("c4", "c5")):
    d.edge(a, b, fs="b", ts="t")
d.edge("b5", "c1", fs="r", ts="l", route="hvh", gut=GX[2] - 34)
d.annot(N, AY, [
    "GOP 配的是 600（H.264 当秒 / H.265 当帧），所以 I 帧基本全靠这三个业务事件驱动",
    "喂点前先查 kTVUBackgroundStreamingSynthesizedFrameKey：",
    "补帧器合成的待机帧要跳过，否则会重置「最后一帧」计时器、模糊叠加",
])

# ④ encode:
N = GX[3] + 40
d.node("d1", N, RY[0], 340, NH, "self.enableH264 ?", "liveWay == TVUH264Live", style="cond")
d.node("d2", N, RY[1], 340, NH, "[self.h264Encoder encode:sb]", "H.264 分支")
d.node("d3", N, RY[2], 340, NH, "self.enableH265 ?", style="cond")
d.node("d4", N, RY[3], 340, NH, "[self.h265Encoder encode:sb isNeedKeyFrame:]", "H.265 分支（多带一个参数）")
d.node("d5", N, RY[4], 340, NH, "lastExternalSourceIndex 变了 ?", "切源时低码率重启编码器", style="cond")
d.edge("d1", "d2", fs="b", ts="t", label="是")
d.edge("d2", "d3", fs="b", ts="t")
d.edge("d3", "d4", fs="b", ts="t", label="是")
d.edge("d4", "d5", fs="b", ts="t")
d.edge("c5", "d1", fs="r", ts="l", route="hvh", gut=GX[3] - 34, label="encode:")
d.annot(N, AY, [
    "H.265 直播 + H.264 录制时，H.264 编码器仍会被拉起（isOpenMuxFlag）",
    "H.264 走 MaxKeyFrameIntervalDuration（秒）",
    "H.265 走 MaxKeyFrameInterval（帧）—— 同一个常量 60*10，单位不同",
    "H.265 在 30fps 下约 20 秒一个 I 帧",
])

# ⑤ VT
N = GX[4] + 40
d.node("e1", N, RY[0], 360, NH, "VTCompressionSessionEncodeFrame", "同步提交，异步出包", style="focal")
d.node("e2", N, RY[1], 360, NH, "videoEncodeCallBack(…)", "static 回调")
d.node("e3", N, RY[2], 360, NH, "dtsAfter = (pts − g_vstarttime) × 1000", "毫秒相对轴")
d.node("e4", N, RY[3], 360, NH, "dts 兜底：0 → last_dts + 33", "相等 → +1，保严格单调")
d.node("e5", N, RY[4], 360, NH, "GetH264ParameterSetAtIndex(0/1)", "IDR 时取 sps / pps 拼 4 字节起始码")
for a, b in (("e1", "e2"), ("e2", "e3"), ("e3", "e4"), ("e4", "e5")):
    d.edge(a, b, fs="b", ts="t")
d.edge("d2", "e1", fs="r", ts="l", route="hvh", gut=GX[4] - 34, style="cross", label="提交")
d.annot(N, AY, [
    "g_vstarttime 是全局唯一时间基准（首帧 HostTime 秒值），三处互斥初始化",
    "H.265 侧同理，取 VPS / SPS / PPS 三段",
    "CMBlockBufferGetDataPointer 拿到的是 AVCC 长度前缀格式，出口处转起始码",
])

# ⑥ 出口
N = GX[5] + 40
d.node("f1", N, RY[0], 420, NH, "isEnableFrameTransfer ?", "tvu_enable_frame_transfer", style="cond")
d.node("f2", N, RY[1], 420, NH, "AVFormatControl::addH264Data(…)", "链路① SEI → SPS/PPS → 帧数据 → ASF mux", style="sink")
d.node("f3", N, RY[2], 420, NH, "muxFrameWithStremId:andKeyFrame:andPts:…", "链路② libtvulive2_mux_frame", style="sink")
d.node("f4", N, RY[4], 420, NH, "TVURecordMuxHandler::addVideoData(…)", "录制旁路 · .asf 落盘", style="sink")
d.edge("f1", "f2", fs="b", ts="t", label="否")
d.edge("f2", "f3", fs="b", ts="t", style="dash", label="互斥")
d.edge("e5", "f1", fs="r", ts="l", route="hvh", gut=GX[5] - 34)
d.edge("e5", "f4", fs="r", ts="l", route="hvh", gut=GX[5] - 18, foff=14, style="dash", label="并行")
d.annot(N, AY, [
    "链路① 之后：Dispatch_Data() 按时间戳交错音视频 → AVFormatHttp::Product_Data_Packet",
    "→ CTVUTransporterT::callback_data_in（App 层最后一站）",
    "链路② 之后：sendFrameDataWithMediaType: → CMessageProcessing::SendMsg_SendFrameData",
    "两条链路都要求 g_livestate && ntpSynced 才真正上网",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "条件判断"),
    ("box", "focal", "GPU 合成 / 硬件压缩"), ("box", "sink", "出口"),
    ("line", "solid", "同线程调用"), ("line", "cross", "异步回调"), ("line", "dash", "并行 / 互斥"),
]

cards = [
    card("I 帧到底谁在决定", "coral", "不是周期 GOP",
         ["<code>streamType</code> 或 <code>streamSubType</code> 变（切源）",
          "exif <code>LensModel</code> 前后置翻转（切摄像头）",
          "<code>isFirst</code>（开播首帧）",
          "外加 R 端下发的 <code>forceInsertKeyFrame</code>",
          "GOP 常量 600 在 H.264 是<strong>秒</strong>（等于关掉周期 GOP），在 H.265 是<strong>帧</strong>"]),
    card("两条互斥推流链路", "ink", "isEnableFrameTransfer 一个开关切换",
         ["关：<code>AVFormatControl::addH264Data</code> → ASF mux → <code>CTVUTransporterT</code>",
          "开：<code>TVULiveMediaCenter muxFrameWithStremId:</code> → <code>libtvulive2_mux_frame</code>",
          "I 帧的拼装顺序固定：<strong>SEI → SPS/PPS → 帧数据</strong>",
          "录制旁路与两者并行，走 <code>TVURecordMuxHandler</code>，不上网"]),
    card("dts 的两层兜底", "muted", "保严格单调",
         ["<code>dtsAfter = (pts − g_vstarttime) × 1000</code>",
          "算出 0 → 用 <code>last_dts + 33</code>（假定 30fps）",
          "与上一帧相等 → <code>+1</code>",
          "R 端看到的时间戳秩序，最后一道保障是 Mux 层的 <code>Dispatch_Data()</code> 交错"]),
]

write(OUT, d, "Call graph · 方法级 M4", "视频编码与推流 — 一个方法一个盒子",
      "从 <code>sendToEncoderWithSamplebuffer</code> 到两条互斥推流链路的逐方法调用图。"
      "这一段取代了语雀旧图里已失效的「编码器扇出 → Record + 传输」。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ bc4021368 · 2026-08-24 · Diagram Design 2.6.1")
