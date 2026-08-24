import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from callgraph import Diagram, card, write, lanes

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "M3-合流层四线程与分发.html")

GW = [420, 720, 520, 420, 440, 420]
GX, TOTW = lanes(GW, gap=68, x0=80)
NH = 52
RY = [128 + i * 68 for i in range(6)]
CY = [y + 26 for y in RY]
GT, GH, AY = 108, 560, 548

d = Diagram(TOTW, 760, "m3",
            "合流层四线程与合成分发 · 方法级调用图",
            "TVUAVStreamManager 起四条线程：handle 线程出队并按 streamType 选合成方法，"
            "双摄可走 Metal 直达绕过软合成；结果回填到编码、渲染、自动跟拍三路队列；"
            "encoder 线程出队后调 sendToEncoderWithSamplebuffer 交给编码层。")

d.group("① InitHandleAVStreamThread()   四条 pthread", GX[0], GT, GW[0], GH)
d.group("② handleThread() → handleWithSamplebuffer()   〔handle 线程〕左列为 Metal 直达旁路", GX[1], GT, GW[1], GH)
d.group("③ 按 streamType 选合成方法", GX[2], GT, GW[2], GH)
d.group("④ AddBufferToWorkQueue 回填三路", GX[3], GT, GW[3], GH)
d.group("⑤ encoderThread() → encoderWithSamplebuffer()", GX[4], GT, GW[4], GH)
d.group("⑥ renderThread() / autoPanThread()", GX[5], GT, GW[5], GH)

# ① 四条线程
N = GX[0] + 40
d.node("t1", N, RY[0], 340, NH, "startHandleThreadTask", "→ handleThread()")
d.node("t2", N, RY[1], 340, NH, "startEncoderThreadTask", "→ encoderThread()")
d.node("t3", N, RY[2], 340, NH, "startRenderThreadTask", "→ renderThread()")
d.node("t4", N, RY[3], 340, NH, "startAutoPanThreadTask", "→ autoPanThread()")
d.annot(N, AY, [
    "四条线程各有独立的 threadArray[i].mutex / cond",
    "_isSuspendAVStreamThread 为真时 pthread_cond_wait 挂起",
    "SuspendAVStreamThread() / ActiveAVStreamThread() 成对使用；",
    "进二级页面挂起、回主页恢复 —— 这对被吞过（见 M6 的预览自愈）",
])

# ② handle 线程：左列 Metal 旁路，右列主链
MB, MW = GX[1] + 40, 280           # Metal 列
MA, AW = GX[1] + 360, 340          # 主链列
d.node("h1", MA, RY[0], AW, NH, "DeQueue(OSMO / External / OSMORTMP)", "先取三个外部源队列")
d.node("h2", MA, RY[1], AW, NH, "主源为空 → return", "不消费相机队列，避免积压", style="cond")
d.node("h3", MA, RY[2], AW, NH, "DeQueue(TVUCameraQueue)", "再取相机队列")
d.node("h4", MA, RY[3], AW, NH, "DeQueue(TVUMutiCameraQueue)", "双摄第二路")
for a, b in (("h1", "h2"), ("h2", "h3"), ("h3", "h4")):
    d.edge(a, b, fs="b", ts="t")
d.edge("t1", "h1", fs="r", ts="l", label="线程体", style="cross")

d.node("g1", MB, RY[3], MW, NH, "TVUSampleBufferIsFront(sb)", "按物理身份配对前/后置", style="cond")
d.node("g2", MB, RY[4], MW, NH, "TVUMetalBeautyFilter 前置合成", "每源帧跑一次，带缓存")
d.node("g3", MB, RY[5], MW, NH, "enqueueDirectEncodeBuffer(sb)", "交付序 == 提交序 ⇒ PTS 单调", style="focal")
d.edge("g1", "g2", fs="b", ts="t")
d.edge("g2", "g3", fs="b", ts="t")
d.edge("h4", "g1", fs="l", ts="r", label="双摄且无换背景", style="dash")
d.annot(MB, AY, [
    "handleWithSamplebuffer 一轮：processTime < 10ms 就 usleep(10ms)；",
    "纯内置相机时 usleep(TVU_EMPTY_TASK_MS)。Camera 模式收到 streamSubType ==",
    "kTVUMutiCameraBackIndex 的双摄帧会整轮丢弃。clearExternalSourcePictureCacheBuffer /",
    "clearExternalSourceBackgroundCacheBuffer 只在 index 或背景填充开关变化时调。",
    "Metal 直达条件：ciPreview != NULL 且 !tvuIsReplaceBackgroundStart；预览直渲 CAMetalLayer，不进 TVURenderQueue。",
])

# ③ handlers
N = GX[2] + 40
d.node("s1", N, RY[0], 440, NH, "handleCameraStream / handleCropStream", "Camera · Crop")
d.node("s2", N, RY[1], 440, NH, "handleExternalSourceStream(node, camera_node)", "External / OSMO 的全部 PIP·PBP·Picture 变体")
d.node("s3", N, RY[2], 440, NH, "handleOSMORTMPStream(rtmp_node, camera_node)", "按 m_osmoRTMPVideoRotation 旋转")
d.node("s4", N, RY[3], 440, NH, "handleMutiCamStreamMux(back, front, …)", "双摄 NV12 软合成（回落路径）", style="focal")
d.edge("h4", "s2", fs="r", ts="l", route="hvh", gut=GX[2] - 34, label="switch")
d.annot(N, AY, [
    "handleMutiCamStreamMux 两个开关：mirrorFront（预览镜像）、",
    "rotateFront180（竖锁下抵消远端 transpose=2）",
    "所有 handler 返回 CMSampleBufferRef，调用方负责 CFRelease",
    "handleReplaceBackgroundStream / handleOSMOPIPStream 当前被注释或改道",
])

