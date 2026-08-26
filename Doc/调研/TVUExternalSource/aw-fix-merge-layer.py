# -*- coding: utf-8 -*-
"""三件事：
① 删掉 SortQueueManager 容器右半那批 dev1 上不存在的方法名（pushSample:andPtsOffset: 等）
② 补上合流层 TVUAVStreamManager（四线程）+ 真实编码器 + 真实出口
③ 把相机带两个终点接进合流层，让三路汇入在同一张图上连通

全部依据（dev1 / share-SPAR-705 实际代码）：
  TVUExternalSourceSortQueueManager.mm:279  sortThread → AddBufferToWorkQueue(m_total_queue[TVUExternalQueue])
  TVUAVStreamManager.mm:3177-3186           四线程 Handle / Encoder / Render / AutoPan
  TVUAVStreamManager.mm:2050 / :2173        renderWithSamplebuffer() → [preview displaySampleBuffer:]
  TVUAVStreamManager.mm:2322 / :2389/:2451  encoderWithSamplebuffer() → Agora / encode:
  TVUAVStreamManager.mm:2460                sendToEncoderWithSamplebuffer()（相机直通入口）
  TVUVideoEncoderManager.h:64               encode:isNeedKeyFrame:externalSourceIndex:
  04 文档 §2.4/§3.1                          AVFormatController / TVULiveMediaCenter / CTVUTransporterT
  07 文档 §7                                 音频四路出口真实命名
"""
import json, io, unicodedata

PATH = "/Users/tvum4pro/Documents/github/WorkLabs/Doc/调研/TVUExternalSource/aw.excalidraw.json"
B62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

doc = json.load(io.open(PATH, encoding="utf-8"))
els = doc["elements"]
by = {e["id"]: e for e in els}

# ============ ① 删除：dev1 不存在的方法名那一段 ============
DEAD_TEXTS = [
    "[TVUExternalSourceConfig manager].renderView", "pushRenderSampleBuffer:",
    "送到渲染视图", "TVUVideoEncoderManager\npushSample:andPtsOffset:sourceType:",
    "consumePixelBuffer:", "送入 agora", "h264", "h265",
    "pushSample:andPtsOffset:", "encode", "Record Video", "传输",
    "TVURecordManager::manager()->addSampleData(sample)",
    "FormatConvertMgr::getInstance()->addSampleData(sample)",
    # 之前加的入口汇总注释，合流层画出来后冗余
    "入口汇总（三路汇入同一编码器）：",
    "  · 外部源 → SortQueue → 处理 node（本容器左侧）",
    "  · 相机合流 → TVUCameraQueue → 合流层四线程",
    "  · 相机直通 → sendToEncoderWithSamplebuffer（跳过合流层）",
    "  详见画布最上方「架构总览」面板",
]

kill = set()
for e in els:
    # 位置约束：只清 y>400 的外部源两带（总览面板 y<-800、相机带 y<210 不受影响）
    if e["type"] == "text" and e.get("text") in DEAD_TEXTS and e["y"] > 400:
        kill.add(e["id"])
        cid = e.get("containerId")
        if cid and by[cid]["type"] != "arrow":
            kill.add(cid)                       # 连带删容器方框
# 删掉与被删方框相连的箭头（及箭头上的标签）
for e in els:
    if e["type"] == "arrow":
        eps = {(e.get(k) or {}).get("elementId") for k in ("startBinding", "endBinding")}
        if eps & kill:
            kill.add(e["id"])
            for b in (e.get("boundElements") or []):
                kill.add(b["id"])
print(f"删除 {len(kill)} 个元素")

els = [e for e in els if e["id"] not in kill]
for e in els:                                   # 清理残留反向引用
    if e.get("boundElements"):
        e["boundElements"] = [b for b in e["boundElements"] if b["id"] not in kill]
    for k in ("startBinding", "endBinding"):
        if e.get(k) and e[k]["elementId"] in kill:
            e[k] = None
by = {e["id"]: e for e in els}

