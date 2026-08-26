import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AUDIO-2-屏幕录制音频.html")

GW = [530, 540, 540, 540]
GX, TOTW = lanes(GW, gap=68, x0=80)
NH = 52
R1 = [128 + i * 70 for i in range(5)]
R2 = [660 + i * 70 for i in range(7)]
G1T, G1H, A1Y = 108, 400, 400
G2T, G2H, A2Y = 640, 610, 1190

d = Diagram(TOTW, 1330, "audio2",
            "屏幕录制音频 · 方法级调用图",
            "屏共音频是跨进程设计：Broadcast Upload Extension 抓 App 音频经 Peertalk 送主 App，"
            "而 Mic 音频那条扩展进程路径收发两侧都已注释掉，实际由主 App 本地采集链改道进 mic 队列。"
            "两路在 screenRecordingAudioThread 上按 25ms 门限对齐后混音，index 恒为 100。")

d.group("① 扩展进程 · ReplayKit 回调", GX[0], G1T, GW[0], G1H)
d.group("② 扩展进程 · 三路队列（Mic 那条已注释）", GX[1], G1T, GW[1], G1H)
d.group("③ 扩展进程 · 格式归一 + 发帧", GX[2], G1T, GW[2], G1H)
d.group("④ 主 App · 收帧与三个 case", GX[0], G2T, GW[0], G2H)
d.group("⑤ 主 App · App 音频分包", GX[1], G2T, GW[1], G2H)
d.group("⑥ 主 App · Mic 队列的三家改道", GX[2], G2T, GW[2], G2H)
d.group("⑦ 主 App · 25ms 对齐 + 混音 + 出口", GX[3], G2T, GW[3], G2H)

# ---------------- 带 1 ----------------
N = GX[0] + 30
d.node("p1", N, R1[0], 470, NH, "SampleHandler::processSampleBuffer:withType:", "SampleHandler.m:42〔ReplayKit 回调线程〕", style="focal")
d.node("p2", N, R1[1], 470, NH, "闸门 isSocketConnect ?", ":43 · 否则 closeShareScreen", style="cond")
d.node("p3", N, R1[2], 470, NH, "闸门 音频停超 10s ?", ":49 · finishBroadcastWithError:", style="cond")
d.node("p4", N, R1[3], 470, NH, "刷新 last_audio_time_stamp", ":53-55 · type != Video 时")
for x, y in (("p1","p2"),("p2","p3"),("p3","p4")): d.edge(x, y, fs="b", ts="t")
d.annot(N, A1Y, [
    "扩展进程 target = TVUScreenRecording（app-extension），已用 plutil 核 pbxproj。",
    "Sources：SampleHandler.m · TVUScreenRecordingClientSocketManager.mm",
    "· TVUExtendRecordingQueueMananger.mm · TVUFFmpegResample.mm · TVULocalPushManager.m",
])

N = GX[1] + 30
d.node("q1", N, R1[0], 480, NH, "-sendSampleBuffer:withType:", "Client.mm:96 · 校验 channel 与 DataIsReady")
d.node("q2", N, R1[1], 480, NH, "Video → 入队 TVUEXRecordingVideo", ":113 · 帧间隔 ≥ 30ms 才收", style="queue")
d.node("q3", N, R1[2], 480, NH, "AudioApp → 入队 TVUEXRecordingAudioApp", ":119 · 无条件", style="queue")
d.node("q4", N, R1[3], 480, NH, "AudioMic → 【已注释】", ":121-124 · 线程也没创建（ExtendQueue.mm:177）", style="drop")
d.edge("p4", "q1", fs="r", ts="l", route="hvh", gut=GX[1] - 34)
for x, y in (("q1","q2"),("q2","q3"),("q3","q4")): d.edge(x, y, fs="b", ts="t")
d.annot(N, A1Y, [
    "free 池：video 5 / audioApp 10 / audioMic 10（ExtendQueue.mm:11-12）。",
    "线程 EXRecordingVideoThread 与 EXRecordingAudioAPPThread 各一条；",
    "EXRecordingAudioThread 在本基线里不存在。",
])

N = GX[2] + 30
d.node("r1", N, R1[0], 480, NH, "-sendAudioSampleBuffer:frameType:", "Client.mm:256〔EXRecordingAudioAPPThread〕")
d.node("r2", N, R1[1], 480, NH, "float → int16 / BE → LE", ":306 / :317 · 按 ASBD flags 条件转")
d.node("r3", N, R1[2], 480, NH, "TVUFFmpegResample → 48000 / 1ch / S16", ":334-349 · 长度受 swr_get_delay 影响可变", style="focal")
d.node("r4", N, R1[3], 480, NH, "[connectedChannel sendFrameOfType:102]", ":358 · Peertalk 127.0.0.1:2345", style="sink")
d.edge("q3", "r1", fs="r", ts="l", route="hvh", gut=GX[2] - 34)
for x, y in (("r1","r2"),("r2","r3"),("r3","r4")): d.edge(x, y, fs="b", ts="t")
d.annot(N, A1Y, [
    "48k 对齐是在扩展进程做的，主 App 侧那个 audioAppResample 已被注释停用。",
    "发出去的是单声道 —— 主 App 收到后才转双声道。",
    "⚠️ Peertalk 帧头字节序未确认（仓库只有预编译二进制，无 PTProtocol.m）。",
])

