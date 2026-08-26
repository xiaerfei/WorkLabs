import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AUDIO-3-会议音频双向.html")

GW = [540, 550, 550, 550]
GX, TOTW = lanes(GW, gap=68, x0=80)
NH = 52
R1 = [128 + i * 70 for i in range(5)]
R2 = [680 + i * 70 for i in range(7)]
G1T, G1H, A1Y = 108, 470, 480
G2T, G2H, A2Y = 660, 680, 1210

d = Diagram(TOTW, 1420, "audio3",
            "会议音频双向 · 方法级调用图",
            "三套会议系统（Agora Partyline / WebRTC VOIP / RTIL VoIP）共用同一个 AgoraRtcEngineKit，"
            "只靠 trackId 区分。上行从采集回调分三路走；下行拉到的 2048 字节单声道块既进播放队列，"
            "也进两个二次混音队列，由 encode: 拉取混进推流 PCM。")

d.group("① 上行 · 采集出口三分叉", GX[0], G1T, GW[0], G1H)
d.group("② 上行 · WebRTC / RTIL", GX[1], G1T, GW[1], G1H)
d.group("③ 上行 · Agora Partyline", GX[2], G1T, GW[2], G1H)
d.group("④ 下行 · 拉流与重采样", GX[0], G2T, GW[0], G2H)
d.group("⑤ 下行 · 播放队列 + 混音队列填充", GX[1], G2T, GW[1], G2H)
d.group("⑥ 下行 · 出声（两套后端互斥）", GX[2], G2T, GW[2], G2H)
d.group("⑦ 二次混音：混进推流 PCM", GX[3], G2T, GW[3], G2H)

# ---------------- 上行 ----------------
N = GX[0] + 30
d.node("a1", N, R1[0], 480, NH, "RecordCallback(…)", "TVURecorder.mm:373〔AURemoteIO 实时线程〕", style="focal")
d.node("a2", N, R1[1], 480, NH, "-pushWebRTCAudioData:dataSize:timestamp:", ":546 · voipIsCalling；排除 Partyline/Lite 编译")
d.node("a3", N, R1[2], 480, NH, "-[TVURTILVoIPManager pushAudioData:…]", ":555 · 仅主 App（TVUOnlyAnyWhere）")
d.node("a4", N, R1[4], 480, NH, "-sendToEncoderWithAudioData:…", ":615 · 主链，最终到 encode:")
for x, y in (("a1","a2"),("a2","a3"),("a3","a4")): d.edge(x, y, fs="b", ts="t")
d.annot(N, A1Y, [
    "三路是并列旁路，不是互斥分支 —— 同一块 PCM 可以同时喂 WebRTC、RTIL 和推流。",
    "两条会议旁路都在 isSendAuidoToEncoder 之前，所以「音频不进推流」时会议侧照常有声。",
    "AudioQueue 侧同构：inputBufferHandler :783 RTIL / :794 WebRTC / :842 编码器。",
])

N = GX[1] + 30
d.node("b1", N, R1[0], 490, NH, "-resampleToWebRTCAudioData:andSize:andNowTime:", ":2507 · 仅采集率 != webRTCSampleRateSDP", style="cond")
d.node("b2", N, R1[1], 490, NH, "subcontractWithInBuffer:…andMBytesPerFrame:2", ":2569 · 切成 2048B 单声道块")
d.node("b3", N, R1[2], 490, NH, "-[TVUWebRTCManager tvuWriteAudiodataToWebRTC:…]", ":2572 · 率相同则双声道取左声道降 mono")
d.node("b4", N, R1[3], 490, NH, "-[RTCPeerConnection acceptRecodedAudioData:…]", "WebRTCManager.mm:755〔kSerialQueueTag〕", style="sink")
for x, y in (("b1","b2"),("b2","b3"),("b3","b4")): d.edge(x, y, fs="b", ts="t")
d.edge("a2", "b1", fs="r", ts="l", route="hvh", gut=GX[1] - 34)
d.annot(N, A1Y, [
    "RTIL 上行另一条：TVURTILVoIPManager.mm:120 → TVURTILVoIPEngine.mm:153",
    "→ pushExternalAudioFrameRawData:samples:sampleRate:channels:trackId:timestamp:",
    "samples = dataSize/2（总数）· 率与声道原样透传 · timestamp 单位【秒】。",
    "⚠️ 与 Agora 那条走同一个 API 但 timestamp 单位不同，未找到补偿代码。",
])