# ④ 回填三路
N = GX[3] + 40
d.node("r2", N, RY[0], 340, NH, "AddBufferToWorkQueue(…RenderQueue)", "preview_buffer 优先")
d.node("r1", N, RY[2], 340, NH, "AddBufferToWorkQueue(…EncoderQueue)", "带 streamSubType 一起入队")
d.node("r3", N, RY[4], 340, NH, "AddBufferToWorkQueue(…AutoPanQueue)", "仅 AutoPan 开启时")
d.edge("s4", "r2", fs="r", ts="l", route="hvh", gut=GX[3] - 52, foff=-12, label="预览")
d.edge("s4", "r1", fs="r", ts="l", route="hvh", gut=GX[3] - 36, toff=16, label="合成帧")
d.edge("s4", "r3", fs="r", ts="l", route="hvh", gut=GX[3] - 20, foff=12, style="dash", label="跟拍")
d.edge("g3", "r1", fs="r", ts="l", route="hvh", gut=GX[3] - 4, toff=-16, style="dash", hops=[306, 426])
d.annot(N, AY, [
    "AddBufferToWorkQueue 里顺带做三件事：",
    "g_vstarttime 首帧初始化、checkUseSystemPreview 复检、入队时丢错位帧",
    "free 队列取不到节点只打日志，帧被丢掉 —— 这是合流层唯一的丢帧点",
])

# ⑤ encoder 线程
N = GX[4] + 40
d.node("e1", N, RY[2], 360, NH, "DeQueue(TVUEncoderQueue)", "空则 usleep(10ms) return")
d.node("e2", N, RY[3], 360, NH, "sendToEncoderWithSamplebuffer(…)", "sb, streamType, streamSubType → M4", style="sink")
d.edge("e1", "e2", fs="b", ts="t")
d.edge("r1", "e1", fs="r", ts="l", style="cross", label="出队")
d.annot(N, AY, [
    "sendToEncoderWithSamplebuffer 整体包在 @autoreleasepool 里 ——",
    "C++ 线程没有 runloop 自动释放池，不包就是持续增长型泄漏",
    "调完之后 ResetWorkQueueNode(bufferNode) 归还 free 队列",
    "M4 从这里接手",
])

# ⑥ render / autoPan
N = GX[5] + 40
d.node("p1", N, RY[0], 340, NH, "DeQueue(TVURenderQueue)", "renderWithSamplebuffer()")
d.node("p2", N, RY[1], 340, NH, "needSnapImage → 截图", "shouldUseSystemPreview 决定冻不冻")
d.node("p3", N, RY[4], 340, NH, "DeQueue(TVUAutoPanQueue)", "faceTrackWithPixelbuffer:targetView:")
d.edge("p1", "p2", fs="b", ts="t")
d.edge("r2", "p1", fs="r", ts="l", style="cross", label="出队")
d.edge("r3", "p3", fs="r", ts="l", style="cross")
d.annot(N, AY, [
    "renderWithSamplebuffer 在「美颜 → 关闭」的切换窗口里会冻住自定义",
    "DisplayLayer，等系统预览顶上来，避免闪一帧非镜像画面",
    "autoPan 位移超 kTVUAutoPanThreshold 才动 panView，X / Y 交替移动",
])

d.legend = [
    ("box", "call", "方法调用"), ("box", "cond", "条件判断"),
    ("box", "focal", "两条合成路径"), ("box", "sink", "交给 M4"),
    ("line", "solid", "同线程调用"), ("line", "cross", "队列交接"), ("line", "dash", "旁路 / 可选"),
]

cards = [
    card("四条线程各守一路队列", "coral", "互不阻塞是设计目标",
         ["handle 线程：唯一会同时碰多个输入队列的线程，合成在这里做",
          "encoder 线程：只碰 TVUEncoderQueue，出队即调 sendToEncoder",
          "render 线程：只碰 TVURenderQueue，慢了只影响预览，不影响推流",
          "autoPan 线程：只碰 TVUAutoPanQueue，人脸检测慢也不拖累前三条"]),
    card("两条合成路径的分界", "ink", "Metal 直达只服务双摄",
         ["条件：<code>ciPreview != NULL</code> 且 <code>!effectsOn</code> 且双摄 streamType",
          "换背景开启 → 回落到 <code>handleMutiCamStreamMux</code>",
          "美颜已挪进 Metal 管线做前置合成，不再强制回落",
          "直达路径的预览不进 TVURenderQueue，直渲 CAMetalLayer"]),
    card("主源缺帧的处理", "muted", "宁可整轮不做，也不出半成品",
         ["OSMOPIP/PBP 主源是 OSMO 队列；ExternalSource* 是 External；OSMORTMP 是 OSMORTMP",
          "主源为空就 <code>return</code>，<strong>不消费</strong>相机队列 —— 否则相机 buffer 积压",
          "双摄模式相机帧为空同样整轮跳过",
          "过渡帧机制在这一层被硬禁用：外部源断帧没有兜底"]),
]

write(OUT, d, "Call graph · 方法级 M3", "合流层四线程与合成分发 — 一个方法一个盒子",
      "<code>TVUAVStreamManager</code> 的四条线程、14 种 streamType 到 4 组 handler 的分发、"
      "以及双摄的 Metal 直达旁路（②的左列）。橙色是两条互斥的合成路径，蓝线是队列交接。",
      cards, "TVUAnywhere iOS · share/SPAR-705 @ bc4021368 · 2026-08-24 · Diagram Design 2.6.1")