# ---------------- 带 2 ----------------
N = GX[0] + 30
d.node("s1", N, R2[0], 470, NH, "-ioFrameChannel:didReceiveFrameOfType:…", "ServerSocket.mm:96〔Peertalk 读线程〕", style="focal")
d.node("s2", N, R2[1], 470, NH, "dispatch_async(_processQueue)", ":104〔com.screenRecordingProcessQueue〕")
d.node("s3", N, R2[2], 470, NH, "-screenRecordingServerSocketReceiveFrame:…", "主 App MainViewController.mm:7582 ‖ IRL TVUIRLSDK.mm:378")
d.node("s4", N, R2[3], 470, NH, "frame->length = ntohl(frame->length)", ":7586 ‖ :382")
d.node("s5", N, R2[4], 470, NH, "case 102  断流检测 ≥ 0.3s ?", ":7620 · 是则 forceInsertKeyFrame（插视频 I 帧）", style="cond")
d.node("s6", N, R2[5], 470, NH, "case 103 AudioMic → 【空 / 全注释】", ":7682 ‖ :443 · Now use audioUnit to capture", style="drop")
for x, y in (("s1","s2"),("s2","s3"),("s3","s4"),("s4","s5"),("s5","s6")): d.edge(x, y, fs="b", ts="t")
d.edge("r4", "s1", fs="b", ts="t", style="cross", label="socket")
d.annot(N, A2Y, [
    "音频断流会触发视频插 I 帧 —— 跨模态耦合，不直觉但是刻意的。",
    "PTS 算法 2023-09-22 改过：不再累计采样点，每帧独立算，",
    "「出问题只会影响当前的音频帧」。",
])

N = GX[1] + 30
d.node("t1", N, R2[0], 480, NH, "闸门 mixType != MicAudioOnly ?", ":7632 · App 音频总闸", style="cond")
d.node("t2", N, R2[1], 480, NH, "monoConvertToStereoWithMonoAudio:", ":7668 · TVUAnywhereTool 版（写堆缓冲，会 realloc）")
d.node("t3", N, R2[2], 480, NH, "TVUScreenRecordPcmContractor::pushFrame", ":7677 · (stereo, len×2, pts×1000, 100)")
d.node("t4", N, R2[3], 480, NH, "TVUScreenRecordPcmContractor::doencode()", "PcmContractor.mm:137〔tvu_screen_record_pcm_separator〕", style="focal")
d.node("t5", N, R2[4], 480, NH, "闸门 size == capacity(4096) ?", ":161 · 否则只打日志丢弃", style="cond")
d.node("t6", N, R2[6], 480, NH, "→ addDataToScreenRecordingQueue[AudioApp]", ":171 · 4096B / 2ch / 48000", style="queue")
for x, y in (("t1","t2"),("t2","t3"),("t3","t4"),("t4","t5"),("t5","t6")): d.edge(x, y, fs="b", ts="t")
d.edge("s5", "t1", fs="r", ts="l", route="hvh", gut=GX[1] - 34)
d.annot(N, A2Y, [
    "分包器把可变长的单声道输入规整成恒定 4096 字节双声道块（21.333ms）。",
    "getShareScreenAudioMixType：1=只 Mic（拦 App）· 2=只屏共（拦 Mic）",
    "· 3/0/未设置=两路都混（默认）。",
])

N = GX[2] + 30
d.node("u1", N, R2[0], 480, NH, "aacEncoder.mm:139  tvuSendAudioToScreenShare", "调用方 sendFrameToEncoder :289-293（内置 mic）")
d.node("u2", N, R2[1], 480, NH, "TVUExtAudioEncoder.mm:144  同名 static 副本", "调用方 doencode() :236（Accsoon / 外部源）")
d.node("u3", N, R2[2], 480, NH, "RTMPIngestController.mm:47  同名 static 副本", "调用方 didReceiveAudioSampleBuffer: :388（DJI）")
d.node("u4", N, R2[3], 480, NH, "PcmContractor.mm:121  同名 static 副本", "本 TU 内无调用方 —— 死代码", style="drop")
d.node("u5", N, R2[4], 480, NH, "闸门 mixType == ShareScreenAudioOnly ?", "四份副本内一致 · Mic 音频总闸", style="cond")
d.node("u6", N, R2[5], 480, NH, "→ addDataToScreenRecordingQueue[AudioMic]", "队列内 adjustAudioGain 施加 Mute/增益（:267）", style="queue")
for x, y in (("u1","u2"),("u2","u3"),("u3","u4"),("u4","u5"),("u5","u6")): d.edge(x, y, fs="b", ts="t", style="dash")
d.annot(N, A2Y, [
    "tvuSendAudioToScreenShare 不是一个函数 —— 是同一份 static 函数体复制到 4 个 TU，彼此不可见。",
    "三家的注释都写明动机：编码器第一道闸门只收 index 100，直送会被整块丢，",
    "所以改道进 mic 队列，顺带吃到队列的 adjustAudioGain。",
    "只有 AudioMic 那一路加增益；App 路是 memcpy 原样（:270）。",
])

