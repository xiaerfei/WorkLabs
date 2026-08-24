import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "M7-Overlay注入双路.html")

B1W = [460, 480, 520, 480]
B1X, TOTW = lanes(B1W, gap=68, x0=80)
R1 = [136 + i * 68 for i in range(4)]
G1T, G1H, A1Y = 108, 420, 428

B2W = [460, 480, 520, 480]
B2X = B1X
R2 = [616 + i * 68 for i in range(4)]
G2T, G2H, A2Y = 588, 420, 908

d = Diagram(TOTW, 1080, "m7",
            "Overlay 注入双路 · 方法级调用图",
            "Overlay 的画面与声音是两套完全独立的注入路径。上带：三类内容源渲染成位图，"
            "在 sendToEncoder 里做 GPU 水印合成，内置全屏模板改为整帧替换。"
            "下带：WebView 页内 JS 抓 Web Audio 回传 PCM、弹幕朗读取 PCM，"
            "两路进 Overlay 混音器与本地 mic 混合后交给音频编码器。")

d.group("① Overlay 内容源（画面）", B1X[0], G1T, B1W[0], G1H)
d.group("② TVUSnapshotManager   容器与节点", B1X[1], G1T, B1W[1], G1H)
d.group("③ 画面注入：两条互斥合成路径", B1X[2], G1T, B1W[2], G1H)
d.group("④ 约束与拆除", B1X[3], G1T, B1W[3], G1H)
d.group("⑤ Overlay 内容源（声音）", B2X[0], G2T, B2W[0], G2H)
d.group("⑥ 攒块与格式归一", B2X[1], G2T, B2W[1], G2H)
d.group("⑦ TVUOverlayAudioMixerManager   三路混音", B2X[2], G2T, B2W[2], G2H)
d.group("⑧ 出口", B2X[3], G2T, B2W[3], G2H)

# ---- ① 画面源
N = B1X[0] + 40
d.node("a1", N, R1[0], 380, 52, "TVUPictureSnapshotManager", "图片 overlay · 可拖拽缩放")
d.node("a2", N, R1[1], 380, 52, "TVUTextSnapshotManager", "文字渲染成位图")
d.node("a3", N, R1[2], 380, 52, "TVUWebSnapshotManager", "WKWebView 定时快照")
d.node("a4", N, R1[3], 380, 52, "内置全屏模板", "Privacy Screen / Starting Soon", style="focal")
d.annot(N, A1Y, [
    "三类源最终都变成 TVUSnapshotNode.image 一张位图",
    "内置模板恒定追加在 snapNodes 末尾（isBuiltInOverlay = YES）",
    "所以只查 lastObject 就能判断，不必遍历整个数组",
])

