# 滤镜/特效 Shader 参考：LUT · 美颜 · 转场 · movit 链组装

> 摘录自知乎《我的音视频技术路线》第 3 节（ https://zhuanlan.zhihu.com/p/120855530 ，分析见[文章分析](./杂项记录/我的音视频技术路线_文章分析.md)）。
> 代码为原文照录（GLSL，明显笔误已修正并标注）；每节末尾附「WorkLabs/Metal 落地注记」——本项目预览管线已全面 Metal 化，GLSL 仅作原理参考。

---

## 1. 滤镜：查找表（LUT）

滤镜的主流实现是查找表（LUT，Look-Up Table）：设计师在 Photoshop 里调好一张表，程序端直接套用——生产流程极简，这是 LUT 统治滤镜领域的根本原因。

### 1.1 1D LUT

一维表，每个通道独立映射，只影响各自的曲线：

- 256×1：调亮度、对比度、黑白等级（单条 Gamma 曲线）；
- 256×3：RGB 三通道各一条曲线；
- Instagram 经典滤镜（amaro、lomo、Hudson、Sierra…）大量是 1D LUT。

```glsl
void main() {
    vec2 uv = gl_FragCoord.st / u_resolution;
    uv.y = 1.0 - uv.y;

    vec4 originColor = texture2D(u_texture, uv);
    vec4 texel = texture2D(u_texture, uv);
    vec3 bbTexel = texture2D(u_blowoutTex, uv).rgb;
    // 256x1：用原色值作为查表坐标
    texel.r = texture2D(u_overlayTex, vec2(bbTexel.r, texel.r)).r;
    texel.g = texture2D(u_overlayTex, vec2(bbTexel.g, texel.g)).g;
    texel.b = clamp(texture2D(u_overlayTex, vec2(bbTexel.b, texel.b)).b, 0.1, 0.9);
    // 256x3：每个通道查各自的曲线行
    vec4 mapped;
    mapped.r = texture2D(u_mapTex, vec2(texel.r, .25)).r;
    mapped.g = texture2D(u_mapTex, vec2(texel.g, .5)).g;
    mapped.b = texture2D(u_mapTex, vec2(texel.b, 0.1)).b;
    mapped.a = 1.0;

    mapped.rgb = mix(originColor.rgb, mapped.rgb, 1.0);
    gl_FragColor = mapped;
}
```

### 1.2 3D LUT

三维表：RGB 三通道的映射**相互关联**（输入是 RGB 立方体中的一个点），表现力远强于 1D。常见打包方式是把 64³ 的立方体切成 64 片 64×64，拼进一张 512×512 的 2D 纹理；采样时蓝色通道决定取哪两片，再在两片之间插值：

```glsl
void main() {
    vec2 uv = gl_FragCoord.st / u_resolution;
    uv.y = 1.0 - uv.y;
    lowp vec3 textureColor = texture2D(u_texture, uv).rgb;

    // 黑电平/范围预处理 + 各通道灰阶曲线
    textureColor = clamp((textureColor - vec3(u_levelBlack)) * u_levelRangeInv, 0.0, 1.0);
    textureColor.r = texture2D(u_grayTexture, vec2(textureColor.r, 0.5)).r;
    textureColor.g = texture2D(u_grayTexture, vec2(textureColor.g, 0.5)).g;
    textureColor.b = texture2D(u_grayTexture, vec2(textureColor.b, 0.5)).b;

    // 蓝色通道 → 切片索引（16 片 4x4 排布的版本）
    mediump float blueColor = textureColor.b * 15.0;

    mediump vec2 quad1;
    quad1.y = floor(blueColor / 4.0);
    quad1.x = floor(blueColor) - (quad1.y * 4.0);
    mediump vec2 quad2;
    quad2.y = floor(ceil(blueColor) / 4.0);
    quad2.x = ceil(blueColor) - (quad2.y * 4.0);

    // R/G 在片内定位（0.5/64 是半像素偏移，防边缘渗色）
    highp vec2 texPos1;
    texPos1.x = (quad1.x * 0.25) + 0.5 / 64.0 + ((0.25 - 1.0 / 64.0) * textureColor.r);
    texPos1.y = (quad1.y * 0.25) + 0.5 / 64.0 + ((0.25 - 1.0 / 64.0) * textureColor.g);
    highp vec2 texPos2;
    texPos2.x = (quad2.x * 0.25) + 0.5 / 64.0 + ((0.25 - 1.0 / 64.0) * textureColor.r);
    texPos2.y = (quad2.y * 0.25) + 0.5 / 64.0 + ((0.25 - 1.0 / 64.0) * textureColor.g);

    lowp vec4 newColor1 = texture2D(u_lookupTexture, texPos1);
    lowp vec4 newColor2 = texture2D(u_lookupTexture, texPos2);
    // 两片之间按蓝色小数部分插值
    lowp vec3 newColor = mix(newColor1.rgb, newColor2.rgb, fract(blueColor));

    textureColor = mix(textureColor, newColor, u_strength);   // strength 控制滤镜强度
    gl_FragColor = vec4(textureColor, 1.0);
}
```