N = GX[3] + 30
d.node("v1", N, R2[0], 480, NH, "encodeAudio()", "QueueManager.mm:448〔screenRecordingAudioThread〕", style="focal")
d.node("v2", N, R2[1], 480, NH, "两路都空 → usleep(10ms)", ":458 · 音频侧无补帧、无补静音", style="drop")
d.node("v3", N, R2[2], 480, NH, "单路降级：断超 1s ?", ":464 · 取 mic 优先，否则 app；index=100", style="cond")
d.node("v4", N, R2[3], 480, NH, "25ms 对齐：丢领先那一路的队首", ":506 / :513 · |mic_pts − app_pts| ≥ 25ms", style="cond")
d.node("v5", N, R2[4], 480, NH, "mix(source, data_mix, micSize, coefficient)", ":536 · 用 mic 响度 duck 掉 App 音频", style="focal")
d.node("v6", N, R2[5], 480, NH, "-[TVUAudioEncoderManager encode:]", ":490（降级）/ :543（混音）· 全部 index=100", style="sink")
for x, y in (("v1","v2"),("v2","v3"),("v3","v4"),("v4","v5"),("v5","v6")): d.edge(x, y, fs="b", ts="t")
d.edge("t6", "v1", fs="r", ts="l", route="hvh", gut=GX[3] - 34)
d.edge("u6", "v1", fs="r", ts="l", route="hvh", gut=GX[3] - 48)
d.annot(N, A2Y, [
    "coefficient = tvuGetVolumeScale(getPcmDB(mic)) = 1 − db×0.015，查表 [0.10, 1.00]。",
    "mix() 里 mic 系数恒 1.0、app 乘 coefficient —— 语义是动态 ducking。",
    "输出块的 size / channel / sampleRate / pts 全部取 mic 节点（:538-541）。",
    "⚠️ data_mix 只按首帧 malloc 一次（:532），可变块长会越界写。",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "闸门 / 分支"),
    ("box", "focal", "线程入口 / 关键处理"), ("box", "queue", "入队"),
    ("box", "drop", "死代码 / 丢弃"), ("box", "sink", "出口"),
    ("line", "solid", "同线程调用"), ("line", "dash", "并列副本 / 否分支"), ("line", "cross", "跨进程"),
]

cards = [
    card("Mic 那条扩展进程路径是死的", "coral", "收发两侧都注释掉了",
         ["发送侧 <code>Client.mm:121-124</code> 入队调用注释；线程创建 <code>ExtendQueue.mm:177</code> 也注释",
          "接收侧主 App <code>MainViewController.mm:7682-7725</code> 整段注释；IRL <code>TVUIRLSDK.mm:443-447</code> 是空 case",
          "原因写在 <code>:7684</code>：<code>Now use audioUnit to capture</code>",
          "屏共的 Mic 声实际来自主 App 本地采集链，经四份 static 副本之一改道进来"]),
    card("三家共用同一条改道", "ink", "因为编码器只收 index 100",
         ["<code>encode:</code> 第一道闸门：<code>isReceivingFrame && index != 100 → return</code>",
          "mic / Accsoon / DJI 直送都会被整块丢，所以全部改道进 mic 队列",
          "顺带吃到队列的 <code>adjustAudioGain</code>，所以三家都<strong>不预先施加增益</strong>",
          "App 路不加增益（<code>memcpy</code> 原样）"]),
    card("25ms 门限只管音频两路之间", "muted", "与视频无关",
         ["<code>tvu_filter_pts_offset = 25</code>，超门限就丢领先那一路的队首",
          "<code>last_audio_mix_time</code> 只在双路混音成功时刷新",
          "<code>getCurrentNodePts()</code> 空队列返回 −1，任一为 −1 整段跳过",
          "⚠️ mic 与视频之间代码里没有任何 pts 重锚"]),
]

write(OUT, d, "Call graph · 音频 A2", "屏幕录制音频 — 跨进程两带",
      "上带是 Broadcast Upload Extension，下带是主 App。蓝线是跨进程交接；"
      "灰虚框是已注释或不可达的代码路径。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ 736863f1f · 2026-08-25 · Diagram Design 2.6.1")
