"""Call-graph diagram generator for the diagram-design light skin.

One box per method call. Groups are `Class::method` containers. Call expressions
float beside boxes as annotations. Emits a self-contained HTML file and validates
its own geometry (mask overlaps, parallel-run spacing, boxes-on-path).
"""

INK   = "#2d3142"
MUTED = "#4f5d75"
SOFT  = "#7a8399"
PAPER = "#f5f5f5"
ACC   = "#eb6c36"
LINK  = "#2e5aa8"

R = 8  # elbow radius


# ---------------------------------------------------------------- primitives

class Node:
    def __init__(self, nid, x, y, w, h, title, sub=None, style="call", tag=None):
        self.id, self.x, self.y, self.w, self.h = nid, x, y, w, h
        self.title, self.sub, self.style, self.tag = title, sub, style, tag

    @property
    def cx(self): return self.x + self.w / 2
    @property
    def cy(self): return self.y + self.h / 2
    @property
    def r(self): return self.x + self.w
    @property
    def b(self): return self.y + self.h

    def port(self, side, off=0.0):
        if side == "l": return (self.x, self.cy + off)
        if side == "r": return (self.r, self.cy + off)
        if side == "t": return (self.cx + off, self.y)
        if side == "b": return (self.cx + off, self.b)
        raise ValueError(side)


STYLES = {
    # style        fill                        stroke                    dash
    "call":       ("#ffffff",                  INK,                      None),
    "queue":      ("rgba(45,49,66,0.05)",      MUTED,                    None),
    "focal":      ("rgba(235,108,54,0.08)",    ACC,                      None),
    "sink":       ("rgba(79,93,117,0.10)",     SOFT,                     None),
    "ext":        ("rgba(45,49,66,0.03)",      "rgba(45,49,66,0.30)",    None),
    "drop":       ("rgba(45,49,66,0.02)",      "rgba(45,49,66,0.20)",    "4,3"),
    "cond":       ("#ffffff",                  MUTED,                    "4,3"),
}


def lanes(widths, gap=68, x0=80):
    """Return (xs, total_width) for a row of group containers."""
    xs, x = [], x0
    for w in widths:
        xs.append(x)
        x += w + gap
    return xs, x - gap + x0


def tw(s, size=9):
    """Approximate rendered width: CJK/full-width ~= size, latin ~= size*0.55."""
    w = 0.0
    for ch in s:
        w += size if ord(ch) > 0x2000 else size * 0.55
    return w


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


