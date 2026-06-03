#include <metal_stdlib>
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
