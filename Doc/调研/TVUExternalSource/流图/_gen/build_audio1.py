import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AUDIO-1-本地麦克风采集.html")

GW = [500, 520, 500, 510, 520]
GX, TOTW = lanes(GW, gap=68, x0=80)
NH = 52
RY = [128 + i * 70 for i in range(8)]
GT, GH, AY = 108, 690, 690

d = Diagram(TOTW, 900, "audio1",
            "本地麦克风采集 · 方法级调用图",
            "TVURecorder 有 AudioUnit(VPIO/RemoteIO) 与 AudioQueue 两套采集实现，回调里依次过 9 道闸门、"
            "两处静音抹零、增益施加与两条会议上行旁路，再经重采样与定长分包，最后由 "
            "aacEncoder::sendFrameToEncoder 做四路分流。")

d.group("① 启动：两套实现二选一", GX[0], GT, GW[0], GH)
d.group("② 采集回调（实时线程）· 前段", GX[1], GT, GW[1], GH)
d.group("③ 会议上行旁路 + 闸门后段", GX[2], GT, GW[2], GH)
d.group("④ 重采样 + 定长分包", GX[3], GT, GW[3], GH)
d.group("⑤ sendFrameToEncoder 四路分流", GX[4], GT, GW[4], GH)

# ① 启动
N = GX[0] + 30
d.node("a1", N, RY[0], 440, NH, "-startRecorder", "TVURecorder.mm:1281〔com.tvu.audio.capture〕", style="focal")
d.node("a2", N, RY[1], 440, NH, "-startAudioUnitRecorder", ":1603 · realization == AudioUnit")
d.node("a3", N, RY[2], 440, NH, "-initAudioComponent", ":1884 · subType 按 flavor 选 VPIO / RemoteIO")
d.node("a4", N, RY[3], 440, NH, "-setUpRecoderWithFormatID:", ":1032 · 蓝牙→16k，否则 48k")
d.node("a5", N, RY[4], 440, NH, "-getCurrentAuidoChannel", ":2704 · 立体声有线/USB → 2，否则 1")
d.node("a6", N, RY[5], 440, NH, "AudioUnitInitialize / OutputUnitStart", ":1637 / :1644")
d.node("a7", N, RY[6], 440, NH, "-startAudioQueueRecorder", ":1450 · realization == AudioQueue", style="cond")
d.node("a8", N, RY[7], 440, NH, "AudioQueueNewInput / AllocateBuffer ×3", ":1488 / :1509 · 2048 × channel")
for x, y in (("a1","a2"),("a2","a3"),("a3","a4"),("a4","a5"),("a5","a6")):
    d.edge(x, y, fs="b", ts="t")
d.edge("a1", "a7", fs="l", ts="l", route="ring", gut=RY[7] + NH + 26, gut2=GX[0] + 12)
d.edge("a7", "a8", fs="b", ts="t")
d.annot(N, AY, [
    "AVAudioSession 期望值：setPreferredSampleRate:48000（:1618）",
    "setPreferredIOBufferDuration:1024/48000（:1626）→ 目标 1024 帧/回调，但不保证。",
    "SPAR-771：IRL 且非 VPIO 时先 restoreAudioSessionModeToDefaultIfNeeded（:1857）。",
])

# ② 回调前段
N = GX[1] + 30
d.node("b1", N, RY[0], 460, NH, "RecordCallback(…inNumberFrames…)", ":373〔AURemoteIO I/O 实时线程〕", style="focal")
d.node("b2", N, RY[1], 460, NH, "CMClockMakeHostTimeFromSystemUnits", ":392-407 · 取 host 时钟算 currentTime")
d.node("b3", N, RY[2], 460, NH, "G1  audioIsReady && videoIsReady ?", ":430 · 否则丢帧 + 清两个混音队列", style="cond")
d.node("b4", N, RY[3], 460, NH, "G2  frames×2×ch ≤ 10240 ?", ":448 · 仅 AudioUnit 侧", style="cond")
d.node("b5", N, RY[4], 460, NH, "AudioUnitRender(_audioUnit, …)", ":512 · G3 status != noErr 丢帧")
d.node("b6", N, RY[5], 460, NH, "G4  isSilenceCarAudioBuff(…)", ":184 · 恒返回 NO —— 死闸门，仅埋点", style="drop")
d.node("b7", N, RY[6], 460, NH, "-setCaptureGainWithSource:…", ":2632 · gain≠1.0 才做，逐 int16 × gain + 软限幅")
d.node("b8", N, RY[7], 460, NH, "inputBufferHandler(…)", ":697〔AudioQueue 内部线程〕同构，逐条对应", style="cond")
for x, y in (("b1","b2"),("b2","b3"),("b3","b4"),("b4","b5"),("b5","b6"),("b6","b7")):
    d.edge(x, y, fs="b", ts="t")