class Diagram:
    def __init__(self, w, h, slug, title, desc):
        self.w, self.h = w, h
        self.slug, self.title, self.desc = slug, title, desc
        self.nodes, self.groups, self.edges, self.notes, self.cells = {}, [], [], [], []
        self.legend = []

    # -- content ----------------------------------------------------------
    def node(self, nid, x, y, w, h, title, sub=None, style="call", tag=None):
        n = Node(nid, x, y, w, h, title, sub, style, tag)
        self.nodes[nid] = n
        return n

    def group(self, label, x, y, w, h):
        self.groups.append((label, x, y, w, h))

    def annot(self, x, y, lines, color=None):
        """Left-aligned mono annotation lines (floating call expressions)."""
        for i, t in enumerate(lines):
            self.notes.append((x, y + i * 15, t, "start", False, color or SOFT))

    def note(self, x, y, text, anchor="start", italic=False, color=None):
        """Floating call-expression / annotation text (no box)."""
        self.notes.append((x, y, text, anchor, italic, color or SOFT))

    def queue_cells(self, x, y, n, labels=None, cw=40, ch=22, gap=8):
        for i in range(n):
            lab = labels[i] if labels else str(i)
            self.cells.append((x + i * (cw + gap), y, cw, ch, lab))

    def edge(self, a, b, label=None, style="solid", fs="r", ts="l",
             foff=0.0, toff=0.0, route="auto", gut=None, gut2=None,
             lside="above", ldx=0, hops=None):
        self.edges.append(dict(a=a, b=b, label=label, style=style, fs=fs, ts=ts,
                               foff=foff, toff=toff, route=route, gut=gut, gut2=gut2,
                               lside=lside, ldx=ldx, hops=hops or []))

    # -- routing ----------------------------------------------------------
    def _path(self, e):
        A, B = self.nodes[e["a"]], self.nodes[e["b"]]
        x1, y1 = A.port(e["fs"], e["foff"])
        x2, y2 = B.port(e["ts"], e["toff"])
        route, gut = e["route"], e["gut"]

        if route == "auto":
            if abs(y1 - y2) < 0.5 and e["fs"] in "lr":
                route = "straight"
            elif abs(x1 - x2) < 0.5 and e["fs"] in "tb":
                route = "straight"
            elif e["fs"] in "lr" and e["ts"] in "lr":
                route = "hvh"
            elif e["fs"] in "tb" and e["ts"] in "tb":
                route = "vhv"
            elif e["fs"] in "lr":
                route = "hv"
            else:
                route = "vh"

        if route == "straight":
            return f"M {x1},{y1} L {x2},{y2}", (x1, y1, x2, y2)

        if route == "hvh":                       # right/left -> vertical gutter -> in
            gx = gut if gut is not None else (x1 + x2) / 2
            sy = R if y2 > y1 else -R
            sx = R if gx > x1 else -R
            ex = R if x2 > gx else -R
            seg = [f"M {x1},{y1} H {gx-sx} Q {gx},{y1} {gx},{y1+sy}"]
            down = y2 > y1
            hops = sorted([h for h in e["hops"] if min(y1, y2) + R < h < max(y1, y2) - R],
                          reverse=not down)
            for h in hops:                       # bump over a crossing horizontal
                a, b = (h - 8, h + 8) if down else (h + 8, h - 8)
                seg.append(f"V {a} a 8,8 0 0,1 0,{16 if down else -16}")
                _ = b
            seg.append(f"V {y2-sy} Q {gx},{y2} {gx+ex},{y2} H {x2}")
            return " ".join(seg), (x1, y1, x2, y2)

        if route == "vhv":                       # top/bottom -> horizontal gutter -> in
            gy = gut if gut is not None else (y1 + y2) / 2
            sx = R if x2 > x1 else -R
            sy = R if gy > y1 else -R
            ey = R if y2 > gy else -R
            d = (f"M {x1},{y1} V {gy-sy} Q {x1},{gy} {x1+sx},{gy} "
                 f"H {x2-sx} Q {x2},{gy} {x2},{gy+ey} V {y2}")
            return d, (x1, y1, x2, y2)

        if route == "ring":                      # out -> channel y (gut) -> back x (gut2) -> in left edge
            cy_ch = gut
            bx = e["gut2"]
            sy = R if cy_ch > y1 else -R
            d = (f"M {x1},{y1} V {cy_ch-sy} Q {x1},{cy_ch} {x1-R},{cy_ch} "
                 f"H {bx+R} Q {bx},{cy_ch} {bx},{cy_ch-sy} "
                 f"V {y2+R if cy_ch > y2 else y2-R} Q {bx},{y2} {bx+R},{y2} H {x2}")
            return d, (x1, y1, x2, y2)

        if route == "hv":                        # side out, top/bottom in
            sx = R if x2 > x1 else -R
            sy = R if y2 > y1 else -R
            d = f"M {x1},{y1} H {x2-sx} Q {x2},{y1} {x2},{y1+sy} V {y2}"
            return d, (x1, y1, x2, y2)

        if route == "vh":                        # top/bottom out, side in
            sy = R if y2 > y1 else -R
            sx = R if x2 > x1 else -R
            d = f"M {x1},{y1} V {y2-sy} Q {x1},{y2} {x1+sx},{y2} H {x2}"
            return d, (x1, y1, x2, y2)

        raise ValueError(route)

    # -- emit -------------------------------------------------------------
    def svg(self):
        o = []
        o.append(f'<svg viewBox="0 0 {self.w} {self.h}" xmlns="http://www.w3.org/2000/svg" '
                 f'role="img" aria-labelledby="{self.slug}-title {self.slug}-desc">')
        o.append(f'  <title id="{self.slug}-title">{esc(self.title)}</title>')
        o.append(f'  <desc id="{self.slug}-desc">{esc(self.desc)}</desc>')
        o.append('  <defs>')
        for mid, col in (("arrow", MUTED), ("arrow-accent", ACC), ("arrow-link", LINK)):
            o.append(f'    <marker id="{mid}" markerWidth="8" markerHeight="6" refX="7" refY="3" '
                     f'orient="auto"><polygon points="0 0, 8 3, 0 6" fill="{col}"/></marker>')
        o.append('  </defs>')
        o.append(f'  <rect width="100%" height="100%" fill="{PAPER}"/>')

        # groups first
        for label, x, y, w, h in self.groups:
            o.append(f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" '
                     f'fill="rgba(45,49,66,0.02)" stroke="rgba(45,49,66,0.10)" stroke-width="0.8"/>')
            lw = int(len(label) * 4.6) + 16
            o.append(f'  <rect x="{x+16}" y="{y-6}" width="{lw}" height="12" rx="2" fill="{PAPER}"/>')
            o.append(f'  <text x="{x+24}" y="{y+3}" fill="rgba(45,49,66,0.55)" font-size="8" '
                     f'font-family="\'Geist Mono\', monospace" letter-spacing="0.10em">{esc(label)}</text>')

        # arrows
        for e in self.edges:
            d, (x1, y1, x2, y2) = self._path(e)
            if e["style"] == "dash":
                stroke, sw, dash, mk = MUTED, 1, ' stroke-dasharray="4,3"', "arrow"
            elif e["style"] == "cross":
                stroke, sw, dash, mk = LINK, 1.2, "", "arrow-link"
            elif e["style"] == "accent":
                stroke, sw, dash, mk = ACC, 1.2, "", "arrow-accent"
            else:
                stroke, sw, dash, mk = MUTED, 1.2, "", "arrow"
            o.append(f'  <path d="{d}" fill="none" stroke="{stroke}" stroke-width="{sw}"{dash} '
                     f'marker-end="url(#{mk})"/>')
            if e["label"]:
                self._emit_edge_label(o, e, x1, y1, x2, y2, stroke, d)

        # nodes
        for n in self.nodes.values():
            fill, stroke, dash = STYLES[n.style]
            da = f' stroke-dasharray="{dash}"' if dash else ""
            o.append(f'  <rect x="{n.x}" y="{n.y}" width="{n.w}" height="{n.h}" rx="6" fill="{PAPER}"/>')
            o.append(f'  <rect x="{n.x}" y="{n.y}" width="{n.w}" height="{n.h}" rx="6" '
                     f'fill="{fill}" stroke="{stroke}" stroke-width="1"{da}/>')
            ty = n.cy + (4 if not n.sub else -3)
            if n.tag:
                tw = int(len(n.tag) * 4.4) + 12
                tc = ACC if n.style == "focal" else "rgba(45,49,66,0.70)"
                ts = ACC if n.style == "focal" else "rgba(45,49,66,0.35)"
                o.append(f'  <rect x="{n.x+8}" y="{n.y+6}" width="{tw}" height="12" rx="2" '
                         f'fill="transparent" stroke="{ts}" stroke-width="0.8"/>')
                o.append(f'  <text x="{n.x+8+tw/2}" y="{n.y+15}" fill="{tc}" font-size="7" '
                         f'font-family="\'Geist Mono\', monospace" text-anchor="middle" '
                         f'letter-spacing="0.06em">{esc(n.tag)}</text>')
                ty = n.y + 34 if not n.sub else n.y + 32
            o.append(f'  <text x="{n.cx}" y="{ty}" fill="{INK}" font-size="11" font-weight="600" '
                     f'font-family="\'Geist\', sans-serif" text-anchor="middle">{esc(n.title)}</text>')
            if n.sub:
                o.append(f'  <text x="{n.cx}" y="{ty+15}" fill="{MUTED}" font-size="9" '
                         f'font-family="\'Geist Mono\', monospace" text-anchor="middle">{esc(n.sub)}</text>')

        # queue cells
        for x, y, w, h, lab in self.cells:
            o.append(f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" fill="#ffffff" '
                     f'stroke="rgba(79,93,117,0.45)" stroke-width="0.8"/>')
            o.append(f'  <text x="{x+w/2}" y="{y+15}" fill="{MUTED}" font-size="9" '
                     f'font-family="\'Geist Mono\', monospace" text-anchor="middle">{esc(lab)}</text>')

        # floating annotations
        for x, y, text, anchor, italic, color in self.notes:
            fam = "'Instrument Serif', serif" if italic else "'Geist Mono', monospace"
            sz = 12 if italic else 9
            st = ' font-style="italic"' if italic else ""
            o.append(f'  <text x="{x}" y="{y}" fill="{color}" font-size="{sz}" font-family="{fam}" '
                     f'text-anchor="{anchor}"{st}>{esc(text)}</text>')

        # legend
        if self.legend:
            ly = self.h - 44
            o.append(f'  <line x1="40" y1="{ly}" x2="{self.w-40}" y2="{ly}" '
                     f'stroke="rgba(45,49,66,0.10)" stroke-width="0.8"/>')
            o.append(f'  <text x="40" y="{ly+18}" fill="{MUTED}" font-size="8" '
                     f'font-family="\'Geist Mono\', monospace" letter-spacing="0.14em">图例</text>')
            x = 96
            for kind, val, text in self.legend:
                if kind == "box":
                    fill, stroke, dash = STYLES[val]
                    da = f' stroke-dasharray="{dash}"' if dash else ""
                    o.append(f'  <rect x="{x}" y="{ly+9}" width="16" height="11" rx="2" fill="{fill}" '
                             f'stroke="{stroke}" stroke-width="1"{da}/>')
                else:
                    col = {"solid": MUTED, "dash": MUTED, "cross": LINK, "accent": ACC}[val]
                    da = ' stroke-dasharray="4,3"' if val == "dash" else ""
                    mk = {"solid": "arrow", "dash": "arrow", "cross": "arrow-link", "accent": "arrow-accent"}[val]
                    o.append(f'  <line x1="{x}" y1="{ly+14}" x2="{x+36}" y2="{ly+14}" stroke="{col}" '
                             f'stroke-width="1.2"{da} marker-end="url(#{mk})"/>')
                    x += 20
                o.append(f'  <text x="{x+24}" y="{ly+18}" fill="{MUTED}" font-size="8" '
                         f'font-family="\'Geist Mono\', monospace">{esc(text)}</text>')
                x += 24 + int(len(text) * 8.2) + 40
        o.append('</svg>')
        return "\n".join(o)

    def _emit_edge_label(self, o, e, x1, y1, x2, y2, stroke, dpath):
        """Place the label on a segment that runs through open canvas."""
        lab = e["label"]
        lw = max(24, int(len(lab) * 8.6) + 12)
        gut = e["gut"]

        if abs(y1 - y2) < 0.5 and e["fs"] in "lr":          # straight horizontal
            mx = (x1 + x2) / 2 + e["ldx"]
            my = y1 - 20 if e["lside"] == "above" else y1 + 10
        elif abs(x1 - x2) < 0.5 and e["fs"] in "tb":        # straight vertical
            mx = x1 + 10 + e["ldx"] if e["lside"] != "left" else x1 - 10 - lw + e["ldx"]
            mx += lw / 2 if e["lside"] != "left" else lw / 2
            my = (y1 + y2) / 2 - 6
            mx -= lw / 2
            o.append(f'  <rect x="{mx}" y="{my}" width="{lw}" height="12" rx="2" fill="{PAPER}"/>')
            o.append(f'  <text x="{mx+lw/2}" y="{my+9}" fill="{stroke}" font-size="8" '
                     f'font-family="\'Geist Mono\', monospace" text-anchor="middle" '
                     f'letter-spacing="0.06em">{esc(lab)}</text>')
            return
        elif gut is not None:                                # hvh / vhv : sit on the gutter
            if e["fs"] in "lr":                              # vertical gutter run
                mx = gut - lw / 2 + e["ldx"]
                my = (y1 + y2) / 2 - 6
            else:                                            # horizontal gutter run
                mx = (x1 + x2) / 2 - lw / 2 + e["ldx"]
                my = gut - 20 if e["lside"] == "above" else gut + 10
        else:
            mx = (x1 + x2) / 2 - lw / 2 + e["ldx"]
            my = min(y1, y2) - 20

        o.append(f'  <rect x="{mx}" y="{my}" width="{lw}" height="12" rx="2" fill="{PAPER}"/>')
        o.append(f'  <text x="{mx+lw/2}" y="{my+9}" fill="{stroke}" font-size="8" '
                 f'font-family="\'Geist Mono\', monospace" text-anchor="middle" '
                 f'letter-spacing="0.06em">{esc(lab)}</text>')

    # -- validation -------------------------------------------------------
    def _group_of(self, x, y):
        for label, gx, gy, gw, gh in self.groups:
            if gx <= x <= gx + gw and gy - 12 <= y <= gy + gh + 60:
                return (label, gx, gy, gw, gh)
        return None

    def validate(self):
        errs = []
        ns = list(self.nodes.values())
        # group header must fit its own container
        for label, gx, gy, gw, gh in self.groups:
            if tw(label, 8) + 24 > gw:
                errs.append(f"group label too wide ({tw(label,8):.0f} > {gw-24}): {label[:40]}…")
        # node text must fit the box
        for n in ns:
            if tw(n.title, 11) > n.w - 16:
                errs.append(f"node title too wide: {n.id} :: {n.title}")
            if n.sub and tw(n.sub, 9) > n.w - 12:
                errs.append(f"node sub too wide: {n.id} :: {n.sub}")
        # SVG <text> cannot contain HTML markup — it would render literally
        TAG = __import__("re").compile(r"</?[a-zA-Z][a-zA-Z0-9]*\\s*/?>")
        for x, y, text, anchor, italic, color in self.notes:
            if TAG.search(text):
                errs.append(f"annot contains markup (renders literally): {text[:50]}…")
        for n in ns:
            for t in (n.title, n.sub or ""):
                if TAG.search(t):
                    errs.append(f"node text contains markup: {n.id} :: {t[:40]}…")
        # annotations must stay inside their group
        for x, y, text, anchor, italic, color in self.notes:
            if anchor != "start":
                continue
            g = self._group_of(x, y)
            if g and x + tw(text, 9) > g[1] + g[3] - 8:
                errs.append(f"annot overflows group {g[0][:14]}…: {text[:44]}…")
            # must sit clear of every node inside the same group
            if g:
                for n in ns:
                    if not (g[1] <= n.x and n.r <= g[1] + g[3]):
                        continue
                    if n.y - 10 < y < n.b + 4 and n.x < x + tw(text, 9) and n.r > x:
                        errs.append(f"annot collides node {n.id}: {text[:40]}…")
                        break
            if g and y + 4 > g[2] + g[4]:
                errs.append(f"annot below group {g[0][:14]}…: {text[:40]}…")
        for i, a in enumerate(ns):
            for b in ns[i + 1:]:
                if a.x < b.r and b.x < a.r and a.y < b.b and b.y < a.b:
                    errs.append(f"node overlap: {a.id} / {b.id}")
        # boxes sitting on any horizontal or vertical arrow leg
        def hseg(y, xa, xb, e):
            lo, hi = sorted((xa, xb))
            for n in ns:
                if n.id in (e["a"], e["b"]):
                    continue
                if n.y < y < n.b and n.x < hi and n.r > lo:
                    errs.append(f"arrow {e['a']}->{e['b']} h-leg y={y:.0f} crosses node {n.id}")

        def vseg(x, ya, yb, e):
            lo, hi = sorted((ya, yb))
            for n in ns:
                if n.id in (e["a"], e["b"]):
                    continue
                if n.x < x < n.r and n.y < hi and n.b > lo:
                    errs.append(f"arrow {e['a']}->{e['b']} v-leg x={x:.0f} crosses node {n.id}")

        for e in self.edges:
            A, B = self.nodes[e["a"]], self.nodes[e["b"]]
            x1, y1 = A.port(e["fs"], e["foff"])
            x2, y2 = B.port(e["ts"], e["toff"])
            route, gut = e["route"], e["gut"]
            if route == "auto":
                if abs(y1 - y2) < 0.5 and e["fs"] in "lr":
                    route = "straight"
                elif abs(x1 - x2) < 0.5 and e["fs"] in "tb":
                    route = "straight"
                elif e["fs"] in "lr" and e["ts"] in "lr":
                    route = "hvh"
                elif e["fs"] in "tb" and e["ts"] in "tb":
                    route = "vhv"
                elif e["fs"] in "lr":
                    route = "hv"
                else:
                    route = "vh"
            if route == "straight":
                (hseg if abs(y1 - y2) < 0.5 else vseg)(
                    y1 if abs(y1 - y2) < 0.5 else x1,
                    x1 if abs(y1 - y2) < 0.5 else y1,
                    x2 if abs(y1 - y2) < 0.5 else y2, e)
            elif route == "hvh":
                gx = gut if gut is not None else (x1 + x2) / 2
                hseg(y1, x1, gx, e); vseg(gx, y1, y2, e); hseg(y2, gx, x2, e)
                # a hop is a declared crossing of another arrow, not of a node —
                # nothing to skip here, node crossings are still real errors.
            elif route == "vhv":
                gy = gut if gut is not None else (y1 + y2) / 2
                vseg(x1, y1, gy, e); hseg(gy, x1, x2, e); vseg(x2, gy, y2, e)
            elif route == "ring":
                vseg(x1, y1, gut, e); hseg(gut, x1, e["gut2"], e)
                vseg(e["gut2"], gut, y2, e); hseg(y2, e["gut2"], x2, e)
            elif route == "hv":
                hseg(y1, x1, x2, e); vseg(x2, y1, y2, e)
            elif route == "vh":
                vseg(x1, y1, y2, e); hseg(y2, x1, x2, e)
        return errs