1D vs 3D 取舍：3D 映射关联、效果和谐；1D 省空间，单通道能搞定的（纯曲线调节）用 1D。参考：https://affinityspotlight.com/article/1d-vs-3d-luts/

> **WorkLabs/Metal 落地注记**：Metal 有原生 3D 纹理（`MTLTextureType3D`）+ 硬件三线性插值，**不需要**上面"切片拼 2D + 手动双片插值"的 hack——那是 GLES 没有 3D 纹理时代的产物。把 `.cube` 文件 / PS 导出的 LUT 加载成 64³ 的 3D 纹理，shader 里一次 `sample` 即完成全部插值。`u_strength` 的 mix 保留，可直接对应滤镜强度滑杆。

---

## 2. 美颜

### 2.1 磨皮：降噪滤波器家族

磨皮本质是"保边降噪"——去掉高频噪声（毛孔瑕疵）但保住边缘（五官轮廓）。一张速查表：

| 滤波器 | 权重分布 | 特点 |
|---|---|---|
| 均值模糊 | 平均 | 最糊，无保边 |
| 高斯模糊 | 空间距离的高斯 | 平滑自然，无保边 |
| 表面模糊（surface blur） | 只看颜色差 | 保边，边缘略硬，常配肤色检测 |
| 双边滤波（bilateral） | 空间距离 × 颜色差 双高斯 | 经典磨皮，保边好 |
| 中值模糊 | 核内取中值 | 去椒盐噪声 |
| 导向滤波（guided filter） | 参考引导图 | 效果好，复杂度与核半径无关 |

双边滤波（原文 `curyolor` 笔误已改为 `curColor`）：

```glsl
vec4 BilateralFilter(vec2 uv) {
    float i = uv.x;
    float j = uv.y;
    float sigmaSSquare = 2.0 * SigmaS * SigmaS;   // 空间域 sigma
    float sigmaRSquare = 2.0 * SigmaR * SigmaR;   // 值域 sigma
    vec3 centerColor = texture2D(u_texture, uv).rgb;
    vec3 sum_up, sum_down;
    for (int k = -u_radius; k <= u_radius; k++) {
        for (int l = -u_radius; l <= u_radius; l++) {
            vec2 uv_new = uv + vec2(k, l) / u_resolution;
            vec3 curColor = texture2D(u_texture, uv_new).rgb;
            vec3 deltaColor = curColor - centerColor;
            float len = dot(deltaColor, deltaColor);
            // 空间距离与颜色距离共同决定权重：颜色差大（边缘）→ 权重小 → 保边
            float exponent = -((i-k)*(i-k) + (j-l)*(j-l)) / sigmaSSquare - len / sigmaRSquare;
            float weight = exp(exponent);
            sum_up += curColor * weight;
            sum_down += weight;
        }
    }
    return vec4(sum_up / sum_down, 1.0);
}
```

高斯模糊的关键优化：**横竖两个 pass 分离**，复杂度从 W×H×(2R+1)² 降到 W×H×2(2R+1)。

### 2.2 美白

HighPass 高亮 + 加一点红晕（原文只给思路未给码）。

### 2.3 美型（需配人脸关键点）

