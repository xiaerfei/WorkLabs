# -*- coding: utf-8 -*-
"""把 yuque_diagram.jpg 的内容迁移成 aw.excalidraw.json。
样式对齐原草稿：strokeColor #1e1e1e / transparent / roughness 0 / roundness type3 / fontFamily 6 / lineHeight 1.35
"""
import json, io, unicodedata

ELS = []
IDS = {}
_n = [0]

B62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def nid(tag):
    _n[0] += 1
    return f"{tag}{_n[0]:03d}xxxxxxxxxxxxxx"[:21]


def frac_index(i):
    """生成合法的 excalidraw fractional index。

    fractional-indexing 的 getIntegerLength(head)：'a' -> 键总长 2，'b' -> 3，'c' -> 4 …
    所以 62 个以内用 "a"+1 位，之后必须用 "b"+2 位（不能写成 "b0"）。
    排序上 "az" < "b00" 成立（'a' < 'b'），整体仍严格递增。
    """
    if i < 62:
        return "a" + B62[i]
    j = i - 62
    if j < 62 * 62:
        return "b" + B62[j // 62] + B62[j % 62]
    k = j - 62 * 62
    return "c" + B62[k // 3844] + B62[(k // 62) % 62] + B62[k % 62]


def vw(s, fs):
    """粗略视觉宽度：CJK/全角算 1.0em，其余算 0.52em"""
    w = 0.0
    for ch in s:
        w += 1.0 if unicodedata.east_asian_width(ch) in ("W", "F") else 0.52
    return w * fs


def base(t, x, y, w, h, **kw):
    e = {
        "id": kw.pop("id", nid("e")),
        "type": t,
        "x": float(x), "y": float(y), "width": float(w), "height": float(h),
        "angle": 0,
        "strokeColor": "#1e1e1e",
        "backgroundColor": "transparent",
        "fillStyle": "solid",
        "strokeWidth": 1,
        "strokeStyle": "solid",
        "roughness": 0,
        "opacity": 100,
        "groupIds": [],
        "frameId": None,
        "index": "a0",
        "roundness": None,
        "seed": 100000 + _n[0] * 7919,
        "version": 1,
        "versionNonce": 200000 + _n[0] * 104729,
        "isDeleted": False,
        "boundElements": [],
        "updated": 1787715664455,
        "link": None,
        "locked": False,
    }
    e.update(kw)
    ELS.append(e)
    return e


# ---------- 构件 ----------
def box(key, x, y, w, h, text, rounded=True, dashed=False, fs=20, shape="rectangle"):
    r = base(shape, x, y, w, h,
             roundness={"type": 3} if rounded else None,
             strokeStyle="dashed" if dashed else "solid")
    lines = text.split("\n")
    tw = max(vw(l, fs) for l in lines)
    th = len(lines) * fs * 1.35
    t = base("text", x + (w - tw) / 2, y + (h - th) / 2, tw, th,
             strokeWidth=2, roughness=1,
             text=text, fontSize=fs, fontFamily=6, textAlign="center",
             verticalAlign="middle", containerId=r["id"], originalText=text,
             autoResize=True, lineHeight=1.35, boundElements=None)
    r["boundElements"].append({"type": "text", "id": t["id"]})
    IDS[key] = r
    return r


def frame(key, x, y, w, h):
    r = base("rectangle", x, y, w, h, roundness=None, strokeStyle="dashed")
    IDS[key] = r
    return r


def note(x, y, text, fs=16):
    lines = text.split("\n")
    tw = max(vw(l, fs) for l in lines)
    th = len(lines) * fs * 1.35
    return base("text", x, y, tw, th, strokeWidth=2, roughness=1,
                text=text, fontSize=fs, fontFamily=6, textAlign="left",
                verticalAlign="top", containerId=None, originalText=text,
                autoResize=True, lineHeight=1.35, boundElements=None)


def cells(key, x, y, n, cw, ch, labels):
    for i in range(n):
        box(f"{key}{i}", x + i * cw, y, cw, ch, labels[i], rounded=False, fs=18)


def anchor(e, side):
    x, y, w, h = e["x"], e["y"], e["width"], e["height"]
    return {"r": (x + w, y + h / 2), "l": (x, y + h / 2),
            "t": (x + w / 2, y), "b": (x + w / 2, y + h)}[side]


def arrow(a, sa, b, sb, label=None, dashed=False, pts=None, gap=6):
    ea, eb = IDS[a], IDS[b]
    sx, sy = anchor(ea, sa)
    ex, ey = anchor(eb, sb)
    sx += {"r": gap, "l": -gap}.get(sa, 0)
    sy += {"b": gap, "t": -gap}.get(sa, 0)
    ex += {"r": gap, "l": -gap}.get(sb, 0)
    ey += {"b": gap, "t": -gap}.get(sb, 0)
    raw = [(sx, sy)] + (pts or []) + [(ex, ey)]
    p = [[round(px - sx, 2), round(py - sy, 2)] for px, py in raw]
    xs = [q[0] for q in p]; ys = [q[1] for q in p]
    ar = base("arrow", sx, sy, max(xs) - min(xs), max(ys) - min(ys),
              strokeWidth=2, points=p, lastCommittedPoint=None,
              strokeStyle="dashed" if dashed else "solid",
              startBinding={"elementId": ea["id"], "focus": 0, "gap": gap},
              endBinding={"elementId": eb["id"], "focus": 0, "gap": gap},
              startArrowhead=None, endArrowhead="arrow", elbowed=False,
              fixedSegments=None)
    ea["boundElements"].append({"id": ar["id"], "type": "arrow"})
    eb["boundElements"].append({"id": ar["id"], "type": "arrow"})
    if label:
        fs = 16
        tw, th = vw(label, fs), fs * 1.35
        # 折线中点
        segs = [(raw[i], raw[i + 1]) for i in range(len(raw) - 1)]
        L = [((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** .5 for a, b in segs]
        half = sum(L) / 2.0
        mx, my = raw[0]
        for (a, b), l in zip(segs, L):
            if half <= l or l == 0:
                r = 0 if l == 0 else half / l
                mx, my = a[0] + (b[0] - a[0]) * r, a[1] + (b[1] - a[1]) * r
                break
            half -= l
        t = base("text", mx - tw / 2, my - th / 2, tw, th, strokeWidth=2, roughness=1,
                 text=label, fontSize=fs, fontFamily=6, textAlign="center",
                 verticalAlign="middle", containerId=ar["id"],
                 originalText=label, autoResize=True, lineHeight=1.35,
                 boundElements=None)
        ar["boundElements"].append({"type": "text", "id": t["id"]})
    return ar


# ======================= 布局 =======================
# ---- 根 ----
note(20, 1035, "TVUExternalSourceParse")
box("ffmpeg", 40, 1070, 170, 62, "FFMpeg")

# ---- 视频带 ----
note(760, 436, "TVUExternalSourceQueueManager::startVideoDecodeThreadTask")
note(760, 462, "开启 Video 解码线程：videoDecodeThread --> decodeVideo")

box("admV", 330, 690, 270, 76, "TVUExternalSourceQueueManager\nmethod: addDataToDecoder")
note(800, 596, "TVUExternalSourceQueue")
note(828, 624, "video: queue")
cells("cV", 800, 700, 4, 58, 62, ["0", "1", "2", "..."])
box("deqV", 1130, 702, 150, 58, "deQueue", rounded=False)
note(1372, 636, "TVUExternalSourceVideoDecoder")
box("decV", 1400, 702, 160, 58, "decode:", rounded=False)
box("initD", 1400, 840, 160, 58, "initDecoder", rounded=False)
box("startD", 1400, 970, 160, 58, "startDecode", rounded=False)
note(1690, 636, "VideoToolbox")
box("vtdec", 1660, 702, 360, 58, "VTDecompressionSessionDecodeFrame", rounded=False)
box("didDec", 2100, 702, 220, 58, "didDecompress(......)", rounded=False)
box("procPB", 2100, 840, 220, 76, "processPixelbuffer\n处理帧: 旋转", rounded=False)
box("addD", 2100, 1000, 220, 58, "addData(......)", rounded=False)

arrow("ffmpeg", "r", "admV", "l", label="Video", pts=[(268, 1101), (268, 728)])
arrow("admV", "r", "cV0", "l", label="Node")
arrow("cV3", "r", "deqV", "l", dashed=True)
arrow("deqV", "r", "decV", "l", label="取出一个 node")
arrow("decV", "b", "initD", "t")
arrow("initD", "b", "startD", "t")
arrow("startD", "r", "vtdec", "l", pts=[(1615, 999), (1615, 731)])
arrow("vtdec", "r", "didDec", "l", dashed=True)
arrow("vtdec", "b", "deqV", "b", label="循环开始下一轮",
      pts=[(1840, 1150), (1205, 1150)])
arrow("didDec", "b", "procPB", "t")
arrow("procPB", "b", "addD", "t", label="加入队列")

# ---- SortQueueManager 容器 ----
note(2420, 520, "TVUExternalSourceSortQueueManager::sortThread")
frame("sortBox", 2420, 560, 2250, 720)

box("sortT", 2500, 800, 190, 58, "sortThread", rounded=False)
box("sortS", 2500, 930, 190, 58, "sort", rounded=False)
box("deqW", 2480, 1060, 230, 58, "deQueue(work_queue)", rounded=False)
note(2500, 1128, "获取一个 node")
box("procN", 2820, 860, 170, 90, "处理 node", rounded=False)
note(3060, 636, "[TVUExternalSourceConfig manager].renderView")
note(3060, 664, "pushRenderSampleBuffer:")
box("render", 3080, 710, 210, 54, "送到渲染视图", rounded=False)
box("vem", 3060, 960, 350, 76,
    "TVUVideoEncoderManager\npushSample:andPtsOffset:sourceType:", rounded=False)
box("cpb", 3560, 830, 240, 54, "consumePixelBuffer:", rounded=False)
note(3560, 896, "送入 agora")
note(3560, 956, "h264")
box("ps264", 3560, 990, 250, 54, "pushSample:andPtsOffset:", rounded=False)
note(3560, 1086, "h265")
box("ps265", 3560, 1120, 250, 54, "pushSample:andPtsOffset:", rounded=False)
box("encV", 3890, 1055, 150, 54, "encode", rounded=False)
note(4110, 896, "TVURecordManager::manager()->addSampleData(sample)")
box("recV", 4120, 990, 200, 54, "Record Video", rounded=False)
box("transV", 4120, 1140, 200, 54, "传输", rounded=False)
note(4110, 1212, "FormatConvertMgr::getInstance()->addSampleData(sample)")

arrow("addD", "r", "sortT", "l", dashed=True, pts=[(2400, 1029), (2400, 829)])
arrow("sortT", "b", "sortS", "t")
arrow("sortS", "b", "deqW", "t")
arrow("deqW", "r", "procN", "l", pts=[(2770, 1089), (2770, 905)])
arrow("procN", "r", "render", "l", pts=[(3040, 905), (3040, 737)])
arrow("procN", "b", "vem", "l", pts=[(2905, 1000), (3020, 1000)])
arrow("vem", "r", "cpb", "l", pts=[(3480, 998), (3480, 857)])
arrow("vem", "r", "ps264", "l", pts=[(3490, 998), (3490, 1017)])
arrow("vem", "r", "ps265", "l", pts=[(3500, 998), (3500, 1147)])
arrow("ps264", "r", "encV", "l", pts=[(3850, 1017), (3850, 1082)])
arrow("ps265", "r", "encV", "l", pts=[(3860, 1147), (3860, 1082)])
arrow("encV", "r", "recV", "l", pts=[(4080, 1082), (4080, 1017)])
arrow("encV", "r", "transV", "l", pts=[(4080, 1082), (4080, 1167)])

# ---- 音频带 ----
note(760, 1436, "TVUExternalSourceQueueManager::startAudioDecodeThreadTask")
note(760, 1462, "开启 Audio 解码线程：audioDecodeThread --> decodeAudio")

box("admA", 330, 1620, 270, 76, "TVUExternalSourceQueueManager\nmethod: addDataToDecoder")
note(800, 1526, "TVUExternalSourceQueue")
note(826, 1554, "audio: queue")
cells("cA", 800, 1630, 4, 58, 62, ["0", "1", "2", "..."])
box("deqA", 1130, 1632, 150, 58, "deQueue", rounded=False)
box("decA", 1400, 1632, 160, 58, "decode:", rounded=False)
note(1400, 1566, "TVUExternalSourceAudioDecoder")
box("acfcb", 1330, 1770, 300, 76,
    "AudioConverterFillComplexBuffer\nAudio 解码", rounded=False)
frame("maybe", 1230, 1900, 420, 260)
note(1250, 2010, "可能需要")
box("resamp", 1400, 1940, 160, 54, "重采样", rounded=False)
box("repack", 1400, 2060, 160, 54, "数据分包", rounded=False)
box("tash", 1080, 2210, 800, 76,
    "TVUAudioSampleHandle\naddAudioBuffer:andAudioBufferLenght:andAudioBufferPts:PtsOffset:",
    rounded=False)
box("calVol", 1330, 2350, 300, 54, "caculateVolumn(......) 获取音量柱", rounded=False)
box("pOne", 1010, 2480, 320, 54, "aacEncoder::pushOnechannelFrame", rounded=False)
box("pFrm", 1500, 2480, 250, 54, "aacEncoder::pushFrame", rounded=False)
box("pfad", 940, 2610, 440, 54,
    "PCMFrameList __list.pushFrameAndDouble(加入队列)", rounded=False)
box("pf", 1230, 2740, 400, 54,
    "PCMFrameList __list.pushFrame(加入队列)", rounded=False)

arrow("ffmpeg", "r", "admA", "l", label="Audio", pts=[(268, 1101), (268, 1658)])
arrow("admA", "r", "cA0", "l", label="Node")
arrow("cA3", "r", "deqA", "l", dashed=True)
arrow("deqA", "r", "decA", "l", label="取出一个 node")
arrow("decA", "b", "acfcb", "t")
arrow("acfcb", "b", "resamp", "t")
arrow("resamp", "b", "repack", "t")
arrow("repack", "b", "tash", "t")
arrow("tash", "b", "calVol", "t")
arrow("calVol", "b", "pOne", "t", pts=[(1480, 2440), (1170, 2440)])
arrow("calVol", "b", "pFrm", "t", pts=[(1480, 2440), (1625, 2440)])
arrow("pOne", "b", "pfad", "t")
arrow("pfad", "b", "pf", "t", pts=[(1160, 2700), (1410, 2700)])
arrow("pFrm", "b", "pf", "t", pts=[(1625, 2716), (1450, 2716)])

# ---- aacEncoder::doencode 容器 ----
note(1900, 2240, "aacEncoder::doencode")
frame("doenc", 1900, 2280, 2560, 600)

box("pop", 1980, 2560, 330, 54,
    "PCMFrame * pframe = __list.popFrame()", rounded=False)
box("agora", 2420, 2370, 260, 54, "push agora audio data", rounded=False)
box("encA", 2420, 2630, 260, 54, "encode audio data", rounded=False)
note(2420, 2714, "TVUAudioEncoderManager")
note(2420, 2742, "audioEncodeWithInputBuffer:inputSize:timestamp:outputBuffer:")
note(2830, 2496, "判断 encode 是否成功，连续出现错")
note(2830, 2524, "误会重启编码器")
box("succ", 2820, 2610, 240, 96, "encode success?", rounded=False,
    shape="diamond", fs=18)
note(3210, 2500, "FormatConvertMgr::getInstance()->addSampleData(sampledata);")
box("startTx", 3220, 2560, 200, 54, "开始传输", rounded=False)
box("recA", 3220, 2740, 200, 54, "Record Audio", rounded=False)
note(3210, 2818, "TVURecordManager::manager()->addSampleData(sampledata);")

arrow("pf", "r", "pop", "l", dashed=True, pts=[(1700, 2767), (1700, 2587)])
arrow("pop", "r", "agora", "l", pts=[(2370, 2587), (2370, 2397)])
arrow("pop", "r", "encA", "l", pts=[(2370, 2587), (2370, 2657)])
arrow("encA", "r", "succ", "l")
arrow("succ", "r", "startTx", "l", pts=[(3140, 2658), (3140, 2587)])
arrow("succ", "r", "recA", "l", pts=[(3140, 2658), (3140, 2767)])
arrow("succ", "b", "pop", "b", label="encode failed",
      pts=[(2940, 2880), (2145, 2880)])

# ---- 收尾：分配 index ----
for i, e in enumerate(ELS):
    e["index"] = frac_index(i)

doc = {
    "type": "excalidraw",
    "version": 2,
    "source": "https://excalidraw.com",
    "elements": ELS,
    "appState": {"gridSize": 20, "gridStep": 5, "gridModeEnabled": False,
                 "viewBackgroundColor": "#ffffff"},
    "files": {},
}
out = "/Users/tvum4pro/Documents/github/WorkLabs/Doc/调研/TVUExternalSource/aw.excalidraw.json"
io.open(out, "w", encoding="utf-8").write(json.dumps(doc, ensure_ascii=False, indent=2))

from collections import Counter
print("元素总数:", len(ELS), Counter(e["type"] for e in ELS))
print("index 递增:", all(ELS[i]["index"] < ELS[i + 1]["index"] for i in range(len(ELS) - 1)))
print("id 唯一:", len({e["id"] for e in ELS}) == len(ELS))
xs = [e["x"] for e in ELS]; ys = [e["y"] for e in ELS]
print(f"画布范围 x[{min(xs):.0f},{max(xs):.0f}] y[{min(ys):.0f},{max(ys):.0f}]")