N = GX[2] + 30
d.node("c1", N, R1[0], 490, NH, "-[TVUAudioEncoderManager encode:]", "AudioEncoderManager.mm:92 · Partyline 上行在这里分叉", style="focal")
d.node("c2", N, R1[1], 490, NH, "isJoined && index 匹配 ?", ":189 / :205 · index 守门【之前】就分叉", style="cond")
d.node("c3", N, R1[2], 490, NH, "pushAudioData:andSampes:andTimestamp:", ":237 · andSampes = size / (2 × channel)")
d.node("c4", N, R1[3], 490, NH, "pushExternalAudioFrameRawData(… 48000, 2 …)", "IntegrateAgoraTools.mm:2035 · 内部 samples×2", style="sink")
for x, y in (("c1","c2"),("c2","c3"),("c3","c4")): d.edge(x, y, fs="b", ts="t")
d.edge("a4", "c1", fs="r", ts="l", route="hvh", gut=GX[2] - 34)
d.annot(N, A1Y, [
    "分叉点在 index 守门之前 —— 所以 partyline 里听到的源，可能与推到云端的不是同一路。",
    "timestamp 经 convertToUTCTimestampWithSystemPTS 换成【UTC 毫秒】（HostTimer.mm:29）。",
    "主 App 的 Partyline 上行走这条；aacEncoder.mm:211/:341 那两处只在 _TVUSDKPartyline 编译。",
])

# ---------------- 下行 ----------------
N = GX[0] + 30
d.node("d1", N, R2[0], 480, NH, "rtcResample()", "AudioPlayer.mm:1068〔rtcResample 线程〕", style="focal")
d.node("d2", N, R2[1], 480, NH, "四道早退：水位 / 流类型 / 通话中 / playout", ":1070-1090", style="cond")
d.node("d3", N, R2[2], 480, NH, "getPlayoutAudioByBufferRef:size:2048", ":1095 · WebRTC 下行")
d.node("d4", N, R2[3], 480, NH, "preferenceSampleRate != 48000 ?", ":1103 · 是则建 TVUFFmpegResample", style="cond")
d.node("d5", N, R2[4], 480, NH, "pullPlaybackAudioFrameRawData:lengthInByte:", "IntegrateAgoraTools.mm:2081 · Agora 下行")
d.node("d6", N, R2[5], 480, NH, "enableExternalAudioSink:YES 48000 / 1ch", ":494 · 全仓唯一调用点，在进会路径里", style="ext")
for x, y in (("d1","d2"),("d2","d3"),("d3","d4")): d.edge(x, y, fs="b", ts="t")
d.edge("d5", "d6", fs="b", ts="t", style="dash")
d.annot(N, A2Y, [
    "下行块规格全程一致：2048 字节 / 单声道 / 48000（≈21.33ms）。",
    "⚠️ preferenceSampleRate 实际是 AVAudioSession.sampleRate（采集侧硬件率），",
    "用它判断 WebRTC playout 要不要重采样，前提是否成立未确认。",
    "⚠️ RTIL 单独运行、本进程从未进过 Partyline 时，sink 是否已启用需实测。",
])

N = GX[1] + 30
d.node("e1", N, R2[0], 490, NH, "TVUAudioPlayerQueueManager::addData", ":1146 / :1158 · 8 节点池，池空丢新帧", style="queue")
d.node("e2", N, R2[1], 490, NH, "TVUWebRTCMixQueueManager::addData", ":1151 / :1166 · enableEncoding && enableMixVoip", style="queue")
d.node("e3", N, R2[2], 490, NH, "TVUPartyLineMixQueueManager::addData", ":903 / :1249 · (Joined || RTIL 在跑) && enableMixPartyLine", style="queue")
d.node("e4", N, R2[3], 490, NH, "mix(agora_data, voip_data, 2048, coef)", ":906 · 播放侧动态 ducking")
d.node("e5", N, R2[4], 490, NH, "pcmCacheData 重打包", ":935-952 · AudioUnit 侧块长不固定，靠它对齐")
for x, y in (("e1","e2"),("e2","e3"),("e3","e4"),("e4","e5")): d.edge(x, y, fs="b", ts="t", style="dash")
d.edge("d4", "e1", fs="r", ts="l", route="hvh", gut=GX[1] - 34)
d.annot(N, A2Y, [
    "混音队列节点是 2048B 单声道，被 encode: 消费时才 monoConvertToStereo 成 4096B。",
    "播放器全程单声道（AudioQueue ASBD :483 / AudioUnit ASBD TVURecorder.mm:2691），",
    "这就是混音前必须升声道的原因。",
    "⚠️ TVUAudioPlayerQueueManager.mm:54 在 size<=0 时节点不归还不释放，8 节点池会被耗尽。",
])