瘦脸/大眼/下巴都是**关键点驱动的曲线形变**：以关键点为圆心、radius 内的像素朝目标方向位移，越靠近边缘位移越小：

```glsl
vec2 curveWarp(vec2 textureCoord, vec2 originPosition, vec2 targetPosition, float radius) {
    vec2 direction = targetPosition - originPosition;
    float infect = distance(textureCoord, originPosition) / radius;
    infect = clamp(1.0 - infect, 0.0, 1.0);        // 距圆心越远影响越小
    return textureCoord - direction * infect;       // 反向偏移采样坐标
}
```

> **WorkLabs/Metal 落地注记**：双边滤波核半径直接决定每像素采样数（(2R+1)²），实时管线慎用大半径；高斯务必两 pass 分离。WorkLabs 当前滤镜（颜色校正/裁剪）不涉及这些；若将来做"摄像头美颜"，优先级应是 高斯/表面模糊 → 双边 → 导向滤波。美型依赖人脸关键点（macOS 对应 Vision framework），属另一个工程量级。

---

## 3. 转场

转场的统一范式：**shader 吃两个输入纹理 + 一个 progress（0→1）**。三类基本套路：

**① UV 变换转场**——UV 围绕某点旋转/缩放/平移，progress 驱动变换量：

```glsl
// 围绕 mid 旋转 UV（带宽高比校正）
vec2 rotateUV(vec2 uv, float rotation, vec2 mid) {
    float ratio = resolution.x / resolution.y;
    float s = sin(rotation), c = cos(rotation);
    mat2 rotationMatrix = mat2(c, -s, s, c);
    vec2 coord = vec2((uv.x - mid.x) * ratio, uv.y - mid.y);
    vec2 scaled = rotationMatrix * coord;
    return vec2(scaled.x / ratio + mid.x, scaled.y + mid.y);
}
// 围绕中心缩放
vec2 scale_uv = vec2(0.5 + (tc.x - 0.5) / scaleU, 0.5 + (tc.y - 0.5) / scaleV);
```

**② Blend 转场**——两路输入按 PS 混合模式（滤色/加深/减淡/高亮…）过渡。

**③ 模糊转场**——旋转模糊/高斯模糊/均值模糊渐入渐出。旋转模糊要配**随机采样**打散方向性条纹：

```glsl
float rand(vec2 uv) {
    return fract(sin(dot(uv.xy, vec2(12.9898, 78.233))) * 43758.5453);
}
vec4 rotation_blur(vec2 tc) {
    angle = angle * PI_ROTATION / 180.0;
    float uv_random = rand(tc);                 // 每像素随机相位，打散采样条纹
    vec4 sum_color = vec4(0.0);
    for (float i = 0.0; i < samples; i++) {
        float percent = (i + uv_random) / samples;
        float real_angle = mod(angle + percent * strength, PI_ROTATION);
        sum_color += INPUT(fract(rotateUV(tc, real_angle, center)));
    }
    return sum_color / samples;
}
```

现成转场库（GLSL，可直接移植 Metal）：**https://gl-transitions.com/**

> **WorkLabs/Metal 落地注记**：转场对应 WorkLabs 的"切源过渡"场景（如直播切换画面）。双输入 + progress 的范式可直接进 Metal fragment shader；gl-transitions 的几十个转场全是单函数 GLSL，翻译成 MSL 几乎是机械工作。

---

## 4. 特效

基础特效：抖动、灵魂出窍、故障风（glitch）、光晕、老电影、粒子。原文观点：这些"网上 Shader 到处都是，copy 下来调参数就行"（shadertoy: https://www.shadertoy.com/ ）。

找不到现成的，按这个套路自己推：

1. 善用卷积滤波器（边缘检测、模糊），必要时配随机采样；
2. 熟悉颜色空间与饱和度/锐度/亮度/色度基础调节；
3. UV 变换多写几个攒经验，理解曲线函数，基本都能调出来；
4. 再深就看论文或 OpenCV 的实现。

---

## 5. 滤镜链的串联：GPUImage vs movit【本篇核心】

### 5.1 GPUImage 范式：FBO 链

