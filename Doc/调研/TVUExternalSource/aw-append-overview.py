# -*- coding: utf-8 -*-
"""追加①架构总览面板（高层视图，置于画布最上方）②编码器旁的入口汇总注释。

追加式：不重建、不动已有元素。复用 aw-append-camera.py 的同一套 helper 与 index 续排规则。
"""
import json, io, unicodedata

PATH = "/Users/tvum4pro/Documents/github/WorkLabs/Doc/调研/TVUExternalSource/aw.excalidraw.json"
B62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

doc = json.load(io.open(PATH, encoding="utf-8"))
OLD = doc["elements"]
OLD_IDS = {e["id"] for e in OLD}
NEW, IDS, _n = [], {}, [0]


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


START = max(idx_ord(e["index"]) for e in OLD) + 1


def nid():
    _n[0] += 1
    i = f"ovw{_n[0]:03d}R4tB8yNz6Ws"[:21]
    assert i not in OLD_IDS
    return i


def vw(s, fs):
    return sum(1.0 if unicodedata.east_asian_width(c) in ("W", "F") else 0.52 for c in s) * fs


def base(t, x, y, w, h, **kw):
    e = {"id": kw.pop("id", nid()), "type": t, "x": float(x), "y": float(y),
         "width": float(w), "height": float(h), "angle": 0,
         "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
         "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid",
         "roughness": 0, "opacity": 100, "groupIds": [], "frameId": None,
         "index": "a0", "roundness": None, "seed": 900000 + _n[0] * 7919,
         "version": 1, "versionNonce": 950000 + _n[0] * 104729, "isDeleted": False,
         "boundElements": [], "updated": 1787715664455, "link": None, "locked": False}
    e.update(kw)
    NEW.append(e)
    return e


def box(key, x, y, w, h, text, rounded=True, fs=18, dashed=False):
    r = base("rectangle", x, y, w, h, roundness={"type": 3} if rounded else None,
             strokeStyle="dashed" if dashed else "solid")
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


def note(x, y, text, fs=16):
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


def arrow(a, sa, b, sb, label=None, dashed=False, pts=None, gap=6):
    ea, eb = IDS[a], IDS[b]
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
    ea["boundElements"].append({"id": ar["id"], "type": "arrow"})
    eb["boundElements"].append({"id": ar["id"], "type": "arrow"})
    if label:
        fs = 16; tw, th = vw(label, fs), fs * 1.35
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


# ================= ① 架构总览面板（画布最上方）=================
note(-212, -1620, "架构总览 —— 所有源的汇聚关系（高层视图；下方为方法级细节）", fs=22)
frame("panel", -212, -1570, 4880, 760)

ZY = -1545
note(-150, ZY, "① 源（视频源同一时刻互斥）", fs=18)
note(1180, ZY, "② 前置汇聚", fs=18)
note(2400, ZY, "③ 编码收口", fs=18)
note(3560, ZY, "④ 出口", fs=18)

# --- 源 ---
SRC = [
    ("s1", "内置相机（单摄 / 双摄）"),
    ("s2", "外部源 本地文件 / RTSP / 组播"),
    ("s3", "DJI RTMP"),
    ("s4", "Accsoon USB"),
    ("s5", "静态图片"),
    ("s6", "屏幕录制（跨进程 Peertalk）"),
    ("s7", "会议 / Partyline / 朗读（仅音频）"),
]
for i, (k, t) in enumerate(SRC):
    box(k, -150, -1500 + i * 60, 420, 48, t, fs=16)
note(-150, -1076, "源清单见 05-多源采集入队 §二；索引互斥见 §七", fs=15)

# --- ② 前置汇聚 ---
box("mergeV", 1150, -1470, 400, 84,
    "TVUAVStreamManager 合流层\n8 路队列 + 四线程", fs=17)
box("mixA", 1150, -1250, 400, 84,
    "3 个前置混音器 + 2 个二次混音队列\n（外部源 / Overlay / 屏录 · WebRTC / PartyLine）", fs=14)
note(1150, -1370, "纯相机 isOnlyBuildInCameraStream → 跳过②", fs=15)
note(1150, -1344, "#if _TVUSDKANYWHERELITE → 跳过②③", fs=15)

# --- ③ 编码收口 ---
box("encV", 2400, -1470, 460, 84,
    "TVUVideoEncoderManager\npushSample:andPtsOffset:sourceType:", fs=16)
box("encA", 2400, -1250, 460, 84,
    "TVUAudioEncoderManager\nencode: → AAC-LC 128k", fs=16)
note(2400, -1370, "两个独立漏斗：视频一个、音频一个", fs=15)
note(2400, -1344, "音频侧是全 app 唯一收口（见 07 文档）", fs=15)

# --- ④ 出口 ---
box("outV", 3560, -1470, 380, 84,
    "渲染视图 / Agora / 传输 / 录制\n(pushRenderSampleBuffer / consumePixelBuffer)", fs=14)
box("outA", 3560, -1250, 380, 84,
    "传输 / 录制 / Agora\n(FormatConvertMgr · TVURecordManager)", fs=14)

# --- 汇聚连线：六源扇入，gutter 逐条错开，让扇形可见 ---
for i, k in enumerate(["s1", "s2", "s3", "s4", "s5", "s6"]):
    y = -1500 + i * 60 + 24
    g = 880 + i * 26
    arrow(k, "r", "mergeV", "l", pts=[(g, y), (g, -1428)])
arrow("s7", "r", "mixA", "l", pts=[(1040, -1116), (1040, -1208)])
note(300, -1050, "①中每个源同时也向②音频侧供流（此处只画会议/朗读一条以免过密）", fs=15)

arrow("mergeV", "r", "encV", "l")
arrow("mixA", "r", "encA", "l")
arrow("encV", "r", "outV", "l")
arrow("encA", "r", "outA", "l")

# --- 旁路区：走面板下部空白，不压主干文字 ---
note(-150, -1006, "旁路（跳过前置汇聚）", fs=17)
arrow("s1", "r", "encV", "l", dashed=True, label="纯相机直通",
      pts=[(560, -1476), (560, -960), (2340, -960), (2340, -1428)])
arrow("s1", "r", "outV", "l", dashed=True, label="#if LITE 绕过②③",
      pts=[(480, -1476), (480, -900), (3500, -900), (3500, -1428)])

# ================= ② 编码器旁的入口汇总注释 =================
# vem = TVUVideoEncoderManager 框，位于 SortQueueManager 容器内 (3060,960,350,76)
note(3060, 1102, "入口汇总（三路汇入同一编码器）：", fs=15)
note(3060, 1126, "  · 外部源 → SortQueue → 处理 node（本容器左侧）", fs=15)
note(3060, 1150, "  · 相机合流 → TVUCameraQueue → 合流层四线程", fs=15)
note(3060, 1174, "  · 相机直通 → sendToEncoderWithSamplebuffer（跳过合流层）", fs=15)
note(3060, 1198, "  详见画布最上方「架构总览」面板", fs=15)

# ================= 写回 =================
for i, e in enumerate(NEW):
    e["index"] = frac_index(START + i)

doc["elements"] = OLD + NEW
io.open(PATH, "w", encoding="utf-8").write(json.dumps(doc, ensure_ascii=False, indent=2))

from collections import Counter
print(f"追加 {len(NEW)} 个元素 {dict(Counter(e['type'] for e in NEW))}")
print(f"总计 {len(doc['elements'])} 个（原 {len(OLD)}）")
print("index:", frac_index(START), "→", frac_index(START + len(NEW) - 1))