# ============ 就地改名：仍然存在但名字错的 ============
RENAME = {
    "TVUVideoEncoderManager\npushSample:andPtsOffset:sourceType:":
        "TVUVideoEncoderManager\nencode:isNeedKeyFrame:externalSourceIndex:",
    "FormatConvertMgr::getInstance()->addSampleData(sampledata);":
        "① AVFormatControl::addAACData（ASF）  ② TVULiveMediaCenter（帧传输）— 见 07 §7.2/7.3",
    "TVURecordManager::manager()->addSampleData(sampledata);":
        "TVUAudioRecorderManager → TVURecordMuxHandler::addAudioData / m4a — 见 07 §7.1",
}


def vw(s, fs):
    return sum(1.0 if unicodedata.east_asian_width(c) in ("W", "F") else 0.52 for c in s) * fs


renamed = 0
for e in els:
    if e["type"] == "text" and e.get("text") in RENAME:
        new = RENAME[e["text"]]
        e["text"] = e["originalText"] = new
        lines = new.split("\n")
        e["width"] = max(vw(l, e["fontSize"]) for l in lines)
        e["height"] = len(lines) * e["fontSize"] * 1.35
        renamed += 1
print(f"改名 {renamed} 处")

# SortQueueManager 容器收窄到它真正管的范围（2420 → 3600）
for e in els:
    if e["type"] == "rectangle" and abs(e["x"] - 2420) < 1 and abs(e["y"] - 560) < 1:
        e["width"] = 1180.0
        print("SortQueueManager 容器收窄至 x 2420..3600")

# ============ ②③ 追加：合流层 + 出口 + 三路汇入 ============
NEW, IDS, _n = [], {}, [0]
OLD_IDS = {e["id"] for e in els}