d.edge("a6", "b1", fs="r", ts="l", route="hvh", gut=GX[1] - 34)
d.edge("a8", "b8", fs="r", ts="l", route="hvh", gut=GX[1] - 48, style="dash")
d.annot(N, AY, [
    "PTS：currentTime = audio_base_time + (now_audio_pts − first_audio_pts)  〔秒〕",
    "current_frame_pts = currentTime × 1000  〔毫秒〕",
    "g_tvustartcaptureTime 不参与 mic PTS；g_vstarttime 在本链上只出现在日志里。",
    "⚠️ 实时线程上有 NSLock + pthread_mutex + malloc/realloc + NSMutableData。",
])

# ③ 旁路 + 后段
N = GX[2] + 30
d.node("c1", N, RY[0], 440, NH, "-pushWebRTCAudioData:dataSize:timestamp:", ":2357 · 旁路，voipIsCalling 才进", style="sink")
d.node("c2", N, RY[1], 440, NH, "-resampleToWebRTCAudioData:…", ":2507 · 率不同才走；切 2048B 后送 WebRTC", style="sink")
d.node("c3", N, RY[2], 440, NH, "-[TVURTILVoIPManager pushAudioData:…]", ":555 · 旁路，仅主 App(TVUOnlyAnyWhere)", style="sink")
d.node("c4", N, RY[3], 440, NH, "G5  +[TVURecorder isSendAuidoToEncoder]", ":580 → :1417 · DJI 接管 / 外部源接管时丢弃", style="cond")
d.node("c5", N, RY[4], 440, NH, "M1  getIsCloseAudioOnAgora → memset", ":593 · 抹零而非丢帧", style="drop")
d.node("c6", N, RY[5], 440, NH, "M2  appVoiceState==_Slience → memset", ":598 · AU 侧还含 isAccsoonWithBuildIn", style="drop")
d.node("c7", N, RY[6], 440, NH, "G6  filterInvalidAudioSample(currentTime)", ":882 · 回退或跳 >5s 丢帧；连 10 次重锚", style="cond")
for x, y in (("c1","c2"),("c2","c3"),("c3","c4"),("c4","c5"),("c5","c6"),("c6","c7")):
    d.edge(x, y, fs="b", ts="t")
d.edge("b7", "c1", fs="r", ts="l", route="hvh", gut=GX[2] - 34)
d.annot(N, AY, [
    "两条会议上行旁路都在 G5 之前 —— 即使音频不进推流，会议侧照常有声。",
    "M1 / M2 是 memset 抹零而不是 return：刻意保一条静音音轨，",
    "让 mux 侧的音视频交错不被卡住。",
    "G5 的 AudioUnit 侧比 AudioQueue 侧多一条 !isAccsoonWithBuildIn 例外。",
])

# ④ 重采样 + 分包
N = GX[3] + 30
d.node("d1", N, RY[0], 450, NH, "-sendNeedResampleAudioData:…", ":2236 · 仅 samplerate != 48000（蓝牙）", style="cond")
d.node("d2", N, RY[1], 450, NH, "-getResampleDicWithInputSampleRate:…", ":2070 · dst 固定 1 声道")
d.node("d3", N, RY[2], 450, NH, "[TVUFFmpegResample convertor_feed_data:…]", "Resample.mm:208 · swr_convert")
d.node("d4", N, RY[3], 450, NH, "-sendToEncoderWithAudioData:…", ":2309 · 48k 直入 / 重采样后回流到这里", style="focal")
d.node("d5", N, RY[4], 450, NH, "G9  pcmCacheData.length ≥ needPcmSize ?", ":2335 · 不丢，攒着；needPcmSize = 2048 × ch", style="cond")
d.node("d6", N, RY[5], 450, NH, "correct_pts 回推与递推", ":2334 / :2350 · 按缓存剩余样本补偿")
d.node("d7", N, RY[6], 450, NH, "aacEncoder::sendFrameToEncoder(…)", "aacEncoder.mm:278 · mic 的唯一出口", style="focal")
for x, y in (("d1","d2"),("d2","d3"),("d4","d5"),("d5","d6"),("d6","d7")):
    d.edge(x, y, fs="b", ts="t")
d.edge("d3", "d4", fs="b", ts="t", style="dash", label="回流")
d.edge("c7", "d1", fs="r", ts="l", route="hvh", gut=GX[3] - 34, label="非 48k")
d.edge("c7", "d4", fs="r", ts="l", route="hvh", gut=GX[3] - 48, label="48k")
d.annot(N, AY, [
    "needPcmSize = kTVURecoderPCMMaxBuffSize(2048) × channel —— 两种声道都恰好 1024 帧。",
    "remain_pts = 缓存样本数 × 1000 / samplerate；need_pcm_pts = 1024 × 1000 / samplerate",
    "48k 下 need_pcm_pts 整数截断成 21（真值 21.333），但每回调用新 host 时钟重锚，不累积。",
    "⚠️ aacEncoder 的 PCM 环形池整套是死代码，pushFrame 系全部走不通。",
])

