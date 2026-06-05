#include <metal_stdlib>
#include "WLMetalShaderTypes.h"
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertexShader(uint vid [[vertex_id]],
                              constant float *vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = float4(vertices[vid * 4], vertices[vid * 4 + 1], 0.0, 1.0);
    out.texCoord = float2(vertices[vid * 4 + 2], vertices[vid * 4 + 3]);
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> texture [[texture(0)]],
                               texture2d<float, access::sample> cbCrTexture [[texture(1)]],
                               constant bool &isYUV [[buffer(0)]],
                               constant bool &isFullRange [[buffer(1)]]) {
    constexpr sampler s(coord::normalized, filter::linear);

    if (isYUV) {
        float y = texture.sample(s, in.texCoord).r;
        float2 cbcr = cbCrTexture.sample(s, in.texCoord).rg;

        float cb = cbcr.x - 0.5;
        float cr = cbcr.y - 0.5;

        float r, g, b;
        if (isFullRange) {
            r = y + 1.402 * cr;
            g = y - 0.344 * cb - 0.714 * cr;
            b = y + 1.772 * cb;
        } else {
            r = 1.164 * (y - 0.0625) + 1.793 * cr;
            g = 1.164 * (y - 0.0625) - 0.213 * cb - 0.533 * cr;
            b = 1.164 * (y - 0.0625) + 2.115 * cb;
        }

        return float4(clamp(r, 0.0, 1.0),
                      clamp(g, 0.0, 1.0),
                      clamp(b, 0.0, 1.0),
                      1.0);
    } else {
        return float4(texture.sample(s, in.texCoord).rgb, 1.0);
    }
}

// 基础视频滤镜：复用上面的 vertexShader（全屏 quad + 已含 v-flip 的 texCoord）。
// 镜像 = 翻转采样坐标；裁剪 = 把全屏 [0,1] 采样坐标 remap 到输入子区间（输出 buffer 已按裁剪后尺寸建，故 quad 仍铺满）。
// 颜色校正顺序对齐 CIColorControls：saturation → contrast → brightness；hue 用 YIQ 旋转对齐 CIHueAdjust。
fragment float4 filterFragment(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> tex0 [[texture(0)]],
                               texture2d<float, access::sample> tex1 [[texture(1)]],
                               constant WLFilterParams &p [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);

    float2 uv = in.texCoord;
    // 镜像（自反：正逆同式）
    if (p.hMirror != 0) uv.x = 1.0 - uv.x;
    if (p.vMirror != 0) uv.y = 1.0 - uv.y;
    // 裁剪：输出全屏 → 采样输入子区间 [cropL,1-cropR] × [cropT,1-cropB]
    uv.x = mix(p.cropL, 1.0 - p.cropR, uv.x);
    uv.y = mix(p.cropT, 1.0 - p.cropB, uv.y);

    float3 rgb;
    if (p.isYUV != 0) {
        float y = tex0.sample(s, uv).r;
        float2 cbcr = tex1.sample(s, uv).rg;
        float cb = cbcr.x - 0.5;
        float cr = cbcr.y - 0.5;
        if (p.isFullRange != 0) {
            rgb = float3(y + 1.402 * cr,
                         y - 0.344 * cb - 0.714 * cr,
                         y + 1.772 * cb);
        } else {
            float yy = 1.164 * (y - 0.0625);
            rgb = float3(yy + 1.793 * cr,
                         yy - 0.213 * cb - 0.533 * cr,
                         yy + 2.115 * cb);
        }
    } else {
        rgb = tex0.sample(s, uv).rgb;
    }

    // 颜色校正：saturation → contrast → brightness（luma 用 Rec.709）
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, p.saturation);
    rgb = (rgb - 0.5) * p.contrast + 0.5;
    rgb = rgb + p.brightness;

    // 色相旋转（YIQ 空间，luma 保持）
    if (p.hueRadians != 0.0) {
        // column-major：float3x3(col0, col1, col2)
        const float3x3 rgb2yiq = float3x3(float3(0.299,    0.595716,  0.211456),
                                          float3(0.587,   -0.274453, -0.522591),
                                          float3(0.114,   -0.321263,  0.311135));
        const float3x3 yiq2rgb = float3x3(float3(1.0,      1.0,       1.0),
                                          float3(0.9563,  -0.2721,   -1.1070),
                                          float3(0.6210,  -0.6474,    1.7046));
        float3 yiq = rgb2yiq * rgb;
        float c = cos(p.hueRadians);
        float sn = sin(p.hueRadians);
        float i2 = yiq.y * c - yiq.z * sn;
        float q2 = yiq.y * sn + yiq.z * c;
        rgb = yiq2rgb * float3(yiq.x, i2, q2);
    }

    rgb = clamp(rgb, 0.0, 1.0);
    return float4(rgb, 1.0);
}

struct BorderVertexOut {
    float4 position [[position]];
};

vertex BorderVertexOut borderVertexShader(uint vid [[vertex_id]],
                                          constant float *vertices [[buffer(0)]],
                                          constant float &borderWidth [[buffer(1)]],
                                          constant float *viewSize [[buffer(2)]]) {
    BorderVertexOut out;

    float2 pos = float2(vertices[vid * 2], vertices[vid * 2 + 1]);

    float2 pixelPos = (pos + 1.0) * 0.5 * float2(viewSize[0], viewSize[1]);

    float2 center = float2(viewSize[0], viewSize[1]) * 0.5;
    float2 dir = normalize(pixelPos - center);

    float2 offset = dir * borderWidth;
    pixelPos += offset;

    float2 ndcPos = pixelPos / float2(viewSize[0], viewSize[1]) * 2.0 - 1.0;
    out.position = float4(ndcPos, 0.0, 1.0);

    return out;
}

fragment float4 borderFragmentShader(BorderVertexOut in [[stage_in]]) {
    return float4(1.0, 0.0, 0.0, 1.0);
}
