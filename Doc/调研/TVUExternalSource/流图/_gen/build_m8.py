import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "M8-后台推流补帧与PiP.html")

GW = [500, 480, 520, 500]
GX, TOTW = lanes(GW, gap=68, x0=80)
RY = [128 + i * 68 for i in range(5)]
GT, GH, AY = 108, 424, 472
R2 = [588 + i * 68 for i in range(3)]
G2T, G2H, A2Y = 560, 320, 792

d = Diagram(TOTW, 940, "m8",
            "后台推流补帧与画中画 · 方法级调用图",
            "编码器实际拿到的那一帧被喂给统一喂点，同时驱动画中画窗口与补帧器。"
            "Plan A 靠 multitasking camera access 权限让相机在后台继续出帧；"
            "相机冻帧后补帧器自动接手，把最后一帧高斯模糊后按降档帧率持续重发，"
            "合成的待机帧带标记回灌编码器且不会二次进入喂点。")

d.group("① 统一喂点（在 sendToEncoder 内）", GX[0], GT, GW[0], GH)
d.group("② TVUBackgroundStreamingManager   状态与闸门", GX[1], GT, GW[1], GH)
d.group("③ TVUVideoGapFiller   补帧器", GX[2], GT, GW[2], GH)
d.group("④ 回灌编码器", GX[3], GT, GW[3], GH)
d.group("⑤ 画中画窗口（第二带）", GX[1], G2T, GW[1] + GW[2] + 68, G2H)

# ①
N = GX[0] + 40
d.node("a1", N, RY[0], 420, 52, "sendToEncoderWithSamplebuffer(…)", "M4 的最后一步")
d.node("a2", N, RY[1], 420, 52, "CMGetAttachment(sb, …SynthesizedFrameKey)", "查是不是补帧器自己合成的", style="cond")
d.node("a3", N, RY[2], 420, 52, "-enqueueCameraSampleBuffer:", "喂的就是编码器实际拿到的那一帧", style="focal")
d.node("a4", N, RY[3], 420, 52, "[[TVUVideoEncoderManager manager] encode:…]", "主链继续往下走", style="sink")
d.edge("a1", "a2", fs="b", ts="t")
d.edge("a2", "a3", fs="b", ts="t", label="不是")
d.edge("a3", "a4", fs="b", ts="t")
d.annot(N, AY, [
    "查这个 key 是为了防模糊叠加：补帧器合成的帧会回灌到这里，",
    "再进一次喂点就会重置「最后一帧」计时器并二次模糊",
    "喂点覆盖单摄 / 双摄合成 / 外部源全部场景，是唯一入口",
])

# ②
N = GX[1] + 40
d.node("b1", N, RY[0], 400, 52, "isEnabled && isStreaming", "= shouldKeepStreamingInBackground", style="cond")
d.node("b2", N, RY[1], 400, 52, "-applicationDidEnterBackground", "宿主转发生命周期")
d.node("b3", N, RY[2], 400, 52, "liveFrameRate", "宿主在开播时写入实时编码帧率")
d.node("b4", N, RY[3], 400, 52, "pipelineKeptAliveAcrossBackground", "记录上次是否跳过了拆管线")
d.node("b5", N, RY[4], 400, 52, "inBackground", "预览渲染器据此跳过渲染")
for a, b in (("b1", "b2"), ("b2", "b3"), ("b3", "b4"), ("b4", "b5")):
    d.edge(a, b, fs="b", ts="t")
d.edge("a3", "b1", fs="r", ts="l", route="hvh", gut=GX[1] - 34)
d.annot(N, AY, [
    "shouldKeepStreamingInBackground 为真时宿主不能停采集 / 关编码器 / OffAir",
    "它整个直播期间恒为真，不等于「当前在后台」——所以「跳过重新初始化」",
    "要用 pipelineKeptAliveAcrossBackground 判，否则二级页面返回会误跳编码器重启",
])

# ③
N = GX[2] + 40
d.node("c1", N, RY[0], 440, 52, "-onCapturedSampleBuffer:", "每帧真实帧都喂 · 重置计时")
d.node("c2", N, RY[1], 440, 52, "+standbyFrameRateForLiveFrameRate:", "50/60 → 25 · 25/30 → 10", style="focal")
d.node("c3", N, RY[2], 440, 52, "-startFillingWithHandler:", "起周期 tick")
d.node("c4", N, RY[3], 440, 52, "距上一真实帧超过阈值 ?", "才认定为「有缺口」", style="cond")
d.node("c5", N, RY[4], 440, 52, "-newBlurredLatestSampleBuffer", "高斯模糊一次，之后复用")
for a, b in (("c1", "c2"), ("c2", "c3"), ("c3", "c4"), ("c4", "c5")):
    d.edge(a, b, fs="b", ts="t")