N = GX[2] + 30
d.node("f1", N, R2[0], 490, NH, "audioUnitPlayCallBack", "TVURecorder.mm:640 · 与采集同一个 audio unit", style="focal")
d.node("f2", N, R2[3], 490, NH, "AudioPlayer::audioUnitPlayWithBufferList", ":562 · 按流类型三分支")
d.node("f3", N, R2[5], 490, NH, "…ForAgora / ForVoip / ForIFB", ":817 / :579 / :696")
d.node("f4", N, R2[6], 490, NH, "AudioPlayer::handleOutputBuffer", ":1382 · AudioQueue 后端；AU 在跑则填静音 return（:1389）", style="drop")
d.edge("f1", "f2", fs="b", ts="t")
d.edge("f2", "f3", fs="b", ts="t")
d.edge("f3", "f4", fs="b", ts="t", style="dash", label="另一后端")
d.edge("e5", "f1", fs="r", ts="l", route="hvh", gut=GX[2] - 34)
d.annot(N, A2Y, [
    "后端选择：TVURecorder.mm:2049 按 _realization 写 setAudioPlayerType。",
    "AudioPlayer 管六件事：IFB(AMR 8k) · VFB · WebRTC 下行",
    "· Agora 下行 · mix() 工具 · caculate_bm_db 工具。",
    "caculate_bm_db 是给采集侧 VU 表用的；播放器自己那条",
    "caculateVolumeDB 两个调用点都被注释，getLVolDB 恒返回 −40。",
    "外部源预览播放不走这里 —— 全仓无外部源入口进 AudioPlayer。",
])

N = GX[3] + 30
d.node("g1", N, R2[0], 490, NH, "enableMixPartyLine && Joined ?", "AudioEncoderManager.mm:286", style="cond")
d.node("g2", N, R2[1], 490, NH, "partyLineMixWith(data, size, &out, &n)", ":289 · Partyline 优先")
d.node("g3", N, R2[2], 490, NH, "else if enableMixVoip && voipIsCalling", ":297 → voipMixWith :300", style="cond")
d.node("g4", N, R2[3], 490, NH, "else if enableMixVoip && RTIL 在跑", ":306 → partyLineMixWith :310 · 实测轮不到", style="drop")
d.node("g5", N, R2[4], 490, NH, "memcpy(param->data, data_mix, size)", ":291 / :302 / :312 · 就地覆盖后 free")
for x, y in (("g1","g2"),("g2","g3"),("g3","g4"),("g4","g5")): d.edge(x, y, fs="b", ts="t")
d.edge("e2", "g1", fs="r", ts="l", route="hvh", gut=GX[3] - 34)
d.edge("e3", "g1", fs="r", ts="l", route="hvh", gut=GX[3] - 48)
d.annot(N, A2Y, [
    "三选一是 if / else if / else if —— g4 那支被 g3 抢先，永远轮不到。",
    "后果：RTIL 与 WebRTC 同时在跑时，PartyLine 混音队列只进不出，",
    "涨到 10 个后 addData 开始丢帧刷 log。清空只有首帧/not-ready 两处被动时机。",
    "非主 App 的 flavor 走 :275-284，只认 enableMixVoip，从不读 enableMixPartyLine。",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "闸门 / 分支"),
    ("box", "focal", "线程入口 / 分叉点"), ("box", "queue", "队列填充"),
    ("box", "ext", "SDK 配置"), ("box", "drop", "轮不到 / 静音"), ("box", "sink", "交给 SDK"),
    ("line", "solid", "同线程调用"), ("line", "dash", "并列 / 另一后端"),
]

cards = [
    card("一个 API 两种时间单位", "coral", "Agora 毫秒，RTIL 秒",
         ["Partyline：<code>convertToUTCTimestampWithSystemPTS</code> → <strong>UTC 毫秒</strong>",
          "RTIL VoIP：<code>nowTime</code> 原样透传 → <strong>秒</strong>，不经任何换算",
          "两条都调同一个 <code>pushExternalAudioFrameRawData:…timestamp:</code>",
          "共用同一个 <code>AgoraRtcEngineKit</code>，只靠 trackId 区分；未找到补偿代码"]),
    card("RTIL 那支混音永远轮不到", "ink", "else if 被抢先",
         ["<code>:297</code> 的 <code>voipMixWith</code> 先命中，<code>:306</code> 的 RTIL 分支是 <code>else if</code>",
          "生产侧两家<strong>会</strong>同时塞（RTIL 在跑 + WebRTC 通话 + 两开关都开）",
          "结果 PartyLine 混音队列只进不出，10 个后开始丢帧刷 log",
          "同类问题在非主 App flavor 上更直接：照塞队列但 <code>:275-284</code> 永远不消费"]),
    card("下行块规格是硬契约", "muted", "2048B / 单声道 / 48000",
         ["<code>enableExternalAudioSink:YES sampleRate:48000 channels:1</code>（<code>:494</code>）",
          "播放队列消费侧强校验 <code>node-&gt;size == 2048</code>",
          "混音队列节点也是 2048 单声道，被 <code>encode:</code> 消费时才升成 4096 双声道",
          "<code>mix()</code> 的动态增益 <code>f</code> 是局部变量每次重置 → 块边界有增益跳变"]),
]

write(OUT, d, "Call graph · 音频 A3", "会议音频双向 — 上行带 + 下行带",
      "上带是三路上行，下带是下行拉流、播放与二次混音。橙色是线程入口与分叉点；"
      "灰虚框是轮不到或被静音的路径。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ 736863f1f · 2026-08-25 · Diagram Design 2.6.1")