# ⑤ 四路分流
N = GX[4] + 30
d.node("e1", N, RY[0], 460, NH, "isReceivingFrame ?", "aacEncoder.mm:288 · 屏共优先", style="cond")
d.node("e2", N, RY[1], 460, NH, "tvuSendAudioToScreenShare(…)", ":139（本 TU 副本）→ 屏共 mic 队列", style="sink")
d.node("e3", N, RY[2], 460, NH, "shouldOutputAudioStream ?", ":297 · 朗读/Overlay 要混（仅 IRL）", style="cond")
d.node("e4", N, RY[3], 460, NH, "Overlay 混音器 addDataToAudioMixer", ":304 · sourceQueue[0] 当主源", style="sink")
d.node("e5", N, RY[4], 460, NH, "streamType ∈ PIP / PBP / 替换背景 ?", ":308", style="cond")
d.node("e6", N, RY[5], 460, NH, "外部源混音器 addDataToAudioMixer", ":317 · sourceQueue[0]", style="sink")
d.node("e7", N, RY[6], 460, NH, "-[TVUAudioEncoderManager encode:]", ":319 · 直送，单源直播常态", style="focal")
d.edge("e1", "e2", fs="b", ts="t", label="是")
d.edge("e2", "e3", fs="b", ts="t", style="dash", label="否")
d.edge("e3", "e4", fs="b", ts="t", label="是")
d.edge("e4", "e5", fs="b", ts="t", style="dash", label="否")
d.edge("e5", "e6", fs="b", ts="t", label="是")
d.edge("e6", "e7", fs="b", ts="t", style="dash", label="否")
d.edge("d7", "e1", fs="r", ts="l", route="hvh", gut=GX[4] - 34)
d.annot(N, AY, [
    "四路是 if / else if / else，严格互斥。单声道块在进 Overlay / 外部源",
    "混音器和屏共队列前都会先 convertToStereo（:290 / :299 / :312）。",
    "Partyline SDK 编译时这一整块换成 tvuPushAudioData: 直推 Agora（:324-344）。",
    "同一套阶梯在 Accsoon 与 DJI 侧各抄了一遍，见 AUDIO-5。",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "闸门 / 分支"),
    ("box", "focal", "入口 / 汇聚"), ("box", "drop", "死闸门 / 抹零"), ("box", "sink", "旁路出口"),
    ("line", "solid", "同线程调用"), ("line", "dash", "另一实现 / 否分支"),
]

cards = [
    card("mic 的唯一出口", "coral", "环形池是死代码",
         ["<code>aacEncoder::startEncode()</code> 函数体连 <code>pthread_create</code> 一起被注释（<code>:87-98</code>）",
          "<code>tvu_mic_pcm_separator</code> 线程从不启动，<code>__state</code> 恒为 <code>AAC_ENCODE_STATE_SET</code>",
          "<code>pushFrame</code> / <code>pushOnechannelFrame</code> 必然早退 −1；5 个调用点也全被注释",
          "连带 <code>doencode()</code> 里的 <code>encode:</code> 与 <code>stopEncoder</code> 都不可达"]),
    card("9 道闸门里有一道是死的", "ink", "G4 恒返回 NO",
         ["<code>isSilenceCarAudioBuff()</code>（<code>:184</code>）的 <code>return YES</code> 在 <code>:262</code> 被注释",
          "现在只做埋点，不再丢帧",
          "⚠️ 若恢复，AudioQueue 侧（<code>:757</code>）会漏归还 buffer",
          "G9 是唯一“不丢、攒着”的闸门"]),
    card("两处 memset 而非丢帧", "muted", "刻意保静音音轨",
         ["M1 <code>getIsCloseAudioOnAgora</code>、M2 <code>appVoiceState==_Slience</code>",
          "抹零而不 return，让 mux 侧音视频交错不被卡住",
          "<code>isLiveWithBulidInAudioStream</code> 的目的同样是保静音轨，不是“换用手机麦”",
          "两条会议上行旁路都在 G5 之前，不进推流也照常有声"]),
]

write(OUT, d, "Call graph · 音频 A1", "本地麦克风采集 — 一个方法一个盒子",
      "两套采集实现（AudioUnit / AudioQueue）逐条对应；橙色是入口、汇聚与 mic 的唯一出口。"
      "虚线是另一套实现或“否”分支。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ 736863f1f · 2026-08-25 · Diagram Design 2.6.1")