def frac_index(i):
    if i < 62:
        return "a" + B62[i]
    j = i - 62
    return "b" + B62[j // 62] + B62[j % 62]


def idx_ord(k):
    if len(k) == 2 and k[0] == "a":
        return B62.index(k[1])
    if len(k) == 3 and k[0] == "b":
        return 62 + B62.index(k[1]) * 62 + B62.index(k[2])
    return -1


START = max(idx_ord(e["index"]) for e in els) + 1


def nid():
    _n[0] += 1
    i = f"mrg{_n[0]:03d}K3pV7sQx2Ly"[:21]
    assert i not in OLD_IDS
    return i


def base(t, x, y, w, h, **kw):
    e = {"id": kw.pop("id", nid()), "type": t, "x": float(x), "y": float(y),
         "width": float(w), "height": float(h), "angle": 0,
         "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
         "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid",
         "roughness": 0, "opacity": 100, "groupIds": [], "frameId": None,
         "index": "a0", "roundness": None, "seed": 300000 + _n[0] * 7919,
         "version": 1, "versionNonce": 400000 + _n[0] * 104729, "isDeleted": False,
         "boundElements": [], "updated": 1787715664455, "link": None, "locked": False}
    e.update(kw)
    NEW.append(e)
    return e


def box(key, x, y, w, h, text, rounded=False, fs=16):
    r = base("rectangle", x, y, w, h, roundness={"type": 3} if rounded else None)
    lines = text.split("\n")
    tw = max(vw(l, fs) for l in lines); th = len(lines) * fs * 1.35
    t = base("text", x + (w - tw) / 2, y + (h - th) / 2, tw, th, strokeWidth=2,
             roughness=1, text=text, fontSize=fs, fontFamily=6, textAlign="center",
             verticalAlign="middle", containerId=r["id"], originalText=text,
             autoResize=True, lineHeight=1.35, boundElements=None)
    r["boundElements"].append({"type": "text", "id": t["id"]})
    IDS[key] = r
    return r


def frame(key, x, y, w, h):
    r = base("rectangle", x, y, w, h, roundness=None, strokeStyle="dashed")
    IDS[key] = r
    return r


def note(x, y, text, fs=15):
    lines = text.split("\n")
    tw = max(vw(l, fs) for l in lines); th = len(lines) * fs * 1.35
    return base("text", x, y, tw, th, strokeWidth=2, roughness=1, text=text,
                fontSize=fs, fontFamily=6, textAlign="left", verticalAlign="top",
                containerId=None, originalText=text, autoResize=True,
                lineHeight=1.35, boundElements=None)


def anchor(e, s):
    x, y, w, h = e["x"], e["y"], e["width"], e["height"]
    return {"r": (x + w, y + h / 2), "l": (x, y + h / 2),
            "t": (x + w / 2, y), "b": (x + w / 2, y + h)}[s]


def resolve(k):
    """k 可以是新建元素的 key，也可以是 ('text', 文本) 用来指向已有元素的容器。"""
    if isinstance(k, tuple):
        for e in els:
            if e["type"] == "text" and e.get("text") == k[1] and e.get("containerId"):
                return by[e["containerId"]]
        raise KeyError(k)
    return IDS[k]


def arrow(a, sa, b, sb, label=None, dashed=False, pts=None, gap=6):
    ea, eb = resolve(a), resolve(b)
    sx, sy = anchor(ea, sa); ex, ey = anchor(eb, sb)
    sx += {"r": gap, "l": -gap}.get(sa, 0); sy += {"b": gap, "t": -gap}.get(sa, 0)
    ex += {"r": gap, "l": -gap}.get(sb, 0); ey += {"b": gap, "t": -gap}.get(sb, 0)
    raw = [(sx, sy)] + (pts or []) + [(ex, ey)]
    p = [[round(px - sx, 2), round(py - sy, 2)] for px, py in raw]
    xs = [q[0] for q in p]; ys = [q[1] for q in p]
    ar = base("arrow", sx, sy, max(xs) - min(xs), max(ys) - min(ys), strokeWidth=2,
              points=p, lastCommittedPoint=None,
              strokeStyle="dashed" if dashed else "solid",
              startBinding={"elementId": ea["id"], "focus": 0, "gap": gap},
              endBinding={"elementId": eb["id"], "focus": 0, "gap": gap},
              startArrowhead=None, endArrowhead="arrow", elbowed=False,
              fixedSegments=None)
    ea.setdefault("boundElements", []).append({"id": ar["id"], "type": "arrow"})
    eb.setdefault("boundElements", []).append({"id": ar["id"], "type": "arrow"})
    if label:
        fs = 15; tw, th = vw(label, fs), fs * 1.35
        segs = [(raw[i], raw[i + 1]) for i in range(len(raw) - 1)]
        L = [((q[0] - p0[0]) ** 2 + (q[1] - p0[1]) ** 2) ** .5 for p0, q in segs]
        half = sum(L) / 2.0; mx, my = raw[0]
        for (p0, q), l in zip(segs, L):
            if half <= l or l == 0:
                r = 0 if l == 0 else half / l
                mx, my = p0[0] + (q[0] - p0[0]) * r, p0[1] + (q[1] - p0[1]) * r
                break
            half -= l
        t = base("text", mx - tw / 2, my - th / 2, tw, th, strokeWidth=2, roughness=1,
                 text=label, fontSize=fs, fontFamily=6, textAlign="center",
                 verticalAlign="middle", containerId=ar["id"], originalText=label,
                 autoResize=True, lineHeight=1.35, boundElements=None)
        ar["boundElements"].append({"type": "text", "id": t["id"]})
    return ar


# --- 外部源：sortThread 的真实出口 ---
note(3020, 848, "TVUExternalSourceSortQueueManager.mm:279")
box("xAdd", 3020, 878, 520, 66,
    "AddBufferToWorkQueue\n(m_total_queue[TVUExternalQueue])", fs=16)
arrow(("text", "处理 node"), "r", "xAdd", "l", pts=[(3000, 905)])

# --- 合流层容器 ---
note(4000, 296, "合流层 TVUAVStreamManager + 真实编码器 + 真实出口（三路汇入）", fs=20)
frame("mbox", 4000, 340, 1990, 930)

box("mIn", 4060, 820, 420, 70,
    "AddBufferToWorkQueue\n8 路队列 m_total_queue[…]", fs=16)
box("mDirect", 4060, 940, 420, 70,
    "sendToEncoderWithSamplebuffer\n（相机直通入口 mm:2460）", fs=15)

note(4560, 382, "四线程 TVUAVStreamManager.mm:3177-3186")
box("mHandle", 4560, 412, 420, 50, "Handle  startHandleThreadTask", fs=15)
box("mRender", 4560, 482, 420, 50, "Render  renderWithSamplebuffer() mm:2050", fs=15)
box("mEnc", 4560, 552, 420, 50, "Encoder encoderWithSamplebuffer() mm:2322", fs=15)
box("mPan", 4560, 622, 420, 50, "AutoPan startAutoPanThreadTask", fs=15)

box("preview", 5080, 412, 460, 50, "[preview displaySampleBuffer:]  mm:2173", fs=15)
box("agora", 5080, 482, 460, 50, "tvuConsumePixelBuffer: → Agora  mm:2389", fs=15)
box("encode", 5080, 552, 480, 70,
    "TVUVideoEncoderManager\nencode:isNeedKeyFrame:externalSourceIndex:", fs=15)
note(5080, 626, "mm:2451（LITE build 从 TVUAnywhere.mm:4407 直连此处）")

box("link1", 5080, 664, 480, 70,
    "① AVFormatController::addH264Data\n→ AVFormatHttp::Product_Data_Packet", fs=15)
box("link2", 5080, 754, 480, 70,
    "② TVULiveMediaCenter\n::muxFrameWithStremId", fs=15)
box("rec", 5080, 844, 480, 70,
    "③ TVURecordMuxHandler::addVideoData\n/ AVRecorder::recordData → .asf", fs=15)
box("net", 5080, 950, 480, 50, "CTVUTransporterT::callback_data_in（推网）", fs=15)
note(5080, 1010, "出口命名依据 04 文档 §2.4 / §3.1", fs=14)

# 合流层内部连线
for k in ("mHandle", "mRender", "mEnc", "mPan"):
    arrow("mIn", "r", k, "l", pts=[(4520, 855)])
arrow("mDirect", "r", "mEnc", "l", pts=[(4530, 975), (4530, 577)])
arrow("mRender", "r", "preview", "l")
arrow("mEnc", "r", "agora", "l", pts=[(5030, 577), (5030, 507)])
arrow("mEnc", "r", "encode", "l")
arrow("encode", "b", "link1", "t")
arrow("encode", "r", "link2", "l", pts=[(5600, 587), (5600, 789)])
arrow("encode", "r", "rec", "l", pts=[(5620, 587), (5620, 879)])
arrow("link1", "l", "net", "l", pts=[(5040, 699), (5040, 975)])

# --- 三路汇入 ---
arrow("xAdd", "r", "mIn", "l", label="外部源")
arrow(("text", "AddBufferToWorkQueue(m_total_queue[TVUCameraQueue])"), "r", "mIn", "l",
      label="相机·合流", pts=[(3700, 150), (3700, 855)])
arrow(("text", "sendToEncoderWithSamplebuffer(TVUAVStreamCamera)"), "r", "mDirect", "l",
      label="相机·直通", pts=[(3820, -264), (3820, 975)])

# --- 总览面板里的错名同步修正 ---
for e in els:
    if e["type"] == "text" and e.get("text", "").startswith("TVUVideoEncoderManager\npushSample"):
        e["text"] = e["originalText"] = "TVUVideoEncoderManager\nencode:isNeedKeyFrame:externalSourceIndex:"
        lines = e["text"].split("\n")
        e["width"] = max(vw(l, e["fontSize"]) for l in lines)

# ============ 写回 ============
for i, e in enumerate(NEW):
    e["index"] = frac_index(START + i)

doc["elements"] = els + NEW
io.open(PATH, "w", encoding="utf-8").write(json.dumps(doc, ensure_ascii=False, indent=2))

from collections import Counter
print(f"新增 {len(NEW)} 个元素 {dict(Counter(e['type'] for e in NEW))}")
print(f"总计 {len(doc['elements'])} 个")