# ---- ② 容器
N = B1X[1] + 40
d.node("b1", N, R1[0], 400, 52, "-prepareRenderContainer", "返回容器是否真的挂上了", style="cond")
d.node("b2", N, R1[1], 400, 52, "-insertSnapShotItem:", "有副作用的调用方必须先问 b1")
d.node("b3", N, R1[2], 400, 52, "-snapNodes", "取全部 node（数组）")
d.node("b4", N, R1[3], 400, 52, "-running / -isExsitSnap", "有没有在跑 / 存不存在")
for a, b in (("b1", "b2"), ("b2", "b3"), ("b3", "b4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("a3", "b1", fs="r", ts="l", route="hvh", gut=B1X[1] - 34)
d.annot(N, A1Y, [
    "prepareRenderContainer 是幂等的：已挂载时直接返回 YES",
    "为什么要先问：静音 mic、踢掉另一个内置项、持久化这些副作用",
    "不能在插入被拒之后还留着",
])

# ---- ③ 合成
N = B1X[2] + 40
d.node("c1", N, R1[0], 440, 52, "running && (enableEncoding || isJoinPartline)", "两个前置条件", style="cond")
d.node("c2", N, R1[1], 440, 52, "lastObject.isBuiltInOverlay ?", "内置模板在末尾", style="cond")
d.node("c3", N, R1[2], 200, 52, "fullScreenPixelBuffer…", "整帧替换", style="focal")
d.node("c4", N + 240, R1[2], 200, 52, "addImageWatermarks…GPU:", "逐层叠加", style="focal")
d.edge("c1", "c2", fs="b", ts="t")
d.edge("c2", "c3", fs="b", ts="t", foff=-120, label="是")
d.edge("c2", "c4", fs="b", ts="t", foff=120, label="否")
d.edge("b3", "c1", fs="r", ts="l", route="hvh", gut=B1X[2] - 34, label="nodes")
d.annot(N, A1Y - 60, [
    "withStreamType: abs(streamType) + abs(streamSubType) ——",
    "SPAR-30：streamType(1)+streamSubType(−1)=0 曾把自定义流误判成相机原生流，",
    "绕过了从 GPU 取 buffer 的防死锁分支，3 分钟后卡死",
    "后台推流时 skipOverlayInBackground = inBackground：常规 overlay 刻意不合成，",
    "保持编码帧干净（PiP 拿到同一帧）；内置全屏遮罩例外 —— 遮住画面就是它的目的",
])

# ---- ④ 约束
N = B1X[3] + 40
d.node("d1", N, R1[1], 400, 52, "-goToDetectSnapConditionWithSource:", "分辨率变更后复检")
d.node("d2", N, R1[2], 400, 52, "降到 480 / 576 → 整体拆除", "TVU_OVERLAYUNSUPPORT_HEIGHT = 480", style="drop")
d.edge("d1", "d2", fs="b", ts="t")
d.edge("c4", "d1", fs="r", ts="l", route="hvh", gut=B1X[3] - 34, style="dash")
d.annot(N, A1Y, [
    "source 只用于上报，不影响拆除逻辑：",
    "Local（用户在分辨率页改的）vs Remote（R 端下发）",
    "远端下发那一路用户毫无操作却丢了 overlay，上报要分得开",
])

# ---- ⑤ 声音源
N = B2X[0] + 40
d.node("e1", N, R2[0], 380, 52, "+audioOutputScript", "注入页面的 JS：抓 Web Audio")
d.node("e2", N, R2[1], 380, 52, "-receiveScriptMessage:", "WKScriptMessage 回传 base64 PCM")
d.node("e3", N, R2[2], 380, 52, "TVUChatTTSStreamSpeaker", "弹幕聚合 → 朗读")
d.node("e4", N, R2[3], 380, 52, "-writeUtterance:toBufferCallback:", "不是 speakUtterance:", style="focal")
d.edge("e1", "e2", fs="b", ts="t")
d.edge("e3", "e4", fs="b", ts="t")
d.annot(N, A2Y, [
    "WebView 音频不是系统采集，是页内 JS 抓 Web Audio 再经 scriptMessage 回传",
    "writeUtterance 在部分语音/系统版本上只回一个空 buffer（Apple 已知问题）——",
    "那种情况直接丢这条，两边都听不到，行为一致；刻意不回落 speakUtterance:",
])

# ---- ⑥ 归一
N = B2X[1] + 40
d.node("f1", N, R2[0], 400, 52, "-resampleFloat32ToInt16:", "vDSP 加速 · 自动 clipping")
d.node("f2", N, R2[1], 400, 52, "convertToStereo(…)", "单声道 → 立体声")
d.node("f3", N, R2[2], 400, 52, "攒到 4096B 才推", "pcmCacheData 切片 · correct_pts 递推")
d.node("f4", N, R2[3], 400, 52, "pcmOutput(NSData *pcm)", "TTS 侧的定长切片同理")
d.edge("f1", "f2", fs="b", ts="t")
d.edge("f2", "f3", fs="b", ts="t")
d.edge("e2", "f1", fs="r", ts="l", route="hvh", gut=B2X[1] - 34)
d.edge("e4", "f4", fs="r", ts="l", route="hvh", gut=B2X[1] - 20)
d.annot(N, A2Y, [
    "混音器只吃定长块（4096B = 1024 帧 × 双声道 × int16），",
    "攒块切片由每个写入方自己负责 —— WebView / TTS / mic 三方各写一遍",
    "correct_pts = timestamp − remain_pts，按已缓存长度回推，避免累积漂移",
])

# ---- ⑦ 混音器
N = B2X[2] + 40
d.node("g1", N, R2[0], 440, 52, "addDataToAudioMixer(param, queue)", "按 queueForSource 选路")
d.node("g2", N, R2[1], 440, 52, "audioMixerThread() → audioMixer()", "21.33ms 一轮")
d.node("g3", N, R2[2], 440, 52, "deQueue(LocalCamera) 为节拍", "主源没数据就整轮 return", style="focal")
d.node("g4", N, R2[3], 440, 52, "mix(mic, others, n, out, size, coef)", "归一化叠加 · mic 音量不变")
for a, b in (("g1", "g2"), ("g2", "g3"), ("g3", "g4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("f3", "g1", fs="r", ts="l", route="hvh", gut=B2X[2] - 34, label="路 1")
d.edge("f4", "g1", fs="r", ts="l", route="hvh", gut=B2X[2] - 20, toff=14, label="路 2")
d.annot(N, A2Y, [
    "activeSources 是标志位（按位启停），kTVUOverlayMixerQueueCount = 3 是数组尺寸 —— 两回事",
    "辅源块长必须等于主源：mix() 按主源长度逐样本读，短了就越界读 —— 不一致宁可跳过该路",
    "mic 连续 1 秒无数据才丢辅源队列：空队列是常态（朗读间隙），不能当判据",
])

# ---- ⑧ 出口
N = B2X[3] + 40
d.node("h1", N, R2[1], 400, 52, "param.external_source_index", "取自主源，不是辅源", style="focal")
d.node("h2", N, R2[2], 400, 52, "[TVUAudioEncoderManager encode:]", "→ M5", style="sink")
d.edge("h1", "h2", fs="b", ts="t")
d.edge("g4", "h1", fs="r", ts="l", route="hvh", gut=B2X[3] - 34)
d.annot(N, A2Y, [
    "为什么 index 必须取主源：编码器按 index 整块丢弃。",
    "DJI 接管期间只收 200，带辅源 index(−1) 的混出帧会被整块丢掉。",
    "主源是本地 mic(−1) 时结果与取辅源相同，所以对既有场景是恒等变换",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "条件判断"),
    ("box", "focal", "关键取舍"), ("box", "drop", "拆除"), ("box", "sink", "出口"),
    ("line", "solid", "同线程调用"), ("line", "dash", "约束 / 复检"),
]

cards = [
    card("画面注入的两条互斥路径", "coral", "逐层叠加 vs 整帧替换",
         ["常规 overlay：每个 node 的位图按 <code>abs(streamType)+abs(streamSubType)</code> 叠到 NV12",
          "内置全屏模板：只查 <code>snapNodes.lastObject</code>，命中就整帧替换，跳过与相机帧的合成",
          "后台推流时常规 overlay 刻意不合成 —— 保持编码帧干净，PiP 拿到同一帧",
          "分辨率降到 480 / 576 会把已启用的 overlay 整体拆掉"]),
    card("声音注入：一份 PCM 两个去处", "ink", "主播和观众听同一份",
         ["<code>writeUtterance:toBufferCallback:</code> 取 PCM，本地播一份、推流一份",
          "不存在「合成两遍时间对不齐」",
          "mix 关闭时也走同一条 speaker 实现，实测比 <code>speakUtterance:</code> 省约 2.4 个百分点 CPU",
          "顺带好处：停顿只有一套语义（静音帧，sample-accurate）"]),
    card("混音器最容易踩的两点", "muted", "空队列是常态",
         ["辅源块长必须等于主源 —— <code>mix()</code> 按主源长度逐样本读，短了越界",
          "判「采集停了」不能看队列空，要看 <strong>mic 连续 1 秒无新数据</strong>",
          "混出帧的 <code>external_source_index</code> 必须取主源，否则被编码器整块丢弃",
          "<code>activeSources</code>（标志位）和 <code>kTVUOverlayMixerQueueCount</code>（数组尺寸）是两回事"]),
]

write(OUT, d, "Call graph · 方法级 M7", "Overlay 注入双路 — 一个方法一个盒子",
      "上带是画面注入（三类源 → GPU 水印合成 / 整帧替换），下带是声音注入"
      "（JS 抓 Web Audio、弹幕朗读 → 三路混音器）。两条路径除了共用一个开关，实现上毫无关系。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ bc4021368 · 2026-08-24 · Diagram Design 2.6.1")