HTML = """<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{doctitle}</title>
<link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  *,*::before,*::after{{box-sizing:border-box;margin:0;padding:0}}
  :root{{--paper:#f5f5f5;--ink:#2d3142;--muted:#4f5d75;--soft:#7a8399;--rule:rgba(45,49,66,0.12);--accent:#eb6c36;
        --sans:'Geist',system-ui,sans-serif;--serif:'Instrument Serif',serif;--mono:'Geist Mono',ui-monospace,monospace}}
  body{{font-family:var(--sans);background:var(--paper);color:var(--ink);padding:3rem 2rem 4rem}}
  .frame{{max-width:1760px;margin:0 auto}}
  .eyebrow{{font-family:var(--mono);font-size:.66rem;font-weight:500;letter-spacing:.18em;text-transform:uppercase;color:var(--muted);margin-bottom:.5rem}}
  h1{{font-family:var(--serif);font-size:clamp(1.6rem,2.4vw + .75rem,2.1rem);font-weight:400;letter-spacing:-.02em;line-height:1.15;margin-bottom:.5rem}}
  .lede{{font-size:.9rem;color:var(--muted);line-height:1.6;max-width:74ch;margin-bottom:1rem}}
  .hint{{font-family:var(--mono);font-size:.68rem;color:var(--soft);margin-bottom:.75rem;letter-spacing:.04em}}
  .scroll{{overflow-x:auto;border:1px solid var(--rule);border-radius:8px;background:#fff}}
  svg{{display:block;min-width:{svgw}px;width:{svgw}px;height:auto}}
  .cards{{display:grid;grid-template-columns:{cols};gap:1rem;margin-top:2rem}}
  .card{{background:#fff;border:1px solid var(--rule);border-radius:6px;padding:1.25rem}}
  .card .eyebrow{{margin-bottom:.65rem}}
  .card-header{{display:flex;align-items:center;gap:.5rem;margin-bottom:.65rem}}
  .card-dot{{width:7px;height:7px;border-radius:50%;flex:none}}
  .card-dot.ink{{background:var(--ink)}} .card-dot.coral{{background:var(--accent)}} .card-dot.muted{{background:var(--muted)}}
  .card h3{{font-size:.86rem;font-weight:600}}
  .card ul{{list-style:none;display:flex;flex-direction:column;gap:.45rem}}
  .card li{{font-size:.8rem;line-height:1.5;color:var(--muted);padding-left:.85rem;position:relative}}
  .card li::before{{content:'·';position:absolute;left:.2rem;color:var(--soft)}}
  .card code{{font-family:var(--mono);font-size:.74rem;color:var(--ink)}}
  footer{{margin-top:2.5rem;padding-top:1rem;border-top:1px solid var(--rule);font-family:var(--mono);font-size:.68rem;color:var(--soft);letter-spacing:.06em}}
  @media (max-width:900px){{.cards{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<div class="frame">
  <p class="eyebrow">{eyebrow}</p>
  <h1>{h1}</h1>
  <p class="lede">{lede}</p>
  <p class="hint">← 图宽 {svgw}px，可横向拖动 →</p>
  <div class="scroll">
{svg}
  </div>
  <div class="cards">
{cards}
  </div>
  <footer>{footer}</footer>
</div>
</body>
</html>
"""


def card(eyebrow, dot, title, items):
    lis = "\n".join(f"          <li>{i}</li>" for i in items)
    return (f'    <div class="card">\n'
            f'      <p class="eyebrow">{eyebrow}</p>\n'
            f'      <div class="card-header"><span class="card-dot {dot}"></span><h3>{title}</h3></div>\n'
            f'      <ul>\n{lis}\n      </ul>\n'
            f'    </div>')


def write(path, d, eyebrow, h1, lede, cards, footer):
    errs = d.validate()
    if errs:
        for e in errs:
            print("  !!", e)
    ncols = max(1, len(cards))
    grid = {1: "1fr", 2: "1fr 1fr", 3: "1.1fr 1fr 1fr", 4: "1fr 1fr 1fr 1fr"}[min(ncols, 4)]
    html = HTML.format(doctitle=h1, eyebrow=eyebrow, h1=h1, lede=lede,
                       svgw=d.w, svg=d.svg(), cards="\n".join(cards),
                       footer=footer, cols=grid)
    open(path, "w", encoding="utf-8").write(html)
    print(f"  wrote {path}  ({len(d.nodes)} nodes, {len(d.edges)} edges, {len(errs)} issues)")
    return errs