d.edge("b3", "c1", fs="r", ts="l", route="hvh", gut=GX[2] - 34, label="喂真实帧")
d.annot(N, AY, [
    "50fps 直降固定 10fps 会让后台硬编停止出包，画面冻在前台最后一帧，",
    "模糊根本到不了线上（30 → 10 这种适度降幅可以）。blurRadius 默认 40，按 1920px 归一化",
    "真实帧一恢复，待机状态自动清除 —— 没有显式的「退出待机」调用",
])

# ④
N = GX[3] + 40
d.node("d1", N, RY[1], 420, 52, "PTS 持续推进", "编码器与服务端都看不到断流")
d.node("d2", N, RY[2], 420, 52, "打 SynthesizedFrameKey 标记", "kCFBooleanTrue", style="focal")
d.node("d3", N, RY[3], 420, 52, "reinjectFrameHandler(sb)", "宿主注入的 block", style="sink")
d.edge("d1", "d2", fs="b", ts="t")
d.edge("d2", "d3", fs="b", ts="t")
d.edge("c5", "d1", fs="r", ts="l", route="hvh", gut=GX[3] - 34, label="待机帧")
d.edge("d3", "a2", fs="b", ts="l", route="ring", gut=544, gut2=GX[0] + 16, style="dash", label="回灌")
d.annot(N, AY, [
    "reinjectFrameHandler 由宿主设置，内部调 sendToEncoderWithSamplebuffer ——",
    "编码器调用始终留在 TVUAnywhereSDK 里，补帧模块不直接依赖编码器",
    "回灌帧走完整 M4 链路（含 Overlay 判断），只是喂点那一步被 key 挡掉",
])

# ⑤
N = GX[1] + 40
d.node("e1", N, R2[0], 420, 52, "showPiPEnabled", "用户设置 · 默认 YES", style="cond")
d.node("e2", N, R2[1], 420, 52, "-updatePictureInPictureState", "设置或推流状态变了就重评")
d.node("e3", N + 500, R2[0], 420, 52, "TVUSampleBufferDisplayView", "裸 display layer 宿主视图")
d.node("e4", N + 500, R2[1], 420, 52, "系统 PiP 窗口", "宿主没挂就自己挂到 keyWindow 离屏", style="sink")
d.edge("e1", "e2", fs="b", ts="t")
d.edge("e2", "e3", fs="r", ts="l", route="hvh", gut=N + 460)
d.edge("e3", "e4", fs="b", ts="t")
d.edge("b5", "e1", fs="b", ts="t", style="dash", label="进后台")
d.edge("c5", "e3", fs="b", ts="t", route="vhv", gut=536, style="dash", label="待机画面")
d.annot(GX[1] + 40, A2Y, [
    "Plan A：相机在后台继续出帧 → PiP 显示实时画面",
    "Plan B：相机冻帧 → PiP 显示模糊的待机画面（同一个 display layer）",
    "停 PiP 时用 newBlurredLatestSampleBuffer 把画面冻在一张模糊帧上",
    "后台时预览渲染器要跳过渲染：预览不可见，PiP 从专用层取，渲染是白费 GPU",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "条件判断"),
    ("box", "focal", "关键取舍"), ("box", "sink", "出口"),
    ("line", "solid", "同线程调用"), ("line", "dash", "回灌 / 条件性"),
]

cards = [
    card("A / B 双方案的降级", "coral", "没有显式的权限探测",
         ["补帧器只在「新帧停止到达」时才介入 —— 所以 Plan A → Plan B 是自然降级",
          "不需要先查 multitasking camera access 权限，也不需要设备白名单",
          "真实帧恢复后待机状态自动清除，同样没有显式切换",
          "两个方案共用同一个 display layer，PiP 侧无感"]),
    card("补帧率为什么必须跟着降", "ink", "降幅过大后台硬编直接停摆",
         ["50 / 60 fps → 25；25 / 30 fps → 10；低于 25fps 用原速率，上限 10（从不上调）",
          "50fps 直降固定 10fps：后台硬件编码器停止出包，画面冻在前台最后一帧",
          "结果是模糊帧根本到不了线上 —— 看起来像「补帧没生效」",
          "宿主要在<strong>进后台之前</strong>写好 <code>liveFrameRate</code>"]),
    card("防止模糊叠加的那个标记", "muted", "回灌帧必须被喂点识别出来",
         ["合成帧带 <code>kTVUBackgroundStreamingSynthesizedFrameKey</code>",
          "喂点用 <code>CMGetAttachment</code> 查到就跳过 <code>enqueueCameraSampleBuffer:</code>",
          "不跳过的话：重置「最后一帧」计时器 + 在已模糊的帧上再模糊一次",
          "回灌帧仍走完整 M4 链路，只是不再进喂点"]),
]

write(OUT, d, "Call graph · 方法级 M8", "后台推流补帧与画中画 — 一个方法一个盒子",
      "编码器拿到的那一帧同时驱动画中画和补帧器。橙色是三处关键取舍：喂点位置、"
      "补帧率降档、合成帧标记。虚线是回灌路径。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ bc4021368 · 2026-08-24 · Diagram Design 2.6.1")
