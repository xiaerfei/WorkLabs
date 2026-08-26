# -*- coding: utf-8 -*-
"""把本地相机采集链路（Q7/Q8）追加进 aw.excalidraw.json。

追加式 —— 读入现有文件、只往后加元素，不重建、不动已有元素（含手工编辑）。
index 从现有最大值之后继续；规则见 aw-generator.py 里 frac_index 的注释。
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
    """把 index 字符串还原成序号，用于接着现有最大值往后排。"""
    if len(k) == 2 and k[0] == "a":
        return B62.index(k[1])
    if len(k) == 3 and k[0] == "b":
        return 62 + B62.index(k[1]) * 62 + B62.index(k[2])
    return -1


START = max(idx_ord(e["index"]) for e in OLD) + 1


def nid():
    _n[0] += 1
    i = f"cam{_n[0]:03d}L7mQ2vXk9Pd"[:21]
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
         "index": "a0", "roundness": None, "seed": 500000 + _n[0] * 7919,
         "version": 1, "versionNonce": 700000 + _n[0] * 104729, "isDeleted": False,
         "boundElements": [], "updated": 1787715664455, "link": None, "locked": False}
    e.update(kw)
    NEW.append(e)
    return e


def box(key, x, y, w, h, text, rounded=True, fs=20, shape="rectangle"):
    r = base(shape, x, y, w, h, roundness={"type": 3} if rounded else None)
    lines = text.split("\n")
    tw = max(vw(l, fs) for l in lines); th = len(lines) * fs * 1.35
    t = base("text", x + (w - tw) / 2, y + (h - th) / 2, tw, th, strokeWidth=2,
             roughness=1, text=text, fontSize=fs, fontFamily=6, textAlign="center",
             verticalAlign="middle", containerId=r["id"], originalText=text,
             autoResize=True, lineHeight=1.35, boundElements=None)
    r["boundElements"].append({"type": "text", "id": t["id"]})
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


# =============== 相机带布局（负 y，位于外部源两带之上）===============
note(-212, -640, "本地相机采集链路（Q7 会话生命周期 / Q8 回调链）", fs=20)

# --- 主链 y = -231 ---
note(-212, -268, "TVUCameraManager")
box("out", -212, -231, 250, 62, "AVCaptureVideoDataOutput")

note(150, -268, "TVUCameraManager.mm:1915")
box("cbOut", 150, -231, 350, 62, "captureOutput:\ndidOutputSampleBuffer:", fs=18)

note(560, -418, "#if _TVUSDKPartyline —— delegate 根本不调")
box("plConsume", 560, -381, 280, 54, "tvuConsumePixelBuffer:", fs=18)

note(560, -268, "TVUAnywhere.mm:4375")
box("cbDlg", 560, -231, 380, 62, "tvuCaptureOutput:\ndidOutputSampleBuffer:", fs=18)

box("gate1", 1000, -250, 280, 100, "audioIsReady &&\nvideoIsReady ?",
    rounded=False, fs=17, shape="diamond")
note(970, -448, "两个裸全局 bool（TVUAnywhere.mm:127-128）")
note(970, -422, "只有音频侧有模拟器豁口，视频侧没有")
box("drop1", 970, -381, 300, 54, "丢帧 · videoIsReady = YES", fs=17)

box("gate2", 1350, -250, 270, 100, "CMSampleBuffer\nDataIsReady ?",
    rounded=False, fs=17, shape="diamond")
box("drop2", 1400, -381, 160, 54, "丢帧", fs=17)

note(1680, -418, "#if _TVUSDKANYWHERELITE && !_TVUIRLSDK —— 绕过合流层")
box("liteEnc", 1680, -381, 320, 54, "VideoEncoderManager encode:", fs=17)

note(1690, -268, "TVUAnywhere.mm:4417")
box("send", 1690, -231, 330, 62, "sendToEncode\nWithSampleBuffer:", fs=18)
note(1690, -152, "首行 checkUseSystemPreview() —— 每帧调用")

box("gate3", 2090, -250, 310, 100, "isOnlyBuildIn\nCameraStream ?",
    rounded=False, fs=17, shape="diamond")

# --- YES 支：直通编码 ---
note(2470, -466, "YES —— 纯内置相机")
box("objY", 2470, -429, 340, 50, "ObjTrackingManager acceptSamplebuffer:", fs=16)
box("snap", 2470, -359, 340, 50, "snapImageWithBufferRef  ← 仅此路", fs=16)
box("toEnc", 2470, -289, 470, 50, "sendToEncoderWithSamplebuffer(TVUAVStreamCamera)", fs=16)
note(2470, -228, "→ 直送编码，跳过合流层四线程")

# --- NO 支：进合流层 ---
note(2470, -122, "NO —— 多源 / 双摄 / PIP / PBP / 图片")
box("orient", 2470, -85, 430, 50, "currentOrientation = getCurrentOrientation  ← 仅此路", fs=16)
box("objN", 2470, -15, 340, 50, "ObjTrackingManager acceptSamplebuffer:", fs=16)
box("locPic", 2470, 55, 400, 50, "tvuLocalPictreRecieveSampleBuffer:  ← 仅此路", fs=16)
box("addQ", 2470, 125, 490, 50, "AddBufferToWorkQueue(m_total_queue[TVUCameraQueue])", fs=16)
note(2470, 186, "→ 合流层四线程（同 SortQueue 出口汇入编码器）")

# --- 丢帧回调支 ---
note(150, -566, "AVFoundation 丢帧 = delegate 回调太慢；唯一过载信号")
box("cbDrop", 150, -529, 350, 54, "captureOutput:didDropSampleBuffer:", fs=17)
box("logOnly", 560, -529, 280, 54, "log4cplus_error 仅打日志", fs=17)

# --- 会话生命周期小簇（Q7）---
note(-212, 60, "会话生命周期（Q7）")
box("extStart", -212, 100, 300, 62, "externalStartCaptureSession\n(ExternalSourceView.mm:533)", fs=15)
box("startSess", 150, 100, 300, 62, "startCaptureSession\n(CameraManager.mm:200)", fs=15)
note(-212, 176, "dispatch_async(TVUMainQueue) → 主线程")
note(-212, 202, "start 异步 / stop 同步 → 时序可倒置（C2）")
note(-212, 228, "startRunning 阻塞主线程；setVideoHDREnabled 在其之后 → 起流后重配 format（C3）")

# =============== 连线 ===============
arrow("out", "r", "cbOut", "l")
arrow("cbOut", "r", "plConsume", "l", dashed=True, pts=[(520, -200), (520, -354)])
arrow("cbOut", "r", "cbDlg", "l")
arrow("cbDlg", "r", "gate1", "l")
arrow("gate1", "t", "drop1", "b", label="否")
arrow("gate1", "r", "gate2", "l", label="是")
arrow("gate2", "t", "drop2", "b", label="否")
arrow("gate2", "r", "send", "l", label="是", pts=[(1650, -200), (1650, -200)])
arrow("send", "t", "liteEnc", "b", dashed=True)
arrow("send", "r", "gate3", "l")
arrow("gate3", "t", "objY", "l", label="YES", pts=[(2245, -290), (2420, -290), (2420, -404)])
arrow("objY", "b", "snap", "t")
arrow("snap", "b", "toEnc", "t")
arrow("gate3", "b", "orient", "l", label="NO", pts=[(2245, -60)])
arrow("orient", "b", "objN", "t")
arrow("objN", "b", "locPic", "t")
arrow("locPic", "b", "addQ", "t")
arrow("cbDrop", "r", "logOnly", "l")
arrow("extStart", "r", "startSess", "l")

# =============== 写回 ===============
for i, e in enumerate(NEW):
    e["index"] = frac_index(START + i)

doc["elements"] = OLD + NEW
io.open(PATH, "w", encoding="utf-8").write(json.dumps(doc, ensure_ascii=False, indent=2))

from collections import Counter
print(f"追加 {len(NEW)} 个元素 {dict(Counter(e['type'] for e in NEW))}")
print(f"总计 {len(doc['elements'])} 个（原 {len(OLD)}）")
print("index 起始:", frac_index(START), "→", frac_index(START + len(NEW) - 1))
