# M 系列图的生成器

M 系列（方法级调用图）不是手写 SVG，是脚本生成的 —— 这个密度手摆坐标必错。

```bash
cd _gen
for f in build_m*.py; do python3 "$f"; done   # 全部重生成，直接覆盖 ../M*.html
python3 build_m3.py                            # 或只重生成一张
```

九个 builder 对应九张 M 图（build_m1 … build_m9）。

## callgraph.py 提供什么

| 能力 | 说明 |
|---|---|
| `Diagram(w,h,slug,title,desc)` | 一张图。自带 accessible SVG 契约（title/desc/aria） |
| `d.group(label,x,y,w,h)` | `Class::method` 或线程的外框，标题自动加纸色遮罩 |
| `d.node(id,x,y,w,h,title,sub,style,tag)` | 一个方法盒子。style: `call` / `cond` / `queue` / `focal` / `sink` / `drop` / `ext` |
| `d.edge(a,b,label,style,fs,ts,route,gut,gut2,hops,…)` | 箭头。`route`: `straight` / `hvh` / `vhv` / `hv` / `vh` / `ring`（底部通道回边），圆角肘弯自动算 |
| `hops=[y,…]` | 在竖腿上跳过另一条横线（跨线不相交） |
| `d.annot(x,y,lines)` | 框底浮动注释（放调用表达式与约束） |
| `d.queue_cells(x,y,n)` | 队列格子可视化 |
| `lanes(widths,gap,x0)` | 算一排外框的 x 坐标 |

## 自带校验（`d.validate()`，写文件时自动跑）

- 节点互相重叠
- 箭头的任一水平/垂直腿穿过非端点盒子（`hvh`/`vhv`/`hv`/`vh`/`ring` 全覆盖）
- 组标题宽度超出外框
- 节点标题 / 副标题宽度超出盒子
- 底部注释：超出外框宽度、压到同组盒子上、掉到外框下方
- 文本里混进 HTML 标签（SVG `<text>` 里会原样显示成字符）

中英混排按 CJK≈字号、拉丁≈0.55×字号估宽。有问题会在 stdout 打 `!!` 行，但**仍会写文件** —— 自己看一眼。

> 实战体会：这套校验在这 9 张图里抓出过 20 多处问题，包括 6 处箭头从盒子背后穿过、
> 一处两个注释块叠在同一坐标、一处把音频队列接到了视频线程上。手摆坐标不可能不出错。

中英混排按 CJK≈字号、拉丁≈0.55×字号估宽。有问题会在 stdout 打 `!!` 行，但仍会写文件 —— 自己看一眼。

## 改图

改 `build_mN.py` 里的 spec（坐标常量都在文件头），重跑即可。配色和排版规则来自 `diagram-design` 插件的 style-guide，别在这里硬编码新颜色。