每个滤镜一个 Input/Output，通过 FBO（帧缓冲）串成链——**每个滤镜一个独立渲染 pass**，简单直观，但 N 个滤镜 = N 次完整的纹理写入/读取，带宽开销线性涨。

### 5.2 movit 范式：shader 动态组装（单 pass）

movit（ https://git.sesse.net/?p=movit;a=summary ）支持 FBO 链的全部能力（多输入、可打断中间节点、FrameBufferCache），但多一个杀手锏：**用宏把整条滤镜链拼成一个 shader，一个 pass 跑完**。每个滤镜写成 `FUNCNAME(tc)` 函数，用 `#define INPUT` 指向上一级：

```glsl
precision highp float;
varying vec2 tc;

#define FUNCNAME eff0                 // 滤镜 0：取源纹理（翻转 y）
uniform sampler2D eff0_tex;
vec4 FUNCNAME(vec2 tc) {
    return texture2D(eff0_tex, vec2(tc.x, 1.0 - tc.y));
}
#undef FUNCNAME

#define INPUT eff0                    // 滤镜 1 的输入 = 滤镜 0
#define FUNCNAME eff1                 // 滤镜 1：3D LUT（512x512 打包，64 片 8x8）
uniform float eff1_strength;
uniform sampler2D eff1_lut;
vec4 FUNCNAME(vec2 tc) {
    float strength = eff1_strength;
    lowp vec4 textureColor = INPUT(tc);          // ← 调上一级，而不是采上一级的输出纹理
    mediump float blueColor = textureColor.b * 63.0;
    mediump vec2 quad1; quad1.y = floor(floor(blueColor) / 8.0);
    quad1.x = floor(blueColor) - (quad1.y * 8.0);
    mediump vec2 quad2;
    quad2.y = floor(ceil(blueColor) / 8.0);
    quad2.x = ceil(blueColor) - (quad2.y * 8.0);
    highp vec2 texPos1;
    texPos1.x = (quad1.x * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.r);
    texPos1.y = (quad1.y * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.g);
    highp vec2 texPos2;
    texPos2.x = (quad2.x * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.r);
    texPos2.y = (quad2.y * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.g);
    lowp vec4 newColor1 = texture2D(eff1_lut, texPos1);
    lowp vec4 newColor2 = texture2D(eff1_lut, texPos2);
    lowp vec4 newColor = mix(newColor1, newColor2, fract(blueColor));
    return mix(textureColor, vec4(newColor.rgb, textureColor.w), strength);
}
#undef FUNCNAME
#undef INPUT

#define INPUT eff1                    // 出口 = 最后一级
void main() {
    gl_FragColor = INPUT(tc);
}
```

要点：滤镜之间是**函数调用**而不是"渲染到纹理再采样"——中间结果待在寄存器里，省掉整条链的纹理读写带宽。游戏引擎的 shader 变体/动态生成是同一个思想。

> **WorkLabs/Metal 落地注记**：WorkLabs 当前滤镜走 Metal、且 identity 时直接旁路（见滤镜内存高水位修复 a282ea5），单滤镜场景下无需链组装。将来滤镜可叠加（LUT + 裁剪 + 锐化…）时，movit 思路在 Metal 有三条对应路径，按工程成本排序：
> 1. **运行时拼 MSL 源码** + `newLibraryWithSource:`——和 movit 完全同构，最直接；注意编译耗时（首次毫秒级），需按滤镜组合缓存 pipeline state；
> 2. **function constants**——单一 über-shader 用编译期常量开关各滤镜段，组合数有限时最省事；
> 3. **visible functions / function stitching**（Metal 2.4+）——官方的"函数拼接"机制，最正统但 API 面更大。
> 共同收益：每帧少 N−1 次中间纹理往返，对 4K 画布的带宽节省可观。

---

## 6. 速查资源

- LUT：https://affinityspotlight.com/article/1d-vs-3d-luts/
- 转场库：https://gl-transitions.com/
- 特效灵感：https://www.shadertoy.com/
- 滤镜链框架：movit（ https://git.sesse.net/?p=movit;a=summary ）、GPUImage
- 多轨编辑：MLT（ https://github.com/mltframework/mlt ，Producer→Filter→Consumer）
